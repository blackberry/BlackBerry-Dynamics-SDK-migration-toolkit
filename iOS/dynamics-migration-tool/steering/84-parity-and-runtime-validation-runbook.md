# Steering: iOS Parity and Runtime Validation Runbook

Use this runbook to execute remaining release validation activities.

## Agent Parity Suite

Run the same migration input app through:
- Cursor prompt flow
- Kiro prompt flow
- Generic prompt flow

For each run, compare:
- `coverage` area statuses in `migration-report.json`
- `unsupportedFeatures` count and overlap
- `manualTodos` priority distribution
- `migrationConfidence.level` and `releaseReadiness.recommendation`

Acceptance: No critical domain coverage divergence without explicit rationale.

## Runtime + UEM Suite

Minimum scenarios:
- Activation, unlock, lock, wipe
- Sensitive file read/write in secure container
- Sensitive SQL and Core Data operations
- Secure networking to enterprise endpoint under policy
- DLP copy/paste behavior validation
- ICC flow (if app declares ICC support)

Acceptance: No scenario may bypass authorization or leak sensitive data outside
the secure container/network path.

## Evidence Output

For each app under test, produce:
- parity comparison sheet
- runtime scenario results with pass/fail
- final `migration-report.json`
- release decision record (`go`, `go-with-risks`, `no-go`)
