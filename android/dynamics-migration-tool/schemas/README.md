# Bundled Schemas

These JSON Schema files are bundled with the toolkit so that
`record-prompt-execution.sh` and `validate.sh` can validate migration
artifacts without depending on the canonical source tree.

Files:

- `migration-plan-state.schema.v1.1.0.json` — validates
  `migration-plan-state.json` (domains: secureSql, secureFileStorage,
  secureNetworking, icc, secureUiWidgets, secureClipboard).
- `migration-plan-state.schema.v1.0.0.json` — superseded by v1.1.0 (reference
  only; do not use for new runs).
- `migration-report.schema.v2.1.0.json` — validates
  `dynamics-migration-tool/output/migration-report.json`.
  Requires `apisReplaced[].catalogRow` (referencing
  `contracts/api-catalog.v1.0.0.json`), plus top-level `runId` and
  `provenance`. This is the only migration-report schema bundled with
  the Android toolkit (v2.0.0 was removed pre-GA).
- `module-map.schema.v1.0.0.json` — validates
  `dynamics-migration-tool/output/module-map.json` (the project-shape
  artifact emitted by `bootstrap.sh` and consumed by every prompt and
  validator).

## Authority

The prose-authoritative specs live under `documentation/report-contract/`
in the canonical source tree:

- `schema-v2.1.0.md` + `migration-report.schema.v2.1.0.json` — Android
  migration report (this directory must stay byte-identical to the
  canonical JSON).

The iOS migration report uses its own `2.1.0` shape, documented in the
iOS `steering/80-migration-report-schema.md` and bundled as
`ios/dynamics-migration-tool/schemas/migration-report.schema.v2.1.0.json`.

Other artifacts: `bootstrap-schema-v1.1.0.md`, `module-map-schema-v1.0.0.md`.

If you change a schema:

1. Update both copies (`documentation/report-contract/` and
   `android/dynamics-migration-tool/schemas/`) in the same change.
2. Bump the file name (e.g. `migration-report.schema.v2.2.0.json`) per
   the kit's no-breaking-change-without-version-bump rule.
3. Update validator lookup paths in
   `tooling/record-prompt-execution.sh` if the file names change.

## Lookup order

`record-prompt-execution.sh` resolves schemas in this order:

1. `dynamics-migration-tool/schemas/` (this directory — bundled with
   the toolkit, present in every consumer project).
2. `documentation/report-contract/` (canonical-source layout — present
   only when running inside the BlackBerry Dynamics source tree).

If neither is found, the script fails with a remediation message that
names both expected paths.
