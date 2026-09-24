# Steering: iOS Final Migration Report Contract

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
- Core Data migration status
- SwiftData migration status (`GDSecureModelContainer.create` or
  explicit blocked/not-applicable)
- SQL wrapper status (direct sqlite, FMDB, GRDB, SQLite.swift, SQLCipher)
- SwiftData disposition (`migrated`/`blocked`/`not-applicable` when detected)
- reader/follow-on closure status (not writers only)
- UserDefaults/Keychain/local-crypto decision outcomes with rationale
- unresolved storage risks and affected files/components

### 2) Data in Transit Security Summary

Document how sensitive network traffic was handled:

- secure networking migration status (`GDURLLoadingSystem`, sockets, HTTP)
- secure web content status (`WKWebView+GDNET`)
- URLSession post-authorization timing status
- custom protocol/pinning/trust decision status
- background-session G12 dependency status
- unresolved transport risks and affected paths

### 3) Unsupported/Partially Supported Features

Must include:

- detection evidence
- reason not fully migratable
- recommended mitigation or redesign
- priority and owner hint in `manualTodos`

### 4) Migration Confidence

Add `migrationConfidence` with:

- `score` (0-100)
- `level` (`high` | `medium` | `low`)
- `rationale` (short explanation)

Suggested scoring factors:

- coverage completeness
- count/severity of unresolved TODOs
- validation result
- unsupported feature impact

### 5) Go/No-Go Recommendation

Add `releaseReadiness`:

- `recommendation` (`go` | `go-with-risks` | `no-go`)
- `blockingItems` (array of unresolved blockers)

---

## Quality Gates

Prompt 10 output is acceptable only if:

1. All applicable domains have a coverage status.
2. Toolkit metadata (`toolkit.name/platform/version/reportSchemaVersion`) is present and valid.
3. Unsupported detections are explicit and justified.
4. Data-at-rest and data-in-transit summaries are present.
5. `manualTodos` includes every unresolved high-risk item.
6. Validation result from `validate.sh` is included.
7. When storage domains are applicable, `storageClosure` contains explicit
   Tranche 3 closure evidence.
8. When networking or webview domains are applicable, `networkWebClosure`
   contains explicit Tranche 4 closure evidence.
9. When DLP/ICC/policy domains are applicable, `dlpIccPolicyClosure`
   contains explicit Tranche 5 closure evidence.
10. `uemAdminHandoff` lists the native bundle identifier, app setup type, and
    registered Dynamics URL schemes so `.sc2`, `.sc2.<version>`, `.sc3`, and
    discovery registration can be reviewed.
11. `uemAdminHandoff.requiredPlistKeys` records completed/missing status for
    `GDApplicationID`, `GDApplicationVersion`, `CFBundleURLTypes`,
    `NSFaceIDUsageDescription`, `NSCameraUsageDescription`, and conditional
    `BlackBerryDynamics.CheckEventReceiver`.

---

## Enforcement Model

- This migration kit is an enablement tool for developer-led integration.
- Required checks are enforced by `validate.sh` in local workflow to verify
  migration-tool output quality and consistency.
- Teams may optionally mirror these checks in CI, but CI wiring is not required
  by this kit.
