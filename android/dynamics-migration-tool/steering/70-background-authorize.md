# Steering: Background Authorize

**Ownership:** platform migration kit (bootstrap + prompt 03c + Phase 3b
validator + settings.json contract).

Background Authorize is the **only supported way** for an Android Dynamics
app to access secure APIs (`GDFileSystem`, secure SQLite, `GDHttpClient`,
`GDSocket`, `getApplicationPolicy()`) from a background entry point —
`FirebaseMessagingService`, `JobIntentService` / `JobService`,
`WorkManager` `ListenableWorker`, or any `BroadcastReceiver` whose handler
needs container data.

In this toolkit Background Authorize is **first-class but opt-in**,
matching the Dynamics SDK 15.0 posture (generally available since 14.1,
still opt-in at both the app config and UEM profile levels):

1. **Discovery (mechanical).** Candidate background entry points are
   identified in `00pre-bootstrap.md` and recorded in
   `bootstrap.json.processModel.backgroundEntryPoints[]`. Discovery is
   pure inventory — it does **not** commit the developer to anything.
2. **Intent capture (interactive, end of run).** Prompt
   `03c-background-authorize.md` runs **after** the secure-data domains
   close (04, 05a–c, 06, 07, 08, 09) so the developer can see exactly
   which secure surfaces each candidate would touch. The prompt asks
   the developer to record, per candidate, an `intent` of
   `migrate | deferred | not-applicable` and persists the answers to
   `bootstrap.json.backgroundAuthorize.decisions[]`.
3. **Pattern application (only where the developer opted in).** Only
   candidates with `intent == "migrate"` receive the canonical
   `canAuthorizeAutonomously` + `serviceInit` source edit and trigger
   `GDEnableBackgroundAuthorize: true` in
   `com.blackberry.dynamics.settings.json`.
4. **Validator (Phase 3b).** Validates `migrate`-intent entries
   strictly. For `deferred`, it routes the result through
   `fail_or_defer "backgroundAuthorize"` — a matching
   `deferredDomains[]` entry downgrades it to `check_warn`. For
   `not-applicable`, it records an audit pass line. If candidates
   exist but `bootstrap.backgroundAuthorize.decisions[]` is empty, the
   scoped check returns `PENDING` (informational) and prompt 10's
   `backgroundAuthorizeDecisionsCaptured` gate hard-fails report
   generation.

The domain `backgroundAuthorize` is therefore **waivable** — but only
through the explicit per-candidate deferral path above, not by
hand-editing `deferredDomains[]` without first running prompt 03c.

> **Multi-module note**: `app/src/main/assets/...` references below are
> canonical-shape illustrations. Place
> `com.blackberry.dynamics.settings.json` at every entry in
> `${primary_assets_dirs}` from
> `dynamics-migration-tool/output/module-map.json`. See
> `04-multi-module-projects.md` and `02-create-settings-json.md`.

---

## When Background Authorize is a candidate vs. when it is required

The toolkit distinguishes **candidacy** (mechanical evidence) from
**applicability at runtime** (developer-confirmed). The
`backgroundAuthorize` domain becomes a **candidate** (the executionPlan
row is `applicable: true`) whenever **any** of the following are true
for the primary app module or any in-scope library module:

- A `<service>` in the merged manifest extends
  `com.google.firebase.messaging.FirebaseMessagingService` (push entry
  point).
- A `<service>` extends `android.app.job.JobService`,
  `androidx.core.app.JobIntentService`, or any pre-Oreo `Service`
  subclass that handles `WorkManager`/`AlarmManager`-triggered work.
- A class extends `androidx.work.ListenableWorker` (or its
  subclasses `Worker`, `CoroutineWorker`, `RxWorker`) and accesses any
  Dynamics-secured API.
- A `<receiver>` whose handler chain transitively reads or writes
  secure storage, secure SQLite, secure networking, or policy.

`bootstrap.sh probe` records these in
`processModel.backgroundEntryPoints[]`. Prompt `00-analyze-app.md`
maps the same set onto the `backgroundAuthorize` row of
`executionPlan[]` (`promptId: "03c"`).

If the inventory finds **zero** background entry points the domain is
**not-applicable** and prompt 03c is skipped. There is no other reason
to enable Background Authorize.

Whether each candidate is **actually required** (the developer wires
the canonical pattern and sets `GDEnableBackgroundAuthorize: true`) is
the developer's call. Prompt 03c captures that decision per candidate
into `bootstrap.backgroundAuthorize.decisions[]`:

| `intent` | Source edit | `GDEnableBackgroundAuthorize` flag | `deferredDomains[]` (developer-only) | Closure source | Phase 3b outcome |
|---|---|---|---|---|---|
| `migrate` | Apply template | Set to `true` at every `${primary_assets_dirs}` | not written by agent | `bootstrap.backgroundAuthorize.decisions[]` | strict structural check; `check_fail` on regression (routed through `fail_or_defer`) |
| `deferred` | none | not written (unless another `migrate` intent already required it) | optional post-migration domain entry (correct Phase 0 schema) | `bootstrap.backgroundAuthorize.decisions[]` | always `fail_or_defer "backgroundAuthorize"` → `check_warn` when `decisions[]` records deferral |
| `not-applicable` | none | not written | not written | `bootstrap.backgroundAuthorize.decisions[]` | audit pass line |

Do not write Background Authorize dispositions to
`migration-plan-state.json`. That ledger is reserved for the
data-plane call-site prompts (`04`, `05c`, `06`) and its schema does
not include the `backgroundAuthorize` domain.

A `deferred` decision is a contract with the UEM administrator: until
the developer revisits and migrates, autonomous authorization at the
profile level must **not** be enabled for this app. Prompt 03c writes
this expectation into `Dynamics_Migration_Readme.md` as the UEM
handoff note.

---

## Public APIs (verify against the developer's installed SDK)

Authoritative reference:
[BlackBerry Dynamics Android — `GDAndroid`](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1_g_d_android.html).

| Symbol | Signature | Behavior |
|---|---|---|
| `GDAndroid.getInstance().canAuthorizeAutonomously(Context context)` | `boolean canAuthorizeAutonomously(Context)` | Returns `true` only when policy + container state permit autonomous unlock. Call **before** `serviceInit`. |
| `GDAndroid.getInstance().serviceInit(Context context)` | `boolean serviceInit(Context) throws GDInitializationError` | Initiates background authorization. `context` must be the `android.app.Service` instance (`this`). Returns `true` if authorization can complete autonomously, `false` otherwise (no further callback will fire). Throws `GDInitializationError` if the context is invalid or no `GDStateListener` is reachable. |
| `GDAndroid.getInstance().setGDStateListener(GDStateListener listener)` | `void setGDStateListener(GDStateListener)` | A singleton listener registered in `Application.onCreate()` satisfies the SDK requirement for **all** background services. Background services MUST NOT implement `GDStateListener` themselves. |
| `GDStateListener.onAuthorized()` | callback | Fires once Background Authorize succeeds. Drain any background queue from the Application class's `runOnAuthorized(...)` helper — never directly from inside the `Service`. |
| `GDStateListener.onLocked()` / `onWiped()` | callbacks | Background work must abort cleanly when these fire. |

**Behavioral preconditions (from the API reference):**

1. The app must have **completed foreground activation/authorization
   at least once** before background authorization can work. Fresh
   installs cannot Background Authorize until the user opens the app.
2. Autonomous authorization requires UEM policy support (typically
   "no-password autonomous authorization" or the equivalent enterprise
   setting in the Dynamics profile). Without it,
   `canAuthorizeAutonomously` returns `false`.
3. `GDEnableBackgroundAuthorize` must be `true` in
   `com.blackberry.dynamics.settings.json`.
4. Enterprise simulation mode does **not** support Background
   Authorize.

---

## Configuration (`com.blackberry.dynamics.settings.json`)

Place at every entry in `${primary_assets_dirs}`:

```json
{
  "GDEnableBackgroundAuthorize": true
}
```

Phase 3b fails the settings-flag check when **at least one** decision
in `bootstrap.backgroundAuthorize.decisions[]` is `migrate` **and** any
target's `com.blackberry.dynamics.settings.json` is missing
`GDEnableBackgroundAuthorize: true`. When every decision is `deferred`
or `not-applicable`, the flag is intentionally **not** required; remove
or set a stale flag to `false` on rerun. Leaving it enabled without a
corresponding canonical handshake misleads the UEM administrator.

---

## Canonical implementation pattern (mandatory)

This is the pattern prompt `03c-background-authorize.md` applies and
Phase 3b enforces. Adapt class/package names per call site; do not omit
or reorder the marked checkpoints.

Required structural elements (Phase 3b checks each one):

1. The entry point overrides `onCreate()` and calls
   `GDAndroid.getInstance().canAuthorizeAutonomously(this)` **before**
   `serviceInit(this)`.
2. `serviceInit(this)` is invoked with the `Service`/`Worker` context
   (literal `this`, not the application context, not a passed listener).
3. The return value is captured in a `volatile boolean`
   (`dynamicsBackgroundAuthorizeStarted` or equivalent), and the
   `GDInitializationError` path stores `false`.
4. `onMessageReceived(...)` (or the equivalent handler) refuses to
   touch secure APIs when `dynamicsBackgroundAuthorizeStarted` is
   `false` — it must call a `scheduleRetryWithoutSecureApiAccess(...)`
   helper that uses metadata only.
5. When `dynamicsBackgroundAuthorizeStarted` is `true` but the
   container has not yet observed `onAuthorized()`, the handler defers
   to `MyDynamicsApplication.runOnAuthorized(() -> ...)` rather than
   accessing secure APIs directly.
6. The entry point does **not** implement `GDStateListener` (the
   singleton in the Application class satisfies the SDK requirement
   per `22-multi-process-app-handling.md`).

```java
package com.example.app.push;

import android.util.Log;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;
import com.good.gd.GDAndroid;
import com.good.gd.error.GDInitializationError;

// [BB_DYNAMICS-MIGRATION] Background service entry point prepared for Dynamics Background Authorize.
// Requires Application.onCreate() to have registered a singleton GDStateListener via
// GDAndroid.getInstance().setGDStateListener(...).
public final class AppFirebaseMessagingService extends FirebaseMessagingService {
    private static final String TAG = "AppFirebaseMessaging";

    private volatile boolean dynamicsBackgroundAuthorizeStarted = false;

    @Override
    public void onCreate() {
        super.onCreate();

        try {
            if (!GDAndroid.getInstance().canAuthorizeAutonomously(this)) {
                // [BB_DYNAMICS-MIGRATION] Background Authorize cannot run now.
                // Do not touch GDFileSystem, secure SQLite, GDHttpClient, GDSocket,
                // policy APIs, or repositories that use them from this service.
                Log.i(TAG, "Dynamics autonomous authorization is not available; background work will be skipped/retried.");
                return;
            }

            dynamicsBackgroundAuthorizeStarted = GDAndroid.getInstance().serviceInit(this);
            if (!dynamicsBackgroundAuthorizeStarted) {
                // [BB_DYNAMICS-MIGRATION] serviceInit returned false: no authorization callback will follow.
                Log.i(TAG, "Dynamics serviceInit returned false; background work will be skipped/retried.");
            }
        } catch (GDInitializationError error) {
            // [BB_DYNAMICS-MIGRATION] Treat initialization failure as a safe no-op/retry path.
            Log.w(TAG, "Dynamics Background Authorize initialization failed.", error);
            dynamicsBackgroundAuthorizeStarted = false;
        }
    }

    @Override
    public void onMessageReceived(RemoteMessage message) {
        super.onMessageReceived(message);

        // [BB_DYNAMICS-MIGRATION] FCM payloads must remain metadata-only.
        // Do not put sensitive enterprise data directly in notification title/body/data.
        if (!dynamicsBackgroundAuthorizeStarted) {
            scheduleRetryWithoutSecureApiAccess(message);
            return;
        }

        // [BB_DYNAMICS-MIGRATION] Do not access secure APIs directly here unless
        // the app's singleton GDStateListener has observed onAuthorized().
        if (!MyDynamicsApplication.isContainerAuthorized()) {
            MyDynamicsApplication.runOnAuthorized(() -> handleAuthorizedMessage(message));
            return;
        }

        handleAuthorizedMessage(message);
    }

    private void handleAuthorizedMessage(RemoteMessage message) {
        // [BB_DYNAMICS-MIGRATION] Safe only after Background Authorize/authorization completed.
        // Fetch enterprise data through migrated secure networking/storage paths here.
        // Example:
        // repository.syncFromPush(message.getData());
    }

    private void scheduleRetryWithoutSecureApiAccess(RemoteMessage message) {
        // [BB_DYNAMICS-MIGRATION] Safe fallback path.
        // Use WorkManager/JobScheduler retry metadata only; do not read/write secure
        // container data or perform secure network calls here.
    }
}
```

The template at
`templates/auth/BackgroundAuthorizeServiceTemplate.java` (and `.kt`)
ships the same structure with `__APP_PACKAGE__` and class-name
placeholders for prompt 03c to drop into the developer's tree.

### WorkManager (`ListenableWorker`) variant

`ListenableWorker.doWork()` runs on a background thread inside an
`androidx.work.RxWorker`/`CoroutineWorker`/`Worker` subclass. The
`Context` available via `getApplicationContext()` is **not** a
`Service`. For Background Authorize, prompt 03c migrates such workers
to delegate to a thin `JobIntentService` / `JobService` that performs
the `canAuthorizeAutonomously` → `serviceInit` handshake, then
re-enqueues the actual work on the worker once `onAuthorized()` fires
through the Application's `runOnAuthorized(...)` queue. Workers MUST
NOT call `serviceInit(applicationContext)` directly — `serviceInit`
requires a `Service` context.

### BroadcastReceiver variant

`BroadcastReceiver.onReceive()` does not own a `Service` lifecycle.
Prompt 03c rewrites secure-API-touching receivers to start a dedicated
`JobIntentService` (Pre-31) or schedule a `JobService` (`minSdk >=
31`, which this toolkit enforces), and the handshake lives in that
service per the canonical pattern above.

---

## What MUST NOT happen

| Anti-pattern | Why it fails |
|---|---|
| Calling `serviceInit(listener)` or `serviceInit(applicationContext)` | The documented signature is `serviceInit(Context)` where `context` is the `Service` instance. Anything else throws `GDInitializationError`. |
| Calling `serviceInit(this)` without first calling `canAuthorizeAutonomously(this)` | Phase 3b fails: ordering is mandatory per the API contract. |
| Accessing `GDFileSystem` / secure SQLite / `GDHttpClient` / `getApplicationPolicy()` directly in `onMessageReceived` / `onHandleWork` / `doWork` without checking `dynamicsBackgroundAuthorizeStarted` **and** `isContainerAuthorized()` | Throws `GDNotAuthorizedError` and may crash the service. |
| Implementing `GDStateListener` on a background `Service` while a singleton listener is already set in the Application class | Conflicting listeners — keep one global listener per `22-multi-process-app-handling.md`. |
| Placing sensitive enterprise data in FCM `notification.title` / `notification.body` / top-level `data` payload | Payload is visible to the OS push pipeline outside the Dynamics container. Treat FCM as a wake signal only. |
| Catching `GDInitializationError` and silently retrying secure-API calls | The contract is: on failure, set the flag to `false` and run the metadata-only fallback path. |

---

## Interactions with other domains

- **`authorization` (prompt 03)** must be **closed** before
  `backgroundAuthorize` (prompt 03c) is recorded. The Background
  Authorize handshake depends on the Application class's singleton
  `GDStateListener` and `runOnAuthorized(...)` queue. Treat this as a
  workflow dependency during migration; prompt `10`'s final gate is what
  ultimately enforces the completed state.
- **`secureFileStorage` / `secureSql` / `secureNetworking`**: any code
  reached from a background entry point must already have been
  migrated to the Dynamics secure equivalents — Background Authorize
  unlocks access; it does not migrate downstream call sites.
- **`icc` (prompt 08)** is downstream of `secureFileStorage` per
  existing `requires[]`. Background Authorize does not change that
  chain.

---

## Validator behavior (Phase 3b)

Phase 3b first reads `bootstrap.backgroundAuthorize.decisions[]`. If it
is missing or empty while `processModel.backgroundEntryPoints[]` is
non-empty, Phase 3b returns `PENDING` (informational `check_warn`) —
the developer has not yet been prompted. Prompt 10's
`backgroundAuthorizeDecisionsCaptured` gate hard-fails report
generation when this state persists.

When decisions exist, Phase 3b processes each candidate by intent:

- **`intent: migrate`** — locate the source file and enforce the
  canonical structure:
  1. The file declares a class extending the entry point's `baseClass`.
  2. `GDAndroid.getInstance().canAuthorizeAutonomously(this)` appears
     before `GDAndroid.getInstance().serviceInit(this)`.
  3. The result of `serviceInit(this)` is assigned to a class field
     (heuristic match: `... = GDAndroid.getInstance().serviceInit(this)`).
  4. `GDInitializationError` is caught.
  5. The handler method does not contain unguarded references to
     `GDFileSystem`, `com.good.gd.file.`, `GDHttpClient`, `GDSocket`,
     `SQLiteOpenHelper`, or `getApplicationPolicy(` outside a branch
     that has already checked `dynamicsBackgroundAuthorizeStarted` (or
     the developer-chosen equivalent — Phase 3b accepts any boolean
     field whose initializer is `serviceInit(this)`).
  6. Every `${primary_assets_dirs}` target's
     `com.blackberry.dynamics.settings.json` contains
     `"GDEnableBackgroundAuthorize": true` (settings flag is required
     only when at least one decision is `migrate`).
- **`intent: deferred`** — Phase 3b records the rationale and always
  routes deferred candidates through `fail_or_defer "backgroundAuthorize"`
  (including when other candidates in the same run have `intent: migrate`).
  Captured `decisions[]` deferral downgrades the scoped result to
  `check_warn`. An optional developer-authored `deferredDomains[]`
  entry for `backgroundAuthorize` provides the same downgrade for
  domain-wide sign-off before prompt 10.
- **`intent: not-applicable`** — Phase 3b emits an audit pass line
  carrying the developer's rationale; no further checks.

Any candidate present in `backgroundEntryPoints[]` but absent from
`decisions[]` is a hard `check_fail` ("re-run prompt 03c so the
developer records intent"). Structural failures on `migrate`-intent
entries are also routed through `fail_or_defer "backgroundAuthorize"`,
so a developer who chooses to defer mid-flight can land cleanly by
updating the candidate's `intent` to `deferred` in
`backgroundAuthorize.decisions[]` (re-run prompt 03c step 2).

---

## Cross-references

- Process model and component discovery:
  `steering/22-multi-process-app-handling.md`.
- Application class wiring (singleton `GDStateListener` + Two-Phase
  Init): `steering/20-auth-initialization.md`.
- Settings file contract: `steering/11-settings-json-reference.md`.
- Public API surface: `steering/14-api-provenance-and-replacement-catalog.md`
  ("Background Authorize" row).
- Prompts: `prompts/03c-background-authorize.md` (this domain's
  migration step), `prompts/00pre-bootstrap.md` (discovery).
- Bootstrap schema: `documentation/report-contract/bootstrap-schema-v1.1.0.md`
  (`processModel.backgroundEntryPoints[]`).
