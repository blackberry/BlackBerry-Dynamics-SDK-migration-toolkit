## Task: Migrate SQLite to Dynamics Encrypted SQLite

Goal: Replace standard `sqlite3` calls with `sqlite3enc` for encrypted
database storage in the Dynamics secure container.

**Prerequisites**:
- Prompts 00-03b must be complete
- The analysis (Prompt 00) identified raw SQLite usage

**Skip this prompt if the app does not use raw SQLite (sqlite3 C API).**
If the app uses Core Data, see Prompt 04b instead.

---

## Steps

### 0. SDK Header Verification (Mandatory)

Before making any changes, verify the encrypted SQLite header is accessible:

```bash
# CocoaPods install
rg "sqlite3enc_open" Pods/BlackBerryDynamics --include="*.h" -l 2>/dev/null | head -3

# Manual framework
find . -name "sqlite3enc.h" -path "*/BlackBerryDynamics*" 2>/dev/null | head -3
```

If the header is NOT found: `pod install` has not been run. Run it now.
Do NOT proceed with code changes until the header is accessible — function
signatures (especially `sqlite3enc_open` vs `sqlite3enc_open_v2`) must be
confirmed against the installed version before writing migration code.

### 1. Identify All SQLite Usage

From the Prompt 00 analysis, locate:
- All `#include <sqlite3.h>` / `#import <sqlite3.h>` imports
- All `sqlite3_open()` / `sqlite3_open_v2()` calls
- FMDB usage (calls `sqlite3_open` internally)
- GRDB usage (calls `sqlite3_open` internally)
- SQLite.swift usage
- SQLCipher usage (`sqlite3_key`, SQLCipher pods, encrypted file bootstrap code)

### 2. Replace Header Import

Detect the project integration style:
- **CocoaPods** (has `Podfile`) → use `@import` module syntax
- **Manual framework** (no Podfile) → use `#import <...>` header syntax

**IMPORTANT**: The SQLite module is `GD_C.SecureStore.SQLite` (under `GD_C`,
NOT `BlackBerryDynamics`). Do NOT use `@import BlackBerryDynamics.sqlite3enc`.

**IMPORTANT — Module Discovery**: `GD_C` is defined inside the
`BlackBerryDynamics.framework` modulemap. The compiler only discovers it
after loading that modulemap. You MUST import a `BlackBerryDynamics.*`
module **before** (or alongside) `GD_C` — otherwise you get "Module
'GD_C' not found". The natural pairing is
`@import BlackBerryDynamics.SecureStore.File;` since database files live
in the secure container.

```objc
// Before
#include <sqlite3.h>

// After (CocoaPods — preferred)
// [BB_DYNAMICS-MIGRATION] Using encrypted SQLite for Dynamics secure container
@import BlackBerryDynamics.SecureStore.File; // MUST import first — loads modulemap so GD_C is discoverable
@import GD_C.SecureStore.SQLite;

// After (manual framework integration)
// [BB_DYNAMICS-MIGRATION] Using encrypted SQLite for Dynamics secure container
// #import <BlackBerryDynamics/GD_C/sqlite3enc.h>
```

For Swift (**bridging header required** — both CocoaPods and manual):

`import GD_C.SecureStore.SQLite` does NOT work in Swift with CocoaPods
xcframework integration (build error: "Unable to find module dependency:
'GD_C'"). Use a bridging header instead:

1. Create `YourApp/YourApp-Bridging-Header.h`:
```objc
// [BB_DYNAMICS-MIGRATION] Encrypted SQLite for Dynamics secure container
#import <BlackBerryDynamics/GD_C/sqlite3enc.h>
```

2. Add to both Debug and Release target build settings in `project.pbxproj`:
   `SWIFT_OBJC_BRIDGING_HEADER = YourApp/YourApp-Bridging-Header.h`

3. In Swift source files, do NOT import GD_C — the sqlite3enc functions
   are available automatically via the bridging header:
```swift
// [BB_DYNAMICS-MIGRATION] Encrypted SQLite
import BlackBerryDynamics.SecureStore.File // for GDFileManager
// sqlite3enc functions available via bridging header
```

### 3. Replace Database Open Calls

```objc
// Before
sqlite3_open("/path/to/database.db", &db);
sqlite3_open_v2("/path/to/database.db", &db, flags, NULL);

// After
// [BB_DYNAMICS-MIGRATION] Encrypted database in Dynamics secure container
sqlite3enc_open("database.db", &db);
sqlite3enc_open_v2("database.db", &db, flags, NULL);
```

Note: Use relative paths (no full filesystem path).

### 4. Handle SQLite.swift (if applicable)

SQLite.swift is a Swift wrapper around the SQLite C API. It is **incompatible**
with Dynamics encrypted SQLite because it calls `sqlite3_open` internally.

**Migration steps:**

1. **Rewrite database code** to use raw `sqlite3enc` C API calls directly:
   - Remove `import SQLite` (sqlite3enc functions come via bridging header)
   - Replace `SQLite.swift` connection/table/query DSL with `sqlite3_prepare_v2`,
     `sqlite3_step`, `sqlite3_bind_text`, `sqlite3_finalize`, etc.
   - Use a **bare relative path** for the DB filename — do NOT use
     `GDFileManager.default.url()` or `FileManager` URLs for the sqlite3enc
     path argument; the runtime resolves bare paths within the container.
   - Open with `sqlite3enc_open("database.db", &db)` instead of `try Connection(path)`

2. **Remove the SQLite.swift SPM dependency** from the Xcode project:
   - Edit `project.pbxproj` — remove the `PBXBuildFile` entry for `SQLite in Frameworks`
   - Remove the `SQLite in Frameworks` line from `PBXFrameworksBuildPhase`
   - Remove the `XCRemoteSwiftPackageReference "SQLite.swift"` entry from
     the project's `packageReferences` array
   - Remove the entire `XCRemoteSwiftPackageReference` section for SQLite.swift
   - Remove the entire `XCSwiftPackageProductDependency` section for SQLite
   - Delete `project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

   Do NOT leave this as a manual TODO — the agent must complete the full
   dependency removal.

### 5. Handle FMDB (if applicable)

FMDB calls `sqlite3_open` internally. Either:
- Replace FMDB with direct `sqlite3enc` calls (recommended)
- Or use a custom FMDB fork that links `sqlite3enc`

The FMDB → `sqlite3enc` replacement is high-effort: every `FMDatabase`,
`FMResultSet`, and `FMDatabaseQueue` call needs a direct C equivalent.
Flag as a manual migration task if the FMDB surface area is large (> 20
call sites). Add to `manualTodos` in the migration report.

### 5a. Handle GRDB (if applicable)

GRDB wraps `sqlite3` via its own build pipeline. There is no supported
Dynamics-compatible GRDB fork at this time.

**If GRDB is detected:**
- Flag as UNSUPPORTED in the migration report
- Add to `unsupportedFeatures` with the recommendation to replace GRDB
  with direct `sqlite3enc` calls or to file a request with BlackBerry
  for GRDB support
- Do NOT attempt to patch GRDB internals to link `sqlite3enc` — the
  dependency graph changes are non-trivial and unsupported

### 6. Handle SQLCipher Removal (if applicable)

If the app uses SQLCipher:
- Remove SQLCipher pod/dependency
- Remove passphrase management code
- Implement a **one-time data migration** that runs **once** post-first
  authorization on an upgraded install. The migration is irreversible —
  implement a completion flag to prevent re-running.

  **Migration skeleton** (runs once, post-authorization):
  ```objc
  // One-time SQLCipher → sqlite3enc migration
  // Run this in onAuthorized, guarded by a flag stored in secure file
  NSString *migrationFlag = [securePath stringByAppendingPathComponent:@"sqlcipher_migrated"];
  if ([[GDFileManager defaultManager] fileExistsAtPath:migrationFlag]) {
      return; // already migrated
  }

  // 1. Open the old SQLCipher database (use original passphrase)
  sqlite3 *oldDB;
  sqlite3_open([oldDBPath UTF8String], &oldDB);
  const char *key = [passphrase UTF8String];
  sqlite3_exec(oldDB, [[NSString stringWithFormat:@"PRAGMA key='%s'", key] UTF8String],
               NULL, NULL, NULL);

  // 2. Open the new sqlite3enc database
  sqlite3 *newDB;
  sqlite3enc_open([newDBPath UTF8String], SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                  NULL, &newDB);

  // 3. Copy all tables using SQLite's backup API
  sqlite3_backup *backup = sqlite3_backup_init(newDB, "main", oldDB, "main");
  if (backup) {
      sqlite3_backup_step(backup, -1); // -1 = copy all pages
      sqlite3_backup_finish(backup);
  }

  // 4. Verify the new database
  NSAssert(sqlite3_errcode(newDB) == SQLITE_OK, @"Migration verification failed");

  // 5. Mark migration complete and remove old file
  [[GDFileManager defaultManager] createFileAtPath:migrationFlag contents:nil attributes:nil];
  sqlite3_close(oldDB);
  sqlite3_close(newDB);
  [[NSFileManager defaultManager] removeItemAtPath:oldDBPath error:nil];
  ```

  Add a `[MANUAL-TODO]` requiring the developer to:
  - Confirm the SQLCipher passphrase retrieval mechanism
  - Verify migration on a test device before releasing
  - Confirm `oldDBPath` and `newDBPath` resolve to the correct file locations

### 7. Verify Database Access Timing

All database open/read/write operations must happen post-authorization.
The `sqlite3enc_open` call will fail if called before authorization.

### 8. Build and Verify

Run `xcodebuild` to verify compilation. Classify any failures as
pre-existing (per developer clean-build attestation/history), step-introduced, or unrelated.

---

## Closure Ledger Update (Required)

Before recording Prompt 04 as `completed`, write call-site dispositions for
the `secureSql` domain using the atomic updater:

```bash
python3 dynamics-migration-tool/tooling/update-migration-plan-state.py \
  --analysis dynamics-migration-tool/output/migration-analysis.json \
  --plan dynamics-migration-tool/output/migration-plan-state.json \
  --run-id "<run-id-from-output/bootstrap.json>" \
  --prompt-id "04" \
  --domain-id "secureSql" \
  --updates-file /tmp/secure-sql-updates.json
```

Do not edit `output/migration-plan-state.json` directly.
Missing dispositions block recorder completion.

Disposition rules for this prompt:
- Every applicable `secureSql` call site must be updated.
- `migrated` is valid only when the call site now uses `sqlite3enc_*`
  (or has equivalent verified secure replacement evidence).
- Wrapper-heavy sites (FMDB/GRDB/SQLite.swift/SQLCipher) that cannot be
  safely closed in this prompt must be explicit `blocked` with rationale;
  silent carry-forward is not allowed.
- `blocked` and `deferred` are non-waivable for Prompt 04 completion.

Prompt-scoped validation phases for this prompt are:
`0-artifact-provenance, 7-secure-sql-wrappers`.

---

## Output

- All `sqlite3_open` replaced with `sqlite3enc_open`
- Header imports updated
- SQLite.swift replaced with raw C API and SPM dependency removed (if applicable)
- FMDB/GRDB migration documented (if applicable)
- SQLCipher removed (if applicable)
- Old dependency fully removed from project files (not left as a manual TODO)
- Build verification result

See `41-secure-storage-sql.md` for the full steering reference.
