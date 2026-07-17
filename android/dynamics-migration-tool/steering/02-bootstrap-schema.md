# Steering: Bootstrap Schema

This file is the **agent-facing** contract for `bootstrap.json`. The
canonical specification lives at
`documentation/report-contract/bootstrap-schema-v1.1.0.md` — when the
two disagree, the canonical doc wins.

`bootstrap.json` is produced by prompt 00pre-bootstrap.md (the
pre-prompt that runs before `00-analyze-app.md`). It captures every
piece of human input, environmental check, and permission grant the
migration depends on, **once, up front**, so subsequent prompts have a
single deterministic source for that information.

---

## File location and format

- Path: `dynamics-migration-tool/output/bootstrap.json`
- Encoding: UTF-8, LF line endings, no BOM
- JSON serialization: RFC 8259 compliant
- Key ordering: alphabetical within each object (deterministic diffs)
- Schema version: `"1.1.0"`

The file is always produced by a **full-file overwrite** (Write/CreateFile
tool). Patch-based tools must not be used on this file (see
`00-context.md` "Output File Hygiene").

---

## Top-level shape

```json
{
  "agent": { /* ... */ },
  "attestations": { /* ... */ },
  "backup": { /* ... */ },
  "catalogVersion": "string",
  "deferredDomains": [],
  "environment": { /* ... */ },
  "executedPrompts": [],
  "backgroundAuthorize": { /* optional — written by prompt 03c */ },
  "generatedAt": "ISO-8601 UTC, 'Z' suffix",
  "moduleMap": { /* ... */ },
  "permissions": { /* ... */ },
  "provenance": { /* ... */ },
  "processModel": { /* ... */ },
  "runId": "UUID",
  "schemaVersion": "1.1.0",
  "sdkClassIndex": { /* ... */ },
  "sdkProbe": { /* ... */ },
  "toolkit": { /* ... */ },
  "uem": { /* ... */ },
  "workingTree": { /* ... */ }
}
```

Every top-level key except `backgroundAuthorize` is **required**.
`backgroundAuthorize` is absent on a fresh bootstrap; it is added by
prompt `03c-background-authorize.md` after the developer records
per-candidate intent. Unknown top-level keys are rejected by Phase 0.

---

## Field-by-field

### `schemaVersion` (string, required)

Literal `"1.1.0"`.

### `generatedAt` (string, required)

ISO-8601 UTC timestamp with `Z` suffix, e.g. `"2026-04-29T09:55:12Z"`.
Must be byte-identical to `provenance.generatedAt` (single timestamp source).

### `runId` (string, required)

Stable UUID for the migration run. Generated once by
`tooling/bootstrap.sh probe` and propagated unchanged through
`migration-analysis.json`, `migration-plan-state.json`, and
`migration-report.json`.

### `catalogVersion` (string, required)

Catalog contract version copied from
`contracts/api-catalog.v1.0.0.json` (`catalogVersion` field). Validators
cross-check this against the on-disk catalog and report provenance to
detect contract drift.

### `toolkit` (object, required)

```json
{
  "name": "dynamics-migration-tool",
  "platform": "Android",
  "version": "string — must match dynamics-migration-tool/VERSION"
}
```

### `provenance` (object, required)

Run-level audit fields emitted by `tooling/bootstrap.sh probe`:

```json
{
  "catalogContract": "contracts/api-catalog.v1.0.0.json",
  "catalogSha256": "string | null",
  "catalogVersion": "string",
  "generatedAt": "ISO-8601 UTC timestamp",
  "gitCommit": "string | null",
  "runId": "UUID",
  "sdkArtifact": "string | null",
  "sdkResolvedVersion": "string | null",
  "sdkSha256": "string | null",
  "toolkitVersion": "string"
}
```

`provenance.runId` must match top-level `runId`,
`provenance.catalogVersion` must match top-level `catalogVersion`, and
`provenance.toolkitVersion` must match `toolkit.version`.
`provenance.generatedAt` must match top-level `generatedAt`.

### `agent` (object, required)

```json
{
  "approvalMode": "auto" | "per-command" | "unknown",
  "type": "cursor" | "kiro" | "codex" | "generic",
  "version": "string | null"
}
```

The agent records its own identity. `approvalMode` is the
developer-stated mode for the session (`auto` if "Auto-run all" / "Allow
all" was confirmed; `per-command` if the developer kept per-command
prompts on; `unknown` for `generic`).

### `permissions` (object, required)

Boolean flags recording the developer's confirmation that they enabled
the kit's required allowlist entries. **These are not credentials** —
they are attestations.

```json
{
  "developerConfirmedAt": "ISO-8601 UTC timestamp",
  "fileRead": true,
  "fileWrite": true,
  "fullNetwork": true,
  "shellExec": true
}
```

All four booleans must be `true` before the agent proceeds. If any is
`false`, the prompt aborts and asks the developer to grant the
permission.

### `uem` (object, required)

```json
{
  "gdApplicationId": "string — UEM entitlement ID",
  "gdApplicationVersion": "string — UEM entitlement version",
  "source": "uem-admin-confirmed"
}
```

- `gdApplicationId` must match `^[a-zA-Z0-9._-]+$`, length 1–255.
- `gdApplicationVersion` must match `^\d+\.\d+\.\d+\.\d+$`.
- `source` is always `"uem-admin-confirmed"`. There is no placeholder
  mode in this kit; if the developer cannot supply real UEM values, the
  bootstrap aborts.

### `attestations` (object, required)

```json
{
  "ackBackupBranchCreated": true,
  "ackRedundantEncryptionRemoval": true,
  "ackTwoPhaseStartupChange": true,
  "cleanBaselineBuild": true
}
```

- `cleanBaselineBuild` must be `true` to proceed.
- `ackTwoPhaseStartupChange` and `ackRedundantEncryptionRemoval` must
  both be `true` (the developer is acknowledging that the migration may
  restructure startup and may remove or replace features incompatible
  with a Dynamics container app — e.g. external sharing, external media
  storage, redundant app-level encryption).
- `ackBackupBranchCreated` is `true` only when step 5 of prompt 00pre
  creates the backup branch. When the project is not a git repository,
  this field is `false` and the `backup` object records null values.

> **Schema change note**: the field `cleanWorkingTree` previously lived
> in this object. It was promoted to its own top-level `workingTree`
> object (see below) so that a "yes to all" acknowledgement of the
> attestation block cannot silently override a dirty-tree warning.
> `bootstrap.json` written by older kit versions where `cleanWorkingTree`
> appeared inside `attestations` is **non-conforming**. `validate.sh`
> **Phase 0 (Bootstrap contract)** fails if that field is still present;
> re-run `prompt 00pre-bootstrap.md` to migrate the field to the new
> location.

### `workingTree` (object, required)

```json
{
  "dirty": true | false,
  "override": null | {
    "acknowledged": true,
    "acknowledgedAt": "ISO-8601 UTC timestamp",
    "untrackedFiles": <int>,
    "modifiedFiles": <int>
  }
}
```

- When the project is a git repository, `dirty` is `true` if
  `tooling/git-working-tree.sh porcelain` produced any output at bootstrap
  time, `false` otherwise. That script filters out
  `dynamics-migration-tool/`, `.cursor/`, `.kiro/`, and `AGENTS.md` —
  paths every run adds via `tooling/migrate.sh` (Cursor, Kiro, Codex) —
  so toolkit/IDE wiring alone does not
  force a dirty-tree override. Note the polarity is **inverted** versus
  the deprecated `attestations.cleanWorkingTree`: a clean tree is
  `dirty: false`.
- When the project is not a git repository, record `dirty: false` and
  `override: null` (git working-tree semantics are unavailable).
- `override` is `null` when `dirty: false`. When `dirty: true`, it is
  required and must be an object with `acknowledged: true`. The
  developer must explicitly answer `y` to the standalone dirty-tree
  prompt in step 4 of `00pre-bootstrap.md` — bulk acceptance through the
  `attestations` block is forbidden.
- The constraint `dirty == true` **implies** `override != null`
  (specifically `override.acknowledged == true`). Any other combination
  fails **Phase 0 (Bootstrap contract)** in `validate.sh` when
  `bootstrap.json` is present, and indicates the file is non-conforming
  (prompt `00pre-bootstrap.md` must not be bypassed).
- `acknowledgedAt` is the ISO-8601 UTC timestamp captured at the moment
  the developer typed `y`.
- `untrackedFiles` and `modifiedFiles` are non-negative integers derived
  from `tooling/git-working-tree.sh counts` (same ignore rules as
  `porcelain`; entries starting with `??` count as untracked; everything
  else with non-empty status counts as modified).
  These counts let prompt 10 surface the override in the migration
  report's `releaseReadiness.blockingItems` so reviewers know the diff
  was intermingled.

### `backup` (object, required)

```json
{
  "branch": "migration-backup-YYYYMMDD-HHMMSS",
  "createdFromCommit": "git SHA"
}
```

Android migrations require a Git baseline. The backup branch must exist
locally. Per kit convention, the branch is created but the developer
stays on their working branch — `backup.branch` is purely a rescue
anchor for `--rerun-domain` and `--resume`.

When the project is not a Git repository, or has no commit baseline,
prompt `00pre` must ask for explicit developer consent before invoking
`tooling/lib/ensure-git-baseline.sh --consented`. The helper initializes
Git if needed, excludes toolkit artifacts through `.git/info/exclude`,
and creates the pre-migration app-source baseline commit. If the
developer declines, the migration stops and `bootstrap.json` is not
written.

### `environment` (object, required)

```json
{
  "androidCompileSdk": 34 | null,
  "androidMinSdk": 35 | null,
  "androidSdkRoot": "string | null",
  "gradleVersion": "string | null",
  "javaHome": "string | null",
  "jdk": "17" | null,
  "language": "Java" | "Kotlin" | "Mixed" | "Unknown",
  "os": "darwin" | "linux" | "...",
  "osVersion": "string",
  "shell": "zsh" | "bash" | "...",
  "workingDir": "absolute path"
}
```

The probe script populates this block. If `jdk` is missing, below 17, or
unparseable, the bootstrap aborts.

> **Schema note:** the `projectShape` field previously lived inside
> `environment`. It now lives in the top-level `moduleMap` block (see
> below) alongside the rest of the project-shape facts.

### `moduleMap` (object, required)

```json
{
  "discoveryMethod": "fallback-app-dir" | "settings-gradle-parse" | "user-supplied",
  "path": "dynamics-migration-tool/output/module-map.json",
  "primaryAppModule": "string — module name",
  "projectShape": "single-module" | "multi-module",
  "schemaVersion": "1.0.0"
}
```

This block is a summary pointer to `output/module-map.json`. The full
project model — every source set, library module, convention plugin —
lives in that file. See `04-multi-module-projects.md` for the
agent-facing guide and `documentation/report-contract/module-map-schema-v1.0.0.md`
for the canonical specification.

For canonical single-module projects with an `app/` directory:

- `discoveryMethod: "fallback-app-dir"`
- `projectShape: "single-module"`
- `primaryAppModule: "app"`

### `sdkProbe` (object, required)

```json
{
  "dynamicsSdkArtifact": "com.blackberry.blackberrydynamics:android_handheld_platform:VERSION | null",
  "dynamicsSdkResolvedVersion": "VERSION | null",
  "probeCommand": "string — either runtimeClasspath probe or fallback resolver command",
  "probePassedAt": "ISO-8601 UTC timestamp | null"
}
```

`probePassedAt` is `null` if the probe failed. A successful bootstrap
requires `dynamicsSdkResolvedVersion` to be non-null.

`probeCommand` is normally
`./gradlew :<primaryAppModule.name>:dependencies --configuration
debugRuntimeClasspath` (or `:dependencies` fallback). The primary
module name is taken from `output/module-map.json`. On canonical
projects this expands to `:app:dependencies`; on multi-module
projects it can be `:app-primary:dependencies`,
`:apps-foo-app:dependencies`, etc. On fresh projects before prompt
01 has added Dynamics dependencies, bootstrap may record a
fallback resolver command that preloads pinned Dynamics artifacts
for class-index validation.

### `sdkClassIndex` (object, required)

A map from fully-qualified Dynamics class name to one of `"found"` or
`"not-found"`. Subsequent prompts (04, 05a/05b/05c, 06, 07, 08, 09) consult this
map instead of running their own SDK probes.

```json
{
  "com.good.gd.GDAndroid": "found",
  "com.good.gd.GDStateListener": "found",
  "com.good.gd.database.sqlite.SQLiteOpenHelper": "found",
  "com.good.gd.database.sqlite.SQLiteDatabase": "found",
  "com.good.gd.file.GDFileSystem": "found",
  "com.good.gd.file.FileInputStream": "found",
  "com.good.gd.file.FileOutputStream": "found",
  "com.blackberry.okhttpsupport.interceptor.BBCustomInterceptor": "found",
  "com.blackberry.okhttpsupport.cookie.BBCookieJar": "found",
  "com.good.gd.net.GDSocket": "found",
  "com.good.gd.apache.http.client.HttpClient": "found",
  "com.blackberry.bbwebview.BBWebView": "found",
  "com.good.gd.icc.GDServiceClient": "found",
  "com.good.gd.widget.GDEditText": "found",
  "com.good.gd.widget.GDTextView": "found",
  "com.good.gd.content.ClipboardManager": "found"
}
```

Required class set: every class above must be present and report
`"found"` for the bootstrap to succeed. The list represents the API
surface every applicable migration prompt depends on.

### `executedPrompts` (array, required)

Empty `[]` at bootstrap time. Each migration prompt MUST append an
entry to this array on completion (or skip, or abort). This array is
the **canonical execution audit** consulted by prompt 10's hard gate
(see step 9 of `prompts/10-generate-migration-report.md`).

Entries are written by the helper script
`tooling/record-prompt-execution.sh`, which centralizes the JSON merge
logic and guarantees idempotency. Prompts MUST NOT write this array
directly — always go through the helper, which:

- Replaces (not duplicates) any existing entry with the same `promptId`,
  so prompt re-runs are safe.
- Sorts entries into canonical run order (00pre, 00, 00b, 01, 02, 03,
  03b, 04, 05a, 05b, 05c, 06, 07, 08, 09, 11, 03c, 10, 12) for deterministic diffs.
- Performs a full-file overwrite of `bootstrap.json` so partial writes
  cannot corrupt the file.

Each entry has shape:

```json
{
  "completedAt": "ISO-8601 UTC",
  "filesTouched": ["string — relative paths"],
  "note": "string — optional free text (e.g. 'secureSql not-applicable per executionPlan')",
  "promptId": "00pre | 00 | 00b | 01 | 02 | 03 | 03b | 04 | 05a | 05b | 05c | 06 | 07 | 08 | 09 | 11 | 03c | 10 | 12",
  "startedAt": "ISO-8601 UTC",
  "status": "completed | failed | aborted | skipped",
  "validationProof": {
    "file": ".last-check.json",
    "fingerprint": "sha256 of proof sidecar",
    "validationRunId": "validator run id",
    "mode": "scoped",
    "scope": "full",
    "status": "passed",
    "phases": ["6"],
    "diagnosticContractVersion": "1.0.0"
  }
}
```

#### Status semantics

- `completed` — the prompt ran end-to-end and the recorder wrote its
  `executedPrompts[]` entry. For prompts with a configured scoped validator,
  completion also means the recorder ran `validate.sh --check-prompt <id>`
  and recorded `validationProof`. Prompt `10` remains the final
  cross-domain acceptance gate.
- `skipped` — the prompt's owning domain was marked `not-applicable` in
  `migration-analysis.json` `executionPlan`. A skip still gets recorded
  so the hard gate can verify the plan was honored.
- `failed` — the prompt attempted its work but a step errored. The
  developer must intervene before the migration can continue.
- `aborted` — the prompt deliberately stopped (e.g. prompt 10's
  hard gate refused to write a report).

There is no agent-authored `validateResult` field. Validation is owned by
`tooling/record-prompt-execution.sh`, which consults
`tooling/check-prompt-map.json`, runs configured scoped gates before
recording completion, and runs the final source/report acceptance gates at
prompt `10`. Optional
`validate.sh --check-prompt <id>` runs are manual diagnostics, not
recorder-owned gates.
Prompts MUST NOT pass `--validate-result` to the recorder — that flag
no longer exists.

### `processModel` (object, required)

Emitted by `tooling/bootstrap.sh probe` and copied into `bootstrap.json`
during `00pre-bootstrap.md`. Canonical doctrine:
`steering/22-multi-process-app-handling.md`. The inner `schemaVersion`
of this block (`"1.0.0"`) is independent of the bootstrap schema
version.

```json
{
  "schemaVersion": "1.0.0",
  "discoveryMethod": "merged-manifest" | "source-manifest-scan",
  "mainProcessName": null,
  "components": [
    {
      "classification": "main" | "auxiliary",
      "kind": "activity" | "service" | "provider",
      "manifest": "app/src/main/AndroidManifest.xml",
      "name": "com.example.MainActivity",
      "process": null
    }
  ],
  "backgroundEntryPoints": [
    {
      "baseClass": "com.google.firebase.messaging.FirebaseMessagingService",
      "kind": "service" | "worker" | "receiver",
      "manifest": "app/src/main/AndroidManifest.xml" | null,
      "module": "app",
      "name": "com.example.app.push.AppFirebaseMessagingService"
    }
  ],
  "startupModel": {
    "schemaVersion": "1.0.0",
    "manifestProviders": [ /* provider declarations */ ],
    "appStartupInitializers": [ /* androidx.startup Initializer metadata */ ],
    "workManager": {
      "defaultInitializer": "enabled" | "disabled" | "not-detected",
      "initializerMetadataEntries": [ /* WorkManager initializer metadata */ ],
      "configurationProviderClasses": [ /* Configuration.Provider classes */ ],
      "workerFactoryClasses": [ /* WorkerFactory classes */ ]
    }
  }
}
```

- `mainProcessName`: `null` when the default application process is main; otherwise
  the explicit `android:process` value for main-process components.
- `classification`: drives Phase 3 (`activityInit` required on `main` Activities,
  forbidden on `auxiliary` Activities) and prompt `03-add-dynamics-auth.md`.
- `components[].kind` includes startup-relevant providers (`"provider"`) so
  process classification covers provider process assignment too.
- `backgroundEntryPoints[]` lists every push/job/worker/receiver class
  that is a **candidate** for the Background Authorize handshake. This
  is discovery-only inventory — it does **not** commit the developer to
  implement Background Authorize for any specific candidate. When the
  list is non-empty the `backgroundAuthorize` domain becomes
  **applicable** (a candidate); prompt
  `03c-background-authorize.md` captures per-candidate developer intent
  into the top-level `backgroundAuthorize` block described below.
  Phase 3b of `validate.sh` walks this list and consults
  `bootstrap.backgroundAuthorize.decisions[]` to decide whether to
  enforce strictly (`migrate`), honor a deferral (`deferred`), or
  audit-pass (`not-applicable`). `manifest` is `null` for `worker`
  entries (declared programmatically via WorkManager). `module` is the
  in-scope module name from `module-map.json`. Patch-level additions to
  the `kind` enum (for example new worker bases) do not bump
  `schemaVersion`.
- `startupModel` captures startup-only metadata for Phase 11 startup
  hardening: manifest providers, App Startup initializers, and WorkManager
  default-initializer/config-provider/worker-factory surfaces.

### `backgroundAuthorize` (object, optional)

Absent on fresh bootstrap. Written by prompt
`03c-background-authorize.md` after the developer records intent for
every candidate in `processModel.backgroundEntryPoints[]`. Schema:

```json
{
  "schemaVersion": "1.0.0",
  "capturedAt": "ISO-8601 UTC",
  "decisions": [
    {
      "name": "com.example.app.push.AppFirebaseMessagingService",
      "module": "app",
      "kind": "service" | "worker" | "receiver",
      "intent": "migrate" | "deferred" | "not-applicable",
      "rationale": "non-empty developer-authored string"
    }
  ]
}
```

Phase 0 validates the `backgroundAuthorize` block shape. Prompt 10's
recorder gate requires every candidate in
`processModel.backgroundEntryPoints[]` to have a matching `decisions[]`
entry (by `name`). `rationale` lands verbatim in the migration report.
For each `decisions[]` entry with `intent: "deferred"`, prompt 03c
records the rationale here only — the agent **must not** write
`deferredDomains[]`. Phase 3b honors per-candidate deferral via
`fail_or_defer "backgroundAuthorize"`. Optionally, before prompt 10,
the **developer** may add a domain-level `deferredDomains[]` entry
(see shape below) for release sign-off; that is separate from per-
candidate capture.
- Re-run `00pre-bootstrap.md` after manifest process changes or new
  background entry points are introduced.

### `deferredDomains` (array, required)

**Non-waivable domains**: `authorization`, `policyManagement`, `secureClipboard`, and `transportHardening` cannot be deferred. `backgroundAuthorize` **is waivable** (per-candidate): a `deferred` intent in `backgroundAuthorize.decisions[]` (written by prompt `03c-background-authorize.md`) downgrades Phase 3b to `check_warn` via `fail_or_defer` without requiring a `deferredDomains[]` row. A valid developer-authored `deferredDomains[]` entry for `domain: "backgroundAuthorize"` provides optional domain-wide sign-off before prompt 10. Deferring `secureFileStorage` blocks prompt `08` via `requires[]` in `check-prompt-map.json` — ICC cannot run while storage is open. Entries for the non-waivable domains are ignored by the validator and treated as contract violations in Phase 0.

Empty `[]` at bootstrap time. **Only the developer may add entries.**
The agent NEVER writes to this array — not even via
`record-prompt-execution.sh`. Adding a deferral is a deliberate human
decision that tells the kit "I am intentionally NOT migrating this
domain right now and I take responsibility for the gap".

Each entry has shape:

```json
{
  "deferredAt": "ISO-8601 UTC",
  "deferredBy": "developer",
  "developerSignedOff": true,
  "classification": "plannedInNextRelease | acceptedResidualRisk",
  "domain": "secureSql | secureFileStorage | secureNetworking | webview | icc | secureUiWidgets | backgroundAuthorize",
  "expiresAt": "ISO-8601 UTC timestamp — required, must be in the future",
  "reason": "string — non-empty rationale, e.g. 'Room bridge factory pending review with security team'"
}
```

Required fields:
- `developerSignedOff: true` — the gate ignores entries without this flag.
- `reason` — must be a non-empty string. "TBD" or "" do not satisfy
  the gate.
- `classification` — must be `plannedInNextRelease` or `acceptedResidualRisk`.
- `expiresAt` — required, ISO-8601 UTC timestamp in the future; expired entries are ignored and fail Phase 0.

Common mistake:
- If `developerSignedOff: true`, `classification`, or `expiresAt` is missing, the validator ignores the deferral and the domain stays hard-fail. Do not add partial placeholder entries.

Editing this array by hand (in your editor) is the supported workflow.
A future commit may add a `dynamics-migration-tool/tooling/defer-domain.sh`
helper, but the contract is unchanged: the developer authorizes the
deferral; the agent never invents one.

The presence of a valid entry tells prompt 10's hard gate (step 9) that
the named domain is intentionally not migrated, and the gate passes for
that domain. `validate.sh` honors `deferredDomains[]`: Phase 4 / 5 / 6
checks downgrade `check_fail` to `check_warn` for explicitly deferred domains.

### Audit tag

`[BB_DYNAMICS-MIGRATION]` is the only migration-related source tag and
is audit-only — it never suppresses validator findings. The toolkit
does not support line-level exceptions. If a domain cannot be migrated
in this release, the developer (not the agent) records a domain-level
entry in `deferredDomains[]`. Deferrals are dated, expire, classified,
and surface as release-readiness blockers.

---

## Lifecycle

1. **Created** by prompt 00pre-bootstrap.md immediately after a successful
   probe run. `executedPrompts` and `deferredDomains` start empty.
2. **Read** by every subsequent prompt for UEM credentials, SDK class
   availability, agent identity, or environment metadata. Prompts 04,
   05a/05b/05c, and 06 specifically replace their own `./gradlew dependencies` probe
   with an `sdkClassIndex` lookup.
3. **Appended** by each prompt's completion handler via
   `tooling/record-prompt-execution.sh` — `executedPrompts` accumulates
   as the migration progresses. Entries are upsert (idempotent); a
   prompt re-run replaces its previous entry rather than duplicating
   it.
4. **Optionally augmented** by the developer with `deferredDomains[]`
   entries before re-running prompt 10. The agent never edits this
   array.
5. **Cross-checked** by prompt 10's hard gate (step 9): every applicable
   `executionPlan` row must map to either a completed prompt or a
   developer-signed-off deferral.
6. **Honored** by `tooling/validate.sh` (per `deferredDomains[]`) —
   domain-level deferrals downgrade `check_fail` to `check_warn`.
   Every non-migrated call-site in an applicable, non-deferred domain
   is a hard failure.
7. **Committed to git** alongside `migration-report.json` as part of the
   migration audit trail. There is no `.gitignore` entry for it.

---

## Sensitivity

All fields are equivalent in sensitivity to data already committed by
the kit today (`migration-report.json`, every settings.json target
under `${primary_assets_dirs}` from `output/module-map.json`).
There are no credentials, tokens, keys, or PII in `bootstrap.json`. The
`uem.gdApplicationId` and `uem.gdApplicationVersion` are public
entitlement IDs that already get committed in `settings.json`.

The only fields that are mildly machine-specific are
`environment.workingDir` and `git.remote`/`git.commit`. Both are normal
project metadata and require no special handling.

---

## Validation expectations

When `dynamics-migration-tool/output/bootstrap.json` exists, the Android
`validate.sh` **Phase 0 (Bootstrap contract)** checks:

- JSON parses successfully.
- Every required top-level key is present (see “Top-level shape” above),
  including `processModel`.
- `processModel` shape matches `steering/22-multi-process-app-handling.md`.
- `schemaVersion` is `"1.1.0"`.
- `executedPrompts` and `deferredDomains` are arrays.
- No unknown top-level keys are present.
- Deprecated `attestations.cleanWorkingTree` is absent.
- `workingTree` satisfies the `dirty` / `override` rules above.
- `uem.gdApplicationId` / `uem.gdApplicationVersion` / `uem.source`
  match the regex and literal contracts.

Prompt `00pre-bootstrap.md` is the first line of defense (it refuses to
write an invalid bootstrap). Phase 0 catches drift, hand-edits, and stale
schema mixes before later validator phases run.

If `bootstrap.json` is missing, Phase 0 emits a **warning** only (deferrals
cannot be honored without the file).

The `--preflight` mode remains focused on **JDK / SDK / Gradle build**
readiness and does not duplicate Phase 0.
---

## Why this is a separate steering file

The bootstrap contract is small and stable but referenced by many
prompts. Folding it into `00-context.md` would inflate that file;
folding it into `01-getting-started.md` mixes contract spec with overview
text. A dedicated steering file at `02-` slots cleanly between
foundational context (`00`, `01`) and the migration checklist (`05*`),
matching the existing numbering convention (see
`documentation/authoring/numbering-conventions.md`).
