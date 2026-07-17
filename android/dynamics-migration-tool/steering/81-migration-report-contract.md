# Steering: Android Final Migration Report Contract

This file defines the quality contract for Prompt 10 outputs.

It complements `80-migration-report-schema.md` by defining mandatory analysis
content and quality gates for official migration-kit output.

---

## Required Outputs

- `dynamics-migration-tool/output/migration-report.json`
- `Dynamics_Migration_Readme.md` (project root)

---

## Mandatory Report Content

### 1) Data at Rest Security Summary

Document how sensitive data storage was handled:

- file storage migration status
- SQL migration status
- external storage leakage assessment — **MUST** name the
  `externalStorage` surface set explicitly. If any
  `externalStorage/*` row appears in
  `dynamics-migration-tool/output/.security-blockers.log` the
  summary must state: "Residual external-storage call-sites mean
  enterprise data can leave the Dynamics container; it is
  unencrypted at rest, included in device backups, and not cleared
  by remote container wipe. Manual intervention is required before
  production use." `securityPosture.dataAtRest.status` must be
  `"partial"` (or `"unverified"` if the writer count is large) in
  this case — never `"secured"`.
- unresolved storage risks and affected files/components

### 1a) Security Blockers (mandatory when present)

The validator writes every non-waivable security finding to
`dynamics-migration-tool/output/.security-blockers.log` (TSV:
`domain<TAB>surface<TAB>count<TAB>message`). Current sources are
Phase 4's `externalStorage/api-surface` blocker and Phase 8b
FileProvider path-surface blockers (`fileprovider-external-path`,
`fileprovider-external-files-path`, `fileprovider-external-cache-path`,
`fileprovider-root-path`); future surfaces (e.g. plaintext credentials,
transport-hardening regressions) will append to the same log.

When the log is non-empty the report **MUST**:

- set `releaseReadiness.recommendation = "no-go"` (never
  `"go-with-risks"` or `"go"`);
- set `summary.overallStatus = "failed"`;
- set `migrationConfidence.level = "low"` with a rationale that
  names "security blocker" / the offending domain explicitly;
- set `coverage.secureFileStorage.status = "partial"` when the blocker
  domain is `externalStorage`; the report must not say secure file
  storage is fully migrated while container-boundary escape remains;
- copy every row into `releaseReadiness.blockingItems[]`,
  prefixed `[SECURITY-BLOCKER][<domain>/<surface>]`;
- add one `manualTodos[]` entry per row with
  `blocking: true`, a title starting
  `"Manual intervention required before production use — "`, and
  a `reason` that names the secure replacement
  (catalog rows `fs-java-ext-001 .. fs-java-ext-005` for the
  external-storage set);
- populate the optional top-level `securityBlockers[]` array
  (schema v2.1.0 or later) with one object per row, using the
  shape defined in `documentation/report-contract/schema-v2.1.0.md`
  and `schemas/migration-report.schema.v2.1.0.json`.

The report **MUST NOT** describe a security blocker as
"deferred", "developer signed off", "intentional export
boundary", or "expires <date>". Deferral of `externalStorage`
is rejected by Phase 0 of the validator; the only way for a
security blocker to leave the report green is migration or
removal of the call-site. A `manualTodos[]` entry with
`blocking: true` records that the work is still open — it
is not a waiver.

### 2) Data in Transit Security Summary

Document how sensitive network traffic was handled:

- secure networking migration status (`GDHttpClient`, `GDSocket`, interceptors)
- secure web content status (`BBWebView`)
- unresolved transport risks and affected paths

### 3) Unsupported/Partially Supported Features

Must include:

- detection evidence
- reason not fully migratable
- recommended mitigation or redesign
- severity, blocking, and owner fields in `manualTodos`
- structured `followUp` guidance:
  - `whyBlocked`
  - `safeNextOptions[]`
  - `suggestedAgentPrompt`
  - optional `evidenceFiles[]`

### 3c) Broad DLP / Export Manual Interventions

When validator output indicates broad DLP/output surfaces
(notifications, printing, screenshots/recent thumbnails, autofill,
accessibility, IME/keyboard, external browser/custom tabs, rich clipboard URI
content, drag/drop), the report must include matching `manualTodos[]`
entries.

Rules:

- default `blocking: false` and `owner: "applicationDeveloper"`;
- include module ownership, evidence, required follow-up actions, and
  acceptance criteria;
- escalate to `blocking: true` only when that same path overlaps an
  existing non-waivable security rule (for example `externalStorage`
  security-blocker surfaces or unapproved outbound sharing paths).

### 3a) Media / Export Containment Section

When the app captures, previews, writes, restores, shares, or exports
media/files through camera/gallery/output-URI flows, the report must
include a dedicated `mediaContainment` section.

`mediaContainment.summary` must explain:

- whether app-owned media now remains inside the Dynamics container,
- whether a managed in-container gallery replaced public Gallery /
  MediaStore behavior,
- whether any controlled export path remains,
- and whether any unresolved native-writer or output-URI limitation keeps
  the migration `partial` / `no-go`.

For every media/file write path, `mediaContainment.mediaWritePaths[]`
must record:

- `sourceFile`
- `api`
- `originalBehavior`
- `migratedBehavior`
- whether data stays in the container
- whether direct secure streaming / bounded-memory copy is used
- whether any normal filesystem staging remains
- whether any public export remains
- whether manual intervention is required
- `followUp` when the path still uses filesystem staging, leaves public
  export, or requires manual intervention

For every export/share/capture-intent path,
`mediaContainment.exportPaths[]` must record:

- `sourceFile`
- `pattern`
- `status` (`disabled | migrated | controlled | unresolved`)
- `dlpImpact`
- `behaviorChange`
- `safeOutcome` (`safe | partial | no-go`)
- `followUp` when the path remains unresolved or only partial

The report must not hide camera/media containment changes in generic
`manualTodos` prose alone.

Native OS gallery/viewer launches for secure media
(`Intent.ACTION_VIEW`, `MediaStore.ACTION_REVIEW`,
`Intent.CATEGORY_APP_GALLERY`) must be reported as `unresolved` / `no-go`
unless the migration replaced them with an in-app secure viewer/gallery
or Dynamics ICC. End-user confirmation is not a waiver for unmanaged
egress of secure-container-owned media.

### 3b) Follow-up Guidance

When the report says a migration item is still unresolved, it should hand
the developer a safe next-step description rather than only a red/yellow
status.

Use `followUp` to capture:

- `whyBlocked` — why the tool stopped or why the remaining path is unsafe
- `safeNextOptions[]` — concrete safe strategies the developer can try
- `suggestedAgentPrompt` — copy/paste-ready prompt text for a future AI
  session
- optional `evidenceFiles[]` — the files or artifacts the next session
  should inspect first

The follow-up guidance should stay at the design/remediation level. Do not
fabricate app-specific code recipes that were not verified in the codebase.

### 4) Security Posture

Add `securityPosture` with:

- `dataAtRest` (`status`: `secured` | `partial` | `unverified`, `summary`)
- `dataInTransit` (`status`: `secured` | `partial` | `unverified`, `summary`)

See `80-migration-report-schema.md` for the canonical object shape.

### 5) Migration Confidence

Add `migrationConfidence` with:

- `score` (0-100)
- `level` (`high` | `medium` | `low`)
- `rationale` (short explanation)

Suggested scoring factors:

- coverage completeness
- count/severity of unresolved TODOs
- validation result
- unsupported feature impact

### 6) Go/No-Go Recommendation

Add `releaseReadiness`:

- `recommendation` (`go` | `go-with-risks` | `no-go`)
- `blockingItems` (array of unresolved blockers)
- Failed validation is itself an unresolved blocker. If
  `validation.passed` is `false` or `validation.failures > 0`, the
  report must use `recommendation: "no-go"` and
  `summary.overallStatus: "failed"`.

### 7) Validator-Blocking Failure Snapshot

Add `blockingFailuresFromValidate` (array of strings) with the latest
recorder-owned **source-validation** state (`output/.last-source-check.json`).
Empty array is required after a successful prompt-10 source gate.
Report-contract failures (`output/.last-report-check.json`) are tooling/report
authoring failures and must not be copied into migrated-app blocker fields.
If the recorder fails, fix the reported state/source/report gaps, refresh
report artifacts, and re-run the recorder rather than leaving stale failure
text in the final report.

### 8) Runtime-Only Failure Ledger

Add `runtimeFailures` (array) for defects discovered during runtime
verification that were not detected by static validation. Each entry must
include: `id`, `category`, `symptom`, `rootCause`, `promptGap`,
`validatorGap`, `fix`, and `status` (`open|fixed`).

`category` is a closed enum that lets the validator and downstream
analytics group post-static regressions by root cause:

| `category`                | Use when |
|---------------------------|----------|
| `startupAuthSequencing`   | First-launch failures from accessing secure APIs (Room/DAO/`getWritableDatabase`/network/policy) before `onAuthorized()` (`GDNotAuthorizedError` on `arch_disk_io`, etc.). |
| `deferredInitNullability` | First-launch `NullPointerException` / `UninitializedPropertyAccessException` from UI dereferencing delayed ViewModel/binding fields with `!!` (Pattern 12 violations). |
| `duplicateActivityInit`   | "GD Monitor Fragment already inserted" / duplicate `activityInit(this)` warnings caused by base+subclass both calling `activityInit`. |
| `other`                   | Anything that does not fit the above (justify in `rootCause`). |

### 9) Module Map Surfacing (multi-module support)

Schema v2.1.0 records the project's multi-module shape directly in
the report. The following blocks must be present and must mirror
`dynamics-migration-tool/output/module-map.json`:

- `targetModule` — `name`, `path`,
  `appliesAndroidApplicationPlugin: true`, `applicationId`,
  `buildFile`, `buildFileType`, `conventionPluginRef`,
  `discoveryMethod`, `projectShape`, `sourceSetCount`,
  `inScopeLibraryModules`, and `otherAppModules`. The block identifies
  the single primary application module migrated this run and mirrors
  `module-map.json` `primaryAppModule` plus the module-map top-level
  discovery fields.
- `excludedTestOnlyModules` — every module the discovery step
  classified as test-only or otherwise out of scope. Empty array on
  canonical single-module projects.
- `conventionPlugins` — every Kotlin convention plugin that
  composes the primary module's Android configuration. Empty array
  when no convention plugins exist (Groovy projects, simple apps).
- `summary.migrationCommentCountByModule` — per-module count of
  `[BB_DYNAMICS-MIGRATION]` audit comments, keyed by module path
  (`primaryAppModule.path` and `libraryModulesInScope[*].path`), and
  summing to `summary.migrationCommentCount`.
- `apisReplaced[*].modules` — every Gradle module that owns at
  least one file in `files[]` for that replaced API.
- `filesModified[*].module` — Gradle module owning each modified
  file (or `"<convention-plugin>"` for convention plugin sources).

Sibling application modules (for example `app-primary` vs
`app-secondary`) that were NOT migrated this run must surface as
`manualTodos` entries — one per skipped app module — referencing
`module-map.json` `otherAppModules[]`. Reviewers must be able to
confirm exactly which modules were and were not touched.

### 10) Run-Level Provenance (required)

Report provenance must tie back to bootstrap deterministically:

- Top-level `runId` must equal `bootstrap.json runId`.
- `provenance.runId` must equal top-level `runId`.
- `provenance.bootstrapGeneratedAt` must equal `bootstrap.json generatedAt`.
- `provenance.toolkitVersion` must equal `toolkit.version` and
  `bootstrap.json toolkit.version`.
- `provenance.catalogVersion` must equal both
  `bootstrap.json catalogVersion` and
  `contracts/api-catalog.v1.0.0.json catalogVersion`.
- `provenance.executedPrompts` must mirror
  `bootstrap.json executedPrompts[]` (`promptId` + `status` pairs).
- Git / SDK fields are optional (`null` allowed) when unavailable.
- Recorder lifecycle: prompt-10 drafts are authored before prompt `10` is
  appended; recorder then appends prompt `10` to bootstrap and performs a
  provenance sync. Post-record failures must rollback bootstrap/report so
  retries start from a clean pre-record state.

---

## Quality Gates

Prompt 10 output is acceptable only if:

1. Coverage includes every required area key
   (`secureNetworking`, `securePush`, `secureFileStorage`,
   `secureSql`, `secureUiWidgets`, `secureClipboard`, `authorization`,
   `policyManagement`, `webview`, `icc`) and all applicable domains are
   marked `migrated` or `partial` (never omitted).
2. Toolkit metadata (`toolkit.name/platform/version/reportSchemaVersion`) is present and valid.
3. Unsupported detections are explicit and justified.
4. Data-at-rest and data-in-transit summaries are present.
5. `manualTodos` includes every unresolved high-risk item with explicit
   `blocking` state.
6. The report contains only the fields defined in the v2.1.0 schema;
   unknown top-level keys are rejected by `additionalProperties: false`
   and by the validator's contract check.
7. Validation result from `validate.sh` is included.
8. `blockingFailuresFromValidate` exists and matches the latest
   successful recorder-owned validator state.
9. `runtimeFailures` exists (empty allowed) and entries are complete.
10. `targetModule`, `excludedTestOnlyModules`, `conventionPlugins`,
    `summary.migrationCommentCountByModule`, `apisReplaced[*].modules`,
    and `filesModified[*].module` are present and consistent with
    `module-map.json`.
11. Every `apisReplaced[*].catalogRow` is a non-empty string that
    matches a valid `rows[].id` in
    `contracts/api-catalog.v1.0.0.json`. Free-text provenance is not
    accepted as a substitute. If no catalog row applies, the entry
    must not appear in `apisReplaced` — record it in `manualTodos`
    instead and file a catalog update request.
12. UEM cross-validation
    (`uemAdminHandoff.gdApplicationId` /
    `uemAdminHandoff.gdApplicationVersion`) matches **every**
    settings.json target under `${primary_assets_dirs}` AND
    `bootstrap.json` `uem.gdApplicationId` /
    `uem.gdApplicationVersion`. Any divergence across the three
    sources is a hard fail.
13. Run-level provenance is present and consistent:
    `runId`, `provenance.runId`, `provenance.catalogVersion`,
    `provenance.toolkitVersion`, and `provenance.executedPrompts`
    must match bootstrap + catalog contract.
14. When validator warnings indicate opaque native/closed-source surfaces
    (prebuilt `jniLibs/**/*.so`, JNI `System.loadLibrary` without in-repo
    source, or opaque local binary dependency artifacts such as
    `.aar`/`.jar`/`fileTree`/`flatDir`), the report MUST include
    developer-owned non-blocking `manualTodos[]` entries (`blocking: false`)
    with owning modules, evidence, and required proof actions, and must
    explicitly state those internals are out of automatic migration scope
    unless a non-waivable rule violation is proven.
15. When validator warnings indicate broad DLP/output surfaces
    (notifications, printing, screenshots/recent thumbnails, autofill,
    accessibility, IME/keyboard, external browser/custom tabs, rich
    clipboard URI content, drag/drop), the report MUST include complete
    developer-owned `manualTodos[]` entries. `blocking` defaults to `false`;
    `blocking: true` is allowed only with explicit overlap evidence for an
    existing non-waivable rule.

---

## Enforcement Model

- This migration kit is an enablement tool for developer-led integration.
- Required checks are enforced by `validate.sh` in local workflow to verify
  migration-tool output quality and consistency.
- Teams may optionally mirror these checks in CI, but CI wiring is not required
  by this kit.
