# Steering: Dynamics Authorization & Initialization

Dynamics applications must initialize the Dynamics runtime and handle
authorization state before accessing secure features.

> **Multi-process apps:** Read `processModel` from `bootstrap.json` and follow
> `steering/22-multi-process-app-handling.md`. Do not call `activityInit()` on
> Activities classified `auxiliary`; guard `Application.onCreate()` with
> `isMainProcess()` (see `templates/auth/DynamicsApplicationBase.*`).

> **Multi-module note**: `app/src/main/assets/settings.json` and
> `app/src/main/AndroidManifest.xml` references below are
> canonical-shape illustrations. On multi-module / flavored projects,
> read placeholders from
> `dynamics-migration-tool/output/module-map.json` —
> `${primary_assets_dirs}` for settings.json targets and
> `${primary_manifests}` for manifest hardening targets. The
> Application class lives in the primary module; Activities exported
> through any merged manifest still need the kit-standard Activity
> initialization path (`activityInit(this)` for main-process Activities; see
> `04-multi-module-projects.md`).

---

## Your Responsibilities

- Locate or create the Application class
- Integrate Dynamics initialization at app startup
- Ensure unauthorized or unprovisioned states are handled safely
- Create required configuration files
- Handle manifest merger conflicts with the Dynamics SDK
- **Consult the Architecture Diagrams** from
  `dynamics-migration-tool/output/architecture-diagrams.md` (if available).
  Specifically, Section 4 (Lifecycle Dependency Map) traces every startup
  chain from lifecycle event to secure API call and Section 4B (Summary Table)
  specifies which deferral pattern to apply. Section 5 (Secure API Call Graph)
  provides a bottom-up reverse trace that catches chains top-down tracing misses.

---

## Mandatory Behavior (UEM entitlement IDs)

- **`GDApplicationID` and `GDApplicationVersion`** come from the UEM
  administrator (not the app’s package name or `versionName`).
- They are captured **once** in prompt `00pre-bootstrap.md` and stored in
  `dynamics-migration-tool/output/bootstrap.json`.
- Prompt **`02-create-settings-json.md`** copies those values into
  `app/src/main/assets/settings.json`. Prompt **03** (this flow) must **not**
  ask for UEM credentials; if `settings.json` is missing or wrong, send the
  developer back to `00pre-bootstrap.md` / prompt 02 — do not embed
  placeholders, guesses, or inferred entitlement IDs.
- Provide a clear failure path if authorization is incomplete.

---

## Required Assets Configuration

### settings.json File

Create `app/src/main/assets/settings.json` with real UEM entitlement values
(same strings as `bootstrap.json` → `uem.gdApplicationId` /
`uem.gdApplicationVersion`). Prompt `02-create-settings-json.md` performs
this write; if you are touching auth before prompt 02, ensure that file
already exists from the bootstrap-driven flow.

```json
{
  "GDApplicationID": "<from bootstrap.json uem.gdApplicationId>",
  "GDLibraryMode": "GDEnterprise",
  "GDApplicationVersion": "<from bootstrap.json uem.gdApplicationVersion>"
}
```

**Required Actions**:
- Do **not** ask the developer for these fields in the authorization prompt —
  they were confirmed with the UEM admin during `00pre-bootstrap.md`.
- Do NOT guess values from `build.gradle` or the package name.
- `GDLibraryMode` should be `"GDEnterprise"` for standard deployments.

**Critical**: The app will not authorize without this file.

---

## Supported SDK Entry Paths vs Kit Policy

The public Dynamics Android SDK supports more than one authorization and
Activity monitoring model. This migration kit deliberately standardizes on
one model so prompts, templates, validation, and reporting can reason about
startup deterministically:

**Kit policy:** one Application-scoped `GDStateListener` registered with
`GDAndroid.getInstance().setGDStateListener(...)`, plus
`GDAndroid.getInstance().activityInit(this)` exactly once for every
main-process Activity launch path.

When analyzing an existing app, do not label other documented SDK patterns as
"unsupported." Instead, identify them and make an explicit migration decision:

| Existing supported SDK pattern | Migration decision |
|---|---|
| `GDAndroid.getInstance().authorize(GDAppEventListener)` direct authorization | Convert to the kit policy unless the app intentionally owns a non-Activity authorization flow. Never mix `authorize(...)` with `activityInit(...)` in the same migrated app. |
| Activity monitoring annotation such as `GDMonitorActivity` | Convert to explicit `activityInit(this)` so Phase 3 can prove exactly-once initialization, or preserve only with a documented developer decision and validator/report follow-up. |
| Dynamics replacement Activity base classes | Convert to the app's existing Activity base class plus explicit `activityInit(this)` unless preserving the replacement class is an intentional architecture decision. Do not add a duplicate `activityInit` call if the replacement/base class already performs monitoring. |
| `GDStateAction` local broadcasts for state changes | Prefer the Application `GDStateListener` and `runOnAuthorized(...)` helper for migrated code. If existing code consumes these broadcasts, trace each receiver and convert it to the central state helper or document why the broadcast bridge remains. |
| `applicationInit(...)` receiver-before-auth flows | Do not substitute it for `setGDStateListener(...)`. If an app already uses this supported startup pattern, trace the receiver flow and decide whether to preserve it, convert it to the kit policy, or move the secure work to Background Authorize (`70-background-authorize.md`). |

The current validator enforces the kit policy. Preserving a different
documented SDK pattern is a deliberate exception, not a claim that the SDK
does not support the pattern.

---

## Application Class Setup — Kit Policy: Global GDStateListener

The Dynamics SDK requires that a `GDStateListener` is available when any
Activity calls `activityInit()`. There are two ways to satisfy this:

1. **Global listener (recommended)**: Set a singleton `GDStateListener` via
   `GDAndroid.getInstance().setGDStateListener(...)` in `Application.onCreate()`.
   This is done once, centrally, and all Activities just call `activityInit()`.
2. **Per-Activity listener**: Each Activity implements `GDStateListener`.
   This works but is noisy and repetitive in multi-activity apps.

**For this migration kit, use the global listener approach.** It is more
robust for multi-activity migrations, avoids the common crash where a
secondary Activity calls `activityInit()` without implementing the interface,
and centralizes authorization state management.

### Creating the Application Class

Create an Application class that implements `GDStateListener` and registers
itself as the global listener:

```java
package com.example.app;

import android.app.Application;
import android.util.Log;
import com.good.gd.GDAndroid;
import com.good.gd.GDStateListener;
import java.util.Map;

// [BB_DYNAMICS-MIGRATION] Application class with global GDStateListener
public class MyApplication extends Application implements GDStateListener {

    private static final String TAG = "MyApplication";
    private static boolean isAuthorized = false;
    private static Runnable onAuthorizedCallback = null;

    @Override
    public void onCreate() {
        super.onCreate();
        // Register global listener BEFORE any Activity calls activityInit()
        GDAndroid.getInstance().setGDStateListener(this);
    }

    /** Check if the container has been unlocked. */
    public static boolean isContainerAuthorized() {
        return isAuthorized;
    }

    /**
     * Register a callback to run when authorized.
     * If already authorized, runs immediately.
     */
    public static void runOnAuthorized(Runnable callback) {
        if (isAuthorized) {
            callback.run();
        } else {
            onAuthorizedCallback = callback;
        }
    }

    @Override
    public void onAuthorized() {
        Log.d(TAG, "Dynamics authorized");
        isAuthorized = true;
        if (onAuthorizedCallback != null) {
            onAuthorizedCallback.run();
            onAuthorizedCallback = null;
        }
    }

    @Override public void onLocked() { Log.d(TAG, "Dynamics locked"); }
    @Override public void onWiped() { Log.d(TAG, "Dynamics wiped"); isAuthorized = false; }
    @Override public void onUpdateConfig(Map<String, Object> map) { }
    @Override public void onUpdatePolicy(Map<String, Object> map) { }
    @Override public void onUpdateServices() { }
    @Override public void onUpdateEntitlements() { }
}
```

### Register in AndroidManifest.xml

```xml
<!-- [BB_DYNAMICS-MIGRATION] Registered Application class with global GDStateListener -->
<application
    android:name=".MyApplication"
    ...>
```

### Main-Process Activities Use activityInit()

Every main-process Activity governed by the kit policy must call
`activityInit()` in `onCreate()`, right after `super.onCreate()`:

```java
@Override
protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    GDAndroid.getInstance().activityInit(this);
    setContentView(R.layout.activity_whatever);
    // ...
}
```

The Activity does NOT need to implement `GDStateListener` — the global
listener in the Application class satisfies the SDK requirement.

### Kit-disallowed: direct `authorize()` mixed with `activityInit()`

This migration kit uses **`activityInit()` as its Activity authorization
entry path**. The public SDK also exposes
`GDAndroid.getInstance().authorize(GDAppEventListener)` (see
[`GDAndroid` class reference](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1_g_d_android.html)),
but that path is **mutually exclusive** with `activityInit()` in the same
app: mixing both builds but breaks at runtime.

**Do not** call `authorize()` in any class that also calls `activityInit()`,
and do not migrate apps to use both patterns. If the source app already uses
direct `authorize(...)`, record it as a supported SDK pattern that this kit is
converting to the global-listener/`activityInit` policy. Phase 3 of
`tooling/validate.sh` hard-fails when both appear in scope.

```java
// FORBIDDEN in this kit when activityInit() is wired anywhere in the app:
GDAndroid.getInstance().authorize(this);

// Kit-policy entry path (every main-process Activity):
GDAndroid.getInstance().activityInit(this);
```

For authorization events, use a global `GDStateListener` on the
Application class (see above), not `GDAppEventListener` via `authorize()`.
Background entry points use `canAuthorizeAutonomously(this)` +
`serviceInit(this)` instead — see `70-background-authorize.md`.

### CRITICAL: Exclude Activities in Separate Processes

**Do NOT call `activityInit()` in any Activity that has
`android:process` set in the manifest.** When an Activity runs in a
separate OS process (e.g., `android:process=":error_activity"`),
`activityInit()` attempts to bind to the Dynamics service in the main
process via IPC. That IPC `Message` contains non-Parcelable objects,
which Android's `Messenger` rejects with:

```
java.lang.RuntimeException: Can't marshal non-Parcelable objects
across processes.
    at com.good.gd.client.GDClient$shy.onServiceConnected
```

**Before injecting `activityInit()`, scan for separate-process components:**

```bash
rg "android:process" app/src/main/AndroidManifest.xml
```

Skip `activityInit()` for every Activity, Service, or BroadcastReceiver
that matches. Common separate-process components:
- Crash-reporter Activities (`CustomActivityOnCrash`, `ErrorActivity`)
- Remote Services for background work
- Any component with `android:process` in its manifest declaration

### CRITICAL: Guard Application.ActivityLifecycleCallbacks

If the Application class registers `ActivityLifecycleCallbacks` (e.g.,
to apply `FLAG_SECURE` or track activity state), those callbacks fire
for ALL Activities — including the Dynamics SDK's internal Activities
during activation and unlock. This happens **before** `onAuthorized()`
initializes any `lateinit` properties.

**Guard all `lateinit` property access with `isInitialized`:**

```kotlin
override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
    if (!::preferences.isInitialized) return  // SDK activities fire before init
    if (preferences.secureFlag.value) {
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
}
```

Without this guard, the first Activity lifecycle event (triggered by the
SDK's activation screen) throws `UninitializedPropertyAccessException`
and crashes the app before the user even sees the activation UI.

### Deferring Secure API Access in the Launch Activity

The launch/main Activity must defer its data-loading logic until the
container is authorized. Use the Application class helper:

```java
@Override
protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    GDAndroid.getInstance().activityInit(this);
    setContentView(R.layout.activity_main);

    // Set up UI shell (view references, navigation listeners)
    // Do NOT access secure APIs here.

    // Defer data loading until container is authorized
    MyApplication.runOnAuthorized(new Runnable() {
        @Override
        public void run() {
            runOnUiThread(() -> loadAppData());
        }
    });
}
```

### CRITICAL: Fragment transactions from auth callback must be state-safe

When authorization completes, the app may be backgrounded or mid-lifecycle.
If `runOnAuthorized(...)` directly calls fragment `commit()`, the Activity
can already be state-saved and crash:

`IllegalStateException: Can not perform this action after onSaveInstanceState`

Use a deferred UI-init gate:

```java
private boolean pendingAuthorizedUiInit = false;

private void requestAuthorizedUiInit() {
    if (isFinishing() || isDestroyed()) return;
    if (getSupportFragmentManager().isStateSaved()) {
        pendingAuthorizedUiInit = true;
        return;
    }
    pendingAuthorizedUiInit = false;
    initializeAuthorizedUi(); // commit() happens only when safe
}

@Override
protected void onPostResume() {
    super.onPostResume();
    if (pendingAuthorizedUiInit) requestAuthorizedUiInit();
}
```

Forbidden pattern:

```java
// UNSAFE when auth callback races with onSaveInstanceState
app.runOnAuthorized(() -> runOnUiThread(() -> initializeAuthorizedUi(savedInstanceState)));
```

### CRITICAL: Startup object graphs must be side-effect free

Do not assume "nothing secure happens before `onAuthorized()`" just because
the main Activity's `onCreate()` looks clean. Pre-auth crashes often come
from **constructor-transitive** work:

- helper or repository constructors allocated from `Application.onCreate()`,
  `Activity.onCreate()`, `Service.onCreate()`, `BroadcastReceiver.onReceive()`,
  `ContentProvider.onCreate()`, `androidx.startup.Initializer.create()`,
  `Configuration.Provider.getWorkManagerConfiguration()`, or worker startup methods
- field initializers and `init {}` blocks on those startup-reachable objects
- singleton / factory helpers that allocate secure-storage or secure-network
  objects as part of "lightweight" bootstrap

**Rule:** no constructor, field initializer, `init {}` block, or startup
factory reachable from those pre-auth paths may instantiate or touch
`com.good.gd.file.*`, secure SQL/database access, policy/config reads,
secure clipboard APIs, or secure networking APIs before authorization.
The same rule applies to **method-body** secure-preferences I/O
(`SecurePreferencesHelper.getString` / `putString` and equivalents): do not
call them from Activity/Application `onCreate` / `onStart` / `onResume`
before authorization even when the helper constructor itself is clean.
Phase 11 enforces constructor reachability as `[AUTH-CTOR-001]` /
`[AUTH-STARTUP-001]` and lifecycle prefs/file reachability as
`[AUTH-PREF-001]`.

Phase 11 also enforces provider/App Startup/WorkManager wiring discovered
from manifest providers, App Startup metadata, and WorkManager
default-initializer wiring (`[AUTH-STARTUP-001]`).

Safe patterns:

- keep constructors and field initializers side-effect free
- allocate secure repositories lazily inside a post-auth method
- move the first secure allocation behind `runOnAuthorized(...)`,
  `authorized.observe(...)`, or another explicit post-auth gate

Unsafe pattern:

```kotlin
class SaveLocationHandler {
    private val repo = SecureMediaRepository() // not safe if created from onCreate()
}

class SecureMediaRepository {
    private val root = com.good.gd.file.File("media") // touches secure storage too early
}
```

### Important Notes

- `setGDStateListener()` MUST be called in `Application.onCreate()` before
  any Activity calls `activityInit()` — otherwise the SDK throws
  `GDInitializationError`
- If the app has no Application class, create one
- If the app already has an Application class, add `implements GDStateListener`
  and the `setGDStateListener()` call to its `onCreate()`
- If the app already uses a different documented SDK authorization pattern
  (`authorize(...)`, `GDMonitorActivity`, replacement Activity classes,
  `GDStateAction`, or `applicationInit(...)`), decide explicitly whether to
  convert it to the kit policy or preserve it with developer sign-off. Do not
  silently layer `activityInit()` on top of an existing monitoring mechanism.

---

## Migrating from Android Managed Configurations

If the app uses Android's RestrictionsManager for policy:

### Discovery
Look for:
- `RestrictionsManager` usage
- `<meta-data android:name="android.content.APP_RESTRICTIONS" />` in manifest
- `res/xml/app_restrictions.xml`
- `BroadcastReceiver` for `ACTION_APPLICATION_RESTRICTIONS_CHANGED`

### Migration Steps

1. **Remove Android Managed Configuration**:
   - Delete `<meta-data android:name="android.content.APP_RESTRICTIONS" />` from AndroidManifest.xml
   - Delete `res/xml/app_restrictions.xml` (if exists)

2. **Replace Policy Retrieval**:
   ```java
   // OLD: Android Managed Configurations
   RestrictionsManager mgr = (RestrictionsManager) context.getSystemService(Context.RESTRICTIONS_SERVICE);
   Bundle restrictions = mgr.getApplicationRestrictions();
   
   // NEW: BlackBerry Dynamics
   Map<String, Object> policy = GDAndroid.getInstance().getApplicationPolicy();
   String policyJson = GDAndroid.getInstance().getApplicationPolicyString();
   ```

3. **Replace Policy Updates**:
   ```java
   // OLD: BroadcastReceiver
   IntentFilter filter = new IntentFilter(Intent.ACTION_APPLICATION_RESTRICTIONS_CHANGED);
   registerReceiver(receiver, filter);
   
   // NEW: GDStateListener callback
   @Override
   public void onUpdatePolicy(Map<String, Object> policy) {
       // Handle policy update
   }
   ```

4. **Data Structure Changes**:
   - Android: Uses `Bundle` (flat key-value pairs)
   - Dynamics: Uses `Map<String, Object>` (supports nested structures)
   - Dynamics policy can contain complex JSON structures

### Policy Data Structure Example

Dynamics policy returns nested Map/Vector structures:

```java
import com.good.gd.GDAndroid;
import com.good.gd.error.GDNotAuthorizedError;
import java.util.Map;
import java.util.Vector;

// Get policy
GDAndroid gdAndroid = GDAndroid.getInstance();
String policyString = "";
Map<String, Object> policyMap = new HashMap<>();

try {
    policyString = gdAndroid.getApplicationPolicyString();  // JSON string
    policyMap = gdAndroid.getApplicationPolicy();           // Parsed Map
} catch (GDNotAuthorizedError e) {
    // Handle not authorized - app may not be fully initialized yet
}

// Access nested policy values (structure depends on your UEM policy definition)
// Example: accessing a nested "settings" object with an "enabled" array
Map<String, Object> settings = (Map<String, Object>) policyMap.get("settings");
if (settings != null) {
    Vector<Object> enabledFeatures = (Vector<Object>) settings.get("enabled");
    if (enabledFeatures != null) {
        for (Object feature : enabledFeatures) {
            String featureName = (String) feature;
            // Process feature based on policy
        }
    }
}
```

### Key Differences from Android Managed Configurations

| Aspect | Android RestrictionsManager | BlackBerry Dynamics |
|--------|---------------------------|---------------------|
| Data Type | `Bundle` | `Map<String, Object>` |
| Structure | Flat key-value | Nested (Map/Vector) |
| Access | `getApplicationRestrictions()` | `getApplicationPolicy()` |
| Updates | BroadcastReceiver | `onUpdatePolicy()` callback |
| Raw Format | N/A | `getApplicationPolicyString()` (JSON) |

---

## CRITICAL: Understanding the Dynamics Secure Container Lifecycle

**This section is the most important concept in the entire migration.**

BlackBerry Dynamics wraps the app's data in an encrypted secure container.
All Dynamics-managed storage (SQLite databases, files, network connections,
policy data) lives inside this container. The container is **not accessible**
until the SDK explicitly signals that it is ready via the `onAuthorized()`
callback.

Think of it like a vault: the app process starts, but the vault door is
still locked. The app can set up its UI, but it cannot read or write any
data that lives inside the vault until the SDK opens it.

### Container Lifecycle Scenarios

The container goes through different flows depending on the app's state:

| Scenario | What Happens | When `onAuthorized()` Fires |
|----------|-------------|----------------------------|
| **First launch (activation)** | SDK presents its own activation UI. User enters email + access key (or QR code). SDK provisions the container, downloads policies, creates the encrypted store. | After activation completes successfully. The app has no control over this — the SDK handles the entire flow. |
| **Subsequent launch (unlock)** | SDK presents a password/biometric prompt to unlock the existing container. | After the user successfully unlocks. |
| **Already running (resume)** | If the container is still unlocked (user switches back to the app within the idle timeout), no prompt is shown. | `onAuthorized()` fires again immediately. |
| **Idle lock** | UEM policy defines an idle timeout. When it expires, the SDK overlays a lock screen on top of the app. The container remains decrypted in memory — the app process keeps running and background tasks retain full access to secure APIs. The user just cannot interact with the UI until they re-authenticate. | `onAuthorized()` fires again after the user re-authenticates. `onLocked()` fires when the lock screen appears. |
| **Remote lock** | UEM admin remotely locks the container. Unlike idle lock, this is a hard lock — the container becomes inaccessible to the application layer. The user must obtain a Temporary Unlock Key from the admin to reactivate. Treat this the same as the container being encrypted on disk. | `onAuthorized()` fires only after the user reactivates with the Temporary Unlock Key. |
| **Remote wipe** | UEM admin wipes the container. `onWiped()` fires. All secure data is destroyed. | Never — the app should handle `onWiped()` gracefully. |

**Key insight**: The critical boundary is between "container is not
accessible" and "container is decrypted in memory." There are two distinct
lock types and they behave very differently:

- **Idle lock**: UI-only lock screen. The container stays decrypted in
  memory. The app process keeps running, background tasks retain full
  access to secure APIs (databases, files, networking). The user just
  can't interact with the UI until they re-authenticate.
- **Remote lock**: Hard lock. The container becomes inaccessible to the
  application layer. The user must obtain a Temporary Unlock Key from
  the UEM admin to reactivate. Treat this like the container being
  encrypted on disk — no secure API access is possible.

Once the container is initially unlocked (after first activation or
subsequent launch), it stays decrypted in memory for the lifetime of the
app process — unless a remote lock occurs. Idle lock does NOT re-encrypt
the container.

The app MUST wait for the initial `onAuthorized()` before touching any
secure API. There is no shortcut and no way to predict when it will fire.
On first launch it could take minutes (user going through activation). On
subsequent launches it depends on the user entering their password.

### What This Means for Migrated Apps

In a standard Android app, `onCreate()` is where you typically:
- Open the database and load data
- Read configuration files from disk
- Start network requests to fetch initial content
- Set up adapters with data from local storage

After migration to Dynamics, **none of this can happen in `onCreate()`**
because the secure container is still locked at that point. The app must
split its initialization into two phases:

1. **Phase 1 — `onCreate()`**: UI shell only (layout, view references,
   click listeners for navigation). No data access.
2. **Phase 2 — `onAuthorized()`**: All application-specific logic that
   involves data — database queries, file reads, network calls, policy
   reads. This is where the app "really starts."

### Secure APIs That Require the Container to Be Unlocked

| API Category | Examples | Typical App Usage |
|-------------|----------|-------------------|
| Secure SQLite | `SQLiteOpenHelper.getReadableDatabase()`, `.getWritableDatabase()`, `SQLiteDatabase.openOrCreateDatabase()` | Loading lists, reading settings, any DB query |
| Secure Filesystem | `GDFileSystem.openFileInput()`, `.openFileOutput()`, `com.good.gd.file.FileInputStream/FileOutputStream` | Reading saved files, writing exports, loading cached data |
| Secure Networking | `GDHttpClient.execute()`, `GDSocket.connect()` | API calls, downloading content, syncing data |
| Policy | `GDAndroid.getApplicationPolicy()`, `.getApplicationPolicyString()` | Reading enterprise configuration |

**All of these will throw `GDNotAuthorizedError` if called before the
container is unlocked.**

### The Pattern: Two-Phase Initialization

This example uses the **global listener** approach (recommended for
migrations). The Activity does not implement `GDStateListener` — it
relies on the Application class's `runOnAuthorized()` helper shown
earlier in this document.

```java
public class MainActivity extends AppCompatActivity {

    private ListView listView;
    private MyAdapter adapter;
    private boolean isAuthorized = false;

    // ── Phase 1: UI shell (container is still locked) ──────────────
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        GDAndroid.getInstance().activityInit(this);
        setContentView(R.layout.activity_main);

        listView = findViewById(R.id.listView);
        // Set up click listeners for navigation, FABs, etc.
        // Do NOT access databases, files, network, or policy here.

        // Defer data loading until container is authorized
        MyApplication.runOnAuthorized(new Runnable() {
            @Override
            public void run() {
                runOnUiThread(() -> {
                    isAuthorized = true;
                    loadAppData();
                });
            }
        });
    }

    private void loadAppData() {
        // NOW safe: database, files, network, policy
        DatabaseHelper db = new DatabaseHelper(this);
        List<Item> items = db.getAllItems();
        adapter = new MyAdapter(this, items);
        listView.setAdapter(adapter);
    }

    // ── Handling onResume after authorization ──────────────────────
    @Override
    protected void onResume() {
        super.onResume();
        if (isAuthorized) {
            // Safe to reload data — container is decrypted in memory.
            // Even if the idle lock screen was shown, the container
            // was never re-encrypted, so data access is still valid.
            loadAppData();
        }
        // If not yet authorized, do nothing — the runOnAuthorized
        // callback will handle it when the container is ready.
    }
}
```

### Rules for Any Migrated App

1. **`onCreate()`**: Only call `activityInit()`, `setContentView()`, and
   set up non-secure UI elements (view references, navigation listeners).
   No data access of any kind.
2. **`onAuthorized()`**: This is the app's real entry point for business
   logic. Initialize all secure data here — databases, files, network
   connections, policy reads. Use `runOnUiThread()` if updating UI.
3. **`onResume()`**: Guard with `isAuthorized` / ready flags. Before the
   initial authorization, `onResume()` must not access secure APIs **or**
   touch UI object fields that are only constructed in
   `initializeAuthorizedUi()` / `runOnAuthorized` (those are still null on
   the first resume — see Pattern 14 in
   `21-authorization-deferral-patterns.md`). After authorization, the
   container stays decrypted in memory (even during idle lock), so
   `onResume()` can safely access data; re-enter deferred resume work from
   the end of `initializeAuthorizedUi()` if the Activity is still visible.
4. **`onLocked()`**: This callback fires for both idle lock and remote
   lock, but the implications are very different:
   - **Idle lock**: UI-only lock screen. Container stays decrypted in
     memory. Background tasks and secure API access continue normally.
   - **Remote lock**: Hard lock. Container becomes inaccessible. Secure
     API calls will fail. The user must obtain a Temporary Unlock Key
     from the UEM admin to reactivate.
   The app cannot distinguish between the two from the callback alone.
   If the app has critical background tasks, be aware that remote lock
   will interrupt them.
5. **Button click handlers / user-initiated actions**: These are safe
   because by the time a user can interact with the UI, authorization
   has already completed.
6. **Main-process secondary Activities** (launched from the main activity via
   Intent): These are also safe because the user can only navigate to them
   after the container is unlocked. They still need `activityInit()` under the
   kit policy but do not need to defer their own data access.
7. **Services / BroadcastReceivers / WorkManager workers / startup providers & initializers**: When the
   app process is launched (or re-launched) by the OS for a background
   reason — push delivery, scheduled job, alarm, boot — the secure
   container is locked even though the singleton `GDStateListener` has
   been registered. These entry points MUST follow the **Background
   Authorize** path: call
   `GDAndroid.getInstance().canAuthorizeAutonomously(this)` and
   `GDAndroid.getInstance().serviceInit(this)` in `onCreate()` of the
   `Service`, and defer all secure-API access through the Application
   class's `runOnAuthorized(...)` helper. The canonical, enforceable
   pattern (including FCM payload hardening and the
   `dynamicsBackgroundAuthorizeStarted` retry gate) is in
   `70-background-authorize.md`; prompt `03c-background-authorize.md`
   captures per-candidate developer intent and applies it only where
   the developer opts in. `BroadcastReceiver`s that need secure-API
   access must wrap their handler in a `JobService` so the handshake
   has a real `Service` context. The domain `backgroundAuthorize` is
   a **waivable** domain — every candidate in
   `bootstrap.json.processModel.backgroundEntryPoints[]` must have a
   recorded `intent` of `migrate | deferred | not-applicable` in
   `bootstrap.json.backgroundAuthorize.decisions[]` before prompt 10
   will write a report, but a `deferred` intent (with a written
   rationale) is a legitimate outcome.

### What NOT to Do

```java
// [NOT OK] WRONG: Accessing secure SQLite in onCreate — container is locked
@Override
protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    GDAndroid.getInstance().activityInit(this);
    setContentView(R.layout.activity_main);
    List<Note> notes = dbHelper.getAllNotes();  // CRASH: GDNotAuthorizedError
}

// [NOT OK] WRONG: Starting a network request in onCreate
@Override
protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    GDAndroid.getInstance().activityInit(this);
    setContentView(R.layout.activity_main);
    new FetchDataTask().execute(apiUrl);  // CRASH if using GDHttpClient
}

// [NOT OK] WRONG: Reading a config file in onCreate
@Override
protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    GDAndroid.getInstance().activityInit(this);
    setContentView(R.layout.activity_main);
    String config = readConfigFile();  // CRASH if using GDFileSystem
}
```

---

## Implementation Guidelines

- Initialization should happen once at app startup
- **ALL secure API access MUST be deferred until `onAuthorized()` fires**
- The app's "real start" is `onAuthorized()`, not `onCreate()`
- UI should not access secure APIs before authorization
- Keep authorization logic isolated and readable
- This applies to every app regardless of what secure APIs it uses —
  databases, files, networking, policy, or any combination

### IMPORTANT: The Authorization Boundary Extends Beyond onCreate()

The two-phase pattern above covers the main Activity, but real apps have
secure API access scattered across ViewModels, Fragments, widgets,
BroadcastReceivers, migration routines, and utility functions — all of
which may run before `onAuthorized()`.

`21-authorization-deferral-patterns.md` is the canonical reference for
every deferral strategy beyond the main Activity, including:
- Observable authorization state (LiveData / StateFlow) — **Pattern 1**
- ViewModel init deferral — **Pattern 2**
- Fragment data-observation deferral — **Pattern 3**
- BroadcastReceiver / widget / migration guards — **Patterns 4–7**
- Non-null placeholder observables — **Pattern 12**

---

## GDStateListener — Required Callbacks

The global `GDStateListener` (in the Application class) must implement all
seven callbacks. They can be empty if the app does not need to react to
that specific event:

1. `onAuthorized()` - Container unlocked, safe to access secure APIs
2. `onLocked()` - Lock activated (idle lock = UI-only, container still accessible; remote lock = hard lock, container inaccessible until reactivation with Temporary Unlock Key)
3. `onWiped()` - Container wiped, all secure data destroyed
4. `onUpdateConfig(Map<String, Object>)` - Config changed (cache-and-refresh:
   see `73a-app-config-read-and-refresh.md`)
5. `onUpdatePolicy(Map<String, Object>)` - Policy changed (same cache pattern
   in `73a-app-config-read-and-refresh.md`)
6. `onUpdateServices()` - Services changed
7. `onUpdateEntitlements()` - Entitlements changed

### Canonical Application Class — use the template, do not write from scratch

`dynamics-migration-tool/templates/auth/DynamicsApplicationBase.java` (Java) and
`DynamicsApplicationBase.kt` (Kotlin) provide the correct, ready-to-use Application class.
Always start from the template to avoid the signature pitfalls described below.

The template is derived from the official BlackBerry Dynamics SDK sample
`BlackBerry-Dynamics-Android-Samples / 1-GettingStarted / Dynamics-GettingStarted /
MainActivity.java` (Apache-2.0), generalized to an Application class with a deferral queue.

Canonical Java skeleton (excerpt from template — DO NOT reconstruct from memory):

```java
import com.good.gd.GDAndroid;
import com.good.gd.GDStateListener;
import java.util.Map;  // Required — missing this import is the #1 compile error on prompt 03

public class MyApplication extends Application implements GDStateListener {

    @Override
    public void onCreate() {
        super.onCreate();
        GDAndroid.getInstance().setGDStateListener(this);  // BEFORE any Activity starts
    }

    @Override public void onAuthorized()                             { /* unlock logic */ }
    @Override public void onLocked()                                 { /* lock logic   */ }
    @Override public void onWiped()                                  { /* wipe logic   */ }
    @Override public void onUpdateConfig(Map<String, Object> s)      { }
    @Override public void onUpdatePolicy(Map<String, Object> p)      { }
    @Override public void onUpdateServices()                         { }
    @Override public void onUpdateEntitlements()                     { }
}
```

**Critical signature facts (source: SDK sample + javap):**
- `onUpdateConfig` and `onUpdatePolicy` take `Map<String, Object>` — NOT `Bundle`, NOT
  `Map<String, String>`. Using the wrong type causes a compile error: "does not override
  abstract method".
- All 7 methods must be present — the interface is not partial.
- `java.util.Map` must be imported explicitly in Java (Kotlin imports it automatically).

### Common Mistake: Missing Global Listener

If an Activity calls `activityInit()` without implementing `GDStateListener`
AND no global listener has been set via `setGDStateListener()`, the SDK
throws:

```
GDInitializationError: Each Activity must implement GDStateListener
interface if a singleton interface has not been provided to GDAndroid
```

This commonly happens in multi-activity apps where only the main Activity
implements the interface. When the user navigates to a secondary Activity,
it crashes. The global listener pattern avoids this entirely.

The validator enforces this invariant as `[AUTH-LISTENER-001]` (hard
failure) in Phase 3 and Phase 11. When all three conditions are met
simultaneously — `activityInit()` is called, the Activity does not
implement `GDStateListener`, and `setGDStateListener()` is not called
anywhere — the finding is classified as a guaranteed runtime crash, not
a warning.

### Known Agent Mistake: `applicationInit()` vs `setGDStateListener()`

AI agents have been observed substituting
`GDAndroid.getInstance().applicationInit(this)` for the correct
`GDAndroid.getInstance().setGDStateListener(this)`. The `applicationInit()`
method does **not** register a `GDStateListener` — it is a documented SDK
entry point for a different startup model. Using it instead of
`setGDStateListener()` in the kit-policy Application class
leaves the SDK with no registered listener, and the very first
`activityInit()` call will throw `GDInitializationError`.

**Rule**: The only correct call for registering the kit's global listener is
`GDAndroid.getInstance().setGDStateListener(this)`. Any new occurrence of
`applicationInit(this)` introduced while implementing this kit policy is an
agent error and must be replaced. If it existed before migration, trace the
flow before changing it and document the preserve/convert decision.

---

## Manifest Merger Conflicts (IMPORTANT)

The Dynamics SDK ships its own AndroidManifest.xml which gets merged with your
app's manifest. This frequently causes build failures due to conflicting
attribute values.

### Common Conflicts

| Attribute | SDK Value | Typical App Value | Fix |
|-----------|-----------|-------------------|-----|
| `android:supportsRtl` | `false` | `true` | Add to `tools:replace` |
| `android:allowBackup` | varies | `true` | Add to `tools:replace` |

### Resolution Pattern

1. Ensure the `tools` namespace is declared in `<manifest>`:
   ```xml
   <manifest xmlns:android="http://schemas.android.com/apk/res/android"
       xmlns:tools="http://schemas.android.com/tools">
   ```

2. Add `tools:replace` to `<application>` for conflicting attributes:
   ```xml
   <!-- [BB_DYNAMICS-MIGRATION] Added tools:replace to resolve manifest merger conflicts with Dynamics SDK -->
   <application
       android:allowBackup="false"
       android:supportsRtl="true"
       tools:replace="android:supportsRtl,android:allowBackup"
       ...>
   ```

3. Only add attributes that actually conflict — the build error message
   specifies exactly which attributes need `tools:replace`.

### When to Apply

- **Always check** for manifest merger conflicts after adding the Dynamics SDK dependency
- If the project already has `tools:replace`, append the conflicting attributes
- If `android:allowBackup="true"`, consider changing to `false` (Dynamics manages its own secure backup)

---

## Automatic Permissions

The Dynamics SDK will automatically add required permissions via manifest merger:
- INTERNET
- ACCESS_NETWORK_STATE
- Others as needed

Review merged manifest to understand full permission set.

---

## Output

- Description of the authorization flow
- List of lifecycle touchpoints
- settings.json file created with correct GDApplicationID
- List of files modified for RestrictionsManager migration (if applicable)
- Clear instructions for testing authorization
