# Task: Generate Migration Run Retrospective (Optional)

## Execution Order

Run **only after** prompt `10-generate-migration-report.md` has recorded
`completed` in `bootstrap.json` `executedPrompts[]` and
`dynamics-migration-tool/output/migration-report.json` exists.

This prompt does **not** modify application source code.

Output: `dynamics-migration-tool/output/migration-retrospective.md`

**IMPORTANT — File Write Method**: Use a **full-file overwrite** (not a
patch or append) to create the output file. In AI IDEs, use the
Write/CreateFile tool — do NOT use StrReplace or patch-based tools. If
the file already exists from a previous run, the full-file write will
correctly replace it.

---

## Developer Gate (Required — STOP)

Before reading migration artifacts or writing anything, **ask the
developer explicitly**:

> The migration report is complete. Do you want to generate an optional
> migration run retrospective (`migration-retrospective.md`)? This is a
> detailed, evidence-based review of what went well, what failed, security
> posture, validation results, and suggested migration-tool improvements.
> It is separate from the migration report and does not change your app.

Wait for a clear **yes** or **no**.

- If **no** (or the developer declines / skips): do **not** write
  `migration-retrospective.md`. Record execution as **skipped** (see
  Record execution below) and stop.
- If **yes**: continue with the retrospective task below.

Do not assume consent. Do not generate the retrospective unless the
developer opts in.

---

## Retrospective Task

You are at the final retrospective stage of the BlackBerry Dynamics SDK
migration run.

Create a detailed retrospective for this migration run and save it into
the migration tool output directory.

Create a new Markdown file at:

`dynamics-migration-tool/output/migration-retrospective.md`

This retrospective must be honest, specific, evidence-based, and useful
for improving both:

1. The migrated application
2. The Dynamics SDK migration tool itself

Do not write generic statements. Anchor your observations in the actual
migration run, the files changed, the validation results, the migration
report, unresolved issues, assumptions made, and any areas where manual
judgement was required.

The retrospective must include the following sections.

# Migration Run Retrospective

## 1. Executive Summary

Provide a concise summary of the migration run.

Include:

- Whether the migration completed successfully
- Whether the migrated app builds
- Whether validation passed, partially passed, or failed
- The highest-risk remaining issues
- Whether the app appears safe to hand over to a developer for review

## 2. What Went Well

List the areas where the migration was successful.

Include concrete examples such as:

- Dynamics SDK integration completed correctly
- App initialization/authentication flow migrated successfully
- Filesystem usage replaced with GD secure storage
- Networking migrated to GD secure networking APIs
- Clipboard/DLP-sensitive surfaces handled
- WebView usage migrated or reviewed
- Build files updated cleanly
- Validation checks passed
- Migration report generated correctly

For each item, include:

- What was done
- Why it worked
- Files or components involved
- Any validation evidence

## 3. What Failed or Did Not Work Well

List anything that failed, was incomplete, risky, unclear, or required
manual judgement.

Be explicit about:

- Build failures
- Validation failures
- APIs that could not be migrated safely
- Any insecure fallback
- Any deferred migration decision
- Any use of original Android APIs that may violate the Dynamics
  secure-container model
- Any place where the agent made an assumption
- Any area where manual developer intervention is required

Important:

- Do not hide or downplay failures.
- Do not mark risky unresolved items as complete.
- Do not defer security-sensitive items silently.

For every failure or incomplete item, include:

- Description of the issue
- Why it matters
- File/component affected
- Risk level: Critical, High, Medium, or Low
- Recommended next action

## 4. Security and Data-Protection Review

Review whether the migration preserves the core BlackBerry Dynamics SDK
security contract.

Specifically check and comment on:

- Whether app data is kept inside the Dynamics secure container
- Whether external storage usage remains
- Whether file import/export paths are controlled
- Whether clipboard usage is protected
- Whether networking goes through Dynamics secure networking where required
- Whether WebView usage is secure
- Whether logs, cache files, temporary files, and generated files are
  protected
- Whether any Android platform API remains that may bypass Dynamics controls

If any data may still be written outside the secure container, call this
out as a high-priority issue.

## 5. Validation Results

Summarize all validation performed.

Include:

- Build command used
- Test command used, if any
- Static validation scripts run
- Migration validator results
- Any warnings
- Any failures
- Whether the results are reliable or limited

If validation was not run, explain why and mark this clearly as a gap.

## 6. Migration Tool Retrospective

Assess the migration tool based on this run from the point of view of a
third-party Android developer migrating an app to BlackBerry Dynamics.

### 6.1 What the Migration Tool Did Well

Examples:

- Correctly identified migration surfaces
- Produced useful code changes
- Generated clear migration report
- Followed steering rules
- Avoided unsupported APIs
- Preserved app behaviour
- Helped guide the developer through manual steps

### 6.2 Where the Migration Tool Failed or Was Weak

Examples:

- Missed API surfaces
- Misclassified risky items as deferrable
- Allowed insecure fallback behaviour
- Produced unclear report entries
- Did not provide enough guidance for manual remediation
- Made assumptions without evidence
- Failed to connect validation output back to the migration report
- Did not distinguish between safe deferral and security-critical
  unresolved work

Be especially strict about anything that could result in:

- Data leaving the Dynamics secure container
- Android platform APIs being used where GD APIs are required
- A developer believing the migration is complete when it is not
- A security-sensitive issue being buried as a warning or deferred item

### 6.3 Recommended Improvements to the Migration Tool

Create a prioritized list of improvements.

For each improvement include:

- Title
- Problem observed
- Why it matters
- Suggested change to prompts, steering, validators, report schema, or
  implementation
- Priority: Critical, High, Medium, or Low
- Whether it should block release of the migration tool

Focus on practical improvements that can be implemented in future versions
of the migration kit.

Examples:

- Add stricter rules for external storage
- Remove or restrict unsafe deferral paths
- Add validator checks for known insecure Android APIs
- Improve migration report severity model
- Add mandatory manual intervention section
- Add Compose-specific DLP handling
- Add secure logging checks
- Add clearer build compatibility diagnostics
- Add mapping coverage against Dynamics SDK API surfaces

## 7. Developer Handover Notes

Write clear notes for the developer who will review the migrated app.

Include:

- What they should inspect first
- What they should test manually
- Any known limitations
- Any security-sensitive areas requiring review
- Any app behaviours that may have changed
- Any remaining TODOs

This section should be practical and actionable.

## 8. Final Assessment

Provide a final judgement using one of the following statuses:

- `READY_FOR_DEVELOPER_REVIEW`
- `PARTIALLY_MIGRATED_REQUIRES_MANUAL_WORK`
- `BLOCKED_SECURITY_ISSUES`
- `BLOCKED_BUILD_OR_VALIDATION_FAILURES`

Explain the reason for the selected status.

Also include:

- Top 3 remaining risks
- Top 3 recommended next actions
- Whether the migration tool should be improved before running on similar
  apps again

---

## Evidence Sources (Required)

Base the retrospective on evidence from:

- The completed migration changes (including `[BB_DYNAMICS-MIGRATION]` tags)
- `dynamics-migration-tool/output/migration-report.json`
- `Dynamics_Migration_Readme.md` (project root)
- `dynamics-migration-tool/output/migration-analysis.json`
- `dynamics-migration-tool/output/bootstrap.json`
- `dynamics-migration-tool/output/.last-check.json` (if present)
- `dynamics-migration-tool/output/migration-plan-state.json` (if present)
- Build/test output from the migration run

If evidence is unavailable, explicitly state that the evidence was
unavailable rather than guessing.

---

## Output Requirements

- Write **only** to `dynamics-migration-tool/output/migration-retrospective.md`
- Use clear Markdown formatting
- Do **not** overwrite `migration-report.json` or `Dynamics_Migration_Readme.md`
- The retrospective is separate from the main migration report

---

## Quality Bar

The retrospective should be useful for:

- A developer reviewing the migrated app
- A product owner improving the migration tool
- A Dynamics SDK engineer assessing migration correctness
- A future AI agent improving the tool based on this run

Be honest, specific, security-conscious, and action-oriented.

---

## Record execution

After the developer opts in and the retrospective is written:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 12 \
    --status completed \
    --files-touched dynamics-migration-tool/output/migration-retrospective.md
```

If the developer declines the retrospective:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 12 \
    --status skipped \
    --note "developer declined optional migration retrospective"
```
