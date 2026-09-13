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

FMDB calls `sqlite3_open` internally. **Open-only bridges are forbidden.**

Either:

1. **Replace FMDB with direct `sqlite3enc` calls** (recommended for small
   surfaces), **or**
2. **Keep FMDB but link the entire ObjC SQL module to Dynamics SQLite on
   iOS** (required for large FMDB / shared SPM SQL packages):
   - Add iOS-only `BlackBerryDynamics` product dependency in that package’s
     `Package.swift`
   - Keep `.linkedLibrary("sqlite3")` **macOS-only**
   - Redirect headers on iOS to
     `#import <BlackBerryDynamics/GD_C/sqlite3.h>` + `sqlite3enc.h`
   - Route FMDB open through `sqlite3enc_open` / `sqlite3enc_open_v2`
   - Place SQL shims as **private** headers beside FMDB `.m` sources — do
     **not** drop them under SPM `include/` unless the umbrella is updated
     in the same change (avoids PCM / umbrella failures and GD module leak)

Do **not** mark FMDB sites `migrated` if:
- only the open path was redirected to `sqlite3enc_open`, or
- the iOS SQL module still links system `libsqlite3`, or
- `#include <sqlite3.h>` remains without Dynamics redirect on iOS

The FMDB → direct `sqlite3enc` rewrite is high-effort for large surfaces
(> 20 call sites). Prefer option 2 (full linkage) rather than leaving an
open-only helper. GRDB remains unsupported (see 5a).

Validator Phase `7-secure-sql-wrappers` runs `check-sql-linkage.py` and
fails incomplete linkage even when FMDB lives under excluded library roots.

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
- Stop there. A Dynamics conversion is always a fresh install
  (`steering/18-fresh-dynamics-install.md`). Do **not** invent a
  SQLCipher export/import helper for a previous installation.

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
  **and** all follow-on `sqlite3_*` symbols resolve from Dynamics SQLite on
  iOS (headers + link). Open-only bridges are not `migrated`.
- Wrapper-heavy sites (FMDB/GRDB/SQLite.swift/SQLCipher) that cannot be
  safely closed in this prompt must be explicit `blocked` with rationale;
  silent carry-forward is not allowed.
- FMDB retained in-tree is `migrated` only with the full-linkage pattern in
  `41-secure-storage-sql.md` (iOS BlackBerryDynamics product + header
  redirect; macOS may keep system SQLite).
- `blocked` and `deferred` are non-waivable for Prompt 04 completion.

Prompt-scoped validation phases for this prompt are:
`0-artifact-provenance, 7-secure-sql-wrappers`.

---

## Output

- All `sqlite3_open` replaced with `sqlite3enc_open`
- Header imports updated (Dynamics SQLite on iOS for open **and** exec/prepare)
- SQLite.swift replaced with raw C API and SPM dependency removed (if applicable)
- FMDB migrated via direct `sqlite3enc` **or** full iOS Dynamics linkage
  (not open-only); SPM SQL shims are private headers unless umbrella updated
- GRDB/SQLCipher handled per rules above
- Old dependency fully removed from project files (not left as a manual TODO)
- Build verification result (`xcodebuild` after SQL shim placement)
- Phase 7 SQL linkage checker passes

See `41-secure-storage-sql.md` for the full steering reference.
