# `tooling/phases/`

This directory holds one shell script per validator phase referenced from
[`tooling/check-prompt-map.json`](../check-prompt-map.json). The scripts
are **sourced** (not invoked as subshells) by the orchestrator
[`tooling/validate.sh`](../validate.sh) and inherit every helper, counter,
and module-map scope variable from the parent shell.

| File                    | Phase key | Domain coverage                                                                                          |
|-------------------------|-----------|----------------------------------------------------------------------------------------------------------|
| `phase-0.sh`            | `0`       | `bootstrap.json` contract (schema, UEM, processModel, provenance, deferredDomains shape).                |
| `phase-1.sh`            | `1`       | `settings.json` keys + manifest hardening.                                                               |
| `phase-2.sh`            | `2`       | Gradle integration (dependency, repository, settings.gradle).                                            |
| `phase-3.sh`            | `3`       | Authorization init + two-phase startup guard; WI-01 forbid mixed `authorize()` + `activityInit()`.       |
| `phase-3b.sh`           | `3b`      | Background Authorize wiring (per-candidate intent capture).                                              |
| `phase-4.sh`            | `4`       | Secure file storage + stream-layer closure (steering/40-secure-file-storage.md §5).                      |
| `phase-5.sh`            | `5`       | Secure SQL (`GDSQLiteDatabase`, Room redesign).                                                          |
| `phase-5b.sh`           | `5b`      | Redundant app-level crypto removal.                                                                      |
| `phase-6.sh`            | `6`       | Secure networking + transport hardening.                                                                 |
| `phase-6b.sh`           | `6b`      | WebView → `BBWebView` migration.                                                                         |
| `phase-7.sh`            | `7`       | Policy management; WI-03 warn on uncached `getApplicationConfig`/`getApplicationPolicy` reads.           |
| `phase-8.sh`            | `8`       | Secure UI widgets (catalog lane checks `UI_LANE`, `UI_BIND_001`, `UI_CHILD_001`, `UI_CUSTOM_001`, `UI_PROG_001`, `UI_SEARCH_001`, `UI_TIN_001`, `UI_REMOTE_001`, plus secure clipboard/drag checks). |
| `phase-8b.sh`           | `8b`      | ICC / `TransferFileService` + chooser-bypass audit (secure-container-only).                              |
| `phase-9.sh`            | `9`       | Gradle build evidence (artifact + build log).                                                            |
| `phase-10.sh`           | `10`      | API audit (Dynamics call totals + suspicious survivors).                                                 |
| `phase-11.sh`           | `11`      | Authorization startup hardening (AUTH-INIT-001 / AUTH-DB-001 / AUTH-UI-001 / AUTH-UI-002 / AUTH-UI-003 / AUTH-UI-004 / AUTH-CTOR-001 / AUTH-STARTUP-001 / AUTH-FILE-001 / AUTH-PREF-001). |
| `phase-12.sh`           | `12`      | Push / FCM authorization gate (WI-02): ungated `FirebaseMessagingService` handlers fail.                 |
| `phase-comments.sh`     | `comments`| `[BB_DYNAMICS-MIGRATION]` audit comment tally.                                                           |
| `phase-catalog.sh`      | `catalog` | API catalog cross-check (allowlist of cataloged Dynamics replacements).                                  |
| `phase-report.sh`       | `report`  | `migration-report.json` contract + coverage KPI checks.                                                  |

## Authoring rules

Phase scripts are **not** standalone. Do not add a shebang, do not call
`set -e`, and do not `cd` — those concerns belong to the orchestrator. A
phase script may rely on:

- Counters: `PASS`, `FAIL`, `WARN` (and the `check_pass`, `check_fail`,
  `check_warn`, `fail_or_defer` helpers that mutate them).
- Module map vars: `SRC_DIR`, `PRIMARY_PATH`, `PRIMARY_BUILD_FILE`,
  `MM_PRIMARY_MANIFESTS`, `MM_IN_SCOPE_SOURCE_ROOTS`,
  `MM_IN_SCOPE_MANIFESTS`, `MM_IN_SCOPE_MODULE_PATHS`, etc.
- Pre-built scanners: `STRIP_AUDIT_NOISE_PY`, `NATIVE_SCAN_PY`.
- Deferral state: `DEFERRED_DOMAINS`,
  `BACKGROUND_AUTHORIZE_PER_CANDIDATE_DEFERRED`.
- Bootstrap artefact paths: `BOOTSTRAP_FILE`, `CATALOG_CONTRACT_FILE`.

If a new phase needs additional shared state, define it in the
orchestrator (so every phase sees it) rather than re-deriving it in each
phase script.

## Adding a phase

1. Add the new phase key to `tooling/check-prompt-map.json` (under
   `scopedChecks` or `fullSweep`).
2. Update the `case` arm in `phase_is_allowed` (`tooling/validate.sh`) so
   the orchestrator accepts the new key from `--check-prompt`.
3. Append the new key to `PHASE_ORDER` in `tooling/validate.sh` at the
   point in the canonical sequence where it should run.
4. Create `tooling/phases/phase-<key>.sh` with the body that was
   previously inlined.
5. Run `tooling/phases/_test.sh` and the smoke suite below to confirm.

## Smoke test

Run the in-tree smoke test before merging any phase change:

```bash
bash tooling/phases/_test.sh
```

The smoke test:

- `bash -n`s every `phase-*.sh` and the orchestrator.
- Cross-checks the set of phase scripts on disk against the phase keys
  declared in `check-prompt-map.json` (`noOp` excluded — those map to a
  recorder-side no-op, not a script).
- Verifies the orchestrator's `PHASE_ORDER` covers every phase script on
  disk so no phase silently stops running in the full sweep.
- Confirms `validate.sh --check-prompt 00pre` short-circuits as a no-op
  (the smallest exercise of the `--check-prompt` plumbing).

For end-to-end coverage of the validator (including the per-fixture
scanners that Phase 11 / Phase 4 rely on), also run:

```bash
bash _maintainer/tooling/hardening-smoke.sh
bash _maintainer/tooling/test-review-fixes.sh
```
