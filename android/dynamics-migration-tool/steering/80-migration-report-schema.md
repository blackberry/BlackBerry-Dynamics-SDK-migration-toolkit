# Steering: Migration Report Schema

After all migration prompts are complete, generate a machine-readable
migration report at `dynamics-migration-tool/output/migration-report.json`.

This file is consumed by CI pipelines, compliance dashboards, security
reviewers, UEM administrators, and the HTML report generator
(`dynamics-migration-tool/migration-report-viewer.html`). It must be valid JSON
and follow the schema below exactly.

---

## Schema

```json
{
  "schemaVersion": "2.1.0",
  "generatedAt": "ISO-8601 timestamp",
  "runId": "UUID copied from bootstrap.json runId",
  "provenance": {
    "bootstrapGeneratedAt": "ISO-8601 timestamp from bootstrap.json generatedAt",
    "catalogContract": "contracts/api-catalog.v1.0.0.json",
    "catalogVersion": "string — copied from bootstrap.json catalogVersion",
    "executedPrompts": [
      {
        "promptId": "string",
        "status": "completed | failed | aborted | skipped",
        "startedAt": "ISO-8601 timestamp | optional",
        "completedAt": "ISO-8601 timestamp | optional"
      }
    ],
    "gitCommit": "string | null",
    "runId": "UUID copied from bootstrap.json runId",
    "sdkArtifact": "string | null",
    "sdkResolvedVersion": "string | null",
    "sdkSha256": "string | null",
    "toolkitVersion": "string — copied from bootstrap.json toolkit.version"
  },
  "toolkit": {
    "name": "dynamics-migration-tool",
    "platform": "Android",
    "version": "string (from dynamics-migration-tool/VERSION)",
    "reportSchemaVersion": "2.1.0"
  },
  "project": {
    "name": "string",
    "package": "string",
    "originalMinSdk": "number",
    "migratedMinSdk": "number"
  },
  "summary": {
    "totalFilesModified": "number",
    "totalApisReplaced": "number",
    "migrationCommentCount": "number",
    "migrationCommentCountByModule": {
      "<module-path>": "number"
    },
    "overallStatus": "complete | partial | failed"
  },
  "targetModule": {
    "applicationId": "string | null — primaryAppModule.applicationId",
    "buildFile": "string — repo-relative Gradle build file path",
    "buildFileType": "direct | convention-plugin",
    "conventionPluginRef": null,
    "discoveryMethod": "fallback-app-dir | settings-gradle-parse | user-supplied",
    "inScopeLibraryModules": [],
    "name": "string — Gradle module name from module-map.json primaryAppModule.name",
    "otherAppModules": [],
    "path": "string — module path relative to project root (e.g. app, app-primary/app-primary)",
    "appliesAndroidApplicationPlugin": true,
    "projectShape": "single-module | multi-module",
    "sourceSetCount": 1
  },
  "excludedTestOnlyModules": [
    {
      "name": "string",
      "path": "string",
      "reachedVia": "testImplementation | androidTestImplementation | testApi | androidTestApi | testCompileOnly | androidTestCompileOnly | testRuntimeOnly | androidTestRuntimeOnly"
    }
  ],
  "conventionPlugins": [
    {
      "appliesAndroidPlugin": "com.android.application | com.android.library | null",
      "consumedBy": ["string — module names that apply this plugin"],
      "editStrategy": "edit-convention-plugin | override-in-app-module | not-applicable",
      "pluginId": "string — fully qualified plugin id",
      "sourceFile": "string — repo-relative path to convention plugin source",
      "edited": "boolean — whether this run modified a convention plugin"
    }
  ],
  "filesModified": [
    {
      "path": "string — relative path from project root",
      "module": "string — owning module name (primary or library) or '<convention-plugin>'",
      "changeType": "modified | created | deleted",
      "description": "string — one-line summary"
    }
  ],
  "apisReplaced": [
    {
      "catalogRow": "string — stable row ID from contracts/api-catalog.v1.0.0.json (REQUIRED)",
      "category": "networking | storage-file | storage-sql | ui-widget | clipboard | policy | webview | icc | auth | gradle",
      "original": "string — fully qualified original API",
      "replacement": "string — fully qualified Dynamics API",
      "files": ["string"],
      "modules": ["string — owning Gradle module names from module-map.json"],
      "count": "number",
      "risk": "low | medium | high",
      "riskReason": "string — why this risk level was assigned",
      "before": "string — code snippet BEFORE migration (1-5 lines)",
      "after": "string — code snippet AFTER migration (1-5 lines)"
    }
  ],
  "coverage": {
    "secureNetworking": { "status": "migrated | not-applicable | partial", "details": "string" },
    "securePush": { "status": "migrated | not-applicable | partial", "details": "string" },
    "backgroundAuthorize": { "status": "migrated | not-applicable | partial", "details": "string" },
    "secureFileStorage": { "status": "migrated | not-applicable | partial", "details": "string" },
    "secureSql": { "status": "migrated | not-applicable | partial", "details": "string" },
    "secureUiWidgets": { "status": "migrated | not-applicable | partial", "details": "string" },
    "secureClipboard": { "status": "migrated | not-applicable | partial", "details": "string" },
    "authorization": { "status": "migrated | not-applicable | partial", "details": "string" },
    "policyManagement": { "status": "migrated | not-applicable | partial", "details": "string" },
    "webview": { "status": "migrated | not-applicable | partial", "details": "string" },
    "icc": { "status": "migrated | not-applicable | partial", "details": "string" }
  },
  "egressFeatures": [
    {
      "id": "string — stable id from migration-analysis.json egressFeatures[].id",
      "featureName": "string",
      "domain": "secureFileStorage | secureNetworking | icc | secureClipboard | secureUiWidgets | policyManagement",
      "outcome": "REMOVE | REPLACE_WITH_DYNAMICS | MANUAL_INTERVENTION_REQUIRED | BLOCKED_UNTIL_APPROVED",
      "status": "implemented | manual-follow-up | blocked",
      "reason": "string — why this capability was removed/blocked/replaced",
      "migrationAction": "string — what the migration changed",
      "userVisibleChange": "string — what the user sees now",
      "secureAlternative": "string | null",
      "sourceFiles": ["string — project-root-relative source paths"],
      "followUp": {
        "whyBlocked": "string",
        "safeNextOptions": ["string"],
        "suggestedAgentPrompt": "string",
        "evidenceFiles": ["string"]
      }
    }
  ],
  "mediaContainment": {
    "summary": "string",
    "mediaWritePaths": [
      {
        "sourceFile": "string",
        "api": "string",
        "originalBehavior": "string",
        "migratedBehavior": "string",
        "staysInContainer": "boolean",
        "usesDirectSecureStream": "boolean",
        "usesFilesystemStaging": "boolean",
        "publicExportRemains": "boolean",
        "manualInterventionRequired": "boolean",
        "followUp": {
          "whyBlocked": "string",
          "safeNextOptions": ["string"],
          "suggestedAgentPrompt": "string",
          "evidenceFiles": ["string"]
        }
      }
    ],
    "exportPaths": [
      {
        "sourceFile": "string",
        "pattern": "string",
        "status": "disabled | migrated | controlled | unresolved",
        "dlpImpact": "string",
        "behaviorChange": "string",
        "safeOutcome": "safe | partial | no-go",
        "followUp": {
          "whyBlocked": "string",
          "safeNextOptions": ["string"],
          "suggestedAgentPrompt": "string",
          "evidenceFiles": ["string"]
        }
      }
    ]
  },
  "manualTodos": [
    {
      "id": "string",
      "title": "string",
      "domain": "string",
      "blocking": "boolean",
      "owner": "applicationDeveloper",
      "severity": "P0 | P1 | P2 | P3",
      "reason": "string",
      "affectedModules": ["string"],
      "evidence": ["string"],
      "requiredActions": ["string"],
      "acceptanceCriteria": ["string"],
      "status": "open | completed | acceptedRisk | notApplicable",
      "followUp": {
        "whyBlocked": "string",
        "safeNextOptions": ["string"],
        "suggestedAgentPrompt": "string",
        "evidenceFiles": ["string"]
      }
    }
  ],
  "blockingFailuresFromValidate": [
    "string — final blocking validator failures captured during prompt 10"
  ],
  "runtimeFailures": [
    {
      "id": "string — stable id (e.g. RF-1)",
      "category": "startupAuthSequencing | deferredInitNullability | duplicateActivityInit | other",
      "symptom": "string — runtime symptom or log signature",
      "rootCause": "string — why static checks did not catch it",
      "promptGap": "string — prompt contract gap that allowed this",
      "validatorGap": "string — validator phase/check gap",
      "fix": "string — generic remediation pattern",
      "status": "open | fixed"
    }
  ],
  "unsupportedFeatures": [
    {
      "feature": "string",
      "reason": "string",
      "workaround": "string | null",
      "followUp": {
        "whyBlocked": "string",
        "safeNextOptions": ["string"],
        "suggestedAgentPrompt": "string",
        "evidenceFiles": ["string"]
      }
    }
  ],
  "runtimeTestPlan": [
    {
      "scenario": "string — test scenario name",
      "steps": "string — how to execute the test",
      "expectedResult": "string — what success looks like",
      "relatedAreas": ["string — e.g. authorization, secureSql"]
    }
  ],
  "evidenceCompleteness": {
    "overallStatus": "complete | incomplete | partial",
    "domains": {
      "<domain>": {
        "status": "verified | partial | unverified | not-applicable",
        "validatorVerified": "boolean",
        "inventoriedCallSites": "number",
        "rediscoveredSurfaces": "number"
      }
    },
    "runtimeEvidence": {
      "status": "passed | failed | not-run",
      "summary": "string — explicit runtime proof statement or not-run reason"
    }
  },
  "unverifiedSurfaces": [
    {
      "id": "string — stable id from .independent-evidence.json when available",
      "domain": "string",
      "sourceFile": "string",
      "line": "number | optional",
      "pattern": "string",
      "securityCritical": "boolean",
      "status": "open | resolved | acceptedRisk | notApplicable",
      "reason": "string | optional"
    }
  ],
  "uemAdminHandoff": {
    "gdApplicationId": "string",
    "gdApplicationVersion": "string",
    "entitlementSetup": "string — instructions for creating the entitlement in UEM",
    "connectivityProfile": "string — recommended connectivity profile settings",
    "complianceProfile": "string — recommended compliance policy settings",
    "appPermissions": ["string — Dynamics permissions the app requires"]
  },
  "validation": {
    "passed": "boolean",
    "failures": "number",
    "warnings": "number",
    "mode": "string — required: 'source' | 'final-source' (prompt-10 source validation via record-prompt-execution.sh). Never incremental/scoped/report."
  },
  "securityPosture": {
    "dataAtRest": {
      "status": "secured | partial | unverified",
      "summary": "string"
    },
    "dataInTransit": {
      "status": "secured | partial | unverified",
      "summary": "string"
    }
  },
  "migrationConfidence": {
    "score": "number (0-100)",
    "level": "high | medium | low",
    "rationale": "string"
  },
  "releaseReadiness": {
    "recommendation": "go | go-with-risks | no-go",
    "blockingItems": ["string"]
  },
  "securityBlockers": [
    {
      "domain": "externalStorage",
      "surface": "api-surface",
      "count": 3,
      "message": "External storage / MediaStore / shared-storage API surface detected ...",
      "remediation": "Migrate every call-site to com.good.gd.file.* container paths ...",
      "catalogRows": ["fs-java-ext-001", "fs-java-ext-003"],
      "filePaths": ["app/src/main/java/.../ExportViewModel.kt"]
    }
  ],
  "safFindings": [
    {
      "findingId": "string — stable identifier (e.g. saf-export-001)",
      "classification": "SAF_INBOUND_IMPORT | SAF_OUTBOUND_EXPORT | SAF_EXTERNAL_PRIMARY_STORAGE | SAF_URI_SHARING | SAF_PLAINTEXT_STAGING",
      "sourceFile": "string — relative path",
      "sourceLine": "number",
      "originalBehavior": "string — what the flow does before migration",
      "dataFlowDirection": "inbound | outbound | bidirectional",
      "securityRisk": "low | medium | high | critical",
      "initiatingUiAction": "string — UI element that triggers the flow",
      "targetApi": "string — e.g. ACTION_CREATE_DOCUMENT, ContentResolver.openOutputStream",
      "destinationUserSelected": "boolean — user picks the destination via SAF picker",
      "grantsUriPermissions": "boolean — whether FLAG_GRANT_*_URI_PERMISSION is used",
      "plaintextStagingPresent": "boolean — whether plaintext intermediate exists",
      "migrationDecision": "BLOCKED_PENDING_DEVELOPER_APPROVAL | BLOCK | ALLOW_WITH_DLP_ENFORCEMENT | REPLACE_WITH_SECURE_INTERNAL_FLOW | MANUAL_REDESIGN_REQUIRED",
      "developerApprovalRequested": "boolean",
      "developerResponse": "string | null",
      "decisionTimestamp": "ISO-8601 | null",
      "justification": "string | null",
      "featureStatus": "blocked | migrated-inbound | approved-dlp | replaced-icc | removed",
      "uiBehaviorAfterMigration": "string — what the user sees after migration",
      "runtimeDlpEnforced": "boolean — true only for approved DLP-gated outbound flows",
      "plaintextStagingRemoved": "boolean",
      "changedFiles": ["string"],
      "validationResult": "pass | fail | pending",
      "residualManualWork": "string | null"
    }
  ],
  "safSummary": {
    "inboundImportsSecured": "number",
    "outboundExportsBlocked": "number",
    "outboundExportsApproved": "number",
    "uriSharingFlowsBlocked": "number",
    "externalPrimaryStorageReplaced": "number",
    "plaintextStagingPathsRemoved": "number",
    "unresolvedFlowsRequiringManualIntervention": "number"
  }
}
```

> `securityBlockers[]` is **optional** in the schema but is **mandatory**
> in every report whenever
> `dynamics-migration-tool/output/.security-blockers.log` is non-empty
> after the validator runs. See §"securityBlockers" below and the
> canonical spec in
> `documentation/report-contract/schema-v2.1.0.md`.

---

## Field Rules

### schemaVersion
Always `"2.1.0"` for reports that include `runtimeTestPlan`,
`uemAdminHandoff`, and `apisReplaced[].catalogRow`.

### runId
Copy from `bootstrap.json runId` exactly. This is the stable run-level
identifier that ties bootstrap, analysis, plan-state, and report
artifacts together.

### provenance
`provenance` is required for auditability and must be copied from
bootstrap + current report context:

- `provenance.runId` must equal top-level `runId`.
- `provenance.bootstrapGeneratedAt` must equal `bootstrap.json generatedAt`.
- `provenance.toolkitVersion` must equal `toolkit.version`.
- `provenance.catalogVersion` must equal `bootstrap.json catalogVersion`
  and `contracts/api-catalog.v1.0.0.json catalogVersion`.
- `provenance.executedPrompts` must mirror
  `bootstrap.json executedPrompts[]`.
- `provenance.gitCommit` and SDK fields may be `null` when unavailable.
- Prompt-10 lifecycle is two-step:
  - pre-record draft: provenance mirrors bootstrap **before** prompt `10` is
    appended;
  - post-record final: recorder appends prompt `10` to bootstrap, then syncs
    report provenance from bootstrap. Do not hand-edit `provenance` after
    recorder completion.

### toolkit
- `toolkit.name` must be `"dynamics-migration-tool"`.
- `toolkit.platform` must be `"Android"`.
- `toolkit.version` must match `dynamics-migration-tool/VERSION`.
- `toolkit.reportSchemaVersion` must be `"2.1.0"`.

### overallStatus
- `complete` — all applicable coverage areas are `migrated` AND validation passed with 0 failures
- `partial` — any applicable area is `partial`, or validation has warnings but no failures
- `failed` — validation has failures

### `egressFeatures[]`

This section is the feature-level counterpart to call-site closure. It exists
for capabilities whose business purpose is to move protected data outside the
container, for example:

- backup / restore
- public Downloads or Gallery export
- generic share/open-with/email/viewer flows
- unmanaged printing
- unmanaged clipboard / drag-drop export

Rules:

- The report section is generated from `migration-analysis.json`
  `egressFeatures[]` plus `migration-plan-state.json`
  `egressFeatureDecisions[]`.
- Every analyzed `migration-analysis.json` `egressFeatures[]` entry must have
  a matching report entry.
- `migration-plan-state.json egressFeatureDecisions[].outcome` must match
  report `egressFeatures[].outcome` for the same feature id.
- `status` mapping is deterministic:
  - `REMOVE`/`REPLACE_WITH_DYNAMICS` -> `implemented`
  - `MANUAL_INTERVENTION_REQUIRED` -> `manual-follow-up`
  - `BLOCKED_UNTIL_APPROVED` -> `blocked`
- `REMOVE` and `REPLACE_WITH_DYNAMICS` represent implemented migration
  outcomes.
- `BLOCKED_UNTIL_APPROVED` means the Android path is disabled/unreachable
  today; the report must explain the product decision still needed.
- `MANUAL_INTERVENTION_REQUIRED` means the kit intentionally did not preserve
  the original Android path and is surfacing safe next options instead.
- `REPLACE_WITH_DYNAMICS` entries must name the approved Dynamics boundary in
  `secureAlternative`.
- `BLOCKED_UNTIL_APPROVED` and `MANUAL_INTERVENTION_REQUIRED` entries must
  include `followUp` guidance and a matching `manualTodos[]` entry.

### apisReplaced — catalogRow (required, v2.1.0)
Every `apisReplaced[]` entry must include a `catalogRow` whose value
is a stable row `id` from `contracts/api-catalog.v1.0.0.json`. This
proves the replacement comes from the approved catalog and allows
validators to cross-check report claims against the machine-readable
source of truth.

- The value must match an existing `rows[].id` in the JSON catalog.
- If no catalog row exists for a replacement, do NOT invent a row ID.
  Instead, add a `manualTodo` explaining why the replacement has no
  catalog entry, and file a catalog update request.
- Free-text provenance is not a substitute for `catalogRow`.

### apisReplaced — risk
Assign risk based on behavioral change:
- `low` — drop-in replacement, same method signatures (e.g. SQLite import swap)
- `medium` — API shape changes, requires refactoring but equivalent behavior (e.g. HttpURLConnection to GDHttpClient)
- `high` — behavioral change that could cause runtime issues if not tested (e.g. Socket with custom TLS to GDSocket)

### apisReplaced — modules (multi-module)
List every Gradle module that owns at least one file in `files[]`.
Module names come from `output/module-map.json`
(`primaryAppModule.name` or `libraryModulesInScope[*].name`). On a
canonical single-module project this is `["app"]`. The set lets
downstream reviewers see, per replaced API, whether the change
touched only the application module or also library modules — and,
combined with `summary.migrationCommentCountByModule`, drives the
multi-module scorecard in the HTML report viewer.

### targetModule (multi-module)
Required since schema v2.0.0. Mirror
`output/module-map.json` `primaryAppModule` and module-map top-level
project-shape facts exactly:

- `name` — Gradle module name from `primaryAppModule.name`.
- `path` — module path relative to the project root from
  `primaryAppModule.path`.
- `appliesAndroidApplicationPlugin` — must be `true`; the migration
  does not target library or KMP modules.
- `applicationId` — `primaryAppModule.applicationId` when statically
  discovered, else `null`.
- `buildFile` — `primaryAppModule.buildFile`.
- `buildFileType` — `primaryAppModule.buildFileType`
  (`direct | convention-plugin`).
- `conventionPluginRef` — `primaryAppModule.conventionPluginRef`
  when the application plugin is composed through a convention plugin,
  else `null`.
- `discoveryMethod` — top-level `module-map.json.discoveryMethod`.
- `projectShape` — top-level `module-map.json.projectShape`.
- `sourceSetCount` — count of `primaryAppModule.sourceSets[]`.
- `inScopeLibraryModules` — `module-map.json.libraryModulesInScope[]`.
- `otherAppModules` — `module-map.json.otherAppModules[]`.

Reviewers consume this block to confirm the migration ran against
the intended module on multi-application projects. Sibling
application modules left unmigrated are
recorded under `manualTodos` (one entry per skipped app module),
referencing `module-map.json` `otherAppModules[]`.

### excludedTestOnlyModules (multi-module)
Mirror `output/module-map.json` `excludedTestOnlyModules[]`. Each
entry has `name`, `path`, and `reachedVia` (the test configuration
edge that reached the module, e.g. `testImplementation`). Empty array on canonical
single-module projects. Surfacing this list makes the migration
scope explicit — reviewers can confirm test-only modules were
intentionally skipped rather than accidentally missed.

### conventionPlugins (multi-module)
Mirror `output/module-map.json` `conventionPlugins[]`. Each entry
records the plugin id and the source files that compose its
implementation. Set `edited: true` when prompt 01 modified one of
the listed source files (most commonly when `minSdk` /
`compileSdk` is centralized in a `*.AndroidApplicationConventionPlugin`).
On Groovy-DSL projects without convention plugins this is `[]`.

### summary.migrationCommentCountByModule (multi-module)
Map from module path to per-module count of `[BB_DYNAMICS-MIGRATION]`
audit comments. Keys mirror `module-map.json` `path` values
(`primaryAppModule.path` and each `libraryModulesInScope[*].path`).
Sum of values must equal `summary.migrationCommentCount`. On a
canonical single-module project this is
`{"app": <migrationCommentCount>}`.

### filesModified.module (multi-module)
Each `filesModified[*]` entry records the owning Gradle module
name. Use `primaryAppModule.name`, one of
`libraryModulesInScope[*].name`, or the literal string
`"<convention-plugin>"` for paths inside a Kotlin convention
plugin source file listed under `conventionPlugins[*].sourceFile`.

### apisReplaced — before / after
- Keep snippets short: 1-5 lines of representative code
- Pick the clearest example from the codebase
- Escape quotes and backslashes for valid JSON
- These are shown side-by-side in the HTML report viewer

### runtimeTestPlan
Generate a test scenario for each migrated coverage area. Each scenario should be actionable by a QA engineer who has never seen the codebase. Always include:
- Authorization flow test (activate, lock, wipe)
- One test per migrated area
- Policy retrieval test if policy was migrated

### uemAdminHandoff
This section is for the UEM administrator. Include:
- The exact `gdApplicationId` and `gdApplicationVersion` from settings.json
- Step-by-step entitlement creation instructions
- Connectivity profile recommendations
- Compliance profile recommendations
- App permissions the app requires from Dynamics

### General
- Do NOT include `[BB_DYNAMICS-MIGRATION]` comments in the JSON
- Place the file at: `dynamics-migration-tool/output/migration-report.json`
- `manualTodos` must include anything the agent could not automate. Use this
  single array for both blocking and non-blocking manual interventions; do not
  create parallel `developerActions[]` or `manualInterventions[]` sections.
  The `blocking` boolean, not a separate status name, determines whether the
  item prevents `go`.
- If `bootstrap.json.backup.branch` and `backup.createdFromCommit` are
  both `null`, `manualTodos` must include external rollback-copy
  guidance for the developer. This is the supported non-git bootstrap
  path, not a prompt failure.
- `blockingFailuresFromValidate` must be present (empty array allowed) and
  reflect the latest recorder-owned **source-validation** state after prompt 10
  (`output/.last-source-check.json`). Report-contract failures are tracked
  separately in `output/.last-report-check.json` and must not be copied into
  migrated-app blocker fields.
- `runtimeFailures` must be present (empty array allowed) and capture
  runtime-only migration defects discovered after static checks. Every
  entry must declare a `category` from the enumerated set
  (`startupAuthSequencing`, `deferredInitNullability`,
  `duplicateActivityInit`, `other`); the validator rejects any other
  value. Use `other` only when no enumerated category applies and
  explain the symptom in `rootCause`.
- Non-migrated call-sites are surfaced via `manualTodos` with
  `blocking: true` and `releaseReadiness.blockingItems` when their domain is deferred, or
  as `blockingFailuresFromValidate` when they are simply unmigrated
  (which fails release readiness). The report schema's
  `additionalProperties: false` rejects unknown top-level keys.
- `unsupportedFeatures` must list incompatible third-party libraries or
  patterns — but ONLY if no safe workaround has been implemented in the
  codebase. Safe workarounds are bounded in-memory conversion, GD-backed
  secure temporary storage, direct Dynamics streams, or pipe/memory
  descriptors fed by Dynamics streams. Native `copyToTemp`,
  `createTempFile`, app-private `cacheDir` / `filesDir` staging, and
  write-temp-then-copy patterns are unresolved blockers, not evidence of
  resolution. Document resolved workarounds in the relevant
  `apisReplaced` entry instead.
- **Clipboard DLP** is tracked as its own coverage area (`secureClipboard`).
  Status is `migrated` only when **all** platform and Compose clipboard
  surfaces are closed: no `android.content.ClipboardManager`, no unmanaged
  `LocalClipboardManager` / `LocalClipboard` / Compose `ClipEntry` usage,
  and deterministic flows routed through `com.good.gd.content.ClipboardManager`
  or kit `GDClipboardAdapter`. Status `not-applicable` is valid only when the
  inventory found zero platform **and** zero Compose clipboard usage.
  Include clipboard API replacements in `apisReplaced` with category
  `clipboard` (`clipboard-java-001`, `clipboard-compose-001` … `003`).
- **Background Authorize** is tracked as its own coverage area
  (`backgroundAuthorize`). Status is `not-applicable` only when
  `bootstrap.processModel.backgroundEntryPoints[]` is empty. Status is
  `migrated` when every candidate is either migrated or explicitly
  confirmed not applicable. Status is `partial` while any candidate has
  intent `deferred`. The `details` string must list each candidate's
  name, module, intent, rationale, and functional impact.

### securityPosture
- `dataAtRest` summarizes secure storage/database/container coverage.
- `dataInTransit` summarizes secure network/web transport coverage.
- Use `partial` when unresolved high-risk paths remain.

### mediaContainment
Optional overall, but **required whenever media/export/capture patterns are
part of the migration outcome** (for example MediaStore blockers,
capture-intent output URI flows, MediaRecorder path writers, gallery
redesign, or controlled export behavior changes).

- `summary` explains the chosen containment model and user-visible changes.
- `mediaWritePaths[]` records each media/file write path with whether it
  stays inside the container, uses direct secure streaming, leaves any
  filesystem staging, leaves any public export, and still requires manual
  intervention.
- `exportPaths[]` records each share/export/capture-intent path and must
  classify it as `disabled`, `migrated`, `controlled`, or `unresolved`.
- `controlled` is reserved for safe managed boundaries such as Dynamics
  ICC. Native OS gallery/viewer invocation for secure media
  (`ACTION_VIEW`, `ACTION_REVIEW`, `CATEGORY_APP_GALLERY`) must not be
  reported as `controlled`.
- If any entry has `usesFilesystemStaging: true`,
  `publicExportRemains: true`, or `manualInterventionRequired: true`,
  the report must not present secure file storage as fully migrated.
- When a `mediaWritePaths[]` or `exportPaths[]` entry remains unresolved,
  include a `followUp` object with:
  - `whyBlocked`
  - `safeNextOptions[]`
  - `suggestedAgentPrompt`
  - optional `evidenceFiles[]`

### followUp
Use `followUp` when the report is handing unresolved engineering work back
to the developer for another AI-guided iteration.

- `whyBlocked` explains why the toolkit stopped or why the path is not yet
  safe.
- `safeNextOptions[]` lists the safest next designs to try, not speculative
  code-level guesses.
- `suggestedAgentPrompt` should be copy/paste-ready for the next AI
  session.
- `evidenceFiles[]` should point the next session at the most relevant
  source files or artifacts first.
- `unsupportedFeatures[]` entries should include `followUp`.
- `manualTodos[]` may include `followUp` when a TODO represents developer-
  owned engineering work rather than operational/UEM handoff.

### migrationConfidence
- `score` is 0-100 and should drop when unresolved high-severity or
  blocking manual interventions exist.
- `level` should match score bands:
  - `high`: 80-100
  - `medium`: 50-79
  - `low`: 0-49
- Any non-waivable `securityBlockers[]` entry forces `level = "low"`.

### releaseReadiness
- `go`: no validation failures, no security blockers, no blocking manual
  interventions, no security-critical unverified surfaces, and all
  non-blocking manual interventions recorded.
- `go-with-risks`: no hard runtime blocker, but at least one non-blocking
  manual intervention remains open or accepted as risk.
- `no-go`: validation failures, pre-auth secure access, security blockers,
  security-critical unverified surfaces, or any `manualTodos[]` entry with
  `blocking: true`.
- Any failed `validation` block (`passed: false` or `failures > 0`) forces
  `recommendation = "no-go"` and `summary.overallStatus = "failed"`.
- **Any non-empty `securityBlockers[]` forces `no-go`.** This is not a
  judgement call — Phase 0 + Phase 4 + Phase 10 of the validator
  enforce it. See `40-secure-file-storage.md` §9 for the canonical
  rule and the non-waivable external-storage / MediaStore failure
  mode it prevents.
- A SAF export/share feature that is safely blocked or removed can
  satisfy security closure, but a pending product decision represented by
  `safDecision.migrationDecision: "BLOCKED_PENDING_DEVELOPER_APPROVAL"`
  and a `manualTodos[]` entry with `blocking: true` keeps
  `releaseReadiness.recommendation = "no-go"` until the developer
  explicitly accepts permanent blocking or chooses a replacement.

### safFindings and safSummary

**`safFindings[]` is a REPORT-ONLY section.** It exists only in the
final `migration-report.json` generated at prompt 10. It is NOT an
interim artifact and must NOT be written to `migration-plan-state.json`
or any other file during migration prompts 05a–09.

**Source of truth during migration:** The interim data lives in
`migration-plan-state.json` → `dispositions[].safDecision`. Storage-owned
SAF export/import dispositions use `domain: "secureFileStorage"`; URI
sharing dispositions use `domain: "icc"` when owned by prompt `08`.
`externalStorage` remains only the non-waivable validator/security-blocker
category.

Prompt 10 aggregates `dispositions[]` entries whose `safDecision` object
is present into the `safFindings[]` report section and generates
`manualTodos[]` entries with `blocking: true` for pending approvals.
The `note` field is human-readable audit text; do not parse arbitrary
note prose as the machine contract.

`safFindings[]` is mandatory whenever Phase 4N (SAF directional
classification) detects any SAF pattern. Each finding records:

- **Classification** — one of `SAF_INBOUND_IMPORT`,
  `SAF_OUTBOUND_EXPORT`, `SAF_EXTERNAL_PRIMARY_STORAGE`,
  `SAF_URI_SHARING`, `SAF_PLAINTEXT_STAGING`.
- **Migration decision** — defaults to
  `BLOCKED_PENDING_DEVELOPER_APPROVAL` for outbound/sharing flows.
  Inbound flows default to `migrated-inbound` after secure-copy.
- **Feature status** — `blocked` until developer explicitly approves.
- **Validation** — `pass` only when the blocked path is proven
  unreachable or the approved path has DLP enforcement.

`safSummary` provides aggregate counts for the SAF section header in
the migration report viewer and compliance dashboards.

Rules:
- A `featureStatus: "blocked"` entry is NOT a migration failure; it
  is a secure default. The validator fails only if an outbound path
  remains *reachable without a decision*.
- `migrationDecision` must never be inferred — absence of developer
  response means `BLOCK`.
- `runtimeDlpEnforced` must be `true` for any approved outbound flow;
  `false` on approved outbound flow forces validation failure.
- `plaintextStagingRemoved` must be `true` for every finding;
  `false` forces validation failure.

See `steering/44-saf-trust-boundary.md` for the full contract.

### securityBlockers
Optional in the JSON Schema; mandatory whenever
`dynamics-migration-tool/output/.security-blockers.log` is non-empty.

- Source of truth: TSV log written by
  `tooling/validate.sh` `security_blocker()` during phase scans.
- Each entry has `domain` (closed enum, currently `"externalStorage"`),
  `surface`, `count`, `message`, `remediation`, optional
  `catalogRows[]`, optional `filePaths[]`. Current `externalStorage`
  surfaces include Phase 4 API-surface blockers, Phase 4N SAF
  directional blockers (`saf-outbound-export`,
  `saf-uri-sharing`, `saf-external-primary-storage`), and Phase 8b
  FileProvider-path blockers (`fileprovider-external-path`,
  `fileprovider-external-files-path`, `fileprovider-external-cache-path`,
  `fileprovider-root-path`). See
  `documentation/report-contract/schema-v2.1.0.md` for the full
  field-by-field contract.
- When this array is non-empty the report MUST also:
  - copy each row into `releaseReadiness.blockingItems[]` prefixed
    `[SECURITY-BLOCKER][<domain>/<surface>]`;
  - add a `manualTodos[]` entry per row with `blocking: true`,
    `owner: "applicationDeveloper"`, and a title starting
    `"Manual intervention required before production use — "`;
  - set `releaseReadiness.recommendation = "no-go"`,
    `summary.overallStatus = "failed"`,
    `migrationConfidence.level = "low"`;
  - set `coverage.secureFileStorage.status = "partial"` whenever the
    blocker domain is `externalStorage`; the report must not claim the
    file-storage domain is fully migrated while MediaStore / SAF /
    FileProvider / raw-path or similar container-boundary escapes remain;
  - downgrade `securityPosture.dataAtRest.status` from `"secured"`
    when the blocker is in the `externalStorage` domain.
- The array MUST NOT be used to describe waivable findings or
  deferred items — those go in `manualTodos[]` with `blocking: false`
  unless the item must prevent `go`.

---

## Execution-Plan Gate (Hard, in Prompt 10)

The migration-report schema does NOT carry the per-prompt execution
trail; that lives in `bootstrap.json` under `executedPrompts[]` (see
`steering/02-bootstrap-schema.md` and the canonical
`documentation/report-contract/bootstrap-schema-v1.1.0.md`). However,
prompt 10 is **required** to cross-check the bootstrap audit against
the binding `executionPlan` in `migration-analysis.json` before writing
this report.

A migration-report must NOT be written if any entry in `executionPlan`
where `applicable: true` has neither:

1. A `bootstrap.executedPrompts[]` entry whose `promptId` matches the
   plan's `promptId` AND `status: "completed"` (progress evidence only;
   prompt 10 final source/report gates enforce the migrated state, so no
   separate `validateResult` field is consulted), **nor**
2. A `bootstrap.deferredDomains[]` entry for the same `domain` with
   `developerSignedOff: true` and a non-empty `reason`.

If the gate fails, the report is not written and prompt 10 aborts with
a remediation message. This forecloses the previous "demote applicable
domain to a non-blocking `manualTodo`" loophole.

`manualTodos` may STILL contain post-migration items the developer
must complete (UEM entitlement, runtime testing, third-party
compatibility checks, etc.) — what `manualTodos` may NOT contain is
"this applicable domain wasn't migrated".

### uemAdminHandoff cross-validation

`uemAdminHandoff.gdApplicationId` and `uemAdminHandoff.gdApplicationVersion`
must match three sources exactly:

1. `bootstrap.json` `uem.gdApplicationId` / `uem.gdApplicationVersion`
2. The settings.json `GDApplicationID` / `GDApplicationVersion`
   values written by prompt 02. On multi-module / flavored projects
   the cross-check covers **every** entry in `${primary_assets_dirs}`
   from `output/module-map.json` (main + each declared product
   flavor / build type). All targets must agree byte-for-byte; any
   divergence is a hard fail.
3. The values written into the report itself

Any three-way mismatch is a hard fail — re-run prompt 02 to align
`settings.json` against `bootstrap.json`, then re-run prompt 10.

---

## Companion Output: Dynamics_Migration_Readme.md

In addition to the JSON report, generate a human-readable
`Dynamics_Migration_Readme.md` at the project root. This file gives
developers and reviewers a quick summary of the migration without
needing to parse JSON. See `prompts/10-generate-migration-report.md` (Prompt 10)
for the required sections and formatting rules.

Output files:
- `dynamics-migration-tool/output/migration-report.json` — machine-readable
- `Dynamics_Migration_Readme.md` (project root) — human-readable summary
