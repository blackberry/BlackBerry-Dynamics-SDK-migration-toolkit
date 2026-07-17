# Steering: Multi-Process App Handling

**Ownership:** platform migration kit (bootstrap + auth prompts + Phase 3 validator).

Some Android apps declare `android:process` on Activities, Services, or Providers so components
run outside the main application process (crash handlers, push workers, WebView
sandboxes). Dynamics initialization rules differ by process: the **main** process
owns `setGDStateListener` and `activityInit()` on user-facing Activities; **auxiliary**
processes must not call `activityInit()` (cross-process marshalling failures).

---

## Canonical source of truth

Do **not** re-derive process rules in each prompt. Read
`dynamics-migration-tool/output/bootstrap.json` → `processModel`:

```json
{
  "schemaVersion": "1.0.0",
  "discoveryMethod": "source-manifest-scan",
  "mainProcessName": null,
  "components": [
    {
      "classification": "main",
      "kind": "activity",
      "manifest": "app/src/main/AndroidManifest.xml",
      "name": "com.example.MainActivity",
      "process": null
    },
    {
      "classification": "main",
      "kind": "provider",
      "manifest": "app/src/main/AndroidManifest.xml",
      "name": "com.example.startup.BootstrapProvider",
      "process": null
    },
    {
      "classification": "auxiliary",
      "kind": "activity",
      "manifest": "app/src/main/AndroidManifest.xml",
      "name": "com.example.ErrorActivity",
      "process": ":error_activity"
    }
  ],
  "startupModel": {
    "schemaVersion": "1.0.0",
    "manifestProviders": [ /* provider rows from manifest */ ],
    "appStartupInitializers": [ /* androidx.startup Initializer classes */ ],
    "workManager": {
      "defaultInitializer": "enabled",
      "configurationProviderClasses": [ /* Configuration.Provider classes */ ],
      "workerFactoryClasses": [ /* WorkerFactory classes */ ]
    }
  }
}
```

- `mainProcessName`: `null` when the default package process is main; otherwise the
  explicit `android:process` value shared by main-process components.
- `classification`: `main` | `auxiliary` — drives validator Phase 3 and prompt 03.
- `process`: manifest `android:process` value, or `null` for the default process.
- `startupModel`: startup-only discovery data used by Phase 11 startup guard to
  validate provider/App Startup/WorkManager pre-auth reachability.

Emitted by `tooling/bootstrap.sh probe` and finalized in prompt `00pre-bootstrap.md`.
Validated in `validate.sh` Phase 0 (shape) and Phase 3 (`activityInit` rules).

---

## Application class (`DynamicsApplicationBase`)

Register `GDStateListener` **only in the main process**:

```java
@Override
public void onCreate() {
    super.onCreate();
    if (!isMainProcess()) {
        return;
    }
    GDAndroid.getInstance().setGDStateListener(this);
}
```

The template ships `isMainProcess()` — do not remove the guard.

---

## Activities

| Classification | `activityInit(this)` | Notes |
|----------------|------------------------|-------|
| `main` | **Required** in `onCreate()` after `super.onCreate()` | Includes default-process Activities |
| `auxiliary` | **Forbidden** | Crash UI, isolated workers, etc. |

If `processModel` is missing (stale bootstrap), fall back to manifest scan in prompt 03
and re-run `00pre-bootstrap.md` to refresh bootstrap.

---

## Common auxiliary patterns

- Crash reporter Activities (`ErrorActivity`, `CustomActivityOnCrash`)
- `:remote` / `:webview` / push notification handlers that are **not** the primary UI

When unsure, classify as `auxiliary` if `android:process` is set and the component is
not part of the primary user journey after Dynamics unlock.

---

## Shared Code Reachable from Auxiliary Processes

Utility functions (logging, crash reporting, diagnostics, file helpers) are
frequently shared between the main app and auxiliary-process components.
When migrating `java.io.File` to `com.good.gd.file.File` in shared
utilities, the auxiliary process call paths must be considered.

**Rule:** Code reachable from an auxiliary process (where `onAuthorized()`
will never fire) MUST NOT unconditionally use GD secure APIs. Either:

1. **Keep on standard APIs** — if the code is purely diagnostic (logging,
   crash reporting, telemetry) and does not persist app data, do not
   migrate it to GD APIs.
2. **Add a runtime guard** — check `isContainerAuthorized` (or the
   equivalent `isMainProcess()` guard in `Application.onCreate()`) and
   fall back to standard `java.io.File` / `android.util.Log.*` when the
   container is unavailable.
3. **Split into two implementations** — a GD-secured variant for the main
   process and a standard variant for auxiliary processes, selected at the
   call site based on process identity.

**Crash handlers are the canonical example.** Libraries like
`customactivityoncrash` deliberately run in a separate process so they
survive the main-process crash. Migrating their I/O to GD APIs breaks
this design — the crash handler becomes dependent on the very system
(Dynamics container) that may have caused the crash.

**`DocumentFile.fromFile()` is a related trap.** Even in the main process
(where the container IS authorized), wrapping a `com.good.gd.file.File`
with `DocumentFile.fromFile()` produces a broken `file://` URI (e.g.
`file:///logs`) because GD container-relative paths are virtual — they do
not exist on the real Android filesystem. `DocumentFile.createFile()` and
`ContentResolver.openOutputStream()` fail on these URIs. Use direct GD
`FileInputStream` / `FileOutputStream` instead. See
`40-secure-file-storage.md` §10 for full details.

**Principle:** Auxiliary processes that do not participate in the Dynamics
authorization lifecycle are out-of-scope for secure API migration. Code
shared between main and auxiliary processes requires either a runtime
authorization guard or separate implementations.

### Guard pattern (Kotlin)

```kotlin
fun log(message: String) {
    if (isContainerAuthorized) {
        val out = com.good.gd.file.FileOutputStream("logs/app.log", true)
        out.use { it.write("$message\n".toByteArray()) }
    } else {
        android.util.Log.d(TAG, message)
    }
}
```

### Guard pattern (Java)

```java
public void log(String message) {
    if (isContainerAuthorized()) {
        try (OutputStream out = new com.good.gd.file.FileOutputStream("logs/app.log", true)) {
            out.write((message + "\n").getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            Log.e(TAG, "Secure log failed", e);
        }
    } else {
        Log.d(TAG, message);
    }
}
```

### Validator enforcement

Phase 3 emits `[PROC-AUX-001]` when an auxiliary-process component's
direct call graph (1–2 levels) reaches GD file APIs without an
`isContainerAuthorized` or `isMainProcess` guard. Detection covers:

- `import com.good.gd.file.*`
- fully-qualified inline usage such as
  `com.good.gd.file.FileOutputStream(...)`
- helper/static access via `GDFileSystem.*` / `GDFileHelper.*`
- indirect shared diagnostic helpers (crash-handler Activity → log
  helper → directory/file helper) that open container files

This is a **FAILURE** in Phase 3 (not a soft warning): GD is never
authorized in auxiliary processes, so these paths throw
`GDNotAuthorizedError` at runtime (including crash-handler cascades).

- Prompt 10's recorder gate `auxProcessGdReachClosed` also blocks
  completion while open `PROC-AUX-001` hits remain.
- Each hit must be closed by either:
  1. code remediation (guard/split/remove so the hit disappears), or
  2. an explicit `migration-report.json` `unverifiedSurfaces[]` entry
     (`pattern: "PROC-AUX-001"`, `securityCritical: true`) with non-open
     status (`resolved`, `acceptedRisk`, or `notApplicable`).

When recording report closure for a surviving hit, include the decision
rationale (`keep-native`, `remove`, or deferred/accepted risk) in the
entry notes so reviewers can trace intent.

Keep auxiliary crash-reporter Activities on `android.util.Log` and plain
`java.io` — never route their diagnostics through GD file APIs.

Phase 4 emits `[FS-DOCFILE-001]` when any file importing
`com.good.gd.file.*` also contains `DocumentFile.fromFile` — this is
a FAILURE because the resulting URI is always invalid for container paths.

### Cross-references

- Filesystem migration: `40-secure-file-storage.md`
- Prompt 05a step 1b: auxiliary-process caller audit
- Authorization deferral patterns: `21-authorization-deferral-patterns.md`
- API catalog: `14-api-provenance-and-replacement-catalog.md`

---

## Background entry points (`processModel.backgroundEntryPoints[]`)

`bootstrap.sh probe` additionally records the set of background entry
points that mark `backgroundAuthorize` as a **candidate** domain. This
list is **discovery only** — it does not commit the developer to
implement Background Authorize for any specific entry point. Per-entry
intent is captured later by prompt `03c-background-authorize.md` into
`bootstrap.json.backgroundAuthorize.decisions[]` (see
`70-background-authorize.md`).

The list is non-empty whenever the manifests under scan declare any of
the following:

- A `<service>` whose class extends
  `com.google.firebase.messaging.FirebaseMessagingService`.
- A `<service>` whose class extends `android.app.job.JobService` or
  `androidx.core.app.JobIntentService`.
- A `<receiver>` whose handler chain reads or writes Dynamics-secured
  storage / SQL / networking / policy. (Receivers are recorded; their
  migration path is via a wrapping `JobService` per
  `70-background-authorize.md`.)
- Any class in the in-scope module set extending
  `androidx.work.ListenableWorker` / `Worker` / `CoroutineWorker` /
  `RxWorker`.

`startupModel` complements `backgroundEntryPoints[]` for HR-1-1 startup
guarding:

- `manifestProviders[]`: all manifest `<provider>` declarations (including
  process assignment).
- `appStartupInitializers[]`: classes referenced by
  `androidx.startup.InitializationProvider` metadata.
- `workManager.defaultInitializer`: `enabled` | `disabled` | `not-detected`
  based on merged manifest metadata.
- `workManager.configurationProviderClasses[]` and
  `workManager.workerFactoryClasses[]`: source-discovered classes scanned for
  pre-auth secure API reachability.

```json
{
  "schemaVersion": "1.0.0",
  "components": [ /* unchanged */ ],
  "backgroundEntryPoints": [
    {
      "baseClass": "com.google.firebase.messaging.FirebaseMessagingService",
      "kind": "service",
      "manifest": "app/src/main/AndroidManifest.xml",
      "module": "app",
      "name": "com.example.app.push.AppFirebaseMessagingService"
    },
    {
      "baseClass": "androidx.work.CoroutineWorker",
      "kind": "worker",
      "manifest": null,
      "module": "app",
      "name": "com.example.app.sync.PolicySyncWorker"
    }
  ]
}
```

`kind` is one of `service` | `worker` | `receiver`. `manifest` is
`null` for `worker` entries (no declaration). `baseClass` is the
matched superclass; prompt `03c-background-authorize.md` reads this
field to pick the right adaptation template.

The validator's **Phase 3b** uses this list as the **candidate list**
and cross-references each entry against
`bootstrap.backgroundAuthorize.decisions[]` (written by prompt 03c) to
decide whether to enforce the canonical pattern strictly (`migrate`),
honor a deferral (`deferred`), or audit-pass (`not-applicable`).
`backgroundAuthorize` is a **waivable** domain — but every candidate
must have a recorded intent before prompt 10 will write a report
(`backgroundAuthorizeDecisionsCaptured` gate). See
`02-bootstrap-schema.md` and `70-background-authorize.md`.

---

## Cross-references

- Auth wiring: `20-auth-initialization.md`
- Background Authorize (enforceable): `70-background-authorize.md`
- Bootstrap contract: `02-bootstrap-schema.md`