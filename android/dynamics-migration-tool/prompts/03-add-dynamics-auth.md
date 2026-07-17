## Task: Add BlackBerry Dynamics Authorization

Goal: Set up the kit-standard Dynamics authorization infrastructure —
Application class with global `GDStateListener`, `activityInit()` in every
main-process Activity, manifest fixes, and two-phase startup restructuring in
the main Activity.

**Prerequisites**:
- Prompt 01 (gradle-integration) must be complete — SDK dependency is added,
  minSdk is bumped, project builds
- Prompt 02 (create-settings-json) must be complete — `settings.json` exists
  with developer-provided GDApplicationID and GDApplicationVersion

**Key concept**: Dynamics wraps the app's data in an encrypted secure
container. On first launch the SDK handles activation (provisioning with
UEM) — the app has no control over this flow. On subsequent launches the
SDK prompts the user to unlock the container (password/biometric). The
app's own business logic (database access, file I/O, networking, policy
reads) cannot run until the container is unlocked and `onAuthorized()`
fires. This means the app must split its startup into two phases:
Phase 1 (onCreate) = UI shell only, Phase 2 (onAuthorized) = real app logic.

---

## Module map context (read first)

Load `dynamics-migration-tool/output/module-map.json` and resolve:

- `${primary}` — `primaryAppModule.path`. The Application class,
  `activityInit()` injection, manifest hardening, and
  `app_restrictions.xml` cleanup all happen inside the primary
  application module.
- `${primary_main_manifest}` — `${primary}/src/main/AndroidManifest.xml`.
- `${primary_manifests}` — every manifest file the module map
  associates with the primary module's source sets (main + each
  declared product flavor / build type). All manifest hardening edits
  apply across this set.
- `${primary_res_xml_dirs}` — every `res/xml/` directory on the
  primary module's source sets (main + flavors).

Activities and Application classes that live in **library modules**
listed under `libraryModulesInScope[]` and that are reachable from
the primary module's manifest also need the kit-standard Activity
initialization path. Walk
the dependency graph from the primary module: any Activity class in
an in-scope library module that is exported through the primary
module's manifest (or any merged library manifest under
`${primary_manifests}`) must receive `activityInit(this)` when it is
classified as a main-process Activity, just like Activities in the primary
module itself.

If `module-map.json` is missing, STOP and re-run `00pre-bootstrap.md`.

---

## Steps

### 0. Identify existing supported authorization patterns

Before editing, scan for Dynamics authorization and Activity monitoring
patterns that the public SDK supports but this kit does not use as its default
policy:

```bash
rg "authorize\\(|applicationInit\\(|GDMonitorActivity|GDStateAction|setGDAppEventListener" \
  -g "*.java" -g "*.kt" -g "*.xml" -n
```

If any are present:

- Treat them as **supported SDK patterns**, not as invented or unsupported
  APIs.
- Prefer converting them to the kit policy: Application-level
  `GDStateListener` + exactly-once `activityInit(this)` for main-process
  Activities.
- Do not layer `activityInit(this)` on top of an existing Activity monitoring
  annotation or Dynamics replacement Activity base class until you confirm
  whether that class already performs monitoring.
- Never leave direct `authorize(...)` and `activityInit(...)` mixed in the
  same migrated app. If the developer requires preserving a non-kit
  authorization architecture, stop and record the preserve/convert decision
  for prompt 10 rather than pretending the SDK does not support it.

### 1. Set Up Global GDStateListener in Application Class

**Start from the template — do not write this class from scratch.**

Copy `dynamics-migration-tool/templates/auth/DynamicsApplicationBase.java` (or `.kt` for
Kotlin apps) into your app source tree, rename the class, and update the package declaration.
The template contains the correct:
- 7 callback method signatures (including `Map<String, Object>` on `onUpdateConfig` /
  `onUpdatePolicy` — the most commonly mis-typed signatures)
- `isContainerAuthorized` volatile flag
- `authorized` LiveData for reactive ViewModels
- `runOnAuthorized(Runnable)` deferral queue
- `GDAndroid.getInstance().setGDStateListener(this)` wired in `Application.onCreate()`

Then:
- Register the Application class in `AndroidManifest.xml` (`android:name`)
- Fill in the `// TODO` markers with your app's real startup logic

**Signature guardrail (MANDATORY) — verify template matches your SDK version:**

Even after copying the template, confirm the `GDStateListener` interface in your locally
resolved SDK matches the template's method signatures:

```bash
GD_AAR=$(ls ~/.gradle/caches/modules-2/files-2.1/com.blackberry.blackberrydynamics/android_handheld_platform/*/*/*.aar 2>/dev/null | head -1)
TMP_DIR=$(mktemp -d)
unzip -p "$GD_AAR" libs/gd.jar > "$TMP_DIR/gd.jar"
javap -classpath "$TMP_DIR/gd.jar" com.good.gd.GDStateListener
rm -rf "$TMP_DIR"
```

Expected output (confirm these 7 methods are present with these exact signatures):
```
public abstract void onAuthorized();
public abstract void onLocked();
public abstract void onWiped();
public abstract void onUpdateConfig(java.util.Map);
public abstract void onUpdatePolicy(java.util.Map);
public abstract void onUpdateServices();
public abstract void onUpdateEntitlements();
```

If the SDK's actual signatures differ from the template (e.g., a new method was added),
update the Application class to match `javap` output exactly **before** proceeding.
`@Override` failures for any callback are step-introduced errors that must be fixed here.

This MUST happen before any Activity calls `activityInit()`.

### 2. Add activityInit() to Every Main-Process Activity

- Add `GDAndroid.getInstance().activityInit(this)` to every main-process
  Activity's `onCreate()`, right after `super.onCreate()`
- This includes secondary/detail activities, settings screens, etc.
- Activities do NOT need to implement `GDStateListener` — the global
  listener in the Application class satisfies the SDK requirement
- Under the kit policy, missing `activityInit()` or missing global listener
  causes `GDInitializationError`

**Process model (mandatory)**: Read `bootstrap.json` → `processModel` and follow
`steering/22-multi-process-app-handling.md`. Do **not** re-derive process rules
from manifest prose in this prompt.

- Activities classified **`main`**: add `GDAndroid.getInstance().activityInit(this)`
  after `super.onCreate()`.
- Activities classified **`auxiliary`**: **do not** call `activityInit()` (cross-process
  marshalling failure).
- `Application.onCreate()`: use the template `isMainProcess()` guard before
  `setGDStateListener`.

If `processModel` is missing, re-run `00pre-bootstrap.md`.

**Exactly-once inheritance rule (MANDATORY)**:

`activityInit(this)` must execute exactly once per Activity launch path.
If a base Activity already calls `activityInit(this)`, subclasses in that
inheritance chain must NOT call it again.

- **Allowed**: base class calls `activityInit(this)`, subclass does not.
- **Allowed**: base class does not call `activityInit(this)`, subclass does.
- **Forbidden**: both base and subclass call `activityInit(this)`.

Duplicate calls may trigger runtime warnings such as
`GD Monitor Fragment already inserted` and can lead to fragile startup
behavior.

**Application.ActivityLifecycleCallbacks Guard**: If the Application
class registers `ActivityLifecycleCallbacks` that access `lateinit`
properties (preferences, database handles, etc.), guard every callback
method with `::property.isInitialized` — these callbacks fire for the
SDK's internal Activities before `onAuthorized()` initializes the
properties.

### 3. Handle Manifest Merger Conflicts

- Add `tools` namespace to `<manifest>` if not present
- Add `tools:replace` for conflicting attributes (`supportsRtl`, `allowBackup`, etc.)
- Set `android:allowBackup="false"` (Dynamics manages secure backup)
- Only add attributes that actually conflict — the build error message
  specifies exactly which ones

### 4. Restructure Main Activity Startup (Two-Phase Initialization)

- Find ALL code in `onCreate()`, `onStart()`, or `onResume()` of the
  main/launch Activity (and any shared base Activity) that accesses:
  databases, files, **secure preferences / theme / settings helpers**,
  network, or policy
- Move that code into `onAuthorized()` or a helper method called from it
- Use `runOnUiThread()` in `onAuthorized()` if updating UI elements
- Set up an `isAuthorized` / `authorizedUiInitialized` flag if
  `onResume()` also needs to reload data or touch fields created only
  after authorization (Pattern 14)
- Secondary activities (launched via Intent after the user is already
  interacting with the app) are safe — the container is already unlocked

**Secure preferences are secure file I/O.** After SharedPreferences is
migrated to a Dynamics-backed helper (`SecurePreferencesHelper` or
equivalent using `com.good.gd.file.*`), every former prefs call site on
the launch path becomes a pre-auth crash risk — including theme
application, FLAG_SECURE toggles, PIN/biometric unlock reads, and
settings repositories allocated from `Activity.onCreate()`. Phase 11
enforces this as `[AUTH-PREF-001]`.

**Constructor / initializer audit (MANDATORY)**:

Before you close prompt 03, inspect constructors, field initializers,
singleton factories, and helper objects allocated from
`Application.onCreate()`, `Activity.onCreate()`, `Service.onCreate()`,
`BroadcastReceiver.onReceive()`, `ContentProvider.onCreate()`,
`androidx.startup.Initializer.create()`,
`Configuration.Provider.getWorkManagerConfiguration()`, and worker startup methods. No
startup-reachable constructor, initializer, or factory may instantiate
`com.good.gd.file.*`, secure SQL/database access, policy/config reads,
secure clipboard APIs, secure networking APIs, or **secure-preferences
helpers that perform GD file I/O in get/put methods** before authorization.

If a startup helper currently allocates secure repositories or file handles
as part of object construction, either:

- make the constructor side-effect free and move secure setup to an explicit
  post-auth method, or
- move the allocation itself behind `runOnAuthorized(...)`,
  `authorized.observe(...)`, `databaseReady`, or another explicit
  post-auth gate.

**Do not leave secure-prefs reads in Phase-1 lifecycle methods.** Theme,
settings, PIN material, and similar preference reads that used to call
`SharedPreferences` must not call the Dynamics-backed helper from
`onCreate`/`onStart`/`onResume` until authorization. Validator:
`[AUTH-PREF-001]`.

**Deferred-init UI contract (MANDATORY handoff to Prompt 03b)**: if any
model/VM data source is deferred until authorization, follow Pattern 12
in `steering/21-authorization-deferral-patterns.md` — publish a non-null
placeholder observable in Phase 1 and never use `!!` on delayed model
fields in startup paths. Prompt 03b performs the full audit; the
validator enforces `[AUTH-UI-001]` (fail), `[AUTH-UI-002]` (warn), and
`[AUTH-UI-003]` (fail when the deferred-init startup state machine is
incomplete).

**Deferred Activity UI lifecycle contract (MANDATORY)**: when the launch
Activity constructs heavy UI dependencies only inside
`runOnAuthorized` / `initializeAuthorizedUi()` / `onDynamicsAuthorized()` /
`setupNavigation()` (preview, `NavController`, app interface, adapters),
those fields are still uninitialized when Phase-1 framework callbacks fire
(`onResume`, `onCreateOptionsMenu` after `setSupportActionBar`). Follow
Pattern 14 in `steering/21-authorization-deferral-patterns.md`:

1. Null/ready/`isInitialized` guards on lifecycle **and menu** methods
2. Phase-2 order: navigation/controllers **before** LiveData/prefs observes
   that use them
3. `invalidateOptionsMenu()` (and resume recovery) after Phase-2

Validator: `[AUTH-UI-004]`.

**CRITICAL — lifecycle-safe UI initialization after authorization**

Do **not** run fragment transactions directly from `runOnAuthorized(...)`
without lifecycle/state checks. Activation/unlock can complete after the
Activity has already run `onSaveInstanceState`, and direct `commit()` then
crashes with:

`IllegalStateException: Can not perform this action after onSaveInstanceState`

Use this pattern for launch Activities that initialize fragments post-auth:

```java
private boolean pendingAuthorizedUiInit = false;
private Bundle pendingSavedState;

@Override
protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    GDAndroid.getInstance().activityInit(this);
    setContentView(R.layout.activity_main);

    pendingSavedState = savedInstanceState;
    MyApplication.runOnAuthorized(() -> runOnUiThread(this::requestAuthorizedUiInit));
}

private void requestAuthorizedUiInit() {
    if (isFinishing() || isDestroyed()) return;
    if (getSupportFragmentManager().isStateSaved()) {
        pendingAuthorizedUiInit = true;
        return;
    }
    pendingAuthorizedUiInit = false;
    initializeAuthorizedUi(pendingSavedState);  // fragment add/show/hide commit() happens here
}

@Override
protected void onPostResume() {
    super.onPostResume();
    if (pendingAuthorizedUiInit) {
        requestAuthorizedUiInit();
    }
}
```

Forbidden anti-pattern:

```java
// UNSAFE: may execute after onSaveInstanceState
app.runOnAuthorized(() -> runOnUiThread(() -> initializeAuthorizedUi(savedInstanceState)));
```

### 5. Migrate RestrictionsManager (if applicable)

- Remove `APP_RESTRICTIONS` `<meta-data>` element from every manifest
  in `${primary_manifests}`.
- **Also delete every `app_restrictions.xml` resource under
  `${primary_res_xml_dirs}` in the same step** — once the manifest
  entry is gone, the file is unreferenced and must not linger. The
  validator emits a warning when it stays behind
  (`app_restrictions.xml still exists`), and the developer will not
  know which prompt is responsible for removing it.

  Run from the project root, for each `<res_xml_dir>` in
  `${primary_res_xml_dirs}`:

  ```bash
  rm -f <res_xml_dir>/app_restrictions.xml
  ```

  Verify both removals across the full set:

  ```bash
  rg "APP_RESTRICTIONS" ${primary_manifests} || echo "OK: manifests clean"
  for d in ${primary_res_xml_dirs}; do
    test -f "$d/app_restrictions.xml" \
        && echo "❌ app_restrictions.xml still present at $d" \
        || echo "OK: app_restrictions.xml removed under $d"
  done
  ```

  Include every removed `app_restrictions.xml` path in the
  `--files-touched` list when recording this prompt so the audit trail
  shows the deletions were intentional.

- Replace `RestrictionsManager` with `GDAndroid.getApplicationPolicy()`
- Replace policy update `BroadcastReceiver` with `onUpdatePolicy()` callback

### 6. Build and Verify

Run `./gradlew assembleDebug` to verify the project compiles.

If the build fails, classify each error against the developer's pre-migration clean-build attestation:
- **Pre-existing**: already present before migration
- **Step-introduced**: caused by changes in this prompt — fix before proceeding
- **Unrelated**: environment or transient issue

Specifically for auth wiring, any `GDStateListener` override mismatch
(e.g., "does not override abstract method onUpdatePolicy(...)") is
**step-introduced** and must be fixed in prompt 03 before continuing.

### 7. Post-Change Startup Safety Checks (Mandatory)

Before marking this prompt complete, verify each of the following. If any
check fails, fix it before proceeding to Prompt 03b.

**Check 1 — No secure API access before onAuthorized()**
After refactoring, run a scan for any remaining secure API usage
outside of `onAuthorized()` callbacks:
```bash
rg "GDFileSystem|SQLiteOpenHelper|GDHttpClient|GDSocket|BBCustomInterceptor|getApplicationPolicy" \
  -g "*.java" -g "*.kt" -l
```
For each file found, confirm those usages are inside a post-auth guard
(i.e., gated by `isContainerAuthorized` or called from `onAuthorized()`).

**Check 1b — No constructor-transitive secure API reachability from startup**
Inspect every helper, repository, singleton, and factory allocated from
startup paths (`Application`/`Activity`/`Service`/`BroadcastReceiver`/
`ContentProvider`/`Initializer`/WorkManager config provider). Constructors,
field initializers, and `init {}` blocks must stay side-effect free until
authorization:
```bash
rg "runOnAuthorized|authorized\\.observe|databaseReady|new [A-Z][A-Za-z0-9_]*\\(|[A-Z][A-Za-z0-9_]*\\(" \
  -g "*.java" -g "*.kt" -n
```
For every startup allocation path, confirm any secure API construction
(`com.good.gd.file.*`, secure DB handles, policy/config reads, secure
clipboard, `GDHttpClient`, `GDSocket`) happens only after a post-auth gate.

**Check 2 — Placeholder/loading UI shown in Phase 1**
Confirm the main Activity's `onCreate()` sets up only placeholder UI
(e.g., a splash layout, progress indicator, or empty view) before
authorization. Without it, the app may show stale data or crash when
accessing secure storage pre-auth.

**Check 2b — No unsafe fragment transactions in auth callback**
If `runOnAuthorized(...)` triggers fragment transactions (`beginTransaction().commit()`),
verify the Activity guards state-save windows via `isStateSaved` + deferred
retry in `onPostResume()` (or equivalent lifecycle-resumed pattern). Direct
commit from auth callback without this guard is a post-activation crash risk.

**Check 3 — activityInit() present in every kit-policy Activity**
Run a scan to verify no main-process Activity is missing `activityInit()`:
```bash
rg "extends\s+(AppCompat)?Activity|:\s*(AppCompat)?Activity" \
  -g "*.java" -g "*.kt" -l
```
Cross-reference each result against:
```bash
rg "activityInit" -g "*.java" -g "*.kt" -l
```
Any main-process Activity missing `activityInit()` under the kit policy can
cause `GDInitializationError`.

**Check 3b — no duplicate activityInit() in inheritance chains**
For each Activity class, inspect its base class chain and confirm only one
class in the chain invokes `activityInit(this)`.

If both parent and child call it, remove the child call and keep the
single canonical call in the highest common base Activity.

**Check 3c — global listener registration verified [AUTH-LISTENER-001]**

Verify `setGDStateListener` is called in the Application class:
```bash
rg "setGDStateListener" -g "*.java" -g "*.kt" -l
```

If this returns zero results AND any Activity calls `activityInit()` without
implementing `GDStateListener` itself, the app WILL crash with
`GDInitializationError` on every launch. This is a mandatory check — do
not proceed to prompt 03b until this passes.

Cross-reference: for every Activity calling `activityInit()`, confirm that
EITHER:
- The Activity (or its base class) implements `GDStateListener`, OR
- `setGDStateListener(this)` is called in the Application's `onCreate()`

The validator enforces this as `[AUTH-LISTENER-001]` (hard failure).

**Check 3d — existing supported alternatives handled intentionally**

Re-run the preflight scan from step 0. Any remaining
`authorize(...)`, `applicationInit(...)`, `GDMonitorActivity`,
`GDStateAction`, or replacement-Activity monitoring pattern must have a clear
preserve/convert rationale in the migration notes/report. Do not describe
these as unsupported SDK APIs; describe them as outside the kit's default
authorization policy.

**Check 4 — Application class registered in manifest**
Confirm `AndroidManifest.xml` has `android:name` pointing to the
Application class that implements `GDStateListener`.

**Rollback instruction**: If the app crashes immediately after
authorization changes (blank screen, `GDInitializationError`, or SDK
lock screen stuck):
1. Verify `activityInit(this)` is called in `onCreate()` after `super.onCreate()`
2. Verify no Activity inheritance chain calls `activityInit(this)` more than once
3. Verify `GDAndroid.getInstance().setGDStateListener(this)` is called in
   `Application.onCreate()` — using `applicationInit(this)` is NOT equivalent
   and will NOT register the listener. If `setGDStateListener()` is missing,
   every Activity that calls `activityInit()` without implementing
   `GDStateListener` will crash with `GDInitializationError` [AUTH-LISTENER-001]
4. Check `AndroidManifest.xml` for `android:name` on the `<application>` tag
5. Verify no secure API calls happen before `onAuthorized()` fires

---

## What This Prompt Does NOT Cover

The full authorization deferral audit (ViewModels, Fragments, widgets,
receivers, migrations, utility functions) is handled by **Prompt 03b
(authorization-deferral-audit)**. This prompt focuses on the main
Activity's startup restructuring only. Prompt 03b systematically traces
every pre-auth secure API chain across the entire codebase.

---

## Output

- Application class with global GDStateListener
- `activityInit()` added to every main-process Activity governed by the kit
  policy
- Existing supported non-kit authorization patterns converted or documented
- Manifest merger conflicts resolved
- Main Activity startup restructured (two-phase)
- RestrictionsManager migrated (if applicable)
- Build verification result
- How to test authorization (first activation + subsequent unlock)

See `20-auth-initialization.md` and `21-authorization-deferral-patterns.md`
for the full steering references.

Public references:
- [BlackBerry Dynamics Android API Reference](https://developer.blackberry.com/files/blackberry-dynamics/android/)
- [`GDAndroid` class reference](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1_g_d_android.html)

---

## Record execution

After authorization is wired and the build passes, append the execution
record:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 03 \
    --status completed \
    --files-touched <comma-separated relative paths>
```
