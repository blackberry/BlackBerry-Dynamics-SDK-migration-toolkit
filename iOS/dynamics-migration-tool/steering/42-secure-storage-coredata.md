# Steering: Secure Core Data Storage (iOS)

The Dynamics SDK provides `GDPersistentStoreCoordinator`, a subclass of
`NSPersistentStoreCoordinator`, that stores Core Data data in the encrypted
Dynamics secure container.

This is an iOS-specific migration area with no Android equivalent.

---

## API Replacements

| Standard Core Data API | Dynamics Equivalent | Notes |
|-----------------------|-------------------|-------|
| `NSPersistentStoreCoordinator` | `GDPersistentStoreCoordinator` | Subclass of `NSPersistentStoreCoordinator` |
| `NSSQLiteStoreType` | `GDEncryptedIncrementalStoreType` | Encrypted incremental store |
| `NSBinaryStoreType` | `GDEncryptedBinaryStoreType` | Encrypted binary store |
| `NSPersistentContainer` | Custom setup with `GDPersistentStoreCoordinator` | No direct replacement |

---

## Migration Pattern: Direct Core Data Stack

### Before

```swift
let model = NSManagedObjectModel(contentsOf: modelURL)!
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
try coordinator.addPersistentStore(
    ofType: NSSQLiteStoreType,
    configurationName: nil,
    at: storeURL,
    options: nil
)

let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator
```

### After

```swift
// [BB_DYNAMICS-MIGRATION] Replaced NSPersistentStoreCoordinator with
// GDPersistentStoreCoordinator for encrypted Core Data store
import BlackBerryDynamics.SecureStore.CoreData
import BlackBerryDynamics.SecureStore.File

let model = NSManagedObjectModel(contentsOf: modelURL)!
let coordinator = GDPersistentStoreCoordinator(managedObjectModel: model)

// Resolve URL via GDFileManager documents directory
guard let docsURL = GDFileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
    let err = NSError(domain: "CoreDataMigration", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Secure documents directory unavailable"])
    print("[BB_DYNAMICS-MIGRATION] \(err.localizedDescription)")
    throw err
}
let secureStoreURL = docsURL.appendingPathComponent("MyModel.sqlite")

try coordinator.addPersistentStore(
    ofType: GDEncryptedIncrementalStoreType,
    configurationName: nil,
    at: secureStoreURL,
    options: nil
)

let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator
```

**CRITICAL — Explicit URL Required**: Per `GDPersistentStoreCoordinator.h`,
the URL parameter must be "an absolute path within the BlackBerry Dynamics
secure file system."

Two validated approaches:
- **Recommended**: `GDFileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first`
  then `appendingPathComponent("Model.sqlite")`
- **Alternative**: `URL(string: "/Model.sqlite")!` (bare absolute path in secure container)

**Do NOT pass `nil`** — causes `EncryptedIncrementalStoreErrorDomain Code=134080`.

**Do NOT use** `GDFileManager.default.url(for:in:appropriateFor:create: true)` —
it crashes with `BBFileManagerErrorDomain Code=500` / `NSPOSIXErrorDomain Code=17
"File exists"` when the Documents directory already exists in the container.
Use `.urls(for:in:)` (plural, no create parameter) instead.

---

## Migration Pattern: NSPersistentContainer

### Before

```swift
let container = NSPersistentContainer(name: "MyModel")
container.loadPersistentStores { description, error in
    if let error = error {
        print("Core Data failed: \(error)")
        // Legacy apps often crash here; the migrated flow should not.
    }
}
```

### After

`NSPersistentContainer` uses `NSPersistentStoreCoordinator` internally.
Replace with a custom setup:

```swift
// [BB_DYNAMICS-MIGRATION] Replaced NSPersistentContainer with custom
// Core Data stack using GDPersistentStoreCoordinator
import BlackBerryDynamics.SecureStore.CoreData
import BlackBerryDynamics.SecureStore.File

class SecurePersistentContainer {
    let managedObjectModel: NSManagedObjectModel
    let persistentStoreCoordinator: GDPersistentStoreCoordinator
    let viewContext: NSManagedObjectContext
    private let storeName: String

    init(name: String) {
        storeName = name
        let modelURL = Bundle.main.url(forResource: name, withExtension: "momd")!
        managedObjectModel = NSManagedObjectModel(contentsOf: modelURL)!
        persistentStoreCoordinator = GDPersistentStoreCoordinator(
            managedObjectModel: managedObjectModel
        )
        viewContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        viewContext.persistentStoreCoordinator = persistentStoreCoordinator
    }

    func loadPersistentStores(completionHandler: @escaping (Error?) -> Void) {
        // Use .urls(for:in:) — NOT .url(for:in:appropriateFor:create:)
        // The create:true variant crashes with BBFileManagerErrorDomain Code=500
        // when the directory already exists in the secure container.
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
                options: nil
            )
            completionHandler(nil)
        } catch {
            // Do NOT fatalError — log full diagnostics for debugging
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
        return context
    }
}
```

---

## Objective-C Example

```objc
// [BB_DYNAMICS-MIGRATION] Replaced NSPersistentStoreCoordinator with
// GDPersistentStoreCoordinator for encrypted Core Data store
@import BlackBerryDynamics.SecureStore.CoreData;
// For manual framework integration use:
// #import <BlackBerryDynamics/GD/GDPersistentStoreCoordinator.h>

NSManagedObjectModel *model = [[NSManagedObjectModel alloc]
    initWithContentsOfURL:modelURL];
GDPersistentStoreCoordinator *coordinator =
    [[GDPersistentStoreCoordinator alloc]
        initWithManagedObjectModel:model];

// Resolve store URL via GDFileManager — use URLsForDirectory (no create flag)
NSArray<NSURL *> *docsURLs = [[GDFileManager defaultManager]
    URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
NSURL *storeURL = [docsURLs.firstObject URLByAppendingPathComponent:@"MyModel.sqlite"];

[coordinator addPersistentStoreWithType:GDEncryptedIncrementalStoreType
                          configuration:nil
                                    URL:storeURL
                                options:nil
                                  error:&error];
```

---

## Store Types

### GDEncryptedIncrementalStoreType

- Equivalent to `NSSQLiteStoreType` (incremental/SQLite-backed)
- Recommended for most use cases
- Supports lightweight migration
- Better performance for large datasets

### GDEncryptedBinaryStoreType

- Equivalent to `NSBinaryStoreType`
- Entire store loaded into memory
- Simpler but uses more memory
- Good for small datasets

---

## Lightweight Migration

Lightweight migration works with `GDPersistentStoreCoordinator`:

```swift
let options: [String: Any] = [
    NSMigratePersistentStoresAutomaticallyOption: true,
    NSInferMappingModelAutomaticallyOption: true
]
guard let docsURL = GDFileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
    let err = NSError(domain: "CoreDataMigration", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Secure documents directory unavailable"])
    print("[BB_DYNAMICS-MIGRATION] \(err.localizedDescription)")
    throw err
}
let secureStoreURL = docsURL.appendingPathComponent("MyModel.sqlite")
try coordinator.addPersistentStore(
    ofType: GDEncryptedIncrementalStoreType,
    configurationName: nil,
    at: secureStoreURL,
    options: options
)
```

---

## SwiftData Incompatibility

**SwiftData is NOT supported by the Dynamics SDK.** Apps using SwiftData
(`@Model`, `ModelContainer`, `ModelContext`) cannot redirect their data
to the Dynamics secure container.

If the app uses SwiftData:
1. Flag it as an unsupported feature in the migration report
2. Record SwiftData call sites as explicit `blocked` in the closure ledger
   with rationale/evidence (do not mark as migrated or silently keep).
3. Document it as a manual TODO — the developer must either:
   - Rewrite the data layer using Core Data with `GDPersistentStoreCoordinator`
   - Use `sqlite3enc` directly
   - Accept that SwiftData data is not in the secure container (security risk)

`blocked` and `deferred` are non-waivable for Prompt 04b completion.

---

## Closure Ledger Contract

For prompt-owned `secureCoreData` call sites:
- every applicable call site must have a disposition
- explicit URL-backed encrypted store setup is required for `migrated`
- unresolved sensitive paths fail final storage closure validation

---

## Authorization Timing

Core Data stack initialization MUST happen after authorization:

```swift
func onAuthorized() {
    // [BB_DYNAMICS-MIGRATION] Core Data stack initialized post-authorization
    let container = SecurePersistentContainer(name: "MyModel")
    container.loadPersistentStores { error in
        if let error = error {
            // Do NOT fatalError — log and present recovery UI
            print("[BB_DYNAMICS-MIGRATION] Core Data failed: \(error)")
            return
        }
        // Safe to proceed with data access
    }
}
```

**Common mistake**: Initializing the Core Data stack as a lazy property
on AppDelegate or a singleton — if first accessed before authorization,
it will fail.

---

## Common Issues

1. **`NSPersistentContainer` cannot use `GDPersistentStoreCoordinator`** —
   must replace with custom setup
2. **`at: nil` causes runtime error 134080** — the SDK header requires an
   explicit URL (absolute path within the secure container). This compiles
   but fails at runtime after activation + container unlock. Always pass an
   explicit URL resolved via `GDFileManager.default.urls(for:in:)`.
3. **`GDFileManager.default.url(for:in:appropriateFor:create: true)` crashes**
   — `BBFileManagerErrorDomain Code=500` / `NSPOSIXErrorDomain Code=17
   "File exists"` when the Documents directory already exists. Use the
   `.urls(for:in:)` method (plural, no create parameter) instead.
4. **Pre-auth initialization** — Core Data stack must be created post-auth
5. **`fatalError` on store load** — never use `fatalError` for store init;
   log the full `NSError` (domain, code, userInfo) and show recovery UI.
   The error only surfaces at runtime, not at build time.
6. **NSFetchedResultsController** — works normally once the store is set up
7. **Background contexts** — create via `newBackgroundContext()` on the
   custom container, not `NSPersistentContainer.newBackgroundContext()`
8. **Legacy store migration** — existing unencrypted `NSSQLiteStoreType`
   stores cannot be directly opened as `GDEncryptedIncrementalStoreType`.
   Use Core Data migration API to migrate data (see SDK sample app).
