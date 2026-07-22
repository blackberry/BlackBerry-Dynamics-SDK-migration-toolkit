## Task: Generate Migration Retrospective (Optional)

Goal: Produce a concise post-migration retrospective for maintainers and
developers after prompt 10 has already passed.

This prompt is **optional** and does not modify application source code.

---

## Preconditions

- Prompt 10 is already recorded as `completed`.
- `output/migration-report.json` exists and is valid.

If prompt 10 is not complete, stop and return to prompt 10.

---

## Steps

1. Ask the developer whether to generate the retrospective.
   - If **no**, record prompt 12 as `not-applicable` and stop.
   - If **yes**, continue.

2. Read:
   - `output/migration-report.json`
   - `output/.last-check.json` (if present)
   - `output/migration-plan-state.json` (if present)

3. Write `output/migration-retrospective.md` with these sections:
   - Migration scope and domain coverage (what migrated cleanly / what was N/A)
   - Prompt execution summary (including skipped/not-applicable prompts)
   - API replacement highlights (before/after + risk notes)
   - Files modified summary and migration diff footprint
   - Security posture summary (data at rest / data in transit)
   - UEM handoff checklist (`GDApplicationID`, `GDApplicationVersion`, platform)
   - Runtime test plan (authorization, storage, networking, ICC/DLP as applicable)
   - Manual TODOs with blocking vs non-blocking classification
   - Issues encountered during migration (symptom, root cause, fix, file touched)
   - Toolkit improvement recommendations for future runs
   - **Device / first-activate evidence** (if any): pull crash logs after the
     first Dynamics activate (`systemCrashLogs`), note SIGSEGV in
     `libsqlite3` / post-auth root-install aborts, and record fixes. Prefer
     `output/device-crash-evidence/` when capturing IPS + `crash-summary.json`.

4. Keep content factual and evidence-based; do not include secrets or policy
   values.

---

## Output

- `output/migration-retrospective.md` (optional artifact)
  - Keep it factual and evidence-backed.
  - Include exact validator phase names/check IDs where relevant.
- Prompt 12 recorder status:
  - `completed` when file generated
  - `not-applicable` when developer declines
