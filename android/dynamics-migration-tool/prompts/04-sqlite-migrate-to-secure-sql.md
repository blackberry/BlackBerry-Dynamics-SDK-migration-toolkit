## Task: Secure SQLite Databases

Goal: Ensure all app databases are protected under the Dynamics secure container.

**Prerequisite**: Authorization (prompt 03) and deferral audit (prompt 03b)
must be complete. Database access requires the container to be unlocked
via `onAuthorized()`.

---

## Module map context (read first)

Load `dynamics-migration-tool/output/module-map.json` and resolve:

- `${primary}` — `primaryAppModule.path`.
- `${in_scope_main_src}` — every primary + library `src/main/java` and
  `src/main/kotlin` directory. SQLite/Room call sites frequently live
  in dedicated `core` / `data` library modules, not the application
  module — every search below scans this full set.

Bridge templates (the 5-file Room bridge, the SQLiteOpenHelper bridge)
are copied into the **module that owns the call site being rewired**.
For a single-module project that is `${primary}/src/main/java/<pkg>/dynamicsdb/`.
For a multi-module project where Room database builders live in a
library module (e.g. `core/database`), copy the bridge
into that library module's main source set instead, so the resulting
factory class sits in the same module as the database it serves. The
library module receives a `compileOnly` Dynamics dependency from
prompt 01.

If `module-map.json` is missing, STOP and re-run `00pre-bootstrap.md`.

---

## Steps

### 0. SDK Class Availability (consult bootstrap)

The Dynamics SQLite classes were already verified by prompt
`00pre-bootstrap.md` and the result is recorded in
`output/bootstrap.json` under `sdkClassIndex`. Confirm the relevant
entries are `"found"`:

- `com.good.gd.database.sqlite.SQLiteOpenHelper`
- `com.good.gd.database.sqlite.SQLiteDatabase`

If either is missing or `bootstrap.json` itself is missing/invalid,
STOP and re-run `00pre-bootstrap.md` — the class index has to be
authoritative before this prompt makes code changes. Do NOT run
`./gradlew dependencies` yourself; that probe belongs to the bootstrap.

Do NOT abort if applicability says `secureSql` is `not-applicable` —
just record the prompt as `skipped` (see "Record execution" below) and
move on. Skipping is recorded so prompt 10's hard gate can verify the
plan was honored.

### 1. Inventory All Database Usage

Search the entire source tree for:
- `SQLiteOpenHelper` subclasses
- `Room.databaseBuilder()` / `Room.inMemoryDatabaseBuilder()`
- `SQLiteDatabase.openOrCreateDatabase()` / `SQLiteDatabase.openDatabase()`
- `@Database` annotations (Room)
- `ContentProvider` implementations backed by SQLite
- Any third-party database libraries (SQLCipher, Realm, etc.)

For each database found, record:
- Database name and file location
- Whether it uses raw SQLiteOpenHelper or Room
- Schema version and migration history
- Whether it coexists with another encryption layer (e.g., SQLCipher)

### 2. Migrate Each Database — Use the Template, Do Not Scaffold

**For each database found in step 1, follow the approach below exactly.**

---

#### 2a. Raw SQLiteOpenHelper — two-import swap (no new files needed)

Use `dynamics-migration-tool/templates/sql/raw/DynamicsDbHelper.java` (or `.kt`) as
your reference. The entire migration is **changing two import lines**:

```java
// REMOVE
import android.database.sqlite.SQLiteOpenHelper;
import android.database.sqlite.SQLiteDatabase;

// ADD
import com.good.gd.database.sqlite.SQLiteOpenHelper;  // [BB_DYNAMICS-MIGRATION]
import com.good.gd.database.sqlite.SQLiteDatabase;    // [BB_DYNAMICS-MIGRATION]
```

The class body, constructor, `onCreate`, `onUpgrade`, and every query/insert/update/delete
call are **unchanged**. The Dynamics API is identical to Android SQLite.

Unchanged imports (keep exactly as-is — these have NO Dynamics equivalents):
- `android.database.Cursor`
- `android.content.ContentValues`
- `android.database.sqlite.SQLiteException`
- `android.database.sqlite.SQLiteConstraintException`
- `android.database.sqlite.SQLiteBlobTooBigException`

---

#### 2b. Room — copy the 5-file bridge template (do not write this from scratch)

Room uses `SupportSQLiteOpenHelper`, not `SQLiteOpenHelper` directly. A simple import
swap does not work. You must wire a factory that returns a Dynamics-backed helper.

**Step 1 — Copy the bridge template files into your app:**

```bash
# Copy the bridge into the module that owns the Room database builder.
# For a single-module project this is ${primary}/src/main/java/<pkg>/dynamicsdb/.
# For a multi-module project, substitute the library module path that
# owns the Room database (e.g. core/database/src/main/java/<pkg>/dynamicsdb/).
cp -r dynamics-migration-tool/templates/sql/room-bridge/ \
      <owning-module>/src/main/java/<your/package/path>/dynamicsdb/
```

**Step 2 — Update package declarations** in all 5 files:
Replace `__APP_PACKAGE__` with your actual package (e.g., `com.example.myapp.dynamicsdb`).

**Step 3 — Wire the factory into every `Room.databaseBuilder(...)` call site:**

```java
// BEFORE
AppDatabase db = Room.databaseBuilder(context, AppDatabase.class, "app.db")
        .build();

// AFTER — add .openHelperFactory() before .build()
// [BB_DYNAMICS-MIGRATION] Room database backed by Dynamics secure SQLite via GDRoomOpenHelperFactory.
AppDatabase db = Room.databaseBuilder(context, AppDatabase.class, "app.db")
        .openHelperFactory(new GDRoomOpenHelperFactory())
        .build();
```

For Kotlin:
```kotlin
// [BB_DYNAMICS-MIGRATION] Room database backed by Dynamics secure SQLite via GDRoomOpenHelperFactory.
val db = Room.databaseBuilder(context, AppDatabase::class.java, "app.db")
    .openHelperFactory(GDRoomOpenHelperFactory())
    .build()
```

**Step 4 — Verify each call site from your inventory** has `.openHelperFactory(...)` chained.
Search for any remaining unwired builders:
```bash
rg "Room\.databaseBuilder|Room\.inMemoryDatabaseBuilder" \
  -g "*.java" -g "*.kt" ${in_scope_main_src}
```
Every hit must show `.openHelperFactory(new GDRoomOpenHelperFactory())`.

---

#### FORBIDDEN scaffold patterns — if you produce any of these, the migration is incomplete

The following patterns look like migration but are NOT. If you find yourself writing
any of them, stop and use the template approach above instead:

```java
// FORBIDDEN: class-literal anchor — imports the class but never invokes it
Class<?> anchor = GDFileSystem.class;

// FORBIDDEN: bridge factory that delegates back to FrameworkSQLiteOpenHelperFactory
public SupportSQLiteOpenHelper create(Configuration config) {
    touchDynamicsClasses();                                    // dead code
    return new FrameworkSQLiteOpenHelperFactory().create(config);  // still standard SQLite
}

// FORBIDDEN: SQLCipher conditional that leaves the factory unwired by default
if (!usingSQLCipher) {
    builder.openHelperFactory(new GDRoomOpenHelperFactory());
}
// The factory MUST be wired unconditionally.
// If SQLCipher is present, remove it first (see steering/15-redundant-feature-removal.md).
```

After completing step 3, run a final search to confirm no forbidden patterns remain:
```bash
rg "FrameworkSQLiteOpenHelperFactory" -g "*.java" -g "*.kt" ${in_scope_main_src}
```
That search MUST return zero results.

### 3. Handle Special Cases

**Exception classes** — `SQLiteBlobTooBigException`, `SQLiteConstraintException`,
`SQLiteException` have NO Dynamics equivalents. These imports MUST remain as
`android.database.sqlite.*`. Do not flag them as unmigrated.

**External database access** — If the app reads external SQLite files (e.g.,
backup import using `SQLiteDatabase.openDatabase(path, ...)`), this is NOT
the app's own database. Do not migrate it to Dynamics secure SQLite.

**SQLCipher coexistence** — If the app uses SQLCipher for encryption, the
Dynamics bridge factory should only be applied when SQLCipher is NOT active.
Both provide encryption; applying both is redundant and may conflict.

**`android.database.sqlite.SQLiteTransactionListener`** — The Room bridge
adapter must import this Android type to satisfy Room's interface contract.
This is a legitimate use, not an unmigrated API.

### 4. Verify Container Lifecycle

Ensure ALL database access happens after `onAuthorized()` fires:
- Check `onCreate()`, `onResume()`, and any background tasks
- Move database initialization to `onAuthorized()` or a method called from it
- Secondary activities launched after authorization are safe

**Deferred-init UI safety note (required with Room/DAO migrations)**:
when database attachment moves behind authorization, apply
**Pattern 12** in `steering/21-authorization-deferral-patterns.md`
(non-null placeholder observable + startup state machine). The
DAO-backed `LiveData` must be forwarded into the placeholder via
`MediatorLiveData.addSource` / `StateFlow.collect` after `authorized`
fires — never exposed as a nullable field. The validator enforces
this with `[AUTH-UI-001]`, `[AUTH-UI-002]`, and `[AUTH-UI-003]`.

References (public docs only):
- [BlackBerry Dynamics Android API Reference](https://developer.blackberry.com/files/blackberry-dynamics/android/)
- [BlackBerry Dynamics Android samples (public)](https://github.com/blackberry/BlackBerry-Dynamics-Android-Samples)

### 5. Test

- Create, read, update, delete operations
- Schema migrations (if any)
- App restart — verify data persists
- Force-close and relaunch — verify data survives
- If SQLCipher coexists, test both encryption paths

---

## Output

- Database inventory table (name, type, encryption, migration approach)
- Bridge adapter files created (if Room)
- List of files modified
- Exception class imports documented as intentionally kept
- Risks and manual verification steps
- **`dynamics-migration-tool/output/migration-plan-state.json` updated** —
  merge/upsert one `dispositions[]` entry per
  `migration-analysis.json executionPlan` call site for `secureSql`
  (`migrated` or `removed`), preserving existing
  `egressFeatureDecisions[]` and other domains' `dispositions[]`, then
  full-file overwrite. See
  `steering/79-migration-plan-state-and-call-site-closure.md`.

  Required field names (matched by `record-prompt-execution.sh` and the
  bundled schema `dynamics-migration-tool/schemas/migration-plan-state.schema.v1.1.0.json`):

  ```json
  {
    "schemaVersion": "1.1.0",
    "runId": "<copied unchanged from bootstrap.json / existing migration-plan-state.json>",
    "egressFeatureDecisions": [
      {
        "featureId": "<existing value or new prompt-owned feature id>",
        "domain": "secureFileStorage|secureNetworking|icc|secureClipboard|secureUiWidgets|policyManagement",
        "outcome": "REMOVE|REPLACE_WITH_DYNAMICS|MANUAL_INTERVENTION_REQUIRED|BLOCKED_UNTIL_APPROVED",
        "module": "<optional module path from module-map.json>",
        "note": "<optional detail>",
        "secureAlternative": "<optional string or null>",
        "uiDisposition": "removed|disabled|replaced|flagged",
        "codePathReachable": false
      }
    ],
    "dispositions": [
      {
        "callSiteId": "<id from migration-analysis.executionPlan[].callSites[].id>",
        "domain": "secureSql",
        "status": "migrated",
        "module": "<module path from module-map.json, e.g. app>",
        "note": "optional free text"
      },
      {
        "callSiteId": "<id>",
        "domain": "secureSql",
        "status": "removed",
        "module": "<module path from module-map.json, e.g. app>",
        "note": "call site removed as dead code / feature retired"
      }
    ]
  }
  ```

  Do not invent alternative field names (`disposition`, `state`,
  `verdict`, etc.) — the recorder hard-fails on schema mismatch.
  Preserve the existing top-level `runId` exactly; never regenerate it.
  Keep `egressFeatureDecisions[]` present even when unchanged.

---

## Record execution

After this prompt completes — whether it migrated databases or skipped
because `secureSql` is `not-applicable` — append the execution record so
prompt 10's hard gate sees that the plan was honored:

```bash
# Migrated case (M2: closure requires migration-plan-state.json dispositions)
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 04 \
    --status completed \
    --files-touched <comma-separated relative paths including migration-plan-state.json>

# Skipped case (domain marked not-applicable in migration-analysis.json)
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 04 \
    --status skipped \
    --note "secureSql not-applicable per executionPlan"
```

This records prompt progress only. For an immediate diagnostic, run
`validate.sh --check-prompt 04` (SQL + redundant-crypto + API audit).
Prompt `10` remains the mandatory final source/report gate — no separate
`--validate-result` flag is needed.

Before recording **`completed`**, ensure every applicable `callSites[].id`
for prompt **04** has a matching disposition in `migration-plan-state.json`.
Prompt `10` enforces this closure gate.
