# Steering: Secure SwiftData Storage (iOS)

Dynamics SDK **15.1** provides an encrypted SwiftData backing store so
apps keep Apple's SwiftData programming model while data at rest lives
in the BlackBerry Dynamics secure container.

This is an iOS-specific migration area with no Android equivalent.
It requires **iOS 18+** and Xcode 16+. The integration is built on
SwiftData's custom `DataStore` API, which Apple introduced in iOS 18.

Do **not** invent a competing persistence API. The public substitutions
are:

```text
ModelConfiguration(...)  →  GDSecureModelConfiguration(...)
ModelContainer(...)      →  GDSecureModelContainer.create(...)
```

Downstream APIs stay stock SwiftData: `@Model`, `@Query`, `ModelContext`,
`FetchDescriptor`, `#Predicate`, `SortDescriptor`.

Official guide:
https://docs.blackberry.com/en/blackberry-dynamics-sdk/15.x/blackberry-dynamics-sdk-for-ios/blackberry-dynamics-sdk-for-ios-development-guide/integrating-optional-features/integrating-apple-swiftdata-with-your-blackberry-dynamics-app

---

## API Replacements

| Standard SwiftData API | Dynamics equivalent | Notes |
|---|---|---|
| `ModelConfiguration` | `GDSecureModelConfiguration` | Implements `DataStoreConfiguration`; iOS 18+; single-use |
| `ModelContainer(for:)` / `ModelContainer(for:configurations:)` | `GDSecureModelContainer.create(_:migrationPlan:)` | Factory returns an ordinary `ModelContainer` |
| Store teardown | `GDSecureModelContainer.eraseStore(storeURL:)` | Release the live container first |
| `@Model`, `@Query`, `ModelContext` | unchanged | Keep these |
| `VersionedSchema` / `SchemaMigrationPlan` | unchanged, passed into `create` | Plan requires the `versionedSchema:` configuration initializer |

Import surface:

```swift
import SwiftData
import BlackBerryDynamics
```

Use only cataloged public types from `14-api-provenance-and-replacement-catalog.md`.
Do not invent Dynamics wrappers around `ModelContainer` or `URLSession`.

---

## Migration Pattern

### Before

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Note.self)
    }
}
```

### After

```swift
// [BB_DYNAMICS-MIGRATION] Encrypted SwiftData store created post-authorization
import SwiftData
import BlackBerryDynamics

func onAuthorized(_ event: GDAppEvent) {
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
    }
}
```

Recommended schema grouping from day one:

```swift
import SwiftData

enum CurrentSchema: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Self.Note.self] }

    @Model final class Note {
        var title: String
        var body: String
        init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }
}

typealias Note = CurrentSchema.Note
```

Bare-models initializer (lightweight-only; list **every** `@Model` type,
including relationship targets):

```swift
let config = try GDSecureModelConfiguration(name: "MyApp",
                                            models: [Note.self, Folder.self],
                                            storeURL: storeURL)
```

---

## Hard Invariants

1. **Factory only.** `GDSecureModelContainer.create` registers schema
   metadata and runs migration. `ModelContainer` constructed directly
   from `GDSecureModelConfiguration` fails later with errors such as
   "No schema registered for entity…".
2. **Post-authorization only.** Creating the store before
   `GDAppEventAuthorized` fails because the encrypted container is
   locked.
3. **Do not attach `.modelContainer` on `App` / scene launch.** Dynamics
   owns the window; `App.body` does not re-evaluate after authorize.
   Install `.modelContainer(container)` on the post-auth root view.
4. **Single-use configuration.** Do not cache and reuse a
   `GDSecureModelConfiguration`.
5. **Separate stores from Core Data.** A Core Data stack and a SwiftData
   stack must not read/write the same secure store. Prompt 04b and 04c
   are complementary, not alternatives for the same entities.
6. **Do not rewrite SwiftData to Core Data** just to satisfy Dynamics.
   That was the 15.0 kit posture. SDK 15.1 adds the SwiftData bridge.

---

## Schema Migration

Pass plans through the factory:

```swift
let container = try GDSecureModelContainer.create(config,
                                                  migrationPlan: MyPlan.self)
```

| Schema change | Lightweight | What to do |
|---|---|---|
| Required → optional | Yes | Ship as-is |
| Drop a relationship | Yes | No automatic orphan cleanup |
| Rename with `@Attribute(originalName:)` | Yes | Always include the hint |
| Type change (`String` → `Int` / `URL`) | No | `.custom` stage |
| Optional → required with existing nulls | No | Backfill in `willMigrate` or give a default |
| New required field, no default | No | Make optional, default, or populate in `didMigrate` |
| Rename without `originalName` | No | Add the hint; this is not silent data loss |

`didMigrate` must be idempotent. Failure domain:
`GDEncryptedIncrementalStoreErrorDomain`, code `migrationFailed` (`10010`).

---

## Unsupported / Limited Features

| Feature | Status |
|---|---|
| Persistent history tracking | Not supported (same limitation as Dynamics Core Data) |
| Core Data + SwiftData on one store | Not supported |
| Batch delete | Works; not a bulk store operation |

Workarounds for history-driven patterns: `NSNotification` / Darwin
notifications; `WidgetCenter.shared.reloadAllTimelines()` after save.

---

## Optional Configuration

Set before `create(...)`:

```swift
config.relationshipPrefetchDepth = 1
config.externalBlobCachePolicy = .standard // 64 MiB cap
config.diagnosticsHandler = { event in
    print("[BB_DYNAMICS-MIGRATION] SwiftData diagnostics: \(event)")
}
```

`@Attribute(.externalStorage)` is supported. Binary values at or above
100 KiB are stored as encrypted files beside the store.

---

## Authorization Timing

```swift
func onAuthorized() {
    // [BB_DYNAMICS-MIGRATION] SwiftData stack initialized post-authorization
    let container = try GDSecureModelContainer.create(config)
    // install UI with .modelContainer(container)
}
```

**Common mistakes:**

- `.modelContainer(for:)` on `WindowGroup` / `App`
- Creating `ModelContainer` in a SwiftUI `init` or stored property that
  runs at process start
- Reusing one `GDSecureModelConfiguration` across launches/containers
- Pointing Prompt 04b's `GDPersistentStoreCoordinator` at the SwiftData
  store URL

---

## Closure Ledger Contract

For prompt-owned `secureSwiftData` call sites:

- every applicable call site must have a disposition
- `migrated` requires the factory path after authorization
- persistent-history and same-store mixing cannot be `migrated`
- `blocked` and `deferred` are non-waivable for Prompt 04c completion

Related steering:

- `42-secure-storage-coredata.md` — classic Core Data (separate stores)
- `21-authorization-deferral-patterns.md` — post-auth UI install
- `14-api-provenance-and-replacement-catalog.md` — cataloged names only
