# BlackBerry Dynamics Migration Tool for iOS

Migrate your native iOS app to BlackBerry Dynamics using AI-assisted guidance.

This tool provides structured prompts, steering files, and validation scripts
that work with any AI coding agent (Kiro, Copilot, Cursor, etc.) to automate
the migration of a standard iOS application to BlackBerry Dynamics.

> **Scope:** Native **UIKit / SwiftUI** iOS apps. **Flutter** (and similar
> unofficial hybrid hosts) are detected and flagged as **out of scope** for
> this toolkit release — there is no official BlackBerry Dynamics Flutter SDK.
> See `steering/12-capability-and-support-model.md` and
> `steering/13-unsupported-feature-detection-matrix.md`.

> **Ready to migrate?** Follow the step-by-step walkthrough in
> [MIGRATION_INSTRUCTIONS.md](MIGRATION_INSTRUCTIONS.md).

---

## What's Inside

```
dynamics-migration-tool/
├── README.md                  # This file
├── MIGRATION_INSTRUCTIONS.md  # Step-by-step migration walkthrough
├── VERSION                    # Toolkit version (read by scripts and migration report)
├── tooling/                   # Tool scripts
│   ├── migrate.sh             # Main entry point — sets up your project
│   ├── validate.sh            # Post-migration validation
│   ├── loop-state.sh          # Retry/escalation telemetry helper wrapper
│   ├── runtime-evidence.sh    # Structured runtime QA/UEM evidence helper
│   ├── improvement-backlog.sh # Advisory learning-loop backlog helper
│   ├── release-assessment.sh  # Benchmark/readiness assessment helper
│   └── generate-tool-analysis-report.sh # Post-validation beta-feedback artifact generator
├── migration-report-viewer.html # Visual HTML report viewer (auto-loads from output/)
├── output/                    # Generated migration report output directory
│   └── migration-report.json  # Generated after running prompt 10
├── steering/                  # AI agent guidance (context + constraints)
│   ├── 00-context.md
│   ├── 01-getting-started.md
│   ├── 05-migration-checklist.md
│   ├── 06-inline-migration-comments.md
│   ├── 10-xcode-integration.md
│   ├── 11-info-plist-reference.md
│   ├── 12-capability-and-support-model.md
│   ├── 13-unsupported-feature-detection-matrix.md
│   ├── 14-api-provenance-and-replacement-catalog.md
│   ├── 15-redundant-feature-removal.md
│   ├── 16-supported-app-tiers.md
│   ├── 17-app-extensions-and-share-extensions.md
│   ├── 20-auth-initialization.md
│   ├── 21-authorization-deferral-patterns.md
│   ├── 30-secure-networking.md
│   ├── 40-secure-storage-filesystem.md
│   ├── 41-secure-storage-sql.md
│   ├── 42-secure-storage-coredata.md
│   ├── 45-dlp-pasteboard.md
│   ├── 50-wkwebview-secure.md
│   ├── 60-appkinetics-icc.md
│   ├── 70-background-authorize.md
│   ├── 71-launcher-branding.md
│   ├── 72-local-compliance-and-custom-policies.md
│   ├── 74-fips-compliance.md
│   ├── 75-certificates-kerberos.md
│   ├── 76-enterprise-simulation-testing.md
│   ├── 77-activation-and-easy-activation.md
│   ├── 78-push-channel.md
│   ├── 80-migration-report-schema.md
│   ├── 81-migration-report-contract.md
│   ├── 82-tool-analysis-report-schema.md
│   ├── 83-effectiveness-kpis-and-release-gates.md
│   ├── 84-parity-and-runtime-validation-runbook.md
│   ├── 90-test-against-uem.md
│   ├── 95-troubleshooting.md
│   └── 99-docs-and-references.md
├── prompts/                   # Step-by-step migration prompts (00pre–10, 09b, optional 12)
│   ├── 00pre-bootstrap.md
│   ├── 00-analyze-app.md
│   ├── 00b-generate-architecture-diagrams.md
│   ├── 01-xcode-integration.md
│   ├── 02-configure-info-plist.md
│   ├── 03-add-dynamics-auth.md
│   ├── 03b-authorization-deferral-audit.md
│   ├── 04-sqlite-migrate-to-secure-sql.md
│   ├── 04b-coredata-migrate-to-gdpersistentstore.md
│   ├── 05-filesystem-migrate-to-gdfilemanager.md
│   ├── 06-secure-networking-audit-and-migrate.md
│   ├── 07-wkwebview-secure-migration.md
│   ├── 08-appkinetics-icc.md
│   ├── 09-dlp-pasteboard-migration.md
│   ├── 09b-policy-management.md
│   ├── 10-generate-migration-report.md
│   ├── 11-push-channel.md
│   └── 12-generate-migration-retrospective.md
├── templates/                 # Reusable migration snippets
│   ├── README.md
│   ├── info-plist-manual-required-keys.xml.template
│   └── swiftui-scene-auth-bridge.swift.template
└── LICENSE
```

---

## Migration Prompts

| Step | Prompt File | Required? | What It Does |
|------|------------|-----------|--------------|
| 00pre | `00pre-bootstrap.md` | REQUIRED | Establishes Git baseline, `bootstrap.json`, and `target-map.json` |
| 00 | `00-analyze-app.md` | REQUIRED | Reads all source files, inventories APIs, produces migration plan |
| 00b | `00b-generate-architecture-diagrams.md` | REQUIRED | Generates lifecycle dependency map, data flow diagrams, secure API call graph, risk heatmap |
| 01 | `01-xcode-integration.md` | REQUIRED | Adds SDK via selected method (CocoaPods/SPM/manual), configures Keychain Sharing |
| 02 | `02-configure-info-plist.md` | REQUIRED | Configures Info.plist — **STOPS to ask for GDApplicationID/GDApplicationVersion and app setup type; registers required Dynamics URL schemes** |
| 03 | `03-add-dynamics-auth.md` | REQUIRED | AppDelegate/SceneDelegate, GDiOS authorization, two-phase startup |
| 03b | `03b-authorization-deferral-audit.md` | REQUIRED | Systematic audit of ViewControllers, SwiftUI views, Combine, async/await |
| 04 | `04-sqlite-migrate-to-secure-sql.md` | if applicable | Migrates raw SQLite to encrypted SQLite (sqlite3enc) |
| 04b | `04b-coredata-migrate-to-gdpersistentstore.md` | if applicable | Migrates Core Data to GDPersistentStoreCoordinator |
| 05 | `05-filesystem-migrate-to-gdfilemanager.md` | if applicable | Migrates file I/O to GDFileManager/GDFileHandle |
| 06 | `06-secure-networking-audit-and-migrate.md` | if applicable | Migrates URLSession/sockets to secure networking |
| 07 | `07-wkwebview-secure-migration.md` | if applicable | Enables secure WKWebView via WKWebView+GDNET |
| 08 | `08-appkinetics-icc.md` | if applicable | Adds AppKinetics inter-container communication |
| 09 | `09-dlp-pasteboard-migration.md` | if applicable | Migrates external data movement and DLP controls |
| 09b | `09b-policy-management.md` | if applicable | Migrates managed policy reads, updates, cache handling |
| 11 | `11-push-channel.md` | if applicable | Audits push paths and applies Dynamics Push Channel decisions |
| 10 | `10-generate-migration-report.md` | REQUIRED | Generates migration report in `dynamics-migration-tool/output/` |
| 12 | `12-generate-migration-retrospective.md` | OPTIONAL | Generates post-migration retrospective after prompt 10 |

Prompt 12 writes `dynamics-migration-tool/output/migration-retrospective.md`
when selected. Use this optional artifact to capture migration friction,
manual interventions, and recommended toolkit improvements.

---

## Migration Phases

1. **Analysis** — Scan Xcode project, inventory APIs, classify data sensitivity
2. **Architecture Diagrams** — Lifecycle dependency maps, secure API call graphs
3. **Project Setup** — CocoaPods / official SPM / manual framework, Keychain Sharing, deployment target
4. **Configuration** — Info.plist with entitlement info and URL schemes
5. **Authorization** — GDiOS delegate/notification, two-phase startup
6. **Authorization Deferral** — Audit all pre-auth secure API access
7. **Secure SQL** — Raw SQLite to encrypted SQLite (if applicable)
8. **Secure Core Data** — NSPersistentStoreCoordinator to GDPersistentStoreCoordinator (if applicable)
9. **Secure File Storage** — FileManager/FileHandle to GDFileManager/GDFileHandle
10. **Secure Networking** — GDURLLoadingSystem, GDSocket
11. **Secure WebView** — WKWebView+GDNET (if applicable)
12. **AppKinetics ICC** — GDService/GDServiceClient (if applicable)
13. **External Data Movement + DLP** — direction/sensitivity taxonomy, inbound secure copy, outbound export blockers
14. **Policy Management** — post-auth policy reads, update events, cache/default handling
15. **Push Channel Audit** — APNs vs Dynamics push classification and migration decisions
16. **Report Generation** — Migration report with coverage, risks, test plan
17. **Retrospective (Optional)** — post-acceptance migration learnings artifact

---

## Validation Checks

`validate.sh` (run after migration) checks:

| Phase | What's Checked |
|-------|---------------|
| Configuration | `Info.plist` contains `GDApplicationID`, `GDApplicationVersion`, required native-bundle URL schemes (`.sc2`, `.sc2.<version>`, `.sc3`, discovery schemes), `NSFaceIDUsageDescription`, and `NSCameraUsageDescription` |
| Framework | BlackBerryDynamics framework linked (CocoaPods, official SPM, or manual) |
| Keychain | Keychain Sharing enabled with `com.good.gd.data` group |
| Authorization | `GDiOS` authorization implemented, delegate or notification pattern |
| File Storage | `GDFileManager` used, standard `FileManager` removed for sensitive ops |
| Core Data | `GDPersistentStoreCoordinator` used (if applicable) |
| SQL Database | Encrypted SQLite (`sqlite3enc`) used (if applicable) |
| Networking | `GDURLLoadingSystem` enabled, standard APIs reviewed |
| External Data / DLP | Directional surface classification, inbound secure-copy closure, outbound protected egress closure |
| AppKinetics / ICC | Service contract and Info.plist registration closure |
| Policy Management | Post-auth reads, update handling, cache/default closure |
| Build | Project compiles with `xcodebuild` (CocoaPods projects must use `.xcworkspace` as canonical entrypoint) |
| API Audit | Zero remaining standard APIs for secure operations |
| Migration Report | `dynamics-migration-tool/output/migration-report.json` exists, valid JSON, schema v2.1.0 |

> `validate.sh` verifies migration-tool changes and report contract quality.
> It is not a substitute for full app QA/UAT, security testing, or release sign-off.
> Exit code `3` means `ESCALATION REQUIRED` (retry budget exhausted). Inspect
> `dynamics-migration-tool/output/migration-loop-state.json`, repair the owner
> prompt/domain, then rerun a targeted check.

## Optional Observability

To measure migration efficiency without recording source contents, enable
content-free observability before running toolkit commands:

```bash
export DYNAMICS_MIGRATION_OBSERVABILITY=1
```

This writes JSONL events and a summary under
`dynamics-migration-tool/output/observability/`. Disable it by unsetting the
environment variable. Observability is best-effort and does not change
validation results, prompt gates, or generated reports.

## Context Efficiency

Generate a repository manifest when you want the agent to reuse stable context
and invalidate changed source/state explicitly:

```bash
bash ./dynamics-migration-tool/tooling/generate-repository-manifest.sh
```

This writes `output/repository-manifest.json` and `output/context-summary.md`.
The manifest is an index, not a cache; validation gates still run normally.

## Repair Orchestrator (optional, maturing)

The repair orchestrator is an optional bounded loop around the recorder and the
prompt-scoped validator. It does **not** edit your source code: it records the
prompt, runs scoped validation, and on failure writes a bounded repair task for
the agent to apply.

```bash
bash ./dynamics-migration-tool/tooling/repair-orchestrator.sh --prompt-id <id>
```

Exit codes drive the loop:

- `0` — recorded and validated; continue to the next prompt.
- `1` — `output/repair-task.md` was written; apply the owning prompt to the
  listed files, then re-invoke for the same prompt.
- `3` — escalated (budget exhausted, no-progress, or an owner decision); stop
  and involve a developer.

Budgets, no-progress detection, and escalations are enforced across invocations
and recorded in `output/repair-orchestrator-state.json`; terminal escalations
are reflected into `output/migration-loop-state.json`. See
`steering/96-repair-loop-conduct.md` for the full conduct rules. The loop is
maturing and optional; it never overrides a validator or approves a
trust-boundary decision.

## Reviewer Lane (optional, read-only)

The reviewer lane is an independent, read-only risk review of the migration
artifacts. It cites concrete evidence and produces advisory findings; it never
overrides deterministic validators.

```bash
bash ./dynamics-migration-tool/tooling/reviewer-lane.sh
```

This writes `output/reviewer-lane.json` and `output/reviewer-lane.md`. Use it
for security-sensitive migrations, repeated repair attempts, unsupported-feature
removal, or insufficient runtime evidence.

## Runtime Evidence

Runtime evidence is a structured record of device/UEM validation. Create a
starter artifact, fill it from QA or automation, then validate it:

```bash
bash ./dynamics-migration-tool/tooling/runtime-evidence.sh init-template
bash ./dynamics-migration-tool/tooling/runtime-evidence.sh validate
```

Use `blocked` or `pending` when a device, UEM environment, policy, or human
action is unavailable. Do not mark runtime checks as passed without an observed
result and evidence reference.

## Improvement Backlog

Generate an advisory learning-loop backlog after validation, repair, reviewer,
or runtime evidence artifacts exist:

```bash
bash ./dynamics-migration-tool/tooling/improvement-backlog.sh
```

This writes `output/migration-improvement-backlog.json` and `.md`. Candidates
are not applied automatically; every prompt, steering, validator, or
implementation change still requires maintainer review, a regression fixture,
and deterministic acceptance evidence.

## Release Assessment

Generate a conservative benchmark/readiness assessment from current artifacts
and optional representative benchmark cases:

```bash
bash ./dynamics-migration-tool/tooling/release-assessment.sh
```

Use `--benchmark-dir <dir>` to provide Tier A/Tier B benchmark case JSON files.
Without representative corpus evidence, the assessment reports further
hardening rather than production readiness. The Stage 7 repair orchestrator is
treated as a maturing lane and remains optional/controlled.

---

## Unsupported Features

The migration tool will flag the following iOS features as unsupported:

- **SwiftData** — `@Model`/`ModelContainer`/`ModelContext` cannot be redirected to the secure container
- **Share Extensions** — Dynamics does not support Share Extensions (no secure-container access). Main-app migration continues; isolate the extension from Dynamics shipping and do not Dynamics-authorize it. See `steering/17-app-extensions-and-share-extensions.md`.
- **Other App Extensions** — WidgetKit, SiriKit, Notification Service, etc. (same isolate doctrine)
- **BitCode** — Incompatible with Dynamics cryptographic requirements
- **App Clips** — Not supported by Dynamics
- **CloudKit / iCloud** — Data must stay in the secure container
- **Certain WKWebView features** — WKDownload, WKFindConfiguration, non-pageWorld content worlds
- **Flutter hybrid** — Out of scope for this toolkit release (no official Dynamics Flutter SDK)

These will be listed in the `unsupportedFeatures` section of the migration report.

---

## Using with Cursor

```bash
./dynamics-migration-tool/tooling/migrate.sh --agent cursor
```

This installs steering files into `.cursor/rules/`. Cursor automatically loads
every file in `.cursor/rules/` as Project Rules — the agent receives this
context at the start of every Agent conversation.

**Tips for working effectively in Cursor Agent mode:**

- **Reference files with `@`** — e.g. `@dynamics-migration-tool/prompts/03-add-dynamics-auth.md`
- **Review diffs before accepting** — Cursor shows a diff after each prompt; review before clicking "Accept All".
- **Prompt 02 will pause** — The agent stops and asks for `GDApplicationID`,
  `GDApplicationVersion`, and app setup type. It must register Dynamics URL
  schemes with the native bundle identifier, not `GDApplicationID`.
  Have these ready from your UEM administrator.

---

## Using with Kiro

```bash
./dynamics-migration-tool/tooling/migrate.sh --agent kiro
```

This installs steering files into `.kiro/steering/`. Kiro automatically uses
files in `.kiro/steering/` as context for every conversation.

---

## Using with GitHub Copilot or Other Agents

For agents without automatic context loading:

```bash
./dynamics-migration-tool/tooling/migrate.sh
```

Then for each prompt:
1. Paste the contents of `steering/00-context.md` as initial context
2. Paste the relevant steering file(s) for that prompt
3. Paste the prompt file
4. Review and accept changes

---

## License

Apache 2.0 — See LICENSE file.

---

## Support

- [BlackBerry Dynamics Documentation](https://docs.blackberry.com/en/development-tools/blackberry-dynamics-sdk-ios/)
- [BlackBerry Developer Forums](https://developers.blackberry.com)
- Common issues: `steering/95-troubleshooting.md`
