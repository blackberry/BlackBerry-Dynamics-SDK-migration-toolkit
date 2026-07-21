## Task: Migrate Core Data to GDPersistentStoreCoordinator

Goal: Replace `NSPersistentStoreCoordinator` / `NSPersistentContainer`
with `GDPersistentStoreCoordinator` for encrypted Core Data storage in
the Dynamics secure container.

**Prerequisites**:
- Prompts 00-03b must be complete
- The analysis (Prompt 00) identified Core Data usage

**Skip this prompt if the app does not use Core Data.**
This is an iOS-specific migration step with no Android equivalent.

---

## Steps

### 0. SDK Header Verification (Mandatory)

Before making any changes, verify the Core Data header and confirm the
expected API:

```bash
rg "GDPersistentStoreCoordinator|GDEncryptedIncrementalStoreType|GDEncryptedBinaryStoreType" \
  Pods/BlackBerryDynamics --include="*.h" -l 2>/dev/null | head -5
```

Specifically, read the code example in `GDPersistentStoreCoordinator.h` to
confirm:
- Whether `URL` is required or optional for `addPersistentStore`
- The URL format (absolute path within secure container, e.g. `/example.bin`)
- Available store type constants

If headers are not found, run `pod install` first.

### 1. Identify Core Data Stack

From the Prompt 00 analysis, locate:
- `NSPersistentContainer` usage
- `NSPersistentStoreCoordinator` usage
- `NSManagedObjectContext` creation
- `NSPersistentStoreDescription` configuration
- Core Data model files (`.xcdatamodeld`)

### 2. Replace NSPersistentStoreCoordinator

**CRITICAL — Explicit URL Required**: Per the SDK header (`GDPersistentStoreCoordinator.h`),
the `URL` parameter must be an absolute path within the Dynamics secure file system.
Do NOT pass `nil` — it causes `EncryptedIncrementalStoreErrorDomain Code=134080`
at runtime even though it compiles cleanly.

**Two validated approaches** (pick one):

**Option A — GDFileManager documents path (recommended):**
```swift
guard let docsURL = GDFileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
    // handle error
    return
}
let secureStoreURL = docsURL.appendingPathComponent("MyModel.sqlite")
```

**Option B — Bare absolute path in secure container:**
```swift
let secureStoreURL = URL(string: "/MyModel.sqlite")!
```

**Do NOT use** `GDFileManager.default.url(for:in:appropriateFor:create:)` with
`create: true` — it crashes with `BBFileManagerErrorDomain Code=500` /
`NSPOSIXErrorDomain Code=17 "File exists"` when the Documents directory
already exists in the secure container.

```swift
// Before
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
try coordinator.addPersistentStore(
    ofType: NSSQLiteStoreType,
    configurationName: nil,
    at: storeURL,
    options: nil
)

// After
// [BB_DYNAMICS-MIGRATION] Encrypted Core Data store in Dynamics secure container
import BlackBerryDynamics.SecureStore.CoreData
import BlackBerryDynamics.SecureStore.File

let coordinator = GDPersistentStoreCoordinator(managedObjectModel: model)
guard let docsURL = GDFileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
    let err = NSError(domain: "CoreDataMigration", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Dynamics secure container documents directory not available"])
    print("[BB_DYNAMICS-MIGRATION] \(err.localizedDescription)")
    // surface the error to the caller instead of terminating the app
    throw err
}
let secureStoreURL = docsURL.appendingPathComponent("MyModel.sqlite")
// Always enable automatic lightweight migration options — required if
// the data model ever changes between app versions.
let storeOptions: [AnyHashable: Any] = [
    NSMigratePersistentStoresAutomaticallyOption: true,
    NSInferMappingModelAutomaticallyOption: true
]
try coordinator.addPersistentStore(
    ofType: GDEncryptedIncrementalStoreType,
    configurationName: nil,
    at: secureStoreURL,
    options: storeOptions
)
```

### 3. Replace NSPersistentContainer

If the app uses `NSPersistentContainer`, create a custom replacement:

```swift
// [BB_DYNAMICS-MIGRATION] Custom secure container replacing NSPersistentContainer
import BlackBerryDynamics.SecureStore.CoreData
import BlackBerryDynamics.SecureStore.File

class SecurePersistentContainer {
    let managedObjectModel: NSManagedObjectModel
    let persistentStoreCoordinator: GDPersistentStoreCoordinator
    let viewContext: NSManagedObjectContext
    private let storeName: String

    enum InitError: Error {
        case modelNotFound(String)
        case modelLoadFailed(String)
    }

    init(name: String) throws {
        storeName = name
        guard let modelURL = Bundle.main.url(forResource: name, withExtension: "momd") else {
            throw InitError.modelNotFound("Core Data model '\(name).momd' not found in bundle")
        }
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
            throw InitError.modelLoadFailed("Failed to load Core Data model at \(modelURL)")
        }
        managedObjectModel = model
        persistentStoreCoordinator = GDPersistentStoreCoordinator(
            managedObjectModel: managedObjectModel
        )
        viewContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        viewContext.persistentStoreCoordinator = persistentStoreCoordinator
        viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    func loadPersistentStores(completionHandler: @escaping (Error?) -> Void) {
        // Resolve store URL via GDFileManager — the secure-container equivalent
        // of the app sandbox Documents directory.
        //
        // IMPORTANT: use .urls(for:in:) NOT .url(for:in:appropriateFor:create:)
        // The create:true variant crashes with BBFileManagerErrorDomain Code=500
        // ("File exists") when the directory already exists.
        guard let docsURL = GDFileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else {
            let err = NSError(domain: "SecurePersistentContainer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Secure documents directory unavailable"])
            completionHandler(err)
            return
        }
        let secureStoreURL = docsURL.appendingPathComponent("\(storeName).sqlite")

        do {
            try persistentStoreCoordinator.addPersistentStore(
                ofType: GDEncryptedIncrementalStoreType,
                configurationName: nil,
                at: secureStoreURL,
                options: [
                    NSMigratePersistentStoresAutomaticallyOption: true,
                    NSInferMappingModelAutomaticallyOption: true
                ]
            )
            completionHandler(nil)
        } catch {
            // Log full error details for diagnostics — do NOT fatalError
            print("[BB_DYNAMICS-MIGRATION] Core Data store load failed: \(error)")
            if let nsError = error as NSError? {
                print("  Domain: \(nsError.domain), Code: \(nsError.code)")
                print("  UserInfo: \(nsError.userInfo)")
            }
            completionHandler(error)
        }
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = persistentStoreCoordinator
        context.automaticallyMergesChangesFromParent = true
        return context
    }
}
```

### 4. Update All References

- Replace all `container.viewContext` with `secureContainer.viewContext`
- Replace `container.newBackgroundContext()` with `secureContainer.newBackgroundContext()`
- Replace `container.loadPersistentStores` with `secureContainer.loadPersistentStores`
- Update `@Environment(\.managedObjectContext)` injection
- Update instantiation sites — `SecurePersistentContainer.init` now throws:
  ```swift
  // Call site must handle the throwing init
  do {
      let secureContainer = try SecurePersistentContainer(name: "MyModel")
      secureContainer.loadPersistentStores { error in ... }
  } catch {
      print("[BB_DYNAMICS-MIGRATION] SecurePersistentContainer init failed: \(error)")
  }
  ```

### 5. Flag SwiftData (if detected)

If the app uses SwiftData (`@Model`, `ModelContainer`, `ModelContext`):
- **STOP** — do NOT proceed with Core Data migration for SwiftData entities.
- Flag as UNSUPPORTED in the migration report.
- Generate a **SwiftData Redesign Plan** in the analysis artifact:
  ```
  swiftDataRedesignPlan:
    entities: [list of @Model classes with properties]
    repositories: [files that use ModelContext/ModelContainer]
    recommendedPath: "Rewrite to Core Data + GDPersistentStoreCoordinator"
    estimatedEffort: "high|medium"
    blockers: [e.g., "@Query in SwiftUI views", "ModelContainer in App init"]
  ```
- Mark this prompt as **design-only pending developer approval** — the
  developer must rewrite to Core Data before re-running this prompt.
- Do NOT attempt to migrate SwiftData automatically or leave ambiguous
  "TODO" comments that imply the pipeline can continue.

### 6. Ensure Post-Authorization Timing

Move Core Data stack initialization to `onAuthorized()`. Use a non-fatal
error handler — `fatalError` in production hides useful diagnostics and
makes the app unrecoverable:

```swift
func onAuthorized() {
    let container = SecurePersistentContainer(name: "MyModel")
    container.loadPersistentStores { error in
        if let error = error {
            // Do NOT fatalError — log diagnostics and show recovery UI
            print("[BB_DYNAMICS-MIGRATION] Core Data failed: \(error)")
            // Show an error alert or fallback UI to the developer
            return
        }
        // Proceed with normal app flow
    }
}
```

### 7. Build and Verify

Run `xcodebuild` to verify compilation. Classify any failures as
pre-existing (per developer clean-build attestation/history), step-introduced, or unrelated.

### 8. Post-Auth Runtime Verification (Mandatory)

After a successful build, the Core Data migration **must be verified at
runtime** — static compilation does not catch `addPersistentStore` failures
which only surface after SDK authorization + container unlock.

**Verification checklist** (run on simulator or device with UEM provisioning):

1. Launch app, complete Dynamics activation/unlock
2. Confirm Core Data store loads without error in console logs:
   - **PASS**: No `EncryptedIncrementalStoreErrorDomain` or
     `EncryptedBinaryStoreErrorDomain` errors in console
   - **FAIL**: `Code=134080` or `URL: (null)` → the store URL is likely nil
     or invalid; fix the `at:` parameter
3. Insert a test record, kill the app, relaunch and unlock, fetch the record:
   - **PASS**: Record persists across launches
   - **FAIL**: Data lost → store may be recreating on each launch; check the
     URL path is consistent
4. Confirm no `fatalError` or crash on store load failure — the app should
   show an error state, not terminate

If step 2 fails with `Code=134080`, the most likely cause is `at: nil`
instead of an explicit secure-container URL. Fix:
```swift
// WRONG — causes runtime 134080 error
at: nil

// CORRECT — explicit path in secure filesystem
at: URL(string: "/MyModel.sqlite")!
```

---

## Closure Ledger Update (Required)

Before recording Prompt 04b as `completed`, write call-site dispositions for
the `secureCoreData` domain using the atomic updater:

```bash
python3 dynamics-migration-tool/tooling/update-migration-plan-state.py \
  --analysis dynamics-migration-tool/output/migration-analysis.json \
  --plan dynamics-migration-tool/output/migration-plan-state.json \
  --run-id "<run-id-from-output/bootstrap.json>" \
  --prompt-id "04b" \
  --domain-id "secureCoreData" \
  --updates-file /tmp/secure-coredata-updates.json
```

Do not edit `output/migration-plan-state.json` directly.
Missing dispositions block recorder completion.

Disposition rules for this prompt:
- Every applicable `secureCoreData` call site must be updated.
- Core Data replacements can be `migrated` only when
  `GDPersistentStoreCoordinator` and encrypted store types are in place with
  explicit secure-container URLs.
- SwiftData call sites are unsupported and must be explicit `blocked` with
  rationale/evidence. Do not leave SwiftData as `migrated`, `deferred`, or
  implicit TODO-only status.
- `blocked` and `deferred` are non-waivable for Prompt 04b completion.

Prompt-scoped validation phases for this prompt are:
`0-artifact-provenance, 6-secure-core-data-swiftdata`.

---

## Output

- Core Data stack migrated to `GDPersistentStoreCoordinator`
- `NSPersistentContainer` replaced with custom secure container
- All context references updated
- SwiftData usage flagged (if detected)
- Core Data initialization moved to post-authorization
- Build verification result

See `42-secure-storage-coredata.md` for the full steering reference.
