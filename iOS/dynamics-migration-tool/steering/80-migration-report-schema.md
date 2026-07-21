# Steering: Migration Report Schema

After all migration prompts are complete, generate a machine-readable
migration report at `dynamics-migration-tool/output/migration-report.json`.

This file is consumed by CI pipelines, compliance dashboards, security
reviewers, UEM administrators, and the HTML report generator
(`dynamics-migration-tool/migration-report-viewer.html`). It must be valid JSON
and follow the schema below exactly.

---

## Schema

**Schema version: 2.1.0** (upgrade from 2.0.0 — foundation closure adds
run provenance, closure ledger proof, prompt audit, and validation proof
blocks).
Reports with `schemaVersion: "2.0.0"` are **rejected** by the validator.

```json
{
  "schemaVersion": "2.1.0",
  "platform": "iOS",
  "generatedAt": "ISO-8601 timestamp",
  "toolkit": {
    "name": "dynamics-migration-tool",
    "platform": "iOS",
    "version": "string (from dynamics-migration-tool/VERSION)",
    "reportSchemaVersion": "2.1.0"
  },
  "runProvenance": {
    "runId": "string — from bootstrap.json runId",
    "bootstrapTimestamp": "ISO-8601 timestamp from bootstrap.json",
    "toolkitVersion": "string — from VERSION file"
  },
  "targetMapSummary": {
    "buildEntrypointType": "workspace | project | unresolved",
    "buildEntrypointPath": "string | null",
    "targetCount": "number",
    "applicationTargetCount": "number",
    "extensionLikeTargetCount": "number",
    "ambiguityCount": "number"
  },
  "lifecycleSummary": {
    "primaryPattern": "string",
    "hasSceneDelegate": "boolean",
    "hasSwiftUIApp": "boolean",
    "preAuthRiskCount": "number",
    "selectedAuthorizationPattern": "delegate | notification | mixed | unknown",
    "postAuthBoundary": "string",
    "windowStrategy": "string",
    "sceneQueueingStrategy": "string",
    "lifecycleRootCount": "number",
    "opaqueStartupPathCount": "number",
    "prompt03Validation": "pass | warn | fail",
    "prompt03bValidation": "pass | warn | fail",
    "reachabilityGeneratedAt": "ISO-8601",
    "reachabilitySourceFingerprint": "sha256 string"
  },
  "executedPromptAudit": {
    "recordedCount": "number",
    "prompts": [{ "promptId": "string", "status": "string", "recordedAt": "string" }]
  },
  "closureSummary": {
    "applicableCallSiteCount": "number",
    "resolvedCallSiteCount": "number",
    "unresolvedCallSiteCount": "number",
    "blockedCount": "number",
    "deferredCount": "number",
    "allApplicableDomainsClosed": "boolean"
  },
  "blockers": [{ "domain": "string", "message": "string" }],
  "unresolvedCallSites": [{ "callSiteId": "string", "reason": "string" }],
  "validationProof": {
    "mode": "prompt-scoped | full | preflight",
    "promptScope": "string | null",
    "runId": "string",
    "result": "pass | warn | fail",
    "timestamp": "ISO-8601",
    "isStale": "boolean",
    "phases": ["phase-id"]
  },
  "apiCatalogEvidence": {
    "catalogVersion": "string",
    "unknownCatalogRows": ["string"]
  },
  "runtimeEvidenceStatus": {
    "runtimeVerification": "verified | pending | unavailable",
    "uemEvidence": "verified | pending | unavailable",
    "notes": ["string"]
  },
  "project": {
    "name": "string",
    "bundleIdentifier": "string",
    "originalDeploymentTarget": "string (e.g. 15.0)",
    "migratedDeploymentTarget": "string (e.g. 17.0)",
    "language": "Swift | Objective-C | Mixed",
    "integrationMethod": "CocoaPods | SPM | Manual"
  },
  "summary": {
    "totalFilesModified": "number",
    "totalApisReplaced": "number",
    "migrationCommentCount": "number",
    "overallStatus": "complete | partial | failed"
  },
  "filesModified": [
    {
      "path": "string — relative path from project root",
      "changeType": "modified | created | deleted",
      "description": "string — one-line summary"
    }
  ],
  "apisReplaced": [
    {
      "category": "networking | storage-file | storage-sql | storage-coredata | pasteboard | policy | webview | icc | auth | xcode-config",
      "before": "string — original API (e.g. FileManager.default)",
      "after": "string — Dynamics API (e.g. GDFileManager.default)",
      "catalogRowId": "string — ID from contracts/api-catalog.ios.v1.0.0.json rows[].id",
      "files": ["string"],
      "occurrences": "number",
      "risk": "low | medium | high",
      "riskReason": "string — why this risk level was assigned",
      "beforeSnippet": "string — code snippet BEFORE migration (1-5 lines)",
      "afterSnippet": "string — code snippet AFTER migration (1-5 lines)"
    }
  ],
  "coverage": {
    "secureNetworking": { "status": "migrated | not-applicable | partial", "details": "string" },
    "secureFileStorage": { "status": "migrated | not-applicable | partial", "details": "string" },
    "secureSql": { "status": "migrated | not-applicable | partial", "details": "string" },
    "secureCoreData": { "status": "migrated | not-applicable | partial", "details": "string" },
    "securePasteboard": { "status": "migrated | not-applicable | partial", "details": "string" },
    "authorization": { "status": "migrated | not-applicable | partial", "details": "string" },
    "policyManagement": { "status": "migrated | not-applicable | partial", "details": "string" },
    "webview": { "status": "migrated | not-applicable | partial", "details": "string" },
    "icc": { "status": "migrated | not-applicable | partial", "details": "string" }
  },
  "storageClosure": {
    "sqlWrappers": {
      "directSqliteStatus": "migrated | partial | blocked | not-applicable",
      "fmdbStatus": "migrated | partial | blocked | not-applicable",
      "grdbStatus": "migrated | partial | blocked | not-applicable",
      "sqliteSwiftStatus": "migrated | partial | blocked | not-applicable",
      "sqlcipherStatus": "migrated | partial | blocked | not-applicable",
      "notes": ["string"]
    },
    "coreDataAndSwiftData": {
      "coreDataStatus": "migrated | partial | blocked | not-applicable",
      "swiftDataStatus": "unsupported | blocked | not-applicable",
      "swiftDataDisposition": "blocked | not-applicable",
      "notes": ["string"]
    },
    "fileWritersAndReaders": {
      "writerClosureStatus": "migrated | partial | blocked | not-applicable",
      "readerClosureStatus": "migrated | partial | blocked | not-applicable",
      "followOnConsumersStatus": "migrated | partial | blocked | not-applicable",
      "notes": ["string"]
    },
    "preferencesKeychainCrypto": {
      "sensitiveUserDefaultsStatus": "migrated | partial | blocked | not-applicable",
      "keychainDecisionStatus": "migrated | retained-with-rationale | blocked | not-applicable",
      "localCryptoDecisionStatus": "migrated | retained-with-rationale | blocked | not-applicable",
      "notes": ["string"]
    }
  },
  "networkWebClosure": {
    "urlSession": {
      "callSiteCount": "number",
      "postAuthTimingStatus": "migrated | partial | blocked | unknown",
      "notes": ["string"]
    },
    "directSockets": {
      "callSiteCount": "number",
      "migratedCount": "number",
      "blockedCount": "number",
      "notes": ["string"]
    },
    "protocolAndPinning": {
      "decisionStatus": "migrated | partial | blocked | unknown",
      "notes": ["string"]
    },
    "backgroundSessions": {
      "decisionStatus": "migrated | partial | blocked | unknown",
      "g12Dependency": "none | present | unknown",
      "notes": ["string"]
    },
    "webview": {
      "supportStatus": "migrated | partial | blocked | unknown",
      "contentClassificationStatus": "migrated | partial | blocked | unknown",
      "unsupportedFeatureStatus": "migrated | partial | blocked | unknown",
      "notes": ["string"]
    }
  },
  "dlpIccPolicyClosure": {
    "externalSurfaces": {
      "directionSummary": {
        "unmanagedToManaged": "number",
        "managedToUnmanaged": "number",
        "managedToManaged": "number",
        "metadataOnly": "number",
        "unknownOrBidirectional": "number"
      },
      "managedEndpointClassificationStatus": "migrated | partial | blocked | unknown"
    },
    "inbound": {
      "secureCopyStatus": "migrated | partial | blocked | not-applicable",
      "notes": ["string"]
    },
    "outbound": {
      "approvalBlockerStatus": "migrated | partial | blocked | unknown",
      "notes": ["string"]
    },
    "appkinetics": {
      "serviceClosureStatus": "migrated | partial | blocked | not-applicable",
      "registrationStatus": "verified | partial | missing | not-applicable",
      "notes": ["string"]
    },
    "residualSharePaths": {
      "status": "none | partial | blocked",
      "notes": ["string"]
    },
    "policy": {
      "apiTimingStatus": "migrated | partial | blocked | not-applicable",
      "updateHandlingStatus": "migrated | partial | blocked | not-applicable",
      "cacheStatus": "migrated | partial | blocked | not-applicable",
      "defaultHandlingStatus": "migrated | partial | blocked | not-applicable",
      "notes": ["string"]
    }
  },
  "manualTodos": [
    {
      "priority": "high | medium | low",
      "description": "string",
      "reason": "string"
    }
  ],
  "unsupportedFeatures": [
    {
      "feature": "string",
      "reason": "string",
      "workaround": "string | null"
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
  "uemAdminHandoff": {
    "gdApplicationId": "string",
    "gdApplicationVersion": "string",
    "bundleIdentifier": "string",
    "applicationSetupType": "in-house | partner-third-party | blackberry-developed",
    "requiredPlistKeys": {
      "GDApplicationID": "present | missing",
      "GDApplicationVersion": "present | missing",
      "CFBundleURLTypes": "present | missing",
      "NSFaceIDUsageDescription": "present | missing",
      "NSCameraUsageDescription": "present | missing",
      "BlackBerryDynamics.CheckEventReceiver": "present | missing | not-applicable"
    },
    "registeredUrlSchemes": ["string — Dynamics URL schemes present in CFBundleURLTypes"],
    "entitlementSetup": "string — instructions for creating the entitlement in UEM",
    "connectivityProfile": "string — recommended connectivity profile settings",
    "complianceProfile": "string — recommended compliance policy settings",
    "appPermissions": ["string — Dynamics permissions the app requires"]
  },
  "validation": {
    "passed": "boolean",
    "failures": "number",
    "warnings": "number"
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
  }
}
```

---

## Field Rules

### schemaVersion
Always `"2.1.0"`. Reports with `"2.0.0"` are **rejected** by `validate.sh`.

### platform
Always `"iOS"` for this migration tool.

### toolkit
- `toolkit.name` must be `"dynamics-migration-tool"`.
- `toolkit.platform` must be `"iOS"`.
- `toolkit.version` must match `dynamics-migration-tool/VERSION`.
- `toolkit.reportSchemaVersion` must be `"2.1.0"`.

### runProvenance
- `runProvenance.runId` must match `bootstrap.json.runId` exactly.
- `runProvenance.toolkitVersion` must match `dynamics-migration-tool/VERSION`.
- The recorder enforces run-ID consistency when sealing prompt `10`.

### targetMapSummary
- Must summarize the discovered target map for the same run.
- `ambiguityCount > 0` requires matching entries in report blockers/manual TODOs.

### storageClosure (Tranche 3, when storage domains apply)
- Include explicit status for SQL wrappers, Core Data/SwiftData, file
  writers/readers/follow-on consumers, and preferences/keychain/local crypto.
- SwiftData must be explicit (`blocked`/`not-applicable`), never implicit.
- Use this block to summarize closure evidence, not to bypass ledger outcomes.

### networkWebClosure (Tranche 4, when networking/webview domains apply)
- Summarize URLSession timing treatment, direct socket outcomes, protocol/pinning
  decisions, background-session G12 dependency, and WKWebView closure state.
- This block is evidence summary only; it does not override ledger/validator outcomes.

### dlpIccPolicyClosure (Tranche 5, when dlp/icc/policy domains apply)
- Summarize external surface direction taxonomy and endpoint classification.
- Summarize inbound secure-copy and outbound protected egress closure state.
- Summarize AppKinetics service + plist registration closure.
- Summarize residual URL/share payload path status.
- Summarize policy timing/update/cache/default closure.

### lifecycleSummary
- Must describe the selected authorization integration pattern and post-auth boundary.
- Must expose lifecycle/startup reachability evidence:
  - root count,
  - pre-auth risk count,
  - opaque startup path count,
  - reachability analysis timestamp + source fingerprint.
- Must include scoped prompt validation outcomes for prompt `03` and `03b`.

### executedPromptAudit
- Must be derived from `bootstrap.json.executedPrompts`.
- Every recorded prompt entry must include `promptId`, `status`, and `recordedAt`.

### closureSummary / blockers / unresolvedCallSites
- Must be derived from `migration-analysis.json` + `migration-plan-state.json`.
- Applicable call sites without a disposition are unresolved.
- `blocked` and disallowed `deferred` statuses must surface in blockers.

### validationProof
- Must reflect the latest `output/.last-check.json` for the same run.
- Prompt `10` requires `mode: "full"` and `result: "pass"`.
- `isStale: true` is a hard report failure.

### overallStatus
- `complete` — all applicable coverage areas are `migrated` AND validation passed with 0 failures
- `partial` — any applicable area is `partial`, or validation has warnings but no failures
- `failed` — validation has failures

### apisReplaced — category
iOS-specific categories:
- `storage-coredata` — Core Data migration (iOS-only)
- `pasteboard` — DLP/pasteboard migration (replaces Android's `clipboard` and `ui-widget`)
- `xcode-config` — project configuration changes (replaces Android's `gradle`)

### apisReplaced — risk
Assign risk based on behavioral change:
- `low` — drop-in replacement, same method signatures (e.g. `FileManager` → `GDFileManager`)
- `medium` — API shape changes, requires refactoring (e.g. `NSPersistentContainer` → custom stack)
- `high` — behavioral change that could cause runtime issues (e.g. path differences in secure container)

### apisReplaced — before / after
- Keep snippets short: 1-5 lines of representative code
- Pick the clearest example from the codebase
- Escape quotes and backslashes for valid JSON

### coverage — secureCoreData
This is an iOS-specific coverage area. Set to `not-applicable` if the app
does not use Core Data.

### coverage — securePasteboard
Replaces Android's `secureClipboard` and `secureUiWidgets`. On iOS, DLP is
handled at the pasteboard level, not individual widgets.

### unsupportedFeatures
Must include any detected usage of:
- **SwiftData** — `@Model`, `ModelContainer`, `ModelContext`
- **Share Extension** — `com.apple.share-services` / Share Extension targets
  (Dynamics-unsupported; isolate / non-shipping —
  `17-app-extensions-and-share-extensions.md`)
- **Other App Extensions** — WidgetKit, SiriKit, Notification Service, etc.
- **BitCode** — if was previously enabled
- **App Clips** — if present
- **CloudKit / iCloud** — if used for sensitive data
- **Certain WKWebView features** — WKDownload, WKFindConfiguration, etc.
- **Flutter hybrid** — out of scope this toolkit release

Only list features that are genuinely unsupported AND detected in the codebase.
Do not list features the app doesn't use.

### runtimeTestPlan
Generate a test scenario for each migrated coverage area. Always include:
- Authorization flow test (activate, lock/unlock, wipe)
- One test per migrated area
- Policy retrieval test if policy was migrated

### uemAdminHandoff
Include the `bundleIdentifier` in addition to `gdApplicationId` (iOS-specific
requirement for UEM entitlement mapping).
Also include `applicationSetupType` and `registeredUrlSchemes` so reviewers can
verify that Prompt 02 completed the startup-critical URL registration:
`<bundle-id>.sc2`, `<bundle-id>.sc2.<GDApplicationVersion>`,
`<bundle-id>.sc3`, `com.good.gd.discovery`, and the setup-specific second
discovery policy.
Include `requiredPlistKeys` so the report/readme explicitly records whether
each mandatory Prompt 02 plist requirement was completed:
`GDApplicationID`, `GDApplicationVersion`, `CFBundleURLTypes`,
`NSFaceIDUsageDescription`, `NSCameraUsageDescription`, and conditional
`BlackBerryDynamics.CheckEventReceiver`.

### General
- Do NOT include `[BB_DYNAMICS-MIGRATION]` comments in the JSON
- Place the file at: `dynamics-migration-tool/output/migration-report.json`
- `manualTodos` must include anything the agent could not automate
- **Workaround verification**: Before listing a third-party library in
  `unsupportedFeatures`, search for existing workarounds in the codebase

### securityPosture
- `dataAtRest` summarizes secure storage/container coverage.
- `dataInTransit` summarizes secure networking/web transport coverage.
- Use `partial` when unresolved high-risk paths remain.

### migrationConfidence
- `score` is 0-100 and should drop when unresolved high-priority TODOs exist.
- `level` should match score bands:
  - `high`: 80-100
  - `medium`: 50-79
  - `low`: 0-49

### releaseReadiness
- `go`: no known blockers, validation passed, only low/medium non-blocking TODOs.
- `go-with-risks`: at least one high-risk TODO without hard runtime blocker.
- `no-go`: validation failures, pre-auth secure access, or unresolved blocking risks.

---

## Companion Output: Dynamics_Migration_Readme.md

In addition to the JSON report, generate a human-readable
`Dynamics_Migration_Readme.md` at the project root. See
`prompts/10-generate-migration-report.md` for required sections.

Output files:
- `dynamics-migration-tool/output/migration-report.json` — machine-readable
- `Dynamics_Migration_Readme.md` (project root) — human-readable summary
