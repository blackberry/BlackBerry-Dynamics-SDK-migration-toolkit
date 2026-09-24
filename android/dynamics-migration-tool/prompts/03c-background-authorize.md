## Task: Capture developer intent for Background Authorize per candidate, then apply the canonical pattern only where the developer opts in

Goal: walk every candidate in
`dynamics-migration-tool/output/bootstrap.json` →
`processModel.backgroundEntryPoints[]`, **explain to the developer where
Background Authorize would apply and what it would unlock**, capture a
per-candidate `intent ∈ { migrate, deferred, not-applicable }`, persist
those decisions to `bootstrap.json.backgroundAuthorize.decisions[]`, and
then apply the canonical Background Authorize handshake **only** to
candidates the developer chose to migrate.

This prompt is the **last migration step** before prompt 10 — it runs
after prompts 04 / 05a–c / 06 / 07 / 08 / 09 / **11** have closed the
secure-data surfaces (SQL, file, networking, WebView, ICC, secure
widgets, push/FCM). That ordering is intentional: prompt `11` hardens FCM
payloads and documents Push Channel usage first; this prompt then captures
Background Authorize intent per candidate with full context.

**Prerequisites (gated by the recorder):**
- Prompt `03` (add-dynamics-auth) closed — the Application class is the
  global `GDStateListener` and exposes `isContainerAuthorized()` /
  `runOnAuthorized(Runnable)`.
- Prompt `03b` (authorization-deferral-audit) closed — pre-auth secure
  access on the foreground startup chain is gated.
- All applicable secure-data domains closed:
  `secureFileStorage`, `secureSql`, `secureNetworking`,
  `secureUiWidgets` (those marked `applicable: false` in
  `migration-analysis.json` count as closed).
- `bootstrap.json` exists. If `processModel.backgroundEntryPoints[]` is
  empty, skip this prompt (see "Record execution" below).

**Domain:** `backgroundAuthorize`. **Waivable** — per-candidate
`intent: "deferred"` is captured only in
`bootstrap.backgroundAuthorize.decisions[]` (the agent **must not**
edit `deferredDomains[]`). Phase 3b routes every deferred candidate
through `fail_or_defer "backgroundAuthorize"` (including when other
candidates were migrated in the same run). Background Authorize in
BlackBerry Dynamics SDK 15.0 (Background Authorize generally available
since 14.1) remains **opt-in** at both the app config and UEM profile
levels; the migration toolkit honors that posture.

**Steering references:**
- `steering/70-background-authorize.md` — canonical pattern, public API
  signatures, anti-patterns, deferral mechanics, UEM handoff note.
- `steering/22-multi-process-app-handling.md` —
  `backgroundEntryPoints[]` schema and discovery rules.
- `steering/11-settings-json-reference.md` —
  `com.blackberry.dynamics.settings.json` and the conditional
  `GDEnableBackgroundAuthorize` requirement.
- `steering/14-api-provenance-and-replacement-catalog.md` —
  Background Authorize catalog row.

---

## Module map context (read first)

Resolve from `dynamics-migration-tool/output/module-map.json`:

- `${primary_assets_dirs}` — every assets directory the module map
  records for the primary module (main + each declared product flavor /
  build type). The `com.blackberry.dynamics.settings.json` write targets
  this set when at least one decision is `migrate`.
- `${in_scope_modules}` — primary module plus every entry in
  `libraryModulesInScope[]`. Background entry-point sources may live in
  any of these.

If `module-map.json` is missing, STOP and re-run `00pre-bootstrap.md`.

---

## Steps

### 1. Read the candidate list

Load `bootstrap.json` → `processModel.backgroundEntryPoints[]`. Each
entry has the shape:

```json
{
  "baseClass": "com.google.firebase.messaging.FirebaseMessagingService",
  "kind": "service" | "worker" | "receiver",
  "manifest": "app/src/main/AndroidManifest.xml" | null,
  "module": "app",
  "name": "com.example.app.push.AppFirebaseMessagingService"
}
```

For each entry, locate the source file under `${in_scope_modules}` (by
FQCN) and **scan its handler body** for evidence of secure-API usage
(direct or transitive) — look for: `GDFileSystem`, `GDHttpClient`,
`SQLiteDatabase` opened through Dynamics, secure-storage repositories
that prompts 04 / 05z migrated, secure networking clients that prompt 06
migrated. This evidence becomes the per-candidate explanation in step 2.

If a candidate's class file cannot be located, STOP and report the
discrepancy — the developer either deleted the class or has a stale
bootstrap; re-run `00pre-bootstrap.md`.

### 2. Capture per-candidate developer intent (interactive)

For **every** candidate, present to the developer a block that explains:

- The candidate's FQCN, `kind`, `module`, and `baseClass`.
- The runtime trigger ("This service receives FCM push notifications";
  "This worker runs on Doze-relaxed schedule"; etc.).
- The secure surfaces evidence shows it touches (from step 1).
- The three intent options, with consequences:
  - **migrate** — wire the canonical Background Authorize handshake;
    apply the source edit; ensure `GDEnableBackgroundAuthorize: true`
    in `com.blackberry.dynamics.settings.json`; the candidate becomes
    enforceable by Phase 3b.
  - **deferred** — postpone Background Authorize for this candidate;
    record a non-empty `rationale` in `backgroundAuthorize.decisions[]`
    only (no source edit; do not set `GDEnableBackgroundAuthorize`). The
    migration report flags the candidate as a known gap; Phase 3b
    routes it through `fail_or_defer "backgroundAuthorize"` (scoped
    `check_warn` once intent is captured). The UEM administrator must
    NOT enable autonomous authorization at the profile level for this
    candidate until it is revisited. **Optional post-migration:** the
    developer may later add a domain-level `deferredDomains[]` entry
    for `backgroundAuthorize` (correct schema in
    `steering/02-bootstrap-schema.md`) before prompt 10 — the agent
    never writes that array.
  - **not-applicable** — the developer confirms this entry point does
    not (and will not) touch secure Dynamics APIs at runtime, so the
    handshake is unnecessary. The migration report records the
    confirmation and Phase 3b emits an audit pass line.

The developer's answer for every candidate is **required**. Do not
proceed to step 3 until each candidate has an intent.

Persist the answers to the top of `bootstrap.json`:

```json
"backgroundAuthorize": {
  "schemaVersion": "1.0.0",
  "capturedAt": "<ISO-8601 UTC>",
  "decisions": [
    {
      "name": "com.example.app.push.AppFirebaseMessagingService",
      "module": "app",
      "kind": "service",
      "intent": "migrate",
      "rationale": "Push triggers secure REST sync inside the container."
    }
  ]
}
```

`rationale` is mandatory for every entry and must be a non-empty,
developer-authored string — it lands verbatim in the migration report.

Do **not** append to `bootstrap.json.deferredDomains[]` — that array
is developer-authored only (Phase 0 rejects agent-shaped entries). Per-
candidate deferral is fully expressed by `decisions[]` with
`intent: "deferred"`.

### 3. Apply the canonical pattern to `migrate`-intent candidates only

For each candidate with `intent == "migrate"`, start from
`dynamics-migration-tool/templates/auth/BackgroundAuthorizeServiceTemplate.java`
(or `.kt`). Adapt:

- `__APP_PACKAGE__` → the candidate's package.
- `__ENTRY_POINT_CLASS__` → the existing class name.
- `__ENTRY_POINT_BASE__` → the candidate's `baseClass`.
- `__APP_CLASS__` → the FQCN of the Application class set up in
  prompt 03 (the one that registers the singleton `GDStateListener`).
- `__HANDLER_METHOD__` → the real handler signature for the base
  class (e.g. `onMessageReceived(RemoteMessage message)`,
  `onHandleWork(Intent intent)`, `onStartJob(JobParameters params)`,
  `doWork()`).

When the existing class already has business logic, do **not**
overwrite it wholesale. Instead, perform a structural edit:

1. Add `private volatile boolean dynamicsBackgroundAuthorizeStarted = false;`
   (or `@Volatile private var ... : Boolean = false` in Kotlin).
2. Override / extend `onCreate()` to perform the
   `canAuthorizeAutonomously(this)` → `serviceInit(this)` handshake,
   catching `GDInitializationError`. The Service / Worker wrapper MUST
   NOT implement `GDStateListener` itself — keep the singleton from
   prompt 03 as the sole listener.
3. In the existing handler method (`onMessageReceived` /
   `onHandleWork` / etc.):
   - First branch on `!dynamicsBackgroundAuthorizeStarted` and call
     `scheduleRetryWithoutSecureApiAccess(...)` (a new helper).
   - Next branch on `!<AppClass>.isContainerAuthorized()` and defer
     to `<AppClass>.runOnAuthorized(() -> handleAuthorizedWork(...))`.
   - Move the existing secure-API-touching work into
     `handleAuthorizedWork(...)`.
4. Add a stub `scheduleRetryWithoutSecureApiAccess(...)` that uses
   only metadata (e.g. enqueues a WorkManager job to retry later
   carrying message IDs but no payload contents). Do not write to the
   secure container or perform secure network calls from this helper.
5. Tag every inserted block with `[BB_DYNAMICS-MIGRATION]`.

#### `worker` entries (`migrate` intent)

`androidx.work.ListenableWorker` (and subclasses) run with an
`Application` context — they cannot call `serviceInit(this)` because
`this` is not a `Service`. Migration path:

1. Introduce a thin `JobIntentService` (Pre-31) or `JobService`
   (`minSdk >= 33` — this kit's baseline) under the same package as
   the worker.
2. Move the worker's secure-API-touching work into a method invoked
   from the `JobService`'s `onStartJob(...)` handler, behind the
   Background Authorize gate exactly as in the template.
3. Replace the worker's `doWork()` body with code that enqueues that
   `JobService` and returns `Result.success()` synchronously (the
   real work is the `JobService`'s).
4. Record both the worker file and the new `JobService` file in
   `--files-touched`.

#### `receiver` entries (`migrate` intent)

`BroadcastReceiver.onReceive(...)` is process-startup-limited and
cannot host the handshake. Migration path:

1. Introduce a `JobService` (or `JobIntentService` if the developer
   has not yet moved off it) and move the receiver's secure-API
   handler chain into it.
2. Change the receiver's `onReceive(...)` to enqueue that
   `JobService` with the relevant `Intent` extras — keep the
   receiver itself free of any secure-API touch.
3. Record both files in `--files-touched`.

### 4. Enable `GDEnableBackgroundAuthorize` at every settings target — only when at least one decision is `migrate`

For every entry in `${primary_assets_dirs}` (only when **any**
decision is `migrate`):

- If `com.blackberry.dynamics.settings.json` does not exist, create it
  with `{ "GDEnableBackgroundAuthorize": true }` and a leading audit
  comment block in the surrounding asset directory's README (or in the
  generated file's accompanying note in
  `Dynamics_Migration_Readme.md`).
- If the file exists, **merge** the field (preserve all other keys) so
  that `GDEnableBackgroundAuthorize` is `true`. Do not blanket-
  overwrite an existing developer-edited settings file.

When **no** decision is `migrate` (all decisions are `deferred` or
`not-applicable`), do **not** add the settings flag. If the flag exists
from a previous run, remove `GDEnableBackgroundAuthorize` or set it to
`false` consistently at every `${primary_assets_dirs}` settings target.
Setting it to `true` without a corresponding canonical handshake
misleads UEM administrators into enabling autonomous authorization at
the profile level for an app that cannot use it.

### 5. Confirm FCM payload hardening (push entry points only, intent `migrate`)

If any `migrate`-intent candidate has `baseClass ==
com.google.firebase.messaging.FirebaseMessagingService`, locate the
server-side push notes (often `docs/push.md` /
`Dynamics_Migration_Readme.md` / inline comments) and add / strengthen
the rule: **payload is metadata-only, never enterprise data**. Audit
the existing `onMessageReceived(...)` body for any direct
`message.getData().get("...")` access that reads enterprise content and
replace with a sync trigger that uses the (already migrated) secure
networking path inside `handleAuthorizedWork(...)`.

### 6. UEM handoff note

Append a "Background Authorize — UEM profile" subsection to
`Dynamics_Migration_Readme.md` (create the section if absent) listing,
for every `migrate`-intent candidate, the runtime trigger and the
condition the UEM administrator must satisfy at the profile level
(autonomous-authorization policy enabled, no-password policy, app
allow-listed for background activation). For `deferred` candidates,
list them in a sub-bullet labelled "DEFERRED — do not enable autonomous
authorization at the profile level until these are revisited."

### 7. Do not update `migration-plan-state.json`

Background Authorize candidates are inventoried in
`migration-analysis.json` for reporting, but they are **not** closed
through `migration-plan-state.json`. That file's schema is reserved for
the data-plane call-site prompts (`04`, `05z`, `06`) and only accepts
`secureSql`, `secureFileStorage`, and `secureNetworking` dispositions.

For prompt `03c`, closure is the per-candidate decision set in
`bootstrap.json.backgroundAuthorize.decisions[]`. Prompt 10's recorder
gate treats `backgroundAuthorize` as closed when every
`processModel.backgroundEntryPoints[]` candidate has exactly one
decision with `intent ∈ { migrate, deferred, not-applicable }`; Phase
3b then enforces migrated candidates and routes deferred candidates
through the Background Authorize deferral path.

### 8. Build verification (when any `migrate` intent applied)

Run `./gradlew :<primary_module>:assembleDebug`. Classify each new
build failure as in prompt 03's step 6. Any failure naming
`GDAndroid`, `GDInitializationError`, `serviceInit`, or
`canAuthorizeAutonomously` is step-introduced and must be fixed before
recording.

Skip this step if **no** decision is `migrate` (no source code
changed).

### 9. Static verification

Run the scoped validator before recording:

```bash
bash dynamics-migration-tool/tooling/validate.sh --check-prompt 03c
```

This invokes Phase 3b. Acceptable outcomes:

- `OK|N migrate / 0 deferred / K not-applicable` — every
  `migrate`-intent candidate matches the canonical pattern and the
  settings flag is set (when required); no deferred candidates remain.
- `DEFERRED|…` or `DEFERRED_PARTIAL|…` — at least one candidate has
  `intent: deferred`; Phase 3b routes through `fail_or_defer
  "backgroundAuthorize"` (scoped `check_warn` when
  `backgroundAuthorize.decisions[]` records the deferral).
  `DEFERRED_PARTIAL` means some candidates migrated and others were
  deferred in the same run.
- `PENDING|…` — capture is missing. Re-run step 2.
- `FAIL|…` — structural breakage on a `migrate`-intent candidate.
  Routes through `fail_or_defer`; either fix the structure or change
  that candidate's intent to `deferred` with a written rationale.

---

## What this prompt does NOT cover

- It does not migrate downstream secure-API call sites (file I/O, SQL,
  HTTP, sockets) reached from background entry points. Those are
  closed by prompts 04 / 05a–c / 06 — Background Authorize unlocks
  access; it does not migrate consumers.
- It does not change the foreground startup chain. That belongs to
  prompts 03 / 03b.
- It does not configure UEM-side policy for autonomous authorization
  (no-password policy). The UEM administrator owns that decision; this
  prompt records the app-side opt-in and produces the handoff note for
  the administrator.

---

## Output

- `bootstrap.json` updated with a `backgroundAuthorize` block carrying
  per-candidate `decisions[]` only (including `intent: deferred` rows
  with rationales — no agent writes to `deferredDomains[]`).
- Source edits to each `migrate`-intent background entry point file
  (and any new `JobService` wrappers for `worker` / `receiver`
  entries).
- `com.blackberry.dynamics.settings.json` with
  `"GDEnableBackgroundAuthorize": true` at every
  `${primary_assets_dirs}` target — only when at least one decision is
  `migrate`.
- `Dynamics_Migration_Readme.md` updated with the UEM handoff note.
- Inline `[BB_DYNAMICS-MIGRATION]` audit comments on every edit.

---

## Record execution

When at least one candidate exists:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 03c \
    --status completed \
    --files-touched <comma-separated relative paths>
```

When `processModel.backgroundEntryPoints[]` is empty:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 03c \
    --status skipped \
    --note "no background entry points detected"
```

This records prompt progress only. For an immediate diagnostic, run
`validate.sh --check-prompt 03c`. Prompt `10` enforces
`backgroundAuthorizeDecisionsCaptured` before final completion.
