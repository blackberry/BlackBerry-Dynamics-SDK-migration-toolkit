# Steering: iOS Effectiveness KPIs and Release Gates

This defines measurable quality targets for the migration kit itself.

## KPI Set

| KPI | Target |
|---|---|
| Migration success rate (Tier A corpus) | >= 90% |
| Migration success rate (Tier B corpus) | >= 75% |
| False-positive unsupported detections | <= 10% |
| Mean manual TODO count (Tier A) | <= 8 |
| Median time-to-first-working-build after migration | <= 4 hours |
| Validator contract pass rate | 100% for golden fixtures |

## Validation Corpus

- Baseline corpus: small/medium native apps with standard APIs.
- Stress corpus: multi-target, mixed Swift/ObjC, complex startup.
- Pilot corpus: representative partner/customer app candidates.

## Release Gates

All gates must pass before publishing a kit release:

1. Prompt/schema/validator/viewer contract consistency checks pass.
2. Tier A + Tier B corpus runs meet KPI targets.
3. Agent parity runs (Cursor/Kiro/generic prompts) produce equivalent
   domain coverage outcomes.
4. Runtime/UEM validation suite shows no critical security regressions in
   authorization, secure storage, secure networking, and DLP behavior.
5. Security evidence package is generated and reviewed.

## Security Evidence Package (Required Artifacts)

- `migration-report.json` and `Dynamics_Migration_Readme.md`
- Sensitive data at rest mapping (before/after)
- Sensitive data in transit mapping (before/after)
- Unsupported feature and manual TODO justification
- Validation output from `validate.sh`
- Release recommendation and blocking items with owner
