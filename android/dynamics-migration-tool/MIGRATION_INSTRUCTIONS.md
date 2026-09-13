# Migrating Your Android App to BlackBerry Dynamics

Step-by-step instructions for using the dynamics-migration-tool with an
AI coding agent (Kiro, Cursor, Codex, etc.) to migrate an existing Android
application to a Dynamics-enabled application.

The process is the same for any Android app.

**Install model (mandate):** a Dynamics conversion is always a **fresh
install**. The agent replaces runtime storage APIs and does **not** copy
data from a previously installed non-Dynamics app (SharedPreferences XML,
SQLCipher databases, sandbox files). There is no leftover-data transfer
option. See `steering/18-fresh-dynamics-install.md`.

---

## What You Need Before Starting

1. Your Android app source code (must build successfully before migration)
2. An AI coding agent (Cursor, Kiro, Codex, or equivalent — see "Using Other AI Agents" below)
3. A web browser (for viewing the visual migration report)
4. **Network access to the BlackBerry Maven repository.** The kit downloads
   the Dynamics SDK during prompt `00pre-bootstrap.md` and aborts if
   network is sandboxed. There is no offline / docs-only fallback.
5. A git repository is recommended (but not required) in the project root.
   If present, prompt `00pre` captures git fingerprint, checks working
   tree state, and creates a backup branch. If not present, migration
   still continues in the current working directory.
   Optional setup:
   - `git init`
   - `git add -A`
   - `git commit -m "pre-migration baseline"`
6. From your UEM administrator:
   - `GDApplicationID` (entitlement ID configured in UEM, regex `^[a-zA-Z0-9._-]+$`)
   - `GDApplicationVersion` (entitlement version configured in UEM, regex `^\d+\.\d+\.\d+\.\d+$`)
7. **IDE permissions** for your agent before you start (see step 4
   below). Prompt `00pre` confirms these — it does not configure them
   for you.

Do NOT guess the UEM values. Prompt `00pre-bootstrap.md` collects them
once, up front, and every subsequent prompt reads them from
`output/bootstrap.json` instead of asking again.

### Project shape

The toolkit auto-detects the project's shape during step 5 (when
`00pre-bootstrap.md` runs `bootstrap.sh probe`):

- **Canonical single-module project** — `app/` directory at the
  repository root contains the `com.android.application` plugin.
  No extra steps are needed; the toolkit uses `app` as the primary
  module.
- **Multi-module project, single application module** — for example
  any project with one
  `com.android.application` module reachable from
  `settings.gradle(.kts)`. The toolkit auto-discovers the primary
  module and proceeds. No flags required.
- **Multi-application project** — multiple
  `com.android.application` modules exist (for example
  `app-primary`, `app-secondary`, and `app-tertiary`). `bootstrap.sh probe` exits with code `3` and
  prints the candidate list. Re-run with the module you want to
  migrate this run:

  ```bash
  bash dynamics-migration-tool/tooling/bootstrap.sh probe --app-module <name>
  ```

  Exactly one application module is migrated per run. The other
  application modules are recorded under
  `output/module-map.json` `otherAppModules[]` and surface as
  `manualTodos` in the migration report. To migrate sibling
  application modules, re-run the entire migration on each, one at
  a time, against a fresh backup branch.
- **Convention plugin projects** — Android configuration
  (`compileSdk`, `minSdk`, lint, ProGuard) lives inside Kotlin
  convention plugin source files. The
  toolkit discovers and edits the convention plugin sources when
  that's where the configuration actually lives.

Kotlin Multiplatform (KMP) shared modules are recorded but skipped
by this release. Apps with a KMP shared module will
need a follow-up release to migrate the shared module's code.

---

## Step 1: Set Up Your Working Copy

Create a working copy of your app so the original stays untouched.

```bash
cp -r /path/to/your-app /path/to/your-app-dynamics
cd /path/to/your-app-dynamics
```

Verify it builds before starting:

```bash
./gradlew clean build
```

If it doesn't build, fix that first. The migration tool assumes a working project.

---

## Step 2: Copy the Migration Tool Into Your Project

The dynamics-migration-tool ships alongside the Dynamics SDK. Copy it into
the root of your working copy:

```bash
cp -r /path/to/dynamics-migration-tool ./dynamics-migration-tool
```

---

## Step 3: Run the Setup Script

```bash
chmod +x dynamics-migration-tool/tooling/*.sh
./dynamics-migration-tool/tooling/migrate.sh --agent cursor   # or --agent kiro / codex
```

If you want optional architecture diagnostics (`00b`) included in the
scripted prompt order:

```bash
./dynamics-migration-tool/tooling/migrate.sh --agent cursor --with-diagrams
```

This does three things:
- Verifies your project structure (build.gradle, AndroidManifest.xml, source dirs)
- Installs steering/rule files for your chosen agent:
  - Cursor: `.cursor/rules/`
  - Kiro: `.kiro/steering/`
  - Codex: `AGENTS.md` project instructions
- Prints a ready-to-paste migration prompt

Maintainer-only diagnostics are intentionally separated under
`dynamics-migration-tool/_maintainer/` and are not required for third-party
migrations.

If you want to see the full list of individual prompts (for manual execution),
add `--list-prompts`:

```bash
./dynamics-migration-tool/tooling/migrate.sh --agent cursor --list-prompts
```

---

## Step 4: Grant IDE Permissions Up Front

Prompt `00pre-bootstrap.md` will check that your agent has the
permissions it needs and abort if anything is missing. Grant them
manually in your IDE before you start — the kit deliberately does NOT
auto-write `.cursor/auto-run.json` or any equivalent for you.

| Agent | Where to grant |
|---|---|
| Cursor | Settings → Cursor Settings → Agents → Auto-Run. Set Auto-Run Mode (`Ask Every Time`, `Run in Sandbox`, or `Run Everything`) and Auto-Run Network Access (`sandbox.json Only`, `sandbox.json + Defaults`, or `Allow All`). |
| Kiro | Project settings → Tools → enable file read/write, shell exec |
| Codex | Allow file read/write, shell command execution, and network access for the BlackBerry Maven SDK download when Codex asks for approvals. |
| Generic | Whatever permission UI your agent provides — file read, file write, shell exec, full network |

`00pre` will ask you to confirm these are on. If you say no, it aborts —
this is by design.

UI labels can vary slightly by Cursor version. In some builds, this may
appear under `Chat` instead of `Agents`, and `Run in Sandbox` may appear
as `Auto-Run in Sandbox`.

---

## Step 5: Open Your AI Agent and Start the Migration

Open your project in Cursor, Kiro, or Codex. Start a new agent chat session.

Copy and paste the following prompt:

```
Read the migration prompts in dynamics-migration-tool/prompts/ and execute
them in order (00pre, 00, 01, 02, 03, 03b, 04, 05a, 05b, 05c, 06, 07, 08, 09,
11, 03c, 10) against this project.

Start with 00pre-bootstrap.md — it will ask me to confirm IDE
permissions, collect my GDApplicationID and GDApplicationVersion,
capture attestations, create a backup branch when git is available, and run environment /
network / Dynamics SDK class probes. Do not proceed past 00pre until it
writes dynamics-migration-tool/output/bootstrap.json with
sdkProbe.dynamicsSdkResolvedVersion populated.

Then run 00-analyze-app.md — read all source files, produce the
migration plan including the binding executionPlan[], and show it to
me. Prompt 00b (architecture diagrams) is optional: run it manually
after 00 if you want diagnostics, or include it by running migrate.sh
with --with-diagrams. Then proceed through each applicable prompt sequentially. Each
prompt MUST end by calling
dynamics-migration-tool/tooling/record-prompt-execution.sh so the
executedPrompts[] audit in bootstrap.json stays current.

After prompts 00pre–09, 11 (push/FCM), and 03c (Background Authorize) are complete, run prompt 10. It will hard-gate
on the executionPlan against executedPrompts and deferredDomains in
bootstrap.json — if any applicable domain is missing both an
executed prompt and a developer-signed-off deferral, prompt 10 will
abort and tell me which prompts to re-run. Only when the gate passes
does it write migration-report.json. The recorder call at the end of
prompt 10 automatically runs split final validation:
`validate.sh --mode final-source` (source gate) followed by
`validate.sh --mode report` (report-contract gate), and only records
completion when both pass.

After prompt 10 completes successfully, offer prompt
12-generate-migration-retrospective.md: ask whether to generate the
optional migration retrospective (migration-retrospective.md). Run
prompt 12 only if I opt in.
```

Your AI agent will:
1. **Bootstrap (00pre)** — confirm IDE permissions, collect
   `GDApplicationID` and `GDApplicationVersion`, capture attestations
   (clean baseline build, two-phase startup acknowledgment, etc.),
   create a `migration-backup-YYYYMMDD-HHMMSS` git branch when git is available, probe
   JDK/Gradle/Android SDK, resolve the Dynamics SDK via Gradle, and
   write `output/bootstrap.json`. **This is the only step that asks
   you for input.** Network is mandatory here; the kit aborts if it
   can't reach the BlackBerry Maven repository. On fresh apps where
   prompt 01 has not run yet, bootstrap auto-runs an internal fallback
   resolver so you are not blocked on SDK classpath ordering.
2. **Analyze (00)** — read your entire codebase, produce the
   migration plan, and emit `output/migration-analysis.json` with a
   binding `executionPlan[]` table (**schema 1.2.0**: each row for
   prompts 04/05c/06 includes `callSites[]`). Prompt 00 also seeds
   `output/migration-plan-state.json` (`dispositions: []`). Prompts may
   update that ledger as they migrate call sites, but the closure check is
   enforced at prompt `10`, not after every intermediate prompt (see
   `steering/79-migration-plan-state-and-call-site-closure.md`).
3. **Architecture (00b, optional)** — generate lifecycle dependency
   maps, data flow diagrams, secure API call graph.
4. **Gradle (01)** — add SDK dependency, set `minSdk >= 31`, configure
   the BlackBerry Maven repository.
5. **Settings (02)** — write `settings.json` from the UEM values
   captured in 00pre. The agent does NOT re-ask for these.
6. **Authorization (03 / 03b)** — kit-standard `Application` class,
   global `GDStateListener`, `activityInit()` for main-process Activities,
   explicit conversion/preservation of any existing supported non-kit
   Dynamics authorization patterns, and deferral audit across ViewModels /
   Fragments / receivers.
7. **Migrate applicable domains (04 – 09, 11, 03c)** — SQL, file
   storage, networking, WebView, ICC, UI widgets / clipboard, push/FCM,
   and Background Authorize intent capture. Each prompt appends an
   entry to `bootstrap.json` `executedPrompts[]` on completion (or
   skip), except `03c` also records per-candidate decisions in
   `bootstrap.backgroundAuthorize.decisions[]`.
8. **Report (10)** — cross-checks the execution plan against the
   executed-prompts audit, then writes
   `output/migration-report.json` and
   `Dynamics_Migration_Readme.md`.
   If the cross-check fails, prompt 10 aborts and points you at the
   prompts you need to re-run. The `record-prompt-execution.sh` call
   at the end of prompt 10 automatically runs split final validation
   (`final-source` then `report`) and refuses to record completion
   until both gates pass.
9. **Retrospective (12, optional)** — after prompt 10, the agent asks
   whether you want `output/migration-retrospective.md`. If you decline,
   it records prompt 12 as `skipped` and finishes. If you accept, it
   writes an evidence-based retrospective separate from the migration
   report.

You stay in control — your AI agent shows you what it's changing at
each step, and you can accept, reject, or ask questions at any point.

---

## Step 6: Validate the Migration

Final validation runs automatically when the recorder completes
prompt 10 — you do not need to invoke `validate.sh` separately for
the happy path. If prompt 10's recorder call exited with an error, it
means validation failed and the executedPrompts entry was not written.
Read gate-specific violations from
`dynamics-migration-tool/output/.last-source-check.json` or
`dynamics-migration-tool/output/.last-report-check.json`
(or the recorder's stderr) and tell your agent which checks failed.

If you want to run a manual spot-check at any point:

```bash
./dynamics-migration-tool/tooling/validate.sh
```

You want to see:
- 0 failures
- Warnings are OK (they flag things that "may not apply" to your app
  OR that you've explicitly deferred — see "Deferring a domain" below)
- "Migration validation PASSED"

If there are failures, tell your agent which checks failed and ask it
to fix them, then re-run the relevant migration prompt and finish again at
prompt `10`. If you want an intermediate diagnostic before the final gate,
run `bash dynamics-migration-tool/tooling/validate.sh --check-prompt <id>`
manually.

If recorder/validator exits with code `3` and prints `ESCALATION REQUIRED`,
stop rerunning the same broad gate. Inspect
`output/migration-loop-state.json`, fix the owning prompt/domain first, then
retry prompt `10`.

---

## When stuck

Use this recovery path before re-running the whole migration:

1. Run `bash dynamics-migration-tool/tooling/progress.sh` to see completed
   prompts, pending work, and retry/escalation status.
2. Fix the **owning** prompt/domain that failed. Do **not** thrash prompt
   `10` or jump around unrelated prompts hoping a gate clears.
3. If the recorder/validator prints `ESCALATION REQUIRED` (exit code `3`),
   **stop** and decide with your team — do not keep retrying the same
   failure.
4. Optional bounded repair for controlled prompts
   (`01,02,03,03b,04,05a,05b,05c,06,07,08,09,11,03c`):

   ```bash
   bash dynamics-migration-tool/tooling/repair-orchestrator.sh --prompt-id <id>
   ```

   Obey exit codes `0` (continue), `1` (apply `output/repair-task.md` then
   re-invoke), and `3` (escalated — ask a human). See
   `steering/96-repair-loop-conduct.md`. Prompt `10` stays recorder-owned.

---

## Step 7: Review All Migration Changes

Every change the agent made is tagged with an inline comment:

```bash
rg "\[BB_DYNAMICS-MIGRATION\]" -g "*.java" -g "*.kt" \
  -g "*.xml" -g "*.gradle" -g "*.gradle.kts" -n
```

This gives you a complete audit trail of what was modified and why.

---

## Step 8: Review the Migration Report

The agent generates:
- `dynamics-migration-tool/output/migration-report.json` (schema v2.1.0)

`migration-report.json` contains:

- Every file modified and why
- Every API replaced with risk level (low/medium/high) and before/after code snippets
- Coverage status for each migration area (networking, storage, SQL, etc.)
- Outstanding manual TODOs with severity and blocking status
- Runtime test plan — actionable test scenarios for QA engineers
- UEM admin handoff — entitlement setup, connectivity profile, permissions
- Unsupported features and workarounds
- Validation results

View it as raw JSON:

```bash
cat dynamics-migration-tool/output/migration-report.json | python3 -m json.tool
```

Or open the visual HTML report:

```bash
open dynamics-migration-tool/migration-report-viewer.html
```

### Optional: migration run retrospective (prompt 12)

After prompt 10, your agent should ask whether you want an optional
retrospective. If you accept, it writes:

`dynamics-migration-tool/output/migration-retrospective.md`

That document is separate from `migration-report.json` — it summarizes
what went well, what failed, security posture, validation evidence, and
suggested migration-tool improvements. If you decline, the agent records
prompt 12 as `skipped` in `bootstrap.json` and does not create the file.

You can also run `prompts/12-generate-migration-retrospective.md` manually
later against a completed migration.

```

The viewer will auto-load `output/migration-report.json` automatically. If it
can't find the file (e.g. you're opening the HTML from a different location),
use the file picker to select the JSON manually. You get
a visual dashboard with:
- Summary tiles (status, files modified, APIs replaced, validation)
- Coverage table with status badges
- API replacement cards with side-by-side before/after code diffs and risk badges
- Prioritized manual TODO list
- Numbered runtime test plan for QA
- UEM admin handoff table (printable — hand this to your UEM admin)

---

## Step 9: Clean Up

Once you're satisfied with the migration:

```bash
rm -rf dynamics-migration-tool/
rm -rf .kiro/steering/ .cursor/rules/
```

If you used Codex, remove the marked `BB_DYNAMICS_MIGRATION_CODEX`
section from `AGENTS.md` when you no longer need the migration
instructions. Do not delete `AGENTS.md` if it contains your project's
own Codex instructions.

Keep `dynamics-migration-tool/output/migration-report.json` — it's useful for compliance
audits, team review, and CI integration. Remove it only if you don't need it:

```bash
rm -rf dynamics-migration-tool/output/
```

The migration changes in your source code are permanent and independent of the tool.

---

## Quick Reference

```bash
# 1. Create working copy and verify it builds
cp -r your-app your-app-dynamics
cd your-app-dynamics
./gradlew clean build

# 2. Add the migration tool and run setup
cp -r /path/to/dynamics-migration-tool ./dynamics-migration-tool
chmod +x dynamics-migration-tool/tooling/*.sh
./dynamics-migration-tool/tooling/migrate.sh --agent cursor   # or --agent kiro / codex
# Optional diagnostics: add --with-diagrams to include prompt 00b in the scripted order

# 3. Grant your agent the IDE permissions it'll need
#    (Cursor: Settings → Cursor Settings → Agents → Auto-Run;
#     set mode + network access; Kiro: Tool permissions;
#     Codex: approve file/shell/network access when asked; Generic: equivalent)

# 4. Open your agent, paste the migration prompt from the script output
#    Have your GDApplicationID and GDApplicationVersion ready —
#    prompt 00pre will collect them ONCE and write bootstrap.json.
#    Network access to the BlackBerry Maven repository is mandatory.

# 5. The recorder at the end of prompt 10 runs split final validation automatically.
#    Manual spot-check (optional):
./dynamics-migration-tool/tooling/validate.sh

# 5b. Optional maintainer diagnostics live under:
#     dynamics-migration-tool/_maintainer/README.md

# 6. Review changes
rg "\[BB_DYNAMICS-MIGRATION\]" -g "*.java" -g "*.kt" \
  -g "*.xml" -g "*.gradle" -g "*.gradle.kts" -n

# 7. Review migration report (raw JSON or visual HTML)
cat dynamics-migration-tool/output/migration-report.json | python3 -m json.tool
open dynamics-migration-tool/migration-report-viewer.html

# 8. Clean up the tool (keep output/ for audits — bootstrap.json,
#    migration-analysis.json, migration-report.json are the audit trail)
rm -rf dynamics-migration-tool/ .kiro/steering/ .cursor/rules/
# If Codex was used, remove only the managed BB_DYNAMICS_MIGRATION_CODEX
# section from AGENTS.md unless that file was created solely for migration.
```

---

## Using Codex or Other AI Agents

For Codex, use the first-class setup mode:

```bash
./dynamics-migration-tool/tooling/migrate.sh --agent codex
```

This creates or updates `AGENTS.md` with a marked migration section that
points Codex at the prompt and steering files. Existing project
instructions in `AGENTS.md` are preserved.

If you're using GitHub Copilot, Cody, or another agent that doesn't
auto-load steering/rules files, run setup with `--agent generic`
(this is the default):

```bash
./dynamics-migration-tool/tooling/migrate.sh --agent generic
```

Then for each prompt:
1. Paste `steering/00-context.md` as initial context
2. Paste the relevant steering file for that prompt (the setup output maps them)
3. Paste the prompt file
4. Review and accept changes

The visual report viewer (`migration-report-viewer.html`) works with any agent —
it auto-loads `output/migration-report.json` or lets you pick a file manually.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `migrate.sh` says "not an Android project" | Run from the project root (where `app/build.gradle` lives) |
| Prompt `00pre` aborts on network failure | Network to the BlackBerry Maven repository is required — there is no offline mode. Whitelist `*.blackberry.com` in your IDE / corporate proxy and re-run `00pre` |
| Project is not a git repository | Android migrations require a Git baseline. Re-run prompt `00pre`; it will ask for consent before running `ensure-git-baseline.sh --consented`, which initializes Git, excludes toolkit artifacts, and creates the pre-migration baseline commit. |
| Git baseline commit fails because `user.name` or `user.email` is missing | Configure Git identity, then re-run `00pre`. For this app only: `git config user.name "Your Name"` and `git config user.email "you@example.com"`. Or globally: `git config --global user.name "Your Name"` and `git config --global user.email "you@example.com"`. No remote or GitHub account is required. |
| Prompt `00pre` aborts on permissions | Grant your agent file read / file write / shell exec / full network in your IDE (the kit will not configure these for you), then re-run `00pre` |
| Prompt `00pre` complains about JDK / Gradle / minSdk | Read `output/.bootstrap-probe.json` for the exact reason. JDK must be ≥ 17, Android SDK must be discoverable via `ANDROID_HOME` or `ANDROID_SDK_ROOT`, `gradlew` must be executable |
| Agent invents APIs that don't exist | Tell it: "Only use APIs from the steering files. Do not invent APIs." |
| Build fails after migration | Run `./gradlew build --stacktrace`, check `steering/95-troubleshooting.md` |
| `GDNotAuthorizedError` at runtime | Secure APIs called before `onAuthorized()` — tell your agent to re-run Prompt 03b (deferral audit) |
| `GDInitializationError` at runtime | Missing kit-policy initialization, duplicate Activity initialization, or missing global listener — tell your agent to re-run Prompt 03 |
| `IllegalStateException: Can not perform this action after onSaveInstanceState` right after activation/unlock | A `runOnAuthorized(...)` callback is committing fragment transactions after Activity state is saved. Re-run Prompt 03 and apply lifecycle-safe auth UI init (`isStateSaved` guard + deferred retry in `onPostResume`) before calling fragment `commit()`. |
| Validation fails on a specific phase | The recorder surfaces violations in its stderr and in the latest sidecar (`output/.last-check.json` mirror) plus prompt-10 gate sidecars (`output/.last-source-check.json` and `output/.last-report-check.json`). Tell your agent which checks failed and ask it to re-run the relevant prompt. |
| `validate.sh` flags Room / OkHttp / direct `File` / `createTempFile` | These are the hardened checks (Phase 4 / 5 / 6). Tell your agent to **fix** the flagged call sites (replace `java.io.File` with `com.good.gd.file.File`, replace `FileInputStream`/`FileOutputStream` with `com.good.gd.file` equivalents, implement `SecurePreferencesHelper` for SharedPreferences runtime usage). Re-run the relevant prompt after fixes. If you intentionally accept the gap, add the domain to `bootstrap.json` `deferredDomains[]` (see "Deferring a domain" in step 6) |
| Agent reports "blocked by non-waivable findings" without fixing them | The agent should implement fixes, not just report findings. Tell it: "Read `steering/03-implementation-first-conduct.md` and implement the documented replacements instead of flagging them as blockers." |
| Prompt 10 prints "EXECUTION PLAN GATE FAILED" | An applicable domain has neither a completed prompt nor a developer-signed-off deferral. Either re-run the listed prompts, or add a `deferredDomains[]` entry, then re-run prompt 10 |
| Agent guesses `GDApplicationID` | Stop it. These values MUST come from your UEM admin and are captured by `00pre`. Prompt 02 reads them from `bootstrap.json` and never re-asks |
| `settings.json` doesn't match `bootstrap.json` | Prompt 02 overwrites `settings.json` from `bootstrap.json` — re-run prompt 02 |
| `migration-report.json` missing fields | Ensure prompt 10 ran with schema v2.1.0 steering — re-run prompt 10 |
| Report viewer shows nothing | Check that the JSON is valid: `python3 -m json.tool dynamics-migration-tool/output/migration-report.json` |
| `executedPrompts[]` has duplicate entries | Should be impossible — `record-prompt-execution.sh` is idempotent. If you see duplicates, re-run the offending prompt; the helper will replace its prior entry |

---

## Useful Tools

The toolkit includes several developer-experience scripts beyond the
core `migrate.sh` / `validate.sh` / `record-prompt-execution.sh`:

| Tool | Usage | Description |
|------|-------|-------------|
| `tooling/progress.sh` | `bash dynamics-migration-tool/tooling/progress.sh` | Mid-run progress dashboard showing completed/pending prompts, validation state, and deferred domains. Add `--json` for machine-parseable output. |
| `tooling/loop-state.sh` | `bash dynamics-migration-tool/tooling/loop-state.sh --help` | Loop-state helper used by validator/recorder to track repeated failures, retry budgets, and escalation evidence in `output/migration-loop-state.json`. |
| `tooling/repair-orchestrator.sh` | `bash dynamics-migration-tool/tooling/repair-orchestrator.sh --prompt-id <id>` | Optional bounded Stage 7 repair lane for controlled prompts only (`01,02,03,03b,04,05a,05b,05c,06,07,08,09,11,03c`). Final acceptance remains recorder-owned. |
| Git restore from backup branch | `git branch --list "migration-backup-*"` then `git checkout <migration-backup-branch> -- .` | Restore app sources from the backup branch created by prompt `00pre`. To restore a single file, run `git checkout <migration-backup-branch> -- path/to/file`. |
| `validate.sh --fix-suggestions` | `bash dynamics-migration-tool/tooling/validate.sh --fix-suggestions` | After validation, prints actionable fix instructions grouped by domain for every failure. |
| `migrate.sh --resume` | `bash dynamics-migration-tool/tooling/migrate.sh --resume --agent cursor` | Resume a migration from the last completed prompt (reads `bootstrap.json`). |
| `record-prompt-execution.sh --retry-guidance` | Add `--retry-guidance` to any recorder call | On validation failure, emits structured JSON describing fixable violations and the re-run command. Designed for agent auto-retry loops. |

**Tip**: Run `progress.sh` at any time during the migration to see where
you are. Run `validate.sh --fix-suggestions` after a failed validation
to get specific fix instructions instead of generic failure messages.
If you use the repair orchestrator, treat it as a bounded assistant lane; do
not route prompt `10` final acceptance through it.

---

## Execution Plan and the Hard Gate (Prompt 10)

The migration kit enforces a binding execution contract so that
applicable domains can never be silently skipped:

1. **Prompt 00** writes a mandatory `executionPlan[]` into
   `output/migration-analysis.json` — one row per conditionally
   applicable domain (`secureSql`, `secureFileStorage`,
   `secureNetworking`, `webview`, `icc`, `secureUiWidgets`,
   `secureClipboard`, `securePush`, `backgroundAuthorize`), each
   marked `applicable: true|false` with a rationale. `securePush` maps
   to prompt `11`. `backgroundAuthorize` maps to prompt `03c` and is
   considered closed only when every
   `processModel.backgroundEntryPoints[]` candidate has a matching
   `bootstrap.backgroundAuthorize.decisions[]` entry.
2. **Every prompt** appends an entry to
   `output/bootstrap.json`'s `executedPrompts[]` array on completion
   (via `tooling/record-prompt-execution.sh`). Re-runs upsert (no
   duplicates).
3. **Prompt 10 step 9** is a hard gate. For every applicable plan row
   it requires either:
   - an `executedPrompts[]` entry with `status: "completed"` (proof that
     the prompt ran and recorded its work), or
   - a developer-signed-off entry in
     `output/bootstrap.json` `deferredDomains[]`.

   For `backgroundAuthorize`, prompt 10 also enforces the
   `backgroundAuthorizeDecisionsCaptured` gate: every discovered
   background entry point must have a recorded `migrate`, `deferred`, or
   `not-applicable` decision from prompt `03c`.

   If anything is missing, prompt 10 **does not write a report** and
   tells you which prompts to re-run.

### Deferring a domain

If you need to ship an app where a domain is intentionally not
migrated yet (e.g. Room bridge under security review), edit
`output/bootstrap.json` directly and add an entry to
`deferredDomains[]`:

```json
"deferredDomains": [
  {
    "deferredAt": "2026-04-29T11:00:00Z",
    "deferredBy": "developer",
    "developerSignedOff": true,
    "classification": "plannedInNextRelease",
    "domain": "secureSql",
    "expiresAt": "2026-06-29T11:00:00Z",
    "reason": "Room bridge factory pending security review — JIRA-1234"
  }
]
```

Required fields:
- `developerSignedOff` must be literal `true` (the gate ignores
  `false` or missing).
- `classification` must be `plannedInNextRelease` or
  `acceptedResidualRisk`.
- `expiresAt` must be a future ISO-8601 UTC timestamp.
- `reason` must be a non-empty string. `"TBD"` and `""` do not
  satisfy the gate.

**Only the developer adds these entries.** The agent is forbidden
from writing `deferredDomains[]` — `record-prompt-execution.sh`
refuses to touch it. `validate.sh` honors deferrals by downgrading
the corresponding hardened checks (Phase 4 / 5 / 6 / 8b) from
`check_fail` to `check_warn`, so the gap stays visible in the
output but doesn't block the migration.

---

## Validation Checks (Full Table)

`validate.sh` checks:

| Phase | What's Checked |
|-------|---------------|
| Configuration | `settings.json` exists with `GDApplicationID`, `GDApplicationVersion`, and required keys |
| Gradle | Dynamics SDK dependency present in `build.gradle` |
| Authorization | Kit policy implemented: Application-scoped `GDStateListener`; `activityInit()` called exactly once in every main-process Activity launch path; existing supported non-kit SDK authorization patterns (`authorize(...)`, `GDMonitorActivity`, replacement Activity classes, `GDStateAction`, `applicationInit(...)`) converted or explicitly documented |
| File Storage | `GDFileSystem` used for sensitive file operations; `Context.openFile*` removed; direct `new java.io.File(...)` outside cache paths fails; `File.createTempFile(...)` fails (plaintext temp file leak) |
| SQL Database | `com.good.gd.database.sqlite` used; `android.database.sqlite` removed; `androidx.room.*` wired through a `SupportSQLiteOpenHelper.Factory` backed by `com.good.gd.database.sqlite.*` — Room without a Dynamics bridge factory fails |
| Networking | `GDHttpClient`/`GDSocket` used; `HttpURLConnection`, `java.net.Socket`, `org.apache.http.*` removed; `okhttp3.*` clients must wire `BBCustomInterceptor` or `BBCookieJar`; `retrofit2.*` similarly fails when its underlying OkHttp client is un-intercepted |
| UI Widgets | Catalog-driven lane migration: either AppCompat inflater lane (`GDAppCompatViewInflater`) or explicit GD widget lane, with type-safe bindings; includes `TextInputEditText` and secure clipboard/drag-drop routing. Unsupported widgets in `keepNativeRows[]` stay native with residual-risk documentation. |
| ICC / Sharing | No `ACTION_SEND` / `Intent.createChooser` / `FileProvider.getUriForFile` data leakage; `GDServiceClient.sendTo` used for cross-container sharing |
| Build | Project compiles with `./gradlew assembleDebug` |
| Authorization Guard | No secure API access in `onCreate()` before `onAuthorized()` |
| Migration Comments | `[BB_DYNAMICS-MIGRATION]` tags present at change points |
| Migration Report | `output/migration-report.json` exists, valid JSON, schema v2.1.0 |

> The Room / OkHttp / direct `File` / `createTempFile` checks are the
> hardening added in the gap analysis follow-up. Apps that pre-date
> those checks may need to re-run prompts 04, 05a/05b/05c, and 06.
> Line-level exception tags are not supported. Do **not** add
> `[BB_DYNAMICS-MIGRATION] EXCEPTION`, `[BB_DYNAMICS-WAIVER:*]`, or any
> other waiver-style marker in source. If a call-site cannot be migrated,
> either refactor it to a Dynamics-compatible pattern or have the developer
> record a domain-level deferral in `bootstrap.json.deferredDomains[]`.

> `validate.sh` validates the migration tool's own changes and report
> contract. It is not a substitute for full app QA/UAT, device testing,
> or security review before release.

---

## Unsupported Features

The migration tool flags the following as unsupported:

| Feature | Reason |
|---------|--------|
| Jetpack DataStore | No Dynamics secure container equivalent |
| Room (direct without bridge) | Supported via bridge adapter — see Prompt 04 (`SupportSQLiteOpenHelper.Factory`). Direct Room without the Dynamics bridge factory is insecure. |
| WorkManager with secure data access | Background tasks cannot access secure container before authorization |
| Firebase / Google services accessing sensitive data | Data must stay in the Dynamics secure container |
| Deep links / App Links routing enterprise data | Requires review for DLP compliance |

These appear in the `unsupportedFeatures` section of the migration report
with recommended workarounds where available.

---

## Steering File Reference (Per Prompt)

For agents without automatic context loading, load the relevant steering
file alongside each prompt:

| Prompt | Steering File |
|--------|--------------|
| 00pre | `steering/02-bootstrap-schema.md` |
| 01 | `steering/10-gradle-integration.md` |
| 02 | `steering/11-settings-json-reference.md` |
| 03 / 03b | `steering/20-auth-initialization.md` |
| 04 | `steering/41-secure-storage-sql.md` |
| 05a / 05b / 05c | `steering/40-secure-file-storage.md` |
| 06 | `steering/30-secure-networking.md` |
| 07 | `steering/50-webview-bbwebview.md` |
| 08 | `steering/60-icc-transferfileservice.md` |
| 09 | `steering/45-secure-ui-widgets.md` |
| 11 | `steering/78-push-channel.md` |
| 03c | `steering/70-background-authorize.md` |
| 10 | `steering/80-migration-report-schema.md` |
