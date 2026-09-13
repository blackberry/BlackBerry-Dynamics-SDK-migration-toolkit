# Migrating Your iOS App to BlackBerry Dynamics

Step-by-step instructions for using the dynamics-migration-tool with an
AI coding agent (Kiro, Cursor, etc.) to migrate an existing iOS
application to a Dynamics-enabled application.

The process is the same for any **native** iOS app — UIKit or SwiftUI, Swift or
Objective-C, CocoaPods or Swift Package Manager.

**Install model (mandate):** a Dynamics conversion is always a **fresh
install**. The agent replaces runtime storage APIs and does **not** copy
data from a previously installed non-Dynamics app (`UserDefaults` plists,
SQLCipher databases, sandbox files). There is no leftover-data transfer
option. See `steering/18-fresh-dynamics-install.md`.

**Not in scope for this toolkit release:** Flutter (and similar unofficial
hybrid hosts). Prompt `00pre` detects Flutter and stops Dynamics code
migration — there is no official BlackBerry Dynamics Flutter SDK. Use a
native UIKit/SwiftUI app, or an officially supported cross-platform SDK
(for example BlackBerry Dynamics for React Native).

**Share Extensions are unsupported by Dynamics** but do **not** stop main-app
migration. When Prompt `00pre` / `00` detects a Share Extension, isolate it
from Dynamics shipping (do not link Dynamics or call `authorize()` in the
extension). See `steering/17-app-extensions-and-share-extensions.md`.

---

## What You Need Before Starting

1. Your iOS app source code (must build cleanly before migration)
2. Xcode 15 or newer installed (plus command-line tools)
3. An AI coding agent (Cursor, Kiro, or equivalent — see "Using Other AI Agents" below)
4. A web browser (for viewing the visual migration report)
5. Git installed locally. No remote, GitHub account, or network access is
   required for the migration baseline.
6. From your UEM administrator:
   - GDApplicationID (entitlement ID configured in UEM)
   - GDApplicationVersion (entitlement version configured in UEM)

Do NOT guess these values. The agent will ask you for them during migration.

---

## Step 1: Set Up Your Working Copy

Create a working copy of your app so the original stays untouched.

```bash
cp -R /path/to/your-app /path/to/your-app-dynamics
cd /path/to/your-app-dynamics
```

Verify the project builds before starting. For a `.xcworkspace` project
(CocoaPods or a multi-project workspace):

```bash
xcodebuild -workspace YourApp.xcworkspace \
  -scheme YourApp -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
```

For a `.xcodeproj`-only project (pure SPM or no Pods):

```bash
xcodebuild -project YourApp.xcodeproj \
  -scheme YourApp -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
```

If it doesn't build, fix that first. The migration tool assumes a
working project.

The migration requires a Git baseline before source changes begin. If your
working copy is not already a Git repository with a commit, prompt `00pre`
will ask for consent to initialize Git, exclude toolkit artifacts, and create
a `pre-migration baseline` commit. If Git identity is not configured, use
either local identity for this app:

```bash
git config user.name "Your Name"
git config user.email "you@example.com"
```

or global identity for all local repositories:

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

---

## Step 2: Copy the Migration Tool Into Your Project

The dynamics-migration-tool ships alongside the Dynamics SDK. Copy it
into the root of your working copy:

```bash
cp -R /path/to/dynamics-migration-tool ./dynamics-migration-tool
```

Your project root should now look like:

```
your-app-dynamics/
├── YourApp.xcodeproj/        (or YourApp.xcworkspace/)
├── YourApp/                  # app target source
│   ├── Info.plist
│   ├── AppDelegate.swift
│   └── ...
├── Podfile                   # if you're using CocoaPods
├── Package.swift             # optional, if app uses SwiftPM
├── dynamics-migration-tool/  ← you just added this
│   ├── tooling/                # Tool scripts
│   │   ├── migrate.sh          # Setup and orchestration
│   │   ├── validate.sh         # Preflight, prompt-scoped, and full validation
│   │   ├── record-prompt-execution.sh # Records prompt completion (only writer of executedPrompts[])
│   │   ├── bootstrap.sh        # Used by prompt 00pre
│   │   ├── loop-state.sh       # Retry/escalation telemetry helper
│   │   └── generate-tool-analysis-report.sh # Toolkit-analysis artifact generator
│   ├── schemas/                # JSON schemas for bootstrap, report, and related artifacts
│   ├── migration-report-viewer.html # Visual HTML report viewer (auto-loads JSON)
│   ├── output/                 # Generated artifacts (bootstrap, analysis, report, …)
│   ├── prompts/                # Step-by-step migration prompts (00pre–11, optional 12)
│   ├── steering/               # AI agent context and constraints
│   └── ...
└── ...
```

---

## Step 3: Run the Setup Script

```bash
chmod +x dynamics-migration-tool/tooling/*.sh \
  dynamics-migration-tool/tooling/lib/*.sh
./dynamics-migration-tool/tooling/migrate.sh --agent cursor   # or --agent kiro
```

This does several things:
- Verifies your project structure (`.xcodeproj` / `.xcworkspace`, Podfile or
  SPM package references, Info.plist location, shared schemes)
- Chooses the right build entrypoint (workspace vs project) and prints the
  reason, so you know which scheme to use later
- Installs steering/rule files for your chosen agent:
  - Cursor: `.cursor/rules/`
  - Kiro: `.kiro/steering/`
- Prints a ready-to-paste migration prompt (prefer that output over any
  hand-copied text — it is the canonical kickoff for your agent mode)

If you want the setup script to do an optional pre-flight compile so
you can catch toolchain issues before starting, add `--verify-build`
(and optionally `--scheme YourScheme`):

```bash
./dynamics-migration-tool/tooling/migrate.sh --agent kiro --verify-build --scheme YourApp
```

See `./dynamics-migration-tool/tooling/migrate.sh --help` for all flags.

---

## Step 4: Open Your AI Agent and Start the Migration

Open your project in Cursor or Kiro. Start a new agent chat session.

**Prefer the ready-to-paste prompt printed by `migrate.sh`.** If you need a
fallback, paste the following (Cursor users may prefix paths with `@`):

```
I need to migrate this iOS app to BlackBerry Dynamics. The migration tool
is in dynamics-migration-tool/.

Read the migration prompts in dynamics-migration-tool/prompts and execute them
in this order:
00pre, 00, 00b, 01, 02, 03, 03b, 04, 04b, 05, 06, 07, 08, 09, 09b, 11, 10.
Optional after acceptance: 12.

For each prompt, read the prompt file and its referenced steering files in
dynamics-migration-tool/steering. Always include 00-context.md,
06-inline-migration-comments.md,
14-api-provenance-and-replacement-catalog.md, and
79-migration-plan-state-and-call-site-closure.md.

Start with 00pre-bootstrap.md. Do not proceed until
dynamics-migration-tool/output/bootstrap.json and
dynamics-migration-tool/output/target-map.json exist, are valid JSON, and
share the same runId.

Then run 00-analyze-app.md. Do not make application code changes until the
analysis and migration plan are complete and I have reviewed them.

After I approve the plan, continue through each applicable prompt
sequentially. Use documented Dynamics APIs only; do not invent APIs or stop
at findings that have cataloged replacements. For genuine product/security
ambiguity, ask me before choosing a direction.

When you reach prompt 02 (configure Info.plist / settings), STOP and ask me
for my GDApplicationID, GDApplicationVersion, and app setup type
(in-house/UEM-managed, partner/third-party, or BlackBerry-developed) before
proceeding. Register the required Dynamics URL schemes with the native bundle
identifier, not GDApplicationID.

iOS API guardrails: do not invent GDURLSession, GDPersistentContainer, or
GDSqlDatabase. Use cataloged public surfaces such as GDURLLoadingSystem,
GDSocket, GDPersistentStoreCoordinator, GDEncryptedBinaryStoreType,
GDEncryptedIncrementalStoreType, sqlite3enc_*, GDFileManager, GDFileHandle,
GDCReadStream/GDCWriteStream, and
GDNativePasteboardAccess.performActionOnNativePasteboard:.

Validation and recording contract:
- Prompt 00pre uses validate.sh --preflight, then record prompt 00pre.
- Prompts with no validator mode, such as 00 and 00b, do not need validation
  proof before recording, but their required artifacts must exist.
- Prompt-scoped prompts use validate.sh --check-prompt <prompt-id>, then
  record the prompt.
- Use --status completed for completed prompts.
- Use --status not-applicable only when prompt 00's executionPlan marks the
  prompt's owned domain not applicable and the prompt registry allows it.
- Do not edit bootstrap.json.executedPrompts[] or migration-plan-state.json by
  hand.

If validation or recording fails, fix the underlying source, generated
artifact, or closure-ledger evidence and rerun the same command. Do not patch
state files or validator output to bypass a gate.

Prompt 10 is the final acceptance gate. Follow prompt 10's order: write a
schema-valid draft report after its prerequisite gate passes, run full
validation, fix any failures with full-file overwrite, then record prompt 10
completion. After prompt 10, generate the toolkit analysis artifact with
dynamics-migration-tool/tooling/generate-tool-analysis-report.sh.
```

Your AI agent will:
1. Establish bootstrap provenance and Git baseline (Prompt 00pre)
2. Read your entire codebase and produce a migration plan (Prompt 00)
3. Generate architecture diagrams (Prompt 00b)
4. Set up Xcode / Pods / SPM integration (Prompt 01)
5. Ask you for your GDApplicationID, GDApplicationVersion, and app setup type,
   then register the required Dynamics URL schemes (Prompt 02)
6. Work through each applicable migration prompt (Prompts 03–09b, then 11)
   - 03  add Dynamics authorization to `AppDelegate`/`SceneDelegate`
   - 03b authorization-deferral audit
   - 04  SQLite → secure SQL (`sqlite3enc_*`)
   - 04b Core Data → `GDPersistentStoreCoordinator`
   - 05  filesystem → GDFileManager
   - 06  secure networking audit/migrate (URLSession, Stream sockets)
   - 07  WKWebView secure migration
   - 08  AppKinetics ICC
   - 09  external data movement + DLP
   - 09b managed policy chain
   - 11  push channel audit/migration decisions
7. After each applicable prompt: run prompt-scoped validation (when required),
   then `record-prompt-execution.sh` so `bootstrap.json.executedPrompts[]`
   advances
8. Generate `dynamics-migration-tool/output/migration-report.json`
   (schema **v2.1.0**), run full validation, and record Prompt 10
9. Optionally generate a retrospective (Prompt 12)
10. Generate the toolkit analysis report for developer feedback

You stay in control — your AI agent shows you what it's changing at each step,
and you can accept, reject, or ask questions at any point.

### Per-prompt validation and recording

The toolkit gates progress with `tooling/check-prompt-map.json`. After each
prompt (except where the prompt says validation proof is not required):

```bash
# Prompt 00pre only:
bash ./dynamics-migration-tool/tooling/validate.sh --preflight

# Most other prompts (use the prompt id, e.g. 03, 05, 09b):
bash ./dynamics-migration-tool/tooling/validate.sh --check-prompt <prompt-id>

# Then record completion (recorder is the only writer of executedPrompts[]):
bash ./dynamics-migration-tool/tooling/record-prompt-execution.sh \
  --prompt-id <prompt-id> \
  --status completed
```

Do not hand-edit `bootstrap.json.executedPrompts[]` or
`migration-plan-state.json`. Prompt 10 will refuse to complete until prior
prompts are recorded and full validation passes.

---

## Step 5: Validate the Migration

If your AI agent didn't already run the full sweep as part of Prompt 10,
validate manually:

```bash
./dynamics-migration-tool/tooling/validate.sh
```

You want to see:
- 0 failures
- Warnings are OK (they flag things that may need review for your app)
- `Migration tool self-check PASSED` (or `PASSED with warnings`)

If there are failures, tell your agent which phase failed and ask it to fix
it, referencing the prompt that owns that area (e.g. "Phase 5 failed
validation — re-run prompt 05-filesystem-migrate-to-gdfilemanager.md").

If validator/recorder exits with code `3` and prints `ESCALATION REQUIRED`,
stop rerunning the same broad gate. Inspect
`dynamics-migration-tool/output/migration-loop-state.json`, repair the owner
prompt/domain first, then retry.

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
4. Optional bounded repair for controlled implementation/config prompts:

   ```bash
   bash dynamics-migration-tool/tooling/repair-orchestrator.sh --prompt-id <id>
   ```

   Obey exit codes `0` (continue), `1` (apply `output/repair-task.md` then
   re-invoke), and `3` (escalated — ask a human). See
   `steering/96-repair-loop-conduct.md`. Prompt `10` stays recorder-owned.

---

## Step 5b: Toolkit Analysis Report (Required for Developer Feedback)

Immediately after validation, generate the internal-tooling feedback artifact:

```bash
bash ./dynamics-migration-tool/tooling/generate-tool-analysis-report.sh
```

This writes:
- `dynamics-migration-tool/output/tool-analysis-report.json`

It summarizes migration outcome/friction signals and includes developer
feedback fields you can fill before sharing internally.

---

## Step 6: Review All Migration Changes

Every change the agent made is tagged with an inline comment:

```bash
rg "\[BB_DYNAMICS-MIGRATION\]" -g "*.swift" -g "*.m" -g "*.mm" -g "*.h" \
  -g "Info.plist" -g "Podfile" -g "Package.swift" -n
```

This gives you a complete audit trail of what was modified and why.

---

## Step 7: Review the Migration Report

The agent generates `dynamics-migration-tool/output/migration-report.json`
(schema **v2.1.0**). This file contains:

- Every file modified and why
- Every API replaced with risk level (low/medium/high) and before/after
  code snippets
- Coverage status for each migration area (networking, storage, SQL,
  Core Data, filesystem, WKWebView, pasteboard, sharing)
- Outstanding manual TODOs with priority
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

The viewer will auto-load `output/migration-report.json` and expects schema
**v2.1.0**. If it can't find the file (e.g. you're opening the HTML from a
different location), use the file picker to select the JSON manually. You get
a visual dashboard with:
- Summary tiles (status, files modified, APIs replaced, validation)
- Coverage table with status badges
- API replacement cards with side-by-side before/after code diffs and
  risk badges
- Prioritized manual TODO list
- Numbered runtime test plan for QA
- UEM admin handoff table (printable — hand this to your UEM admin)

---

## Step 8: Clean Up

Once you're satisfied with the migration, **copy any artifacts you want to
keep out of the toolkit directory first**. Removing `dynamics-migration-tool/`
deletes `output/` as well.

```bash
# Optional: keep the report for audits / CI
mkdir -p ../migration-artifacts
cp dynamics-migration-tool/output/migration-report.json ../migration-artifacts/
cp -f dynamics-migration-tool/output/tool-analysis-report.json \
  ../migration-artifacts/ 2>/dev/null || true

rm -rf dynamics-migration-tool/
rm -rf .kiro/steering/    # or .cursor/rules/
```

The migration changes in your source code are permanent and independent
of the tool.

---

## Quick Reference

```bash
# 1. Create working copy and verify it builds
cp -R your-app your-app-dynamics
cd your-app-dynamics
xcodebuild -workspace YourApp.xcworkspace -scheme YourApp \
  -destination 'generic/platform=iOS Simulator' build   # or -project

# 2. Add the migration tool and run setup
cp -R /path/to/dynamics-migration-tool ./dynamics-migration-tool
chmod +x dynamics-migration-tool/tooling/*.sh \
  dynamics-migration-tool/tooling/lib/*.sh
./dynamics-migration-tool/tooling/migrate.sh --agent cursor   # or --agent kiro

# 3. Open your agent, paste the migration prompt from the script output
#    Have your GDApplicationID and GDApplicationVersion ready
#    Agent validates/records each prompt; Prompt 10 runs full validate.sh

# 4. Full validation (if not already done in Prompt 10)
./dynamics-migration-tool/tooling/validate.sh

# 4b. Generate toolkit analysis report (required for developer feedback)
bash ./dynamics-migration-tool/tooling/generate-tool-analysis-report.sh

# 5. Review changes
rg "\[BB_DYNAMICS-MIGRATION\]" -g "*.swift" -g "*.m" -g "*.mm" -g "*.h" \
  -g "Info.plist" -g "Podfile" -g "Package.swift" -n

# 6. Review migration report (raw JSON or visual HTML)
cat dynamics-migration-tool/output/migration-report.json | python3 -m json.tool
open dynamics-migration-tool/migration-report-viewer.html

# 7. Clean up the tool (copy output/ artifacts first if you need them)
mkdir -p ../migration-artifacts
cp dynamics-migration-tool/output/migration-report.json ../migration-artifacts/
rm -rf dynamics-migration-tool/ .kiro/steering/ .cursor/rules/
```

---

## Using Other AI Agents

If you're using GitHub Copilot, Cody, or another agent that doesn't
auto-load steering/rules files, run setup with `--agent generic`
(this is the default):

```bash
./dynamics-migration-tool/tooling/migrate.sh --agent generic
```

Then for each prompt:
1. Paste `steering/00-context.md` as initial context
2. Paste the steering files referenced by that prompt (always include
   `06-inline-migration-comments.md`,
   `14-api-provenance-and-replacement-catalog.md`, and
   `79-migration-plan-state-and-call-site-closure.md`)
3. Paste the prompt file
4. After the prompt work: run `validate.sh --check-prompt <id>` when required,
   then `record-prompt-execution.sh --prompt-id <id> --status completed`
5. Review and accept changes

The visual report viewer (`migration-report-viewer.html`) works with any
agent — it auto-loads `output/migration-report.json` or lets you pick a
file manually.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `migrate.sh` says "No .xcodeproj or .xcworkspace found" | Run from the project root (where your `.xcodeproj`/`.xcworkspace` lives) |
| `migrate.sh` picks the wrong build entrypoint | Pass `--scheme YourScheme` and `--verify-build` to force a specific build path |
| Project is not a Git repository | iOS migrations require a Git baseline. Re-run prompt `00pre`; it will ask for consent before running `ensure-git-baseline.sh --consented`, which initializes Git, excludes toolkit artifacts, and creates the pre-migration baseline commit. |
| Git baseline commit fails because `user.name` or `user.email` is missing | Configure Git identity, then re-run `00pre`. For this app only: `git config user.name "Your Name"` and `git config user.email "you@example.com"`. Or globally: `git config --global user.name "Your Name"` and `git config --global user.email "you@example.com"`. No remote or GitHub account is required. |
| Agent invents APIs that don't exist | Tell it: "Only use APIs from the steering files and the API catalog. Do not invent APIs." |
| Build fails after migration | Clean and rebuild: `xcodebuild clean build`; check `steering/95-troubleshooting.md` |
| Secure APIs fail / unauthorized before unlock | Secure APIs called before `onAuthorized()` / authorized event — tell your agent to re-run Prompt 03 and the 03b deferral audit |
| `GDInitializationError` at runtime | Check Keychain Sharing (`com.good.gd.data`), `GDApplicationID` / `GDApplicationVersion` in Info.plist, and that `GDiOS.sharedInstance().authorize(...)` runs from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`. Re-run Prompts 01–03 as needed; see `steering/95-troubleshooting.md` |
| Validation fails on a specific phase | Tell your agent: "Phase X failed validation. Re-run prompt Y, then `validate.sh --check-prompt Y` and `record-prompt-execution.sh`." |
| Recorder refuses to mark a prompt complete | Prerequisites in `check-prompt-map.json` are not satisfied, or scoped validation did not pass. Fix the owning prompt/domain; do not edit `executedPrompts[]` by hand. |
| Agent guesses GDApplicationID | Stop it. These values MUST come from your UEM admin |
| `migration-report.json` missing fields / viewer rejects schema | Ensure prompt 10 wrote schema **v2.1.0** — re-run prompt 10 |
| Report viewer shows nothing | Check that the JSON is valid: `python3 -m json.tool dynamics-migration-tool/output/migration-report.json` |
| `validate.sh` or recorder exits `3` (`ESCALATION REQUIRED`) | Retry budget is exhausted for repeated failures. Review `output/migration-loop-state.json`, fix the owner prompt/domain, and rerun targeted checks before another full attempt. |
| CocoaPods integration fails | Ensure `pod install` completes cleanly first; use the `.xcworkspace` entrypoint; see CocoaPods guidance in `steering/10-xcode-integration.md` |
| SPM package resolution fails | Use official URL `https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK` (`15.0.0`); try `File > Packages > Reset Package Caches` in Xcode; see SPM guidance in `steering/10-xcode-integration.md` |
