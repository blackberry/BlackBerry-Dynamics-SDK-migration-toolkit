# Steering: Secure SQL Database (iOS)

The Dynamics SDK provides encrypted SQLite through the `sqlite3enc.h` C API.
This replaces the standard `sqlite3.h` with an encrypted variant where all
database files are stored in the Dynamics secure container.

**CRITICAL — Import Module Name**: The encrypted SQLite C API lives under
the `GD_C` module, NOT `BlackBerryDynamics`. The correct module import is
`@import GD_C.SecureStore.SQLite;` (ObjC) or `import GD_C.SecureStore.SQLite`
(Swift). Do NOT use `@import BlackBerryDynamics.sqlite3enc` — that does not
exist.

**CRITICAL — Module Discovery Order**: The `GD_C` module is defined inside
`BlackBerryDynamics.framework/Modules/module.modulemap`. The compiler only
discovers `GD_C` after it has loaded that modulemap — which happens when
**any** `BlackBerryDynamics.*` module is imported first. Therefore, any
file that uses `@import GD_C.SecureStore.SQLite;` MUST also import a
`BlackBerryDynamics.*` module before it (or in a transitively included
header). The natural pairing is `@import BlackBerryDynamics.SecureStore.File;`
since SQLite files live in the secure container.

---

## API Replacements

| Standard SQLite | Dynamics Equivalent (Module Import) | Dynamics Equivalent (Header Import) | Notes |
|----------------|-------------------------------------|--------------------------------------|-------|
| `#include <sqlite3.h>` | `@import GD_C.SecureStore.SQLite;` | `#import <BlackBerryDynamics/GD_C/sqlite3enc.h>` | Encrypted SQLite header — use module import for CocoaPods |
| `sqlite3_open()` | `sqlite3enc_open()` | `sqlite3enc_open()` | Opens encrypted database |
| `sqlite3_open_v2()` | `sqlite3enc_open_v2()` | Opens encrypted database (extended) |
| `sqlite3_close()` | `sqlite3_close()` | Same API (close is not changed) |
| All other `sqlite3_*` | Same | Prepare, step, finalize, bind, etc. are unchanged |

---

## Migration Pattern

### Before (Standard SQLite)

```objc
#include <sqlite3.h>

sqlite3 *db;
int rc = sqlite3_open("/path/to/database.db", &db);
if (rc == SQLITE_OK) {
    // Use database
}
sqlite3_close(db);
```

### After (Dynamics Encrypted SQLite — CocoaPods / Module Import)

```objc
// [BB_DYNAMICS-MIGRATION] Replaced sqlite3_open with sqlite3enc_open
// for encrypted database in the Dynamics secure container
@import BlackBerryDynamics.SecureStore.File; // MUST import first — loads modulemap so GD_C is discoverable
@import GD_C.SecureStore.SQLite;

sqlite3 *db;
int rc = sqlite3enc_open("database.db", &db);
if (rc == SQLITE_OK) {
    // Use database — all queries work the same
}
sqlite3_close(db);
```

If the project uses manual framework integration (no CocoaPods), use
the header import instead:

```objc
#import <BlackBerryDynamics/GD_C/sqlite3enc.h>
```

### Swift

**CRITICAL — CocoaPods xcframework limitation**: In Swift projects using
CocoaPods, `import GD_C.SecureStore.SQLite` will fail with:

```
Unable to find module dependency: 'GD_C'
```

This happens because `GD_C` is declared as a separate `framework module`
inside the `BlackBerryDynamics.framework` modulemap, but there is no
standalone `GD_C.framework`. Swift's module resolver cannot find `GD_C`
when the SDK is delivered as an xcframework via CocoaPods, even though
the modulemap and headers are present. (Objective-C `@import` does not
have this limitation.)

**The fix is to use a bridging header** — this is required for **both**
CocoaPods and manual framework integration in Swift projects:

1. Create (or update) a bridging header:

```objc
// YourApp-Bridging-Header.h
// [BB_DYNAMICS-MIGRATION] Encrypted SQLite for Dynamics secure container
// Bridging header required because GD_C module cannot be directly imported
// in Swift when using CocoaPods xcframework integration
#import <BlackBerryDynamics/GD_C/sqlite3enc.h>
```

2. Set the bridging header in Xcode build settings:
   - Add `SWIFT_OBJC_BRIDGING_HEADER = YourApp/YourApp-Bridging-Header.h`
     to both Debug and Release target configurations in `project.pbxproj`

3. In Swift source files, do NOT use `import GD_C.SecureStore.SQLite`.
   The `sqlite3enc_open`, `sqlite3_prepare_v2`, `sqlite3_step`, etc.
   functions are available automatically through the bridging header:

```swift
// [BB_DYNAMICS-MIGRATION] Encrypted SQLite for Dynamics
import BlackBerryDynamics.SecureStore.File // for GDFileManager
// sqlite3enc functions available via bridging header — do NOT import GD_C

var db: OpaquePointer?
let rc = sqlite3enc_open("database.db", &db)
if rc == SQLITE_OK {
    // Use database
}
sqlite3_close(db)
```

---

## SQLite.swift Migration

If the app uses [SQLite.swift](https://github.com/stephencelis/SQLite.swift)
(SPM package), it must be **fully replaced** with raw `sqlite3enc` C API calls.
SQLite.swift calls `sqlite3_open` internally and cannot be configured to use
the Dynamics encrypted backend.

### Before

```swift
import SQLite

let db = try Connection(databasePath)
let colors = Table("Colours")
let id = SQLite.Expression<Int64>("ColorID")
let favourite = SQLite.Expression<Int64>("Favourite")

for color in try db.prepare(colors) {
    print("id: \(color[id]), favourite: \(color[favourite])")
}
```

### After

Ensure the bridging header includes `#import <BlackBerryDynamics/GD_C/sqlite3enc.h>`
(see the Swift section above for full setup instructions).

```swift
// [BB_DYNAMICS-MIGRATION] Replaced SQLite.swift with sqlite3enc for Dynamics encryption
// sqlite3enc functions available via bridging header — do NOT import GD_C
// Use bare relative path — sqlite3enc_open resolves paths within the Dynamics container.
// Do NOT use GDFileManager.default.url() or NSFileManager paths here.

var db: OpaquePointer?
if sqlite3enc_open("DB.sqlite", &db) == SQLITE_OK {
    var statement: OpaquePointer?
    if sqlite3_prepare_v2(db, "SELECT * FROM Colours", -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
            let colorID = sqlite3_column_int64(statement, 0)
            // ...
        }
    }
    sqlite3_finalize(statement)
}
```

### Dependency Removal

After rewriting the code, **remove the SQLite.swift package entirely** from
the Xcode project. This is NOT a manual step — complete it during migration:

1. Edit `project.pbxproj`:
   - Remove the `SQLite in Frameworks` entry from `PBXBuildFile`
   - Remove `SQLite in Frameworks` from the `PBXFrameworksBuildPhase` files list
   - Remove `XCRemoteSwiftPackageReference "SQLite.swift"` from the project's
     `packageReferences` array
   - Delete the entire `XCRemoteSwiftPackageReference` section for SQLite.swift
   - Delete the entire `XCSwiftPackageProductDependency` section for SQLite
2. Delete `Package.resolved` (under `project.xcworkspace/xcshareddata/swiftpm/`)

---

## FMDB Migration

If the app uses FMDB, the migration requires changing how the database
is opened:

### Before

```swift
let db = FMDatabase(path: databasePath)
db.open()
```

### After

FMDB uses `sqlite3_open` internally. To use encrypted SQLite with FMDB,
you need to either:

1. **Use a custom FMDB build** that links against `sqlite3enc` instead
   of `sqlite3`
2. **Replace FMDB with direct `sqlite3enc` calls** (recommended for
   simpler usage)
3. **Wrap `sqlite3enc_open`** in an FMDB-compatible helper

Option 2 (recommended):

```swift
// [BB_DYNAMICS-MIGRATION] Replaced FMDB with direct sqlite3enc calls
// FMDB uses sqlite3_open internally which is not encrypted
var db: OpaquePointer?
sqlite3enc_open("database.db", &db)
// Use sqlite3_prepare_v2, sqlite3_step, etc. directly
```

---

## GRDB Migration

If the app uses GRDB:

### Before

```swift
let dbQueue = try DatabaseQueue(path: databasePath)
```

### After

No officially supported Dynamics-compatible GRDB backend is shipped today.
Preferred outcome is full replacement with direct `sqlite3enc_*` usage.

If replacement cannot be completed safely in this prompt:
- classify the call sites as explicit `blocked` with rationale/evidence
- record unsupported status in report/manual todos
- do not silently retain GRDB as `migrated`

---

## SQLCipher Removal

If the app uses SQLCipher for database encryption, treat removal as a
decisioned migration task (not a blanket delete):

1. Remove `SQLCipher` or `GRDB-SQLCipher` pod
2. Remove passphrase management code
3. Handle one-time data migration from SQLCipher to Dynamics when evidence
   shows SQLCipher is redundant for the target data path:
   - Open old database with SQLCipher + passphrase
   - Export all data
   - Import into new `sqlite3enc`-opened database
   - Delete old encrypted database
   - This must run post-authorization

If redundancy is not yet proven for a call site, keep it explicit
`blocked`/`deferred` with rationale instead of removing cryptography by
assumption.

---

## Closure Ledger Contract

For prompt-owned `secureSql` call sites:
- every applicable call site must have a disposition
- unresolved sensitive paths fail final validation
- `blocked` and `deferred` are non-waivable for Prompt 04 completion

---

## Database Path Strategy (Canonical — use this everywhere)

**Always use bare relative string paths with `sqlite3enc_open`.** The Dynamics
runtime resolves the path within the secure container automatically.

```swift
// CORRECT — bare relative path
sqlite3enc_open("database.db", &db)
sqlite3enc_open("data/analytics.db", &db)  // subdirectory within container

// WRONG — do NOT use GDFileManager.default.url() or FileManager paths
// sqlite3enc_open(GDFileManager.default.url(for: .documentDirectory, ...).path, &db)
// sqlite3enc_open("/var/mobile/.../Documents/database.db", &db)
```

Rationale: `sqlite3enc_open` takes a `const char* filename` (see `sqlite3enc.h`).
The Dynamics container maps bare relative paths to the secure filesystem.
Full filesystem paths or GDFileManager URLs are not needed and can cause
path resolution issues across SDK versions.

---

## Common Issues

1. **Using standard `sqlite3_open()` after migration** — database will be
   unencrypted and outside the secure container
2. **Database access before authorization** — `sqlite3enc_open` fails before
   the container is unlocked
3. **Mixing encrypted and unencrypted databases** — if the app has multiple
   databases, ensure all sensitive ones use `sqlite3enc_open`
4. **FMDB/GRDB internal sqlite3_open** — these libraries call `sqlite3_open`
   internally; using them as-is bypasses encryption
5. **"Unable to find module dependency: 'GD_C'" in Swift** — this occurs
   when using `import GD_C.SecureStore.SQLite` in Swift with CocoaPods
   xcframework integration. `GD_C` is declared as `framework module GD_C`
   in the BlackBerryDynamics modulemap, but no standalone `GD_C.framework`
   exists. Swift's module resolver cannot find it. Fix: use a bridging
   header with `#import <BlackBerryDynamics/GD_C/sqlite3enc.h>` instead of
   the Swift module import. See the Swift section above for details.
