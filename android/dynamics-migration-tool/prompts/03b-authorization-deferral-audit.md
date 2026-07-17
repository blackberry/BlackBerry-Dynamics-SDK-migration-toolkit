## Task: Authorization Deferral Audit

Goal: Systematically find and fix every component that accesses secure
APIs before the Dynamics container is authorized. This is the step that
prevents the most common class of runtime crashes in migrated apps.

**Prerequisite**: Prompt 03 (add-dynamics-auth) must be complete. The
Application class must have `GDStateListener`, `isContainerAuthorized`,
and `authorized` LiveData set up.

**Module map context**: Load
`dynamics-migration-tool/output/module-map.json` and resolve
`${in_scope_main_src}` (every `src/main/java` and `src/main/kotlin`
directory across the primary application module + every entry in
`libraryModulesInScope[]`). All audits below scan that full set —
deferral problems frequently live in feature/library modules, not just
the primary app module. If `module-map.json` is missing, STOP and
re-run `00pre-bootstrap.md`.

**Input**: The Lifecycle Dependency Map from Prompt 00b
(`dynamics-migration-tool/output/architecture-diagrams.md`). If it
exists, use it as the primary guide — specifically:
- Section 4A (Full Startup Chain Trace) — every pre-auth call chain
- Section 4B (Summary Table) — maps each chain to a deferral pattern
- Section 5 (Secure API Call Graph) — bottom-up reverse trace catches
  chains that top-down tracing misses
- Section 6 (Authorization Boundary) — lists all pre-auth components
- Section 7 (Migration Risk Heatmap) — prioritizes which components to fix first

---

## Why This Is a Separate Step

Prompt 03 sets up the authorization infrastructure (Application class,
`activityInit()`, `onAuthorized()` in the main Activity). But in real
apps, secure API access is scattered far beyond `onCreate()` of the
main Activity:

- ViewModel `init {}` blocks that open databases
- Fragment `onViewCreated()` that observes ViewModel fields
- BroadcastReceivers triggered by system alarms
- App widget factories refreshed by the launcher
- Data migration routines called during startup
- Utility functions called transitively from constructors

Each of these needs its own deferral strategy. Prompt 03 cannot cover
them all without becoming unwieldy. This dedicated audit step ensures
nothing is missed.

---

## Steps

### 1. Consult the Architecture Diagrams

If `dynamics-migration-tool/output/architecture-diagrams.md` exists:

1. Read **Section 4B (Summary Table)** — it maps every pre-auth secure
   API chain to a specific deferral pattern. Work through each row.
2. Cross-reference with **Section 5 (Secure API Call Graph)** — the
   bottom-up trace may reveal chains the top-down trace missed.
3. Use **Section 7 (Migration Risk Heatmap)** to prioritize — fix HIGH
   risk components first.
4. Use **Section 6 (Authorization Boundary)** as a checklist — every
   component listed "ABOVE AUTH BOUNDARY" must be verified.

If the diagrams do not exist, perform the manual audit in Step 2.

### 2. Manual Audit (if no Lifecycle Dependency Map)

Run these searches and verify each hit is either post-auth or properly
deferred:

```bash
# Pass ${in_scope_main_src} to every rg below — never just app/src/main/.
# In multi-module projects, deferral hazards routinely live in feature
# or core library modules, not the primary app module.

# Database access points
rg "getDatabase|getWritableDatabase|getReadableDatabase|openOrCreateDatabase" \
  -g "*.java" -g "*.kt" -n ${in_scope_main_src}

# GD file access points
rg "GDFileSystem|GDFileHelper|com\.good\.gd\.file" \
  -g "*.java" -g "*.kt" -n ${in_scope_main_src}

# GD file access — Fragment lifecycle cross-reference (AUTH-FILE-001)
# For every hit from the GD file search above, trace callers BACKWARDS
# up to 4 levels. If any caller chain reaches Fragment onViewCreated(),
# onCreateView(), onResume(), or adapter setup methods (setupAdapter,
# initAdapter, createAdapter), the call site MUST be deferred or guarded.
#
# Step A: find all files that import/use GD file APIs
rg "com\.good\.gd\.file|GDFileSystem|GDFileHelper" \
  -g "*.java" -g "*.kt" -l ${in_scope_main_src}
# Step B: for each hit, find every function that constructs GDFile / uses GD file I/O
rg "com\.good\.gd\.file\.File\(|GDFile\(|GDFileSystem\.|GDFileHelper\." \
  -g "*.java" -g "*.kt" -n ${in_scope_main_src}
# Step C: trace callers of those functions — search for the function name
# in Fragment and ViewModel files. If the caller is in onViewCreated,
# onCreateView, onResume, setupAdapter, initAdapter, or createAdapter:
#   → The call chain MUST be deferred until authorization.
# Apply Pattern 7 (static boolean guard) to the utility function, OR
# defer the entire call chain using Pattern 3 (observe authorized /
# databaseReady before calling setupAdapter()).
#
# Common dangerous pattern to watch for:
#   val imageRoot get() = app.getCurrentImagesDirectory()
#   // where getCurrentImagesDirectory() → GDFile("path") constructor
#   // and imageRoot is accessed from setupAdapter() in onViewCreated()
#
# Also check ViewModel computed properties (val X get() = ...) that
# resolve through utility functions to GD file constructors. These are
# NOT caught by the database-focused Pattern 2 audit.
rg "setupAdapter|initAdapter|createAdapter" \
  -g "*Fragment.java" -g "*Fragment.kt" -n ${in_scope_main_src}

# GD network access points
rg "GDHttpClient|GDSocket|BBCustomInterceptor" \
  -g "*.java" -g "*.kt" -n ${in_scope_main_src}

# ViewModel init blocks
rg "init \{" -g "*.kt" -n ${in_scope_main_src} | rg -i "model|viewmodel"

# BroadcastReceiver onReceive
rg "onReceive|BroadcastReceiver" -g "*.java" -g "*.kt" -n ${in_scope_main_src}

# Widget factories and providers
rg "RemoteViewsFactory|AppWidgetProvider" -g "*.java" -g "*.kt" -n ${in_scope_main_src}

# Manifest startup surfaces (providers/App Startup/WorkManager initializer)
rg "ContentProvider|androidx\\.startup|Initializer|WorkManagerInitializer|Configuration\\.Provider|WorkerFactory" \
  -g "*.java" -g "*.kt" -n ${in_scope_main_src}

# Migration / upgrade code
rg "migration|upgrade|schema|runMigrations" -g "*.java" -g "*.kt" -n ${in_scope_main_src}

# Activity/Fragment helper methods that may access DB or GD files before auth
rg "setupMenu|setupObserver|setupAdapter|initAdapter|createAdapter|checkForMigration|setupNavigation|setupDrawer|refreshData" \
  -g "*.java" -g "*.kt" -n ${in_scope_main_src}

# Abstract Fragment template hooks (REQUIRED — Pattern 12).
# Many apps wire `setupObserver()` in a base Fragment that calls an
# `abstract fun getObservable()` (or `subscribeUi`, `observeData`, etc.)
# whose concrete override returns a delayed Room/DAO field. The crash
# manifests as NPE in the SUBCLASS file, not the base file, and the
# subclass file has NO deferral marker of its own.
#
# Find all abstract / open template hooks:
rg -n "abstract\s+fun\s+(getObservable|setupObserver|observeData|subscribeUi|subscribeUI)" \
  -g "*.java" -g "*.kt" ${in_scope_main_src}
# Find every concrete override and inspect its body for `!!` on
# ViewModel/binding fields. Both expression-bodied and block forms
# must be reviewed:
rg -n "override\s+fun\s+(getObservable|setupObserver|observeData|subscribeUi|subscribeUI)\b" \
  -g "*.java" -g "*.kt" ${in_scope_main_src}
# Header-line `!!` (catches single-expression overrides):
rg -n "override\s+fun\s+(getObservable|setupObserver|observeData|subscribeUi|subscribeUI)\b[^\n]*!!" \
  -g "*.java" -g "*.kt" ${in_scope_main_src}

# Any `model\.<field>!!` / `viewModel\.<field>!!` in fragment files.
# These are Pattern 12 violations even when the file has no deferral
# marker of its own (the deferral is in the ViewModel or the base
# class). Replace each with Pattern 12 — publish a non-null placeholder
# from the ViewModel and drop the `!!`.
rg -n "(model|viewModel|baseModel)\.[A-Za-z0-9_]+!!" \
  -g "*Fragment.kt" -g "*Fragment.java" ${in_scope_main_src}

# Auth callback + fragment transaction race (post-activation crash risk)
rg "runOnAuthorized|beginTransaction\\(|\\.commit\\(" \
  -g "*.java" -g "*.kt" -n ${in_scope_main_src}

# Application.ActivityLifecycleCallbacks with lateinit access
rg "ActivityLifecycleCallbacks|onActivityCreated|onActivityResumed" \
  -g "*.java" -g "*.kt" -n ${in_scope_main_src}

# Settings/preference observers that trigger DB reads
rg "observeForever|addOnPropertyChangedCallback|registerOnSharedPreferenceChangeListener" \
  -g "*.java" -g "*.kt" -n ${in_scope_main_src}
```

For each hit, classify:
- **Safe** — runs after `onAuthorized()` (user-triggered action, secondary Activity)
- **Needs deferral** — runs before `onAuthorized()` (startup, system event)
- **Needs lifecycle-state guard** — `runOnAuthorized(...)` triggers fragment
  `commit()` without checking `FragmentManager.isStateSaved()` and deferring
  to `onPostResume()` (or equivalent resumed-state gate)

### 3. Apply Deferral Patterns

For each component that needs deferral, apply the appropriate pattern
from `21-authorization-deferral-patterns.md`:

| Component Type | Pattern |
|---------------|---------|
| ViewModel `init {}` with database access | Pattern 2: Observe `authorized` LiveData, init DB on `true` |
| Fragment `onViewCreated()` accessing ViewModel fields | Pattern 3: Observe `databaseReady` before setting up data observers |
| BroadcastReceiver `onReceive()` | Pattern 4: `isContainerAuthorized` static boolean guard |
| App widget factory | Pattern 5: Deferred widget init with `observeForever` |
| Data migration / schema upgrade | Pattern 6: Wrap in `authorized` observer |
| Utility function doing file I/O | Pattern 7: Static boolean guard on I/O, return path reference regardless |
| `!!` assertions on deferred fields | Pattern 8: Convert to `?.` safe calls, or adopt Pattern 12 |
| Activity helper methods (setupMenu, etc.) accessing DB | Pattern 9: Gate behind `databaseReady` LiveData |
| Activity defers heavy UI fields to `initializeAuthorizedUi` / `runOnAuthorized` | Pattern 14: ready/null-guard `onResume`/`onPause`/`onStop`/`onDestroy` + resume recovery after auth |
| Adapter setup (`setupAdapter`, `initAdapter`) passing GD-file-derived args | Pattern 7 guard on utility fn + Pattern 3 deferred adapter construction |
| Application.ActivityLifecycleCallbacks with `lateinit` access | Pattern 10: `::property.isInitialized` guard |
| ViewModel exposes nullable / DAO-backed `LiveData` to UI | Pattern 12: non-null placeholder + state machine (mandatory when Pattern 2 applies) |
| Fragment dereferences `viewModel.X!!` in `onViewCreated` / `setupObserver` | Pattern 12: non-null placeholder by construction; observation is always safe |
| Abstract Fragment template (`abstract fun getObservable()` etc.) overridden with `= model.X!!` in subclasses | Pattern 12: fix is in the ViewModel — publish a non-null placeholder so every subclass override can drop the `!!` |

**Deferred-init UI contract (MANDATORY)** — apply Pattern 12 from
`21-authorization-deferral-patterns.md` whenever ViewModel/database wiring
is delayed until authorization. The validator enforces this with
`[AUTH-UI-001]` (fail), `[AUTH-UI-002]` (warn), and `[AUTH-UI-003]` (fail
when the deferred-init startup state machine is incomplete).

**Deferred Activity UI lifecycle contract (MANDATORY)** — apply Pattern 14
whenever an Activity constructs instance fields only inside
`runOnAuthorized` / `initializeAuthorizedUi` / `onDynamicsAuthorized` /
`setupNavigation` (or equivalent). Guard `onResume` / `onPause` /
`onStop` / `onDestroy` **and** `onCreateOptionsMenu` /
`onPrepareOptionsMenu` until those fields are ready; establish
navigation/controllers before LiveData observes that use them; call
`invalidateOptionsMenu()` after Phase-2. Validator: `[AUTH-UI-004]`.

### 4. Add databaseReady Signal and Publish the Startup State Machine

If any ViewModel defers its database initialization (Pattern 2), add
a `databaseReady` LiveData signal that emits `true` after all
database-backed fields are initialized. Per Pattern 12, `databaseReady`
gates **interactive actions** (edits, navigation that mutates secure
data), not UI observation — UI observation is always safe because the
ViewModel exposes a non-null placeholder.

Required artifact: a **Startup State Machine** note included in the
migration output / `Dynamics_Migration_Readme.md` listing, per
participating ViewModel/Fragment:

1. `PRE_AUTH` — placeholder observable only (no DAO/Room subscription)
2. `AUTH_READY` — DB initialized, DAO stream forwarded into placeholder
3. `UI_ATTACHED` — Fragment/UI observers bound to non-null observable

See `21-authorization-deferral-patterns.md` Pattern 12 for the
MediatorLiveData / StateFlow implementations.

### 5. Post-Audit Build and Smoke Check (Mandatory)

Run `./gradlew assembleDebug` to confirm no compile errors from deferral
changes, then verify the following before marking this prompt complete:

**Pre-authorization scan** — confirm no secure API remains in Phase 1:
```bash
rg "GDFileSystem|com\.good\.gd\.database|GDHttpClient|GDSocket|BBCustomInterceptor|getApplicationPolicy" \
  -g "*.java" -g "*.kt" \
  -n
```
For each match, confirm it is inside a function that is only ever called
from `onAuthorized()`, an `authorized` LiveData observer, or another
post-auth path.

Re-run the audit from Step 2 as well. Every hit should now be either:
- Inside `onAuthorized()` or a method called from it
- Guarded by `isContainerAuthorized` check
- Deferred via LiveData observation on `authorized` or `databaseReady`
- In a secondary Activity (safe — user navigated there post-auth)
- In a user-triggered action (safe — UI is only interactive post-auth)

**Pre-authorization runtime smoke (required)** — this catches issues static
shape checks can miss (for example Room queries triggered by ViewModel
observers on `arch_disk_io` before `onAuthorized()`):

1. Clean install or clear app data.
2. Launch the app and do **not** interact past activation/authorization yet.
3. Capture startup logs:
   ```bash
   adb logcat -d | rg "GDNotAuthorizedError|RoomTrackingLiveData|getWritableDatabase|arch_disk_io"
   ```
4. Treat any hit during first-launch pre-auth as a hard failure for 03b.
5. Fix by deferring ViewModel/Fragment observer wiring until
   `authorized == true` (and `databaseReady == true` where applicable), then
   repeat the smoke until clean.

**Deferred-init nullability smoke**:
```bash
adb logcat -d | rg "NullPointerException|getObservable|setupObserver|onViewCreated"
```
Any startup NPE that traces to delayed model fields is a hard failure for 03b.

**Rollback instruction**: If deferral changes cause a build error or crash:
- Check that all `lateinit var` conversions to nullable properties have
  their call sites updated to use `?.` safe calls or `?.let {}` unwraps
- Check that any ViewModel whose `init {}` was deferred has a corresponding
  `databaseReady` LiveData that Fragments observe before accessing data
- If a singleton `init()` was changed to lazy — confirm every call site
  handles the case where the singleton is accessed before authorization
  (return early or throw in debug)
- Verify `isContainerAuthorized` guard is checked as the first statement
  in BroadcastReceiver `onReceive()` and widget factory methods

---

## Output

- List of every component audited with its classification (safe / deferred)
- Deferral pattern applied to each component
- Code changes made
- Verification that no pre-auth secure API access remains
- Build verified after changes (`./gradlew assembleDebug` passes)
- Startup state-machine note included (`PRE_AUTH -> AUTH_READY -> UI_ATTACHED`)

See `21-authorization-deferral-patterns.md` for the full steering reference
with code examples for each pattern.

---

## Record execution

After the deferral audit is complete and the build passes, append the
execution record:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 03b \
    --status completed \
    --files-touched <comma-separated relative paths>
```
