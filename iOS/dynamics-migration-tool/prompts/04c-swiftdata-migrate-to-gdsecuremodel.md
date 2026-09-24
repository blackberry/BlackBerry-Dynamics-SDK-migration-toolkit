## Task: Migrate SwiftData to GDSecureModelContainer

Goal: Keep the app's SwiftData programming model (`@Model`, `@Query`,
`ModelContext`, `FetchDescriptor`, `#Predicate`, `SortDescriptor`) and
replace only the store configuration/factory so persistence lives in the
Dynamics secure container.

**Prerequisites**:
- Prompts 00–03b must be complete
- The analysis (Prompt 00) identified SwiftData usage

**Skip this prompt if the app does not use SwiftData.**
This is an iOS-specific migration step with no Android equivalent.
It requires Dynamics SDK **15.1** and **iOS 18+** (the integration is
built on SwiftData's custom `DataStore` API, which Apple introduced in
iOS 18).

Do **not** rewrite SwiftData models to Core Data. Prompt 04b owns classic
Core Data stacks. Prompt 04c owns SwiftData. The two stacks may coexist
in the same app only with **separate stores**.

---

## Steps

### 0. SDK Surface Verification (Mandatory)

Before making any changes, confirm the public 15.1 SwiftData types exist
in the installed SDK (CocoaPods, SPM checkout, or linked xcframework).
Search the installed product for:

```text
GDSecureModelConfiguration
GDSecureModelContainer
GDExternalBlobCachePolicy
```

Expected public surface (iOS 18+):

- `import SwiftData`
- `import BlackBerryDynamics`
- `GDSecureModelConfiguration` (replaces `ModelConfiguration`)
- `GDSecureModelContainer.create(_:migrationPlan:)` (replaces
  `ModelContainer(...)`)
- Ordinary SwiftData types after creation: `ModelContainer`,
  `ModelContext`, `@Query`, `FetchDescriptor`, `#Predicate`,
  `SortDescriptor`

If the types are absent, the project is not on Dynamics SDK 15.1. Stop
and fix Prompt 01 integration before continuing. Do **not** invent
replacement type names.

Official guide:
https://docs.blackberry.com/en/blackberry-dynamics-sdk/15.x/blackberry-dynamics-sdk-for-ios/blackberry-dynamics-sdk-for-ios-development-guide/integrating-optional-features/integrating-apple-swiftdata-with-your-blackberry-dynamics-app

### 1. Identify SwiftData Persistence Boundaries

From the Prompt 00 analysis, locate:

- `@Model` types (including relationship targets)
- `ModelConfiguration` / `ModelContainer` construction
- SwiftUI `.modelContainer(...)` on `App` / scenes / views
- `@Query`, `@Environment(\.modelContext)`, `ModelContext` usage
- `VersionedSchema` / `SchemaMigrationPlan` / `MigrationStage` /
  `@Attribute(originalName:)`
- Persistent-history APIs (`fetchHistory`, `deleteHistory`,
  `HistoryProviding`, `NSPersistentHistoryChangeRequest`)
- Any Core Data stack that would open the **same** store URL

Classify each store: enterprise-sensitive data must move onto
`GDSecureModelContainer`. Non-sensitive caches may stay native only with
an explicit `notApplicable` rationale.

### 2. Replace Configuration and Container Factory

Substitute only the store wiring. Do **not** change `@Model` classes into
`NSManagedObject`s.

```swift
// Before
let container = try ModelContainer(for: Note.self, Folder.self)
```

```swift
// After
// [BB_DYNAMICS-MIGRATION] Encrypted SwiftData store via GDSecureModelContainer
import SwiftData
import BlackBerryDynamics

let documentsURL = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
let storeURL = documentsURL.appendingPathComponent("MyApp.sqlite")
let config = try GDSecureModelConfiguration(name: "MyApp",
                                            versionedSchema: CurrentSchema.self,
                                            storeURL: storeURL)
let container = try GDSecureModelContainer.create(config)
```

**Hard rules verified against the public 15.1 API:**

1. Always use `GDSecureModelContainer.create(...)`. Never construct
   `ModelContainer(for:configurations:)` with a
   `GDSecureModelConfiguration`. Bypassing the factory skips schema
   registration and silently ignores any `SchemaMigrationPlan`.
2. Each `GDSecureModelConfiguration` is **single-use**. Create a new
   configuration for every `create(...)` call.
3. Prefer the `versionedSchema:` initializer. The bare `models:`
   initializer does **not** infer related types — list every `@Model`
   type, including relationship-only types, or init throws a
   schema/models mismatch.
4. A `migrationPlan:` argument requires the `versionedSchema:`
   initializer. Passing a plan to a bare-`models:` configuration throws
   `migrationFailed`.
5. Lightweight migration (no plan) still runs inside `create(...)` when
   `@Model` types evolve in place.

Optional knobs, set on the configuration **before** `create(...)`:

- `relationshipPrefetchDepth` (default `1`; read per fetch)
- `externalBlobCachePolicy` (default `.standard`; read once at create)
- `diagnosticsHandler` for fetch/save/migration events

To tear down a store (tests, account switch, reset), release the live
`ModelContainer` first, then call
`GDSecureModelContainer.eraseStore(storeURL:)`.

### 3. Defer Container Creation Until After Authorization

The encrypted store cannot open before Dynamics authorization.

**Forbidden (common SwiftData + SwiftUI pattern):**

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Note.self) // pre-auth + unmanaged store
    }
}
```

`App.body` will not re-evaluate after the authorized event, so attaching
the container there either creates it too early or never installs the
secure container.

**Required:** create the container in `onAuthorized` / authorized-state
handling, then install the real root UI with `.modelContainer(container)`
on that view (typically via `UIHostingController`). Keep
`WindowGroup { EmptyView() }` when Dynamics owns the window.

```swift
func onAuthorized(_ event: GDAppEvent) {
    // [BB_DYNAMICS-MIGRATION] SwiftData container created only after authorization
    do {
        let documentsURL = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask)[0]
        let storeURL = documentsURL.appendingPathComponent("MyApp.sqlite")
        let config = try GDSecureModelConfiguration(name: "MyApp",
                                                    versionedSchema: CurrentSchema.self,
                                                    storeURL: storeURL)
        let container = try GDSecureModelContainer.create(config)
        window?.rootViewController = UIHostingController(
            rootView: ContentView().modelContainer(container)
        )
    } catch {
        print("[BB_DYNAMICS-MIGRATION] Secure SwiftData container failed: \(error)")
        // Present recovery UI — do not fatalError
    }
}
```

`@Query`, `ModelContext`, inserts, fetches, and saves stay standard
SwiftData after the container exists.

### 4. Schema Migration (When the App Evolves Models)

Keep Apple's `VersionedSchema`, `SchemaMigrationPlan`, `MigrationStage`,
and `@Attribute(originalName:)`. Pass the plan through the factory:

```swift
let config = try GDSecureModelConfiguration(name: "Notes",
                                            versionedSchema: NotesSchemaV2.self,
                                            storeURL: storeURL)
let container = try GDSecureModelContainer.create(config,
                                                  migrationPlan: NotesMigrationPlan.self)
```

Lightweight (no plan) is supported for:

- widening required → optional
- dropping a relationship (no automatic orphan cleanup)
- renaming with `@Attribute(originalName:)`

Use a `.custom` stage (not lightweight) for:

- attribute type changes (`String` → `Int`, `String` → `URL`, …)
- tightening optional → required when nulls exist
- adding a new required field with no default
- renaming **without** `@Attribute(originalName:)`

`didMigrate` closures must be idempotent: if they throw, the store is
already on the destination schema and the SDK retries the closure.

Failed migration throws domain `GDEncryptedIncrementalStoreErrorDomain`
code `migrationFailed` (`10010`). Handle it at container-creation time.

### 5. Unsupported or Limited SwiftData Features

These are **not** reasons to abandon SwiftData. Record them explicitly:

| Feature | Treatment |
|---|---|
| Persistent history tracking (`fetchHistory` / `deleteHistory` / `HistoryProviding` / `NSPersistentHistoryChangeRequest`) | **Unsupported** on the secure store. Block or redesign (notifications / widget timeline reload). Do not mark as `migrated`. |
| Core Data and SwiftData on the **same** store URL | **Unsupported**. Keep separate stores. Do not point `GDPersistentStoreCoordinator` and `GDSecureModelContainer` at one file. |
| Batch delete (`ModelContext.delete(model:where:)`) | Supported but not optimized (individual deletes). Leave the API; note the performance caveat for large deletes. |

Do **not** list ordinary `@Model` / `@Query` usage as an unsupported
feature once the store is on `GDSecureModelContainer`.

### 6. Build and Runtime Verification

Run `xcodebuild` and classify failures as pre-existing, step-introduced,
or unrelated.

Runtime checklist (simulator or device, after Dynamics unlock):

1. Container creation succeeds in the authorized handler (no
   `initializationFailed` / "No schema registered for entity").
2. Insert a record, kill the app, relaunch, unlock, fetch — data
   persists.
3. SwiftUI `@Query` views render from the installed container, not from
   a launch-time `.modelContainer(for:)`.
4. If a `SchemaMigrationPlan` exists, upgrade from the previous schema
   once before calling the domain closed.

---

## Closure Ledger Update (Required)

Before recording Prompt 04c as `completed`, write call-site dispositions
for the `secureSwiftData` domain using the atomic updater:

```bash
python3 dynamics-migration-tool/tooling/update-migration-plan-state.py \
  --analysis dynamics-migration-tool/output/migration-analysis.json \
  --plan dynamics-migration-tool/output/migration-plan-state.json \
  --run-id "<run-id-from-output/bootstrap.json>" \
  --prompt-id "04c" \
  --domain-id "secureSwiftData" \
  --updates-file /tmp/secure-swiftdata-updates.json
```

Do not edit `output/migration-plan-state.json` directly.
Missing dispositions block recorder completion.

Disposition rules for this prompt:

- Every applicable `secureSwiftData` call site must be updated.
- `migrated` requires `GDSecureModelConfiguration` +
  `GDSecureModelContainer.create(...)` after authorization, with no
  remaining unmanaged `ModelContainer(` / `ModelConfiguration(` factory
  for that store.
- Persistent-history and same-store Core Data/SwiftData sites are
  `blocked` with rationale/evidence.
- `blocked` and `deferred` are non-waivable for Prompt 04c completion.

Prompt-scoped validation phases for this prompt are:
`0-artifact-provenance, 6b-secure-swiftdata`.

---

## Output

- SwiftData stores created with `GDSecureModelContainer.create(...)`
- `ModelConfiguration` replaced by `GDSecureModelConfiguration`
- Container creation moved to post-authorization
- `.modelContainer(for:)` removed from `App` / scene launch
- `@Model` / `@Query` / `ModelContext` retained
- Unsupported history / same-store mixing flagged when present
- Build and runtime verification result

See `43-secure-storage-swiftdata.md` for the full steering reference.
