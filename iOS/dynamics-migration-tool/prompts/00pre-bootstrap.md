# Task: iOS Migration Bootstrap

**This is the first step of the iOS Dynamics Migration. Run it before prompt 00.**

Goal: Establish a stable `bootstrap.json` and `target-map.json` in
`dynamics-migration-tool/output/` that all subsequent prompts use for
provenance, scope, and run-ID binding.

This prompt makes **no changes to application source**. It only:
1. Ensures a consented Git baseline exists before migration changes begin
2. Cleans stale output from previous runs
3. Interrogates the project structure
4. Collects developer attestations
5. Writes two foundation artifacts

---

## Steps

### -1. Git baseline gate (REQUIRED before bootstrap)

The iOS migration needs a Git baseline before code changes begin. This
baseline is used for rollback, source-control provenance, and comparing the
pre-migration app state against migrated output.

Check whether the project is a Git repository with at least one commit:

```bash
git rev-parse --git-dir
git rev-parse --verify HEAD
```

If both commands succeed, continue to step 0.

If either command fails, show the developer this message **verbatim** and
wait for an explicit answer:

> **Git baseline required**
>
> The iOS migration kit needs a Git baseline before migration changes begin.
> This baseline records the pre-migration app state and gives you a local
> rollback point if the migration needs to be restarted.
>
> The migration kit can initialize Git for this project, exclude its own
> toolkit artifacts from the baseline, and create a pre-migration app-source
> commit.
>
> The following paths will be excluded from the baseline via
> `.git/info/exclude`:
>
> - `dynamics-migration-tool/`
> - `.cursor/`
> - `.kiro/`
> - `AGENTS.md`
>
> Before you approve, confirm that the app source does not contain secrets or
> unwanted generated files that should not be committed.
>
> Do you authorize the migration kit to run `git init` if needed, stage the
> app source, and create a `pre-migration baseline` commit? **[y/N]**

If the developer answers **N or anything other than an explicit `y`**, STOP.
Do not write `bootstrap.json`. The migration cannot continue without a Git
baseline.

If the developer answers **`y`** explicitly, run:

```bash
bash dynamics-migration-tool/tooling/lib/ensure-git-baseline.sh --consented
```

If the helper fails because Git identity is not configured, STOP. Do not
modify Git config. Show the developer these options and tell them to re-run
this prompt after configuring Git:

```bash
# Local identity for this migration app only:
git config user.name "Your Name"
git config user.email "you@example.com"

# Or global identity for all local repositories:
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

No Git remote, GitHub account, or network access is required for the baseline
commit.

### 0. Invoke the bootstrap tooling

Run the bundled bootstrap script:

```bash
bash dynamics-migration-tool/tooling/bootstrap.sh --agent cursor
```

Replace `cursor` with your agent type (`kiro` or `generic`) if appropriate.

If you have a known Xcode scheme, add `--scheme SchemeName`.

This script:
- Cleans any stale migration artifacts from `output/`
- Detects incompatible v2.0.0 output and removes it
- Detects project structure (`.xcodeproj`, `.xcworkspace`, CocoaPods, SPM)
- Generates a stable `runId`
- Writes `output/bootstrap.json`
- Runs `tooling/lib/discover-targets.py` and writes `output/target-map.json`

### 1. Developer attestations (REQUIRED — ask before proceeding)

Ask the developer the following questions and update `bootstrap.json`
with their answers:

**1a. Build readiness**:

> "Does this project currently build cleanly on your machine? (yes/no)"

If **no**: STOP. Ask the developer to fix compile errors before running
any migration prompt. Record `confirmedCleanBuild: "no"` and do not proceed.

If **yes**: Set `developerAttestations.confirmedCleanBuild` to `"yes"`.

**1b. Source control baseline**:

Confirm that `bootstrap.json.sourceControl.commit` and
`bootstrap.json.sourceControl.branch` are populated by step 0. Then set
`developerAttestations.confirmedSourceControlBaseline` to `"yes"` and add a
note containing the recorded commit and branch.

If either value is `null`, STOP and rerun the Git baseline gate and
`bootstrap.sh`. Do not proceed with `confirmedSourceControlBaseline: "no"`;
non-Git iOS migrations are not supported.

**1c. UEM values** (ask only if not already in Info.plist):

> "What are your GDApplicationID and GDApplicationVersion values for this app?"

If the values are already detected from Info.plist (check `bootstrap.json`
`uemValues.provenance == "inferred-from-plist"`), confirm them with the developer:

> "I detected GDApplicationID: [value] from Info.plist — is this correct? (yes/no)"

Record UEM values and provenance in `bootstrap.json.uemValues`.

### 2. Lifecycle discovery (manual analysis)

Read the application source to identify lifecycle entry points and update
`bootstrap.json.lifecycleCandidates[]` with the findings:

Scan for:
- `UIApplicationDelegate` conformance in `.swift` and `.m` files
- `UIWindowSceneDelegate` / `UISceneDelegate` conformance
- `@main` struct with `body: some Scene` (SwiftUI App)
- `UIApplicationDelegateAdaptor` usage
- Main storyboard in Info.plist (`UIMainStoryboardFile`)
- `application(_:didFinishLaunchingWithOptions:)` implementations
- `scene(_:willConnectTo:)` implementations

For each candidate found, add an entry:
```json
{
  "type": "UIApplicationDelegate | UISceneDelegate | SwiftUI-main | ...",
  "file": "relative/path/to/File.swift",
  "symbol": "AppDelegate",
  "notes": "any relevant notes"
}
```

Also scan for background entry points (`BGTaskScheduler`, APNs silent handlers,
`beginBackgroundTask`) and extension targets (WidgetKit, SiriKit, Share
Extension, etc.) and add them to `backgroundCandidates[]` and
`extensionCandidates[]` respectively.

For **Share Extensions** specifically, look for
`NSExtensionPointIdentifier` = `com.apple.share-services` (and Share
Extension targets in `target-map.json`). If found:

1. Record `extensionCandidates[]` with `extensionType: "share-services"`.
2. Show the developer this message **verbatim**:

> **Share Extension detected — unsupported by BlackBerry Dynamics**
>
> iOS Share Extensions cannot access the Dynamics secure container. This
> toolkit will migrate the **main app**, but will **not** Dynamics-enable the
> Share Extension (no `GDiOS.authorize` / no Dynamics frameworks in the
> extension).
>
> Required next steps: exclude the Share Extension from Dynamics shipping
> builds, remove App Group bridges for sensitive data, and redesign share-in
> (if required) as a main-app URL handoff that copies into `GDFileManager`
> only after authorization. See steering
> `17-app-extensions-and-share-extensions.md`.

3. Do **not** stop the whole migration (unlike Flutter). Proceed to Prompt 00
   with the Share Extension flagged for isolate / non-shipping treatment.

### 2a. Flutter hybrid gate (REQUIRED — out of scope this release)

Before finishing bootstrap, detect whether this project is a **Flutter** app
(or Flutter iOS Runner embedding). Scan the project root and app sources for
**any** of:

- `pubspec.yaml` (Flutter package manifest)
- `Flutter/` engine / ephemeral directory, or CocoaPods/`Podfile` dependency on
  `Flutter`
- `GeneratedPluginRegistrant` (`.m` / `.swift` / `.h`)
- `FlutterEngine`, `FlutterViewController`, `FlutterPluginRegistrant`, or
  `import Flutter` in Runner sources
- Xcode target named `Runner` that links `Flutter.framework` / Flutter pods

If **none** match, continue to step 3.

If **any** match, this toolkit release does **not** support Flutter → Dynamics
migration (no official BlackBerry Dynamics Flutter SDK). Do the following:

1. Add a `lifecycleCandidates[]` entry documenting the detection, for example:
   ```json
   {
     "type": "Flutter-hybrid",
     "file": "pubspec.yaml",
     "symbol": "Flutter",
     "notes": "Flutter host detected — out of scope for this iOS toolkit release"
   }
   ```
2. Show the developer this message **verbatim** and wait for an explicit answer:

> **Flutter app detected — out of scope for this toolkit release**
>
> This project appears to be a Flutter (or Flutter Runner) app. BlackBerry
> Dynamics does not ship an official Flutter SDK, and this iOS migration toolkit
> version does **not** attempt Dynamics migration of Flutter UI, engines, or
> Dart plugins.
>
> Continuing would produce incomplete or unsafe results (blank post-auth UI,
> plugin channel failures, false “migrated” validation). Supported paths are
> native UIKit/SwiftUI Dynamics apps, or officially supported cross-platform
> SDKs (for example BlackBerry Dynamics for React Native).
>
> You may finish bootstrap + optional analysis/report only to document the
> finding. Do **not** run Dynamics code-migration prompts (`01`–`09`, `11`)
> against this Flutter app with this toolkit version.
>
> Acknowledge Flutter is out of scope and stop Dynamics code migration? **[y/N]**

3. If the developer answers **anything other than explicit `y`**, STOP. Do not
   proceed to Prompt 00 as a Dynamics migration.
4. If the developer answers **`y`**, finish writing/updating `bootstrap.json`
   with the Flutter `lifecycleCandidates` entry, then proceed **only** to
   analysis / diagrams / report prompts that inventory and document the
   unsupported finding. Do **not** invent FlutterEngine, SceneDelegate, or
   `DynamicsPluginRegistrant` Dynamics wiring in later prompts.

See `steering/12-capability-and-support-model.md` (Flutter apps) and
`steering/13-unsupported-feature-detection-matrix.md`.

### 3. Validate the bootstrap artifacts

Verify both artifacts were written:

```bash
ls -la dynamics-migration-tool/output/bootstrap.json
ls -la dynamics-migration-tool/output/target-map.json
```

Validate bootstrap.json is valid JSON:

```bash
python3 -m json.tool dynamics-migration-tool/output/bootstrap.json > /dev/null && echo "OK"
```

Validate target-map.json is valid JSON:

```bash
python3 -m json.tool dynamics-migration-tool/output/target-map.json > /dev/null && echo "OK"
```

If either file is missing or invalid JSON, re-run bootstrap.sh.

### 4. Verify no stale v2.0.0 artifacts remain

```bash
# Should return no output if cleanup succeeded
grep -l '"schemaVersion".*"2\.0\.0"' dynamics-migration-tool/output/*.json 2>/dev/null || echo "No stale v2.0.0 artifacts"
```

If any v2.0.0 artifacts remain, remove them:

```bash
rm -f dynamics-migration-tool/output/migration-report.json
```

---

## Schema References

- `bootstrap.json` follows `schemas/bootstrap.schema.v1.0.0.json`
- `target-map.json` follows `schemas/target-map.schema.v1.0.0.json`

Both schemas are bundled with the toolkit.

---

## Output

- `dynamics-migration-tool/output/bootstrap.json` — stable run provenance
- `dynamics-migration-tool/output/target-map.json` — Xcode target/package map

---

## Critical Rules

- Do NOT make any code changes to the application in this prompt
- Do NOT proceed without a Git baseline in `bootstrap.json.sourceControl`
- Do NOT proceed to prompt 00 until `bootstrap.json` and `target-map.json` exist and are valid JSON
- Do NOT fabricate UEM values — record them as `null` if not provided
- If the developer answers "no" to the clean-build question, STOP immediately
- If Flutter is detected (step 2a), do **not** run Dynamics code-migration
  prompts (`01`+) with this toolkit version — document only
- Do NOT invent a Flutter + Dynamics migration playbook (explicit engine,
  plugin registrant gating, UIScene removal for Flutter, etc.) in this release
- `bootstrap.json.executedPrompts[]` is written only by `tooling/record-prompt-execution.sh` — do not edit it manually
- The `runId` in bootstrap.json must match the `runId` in target-map.json

---

## Next Step

After this bootstrap is complete:
- **Native UIKit/SwiftUI apps:** proceed to **00-analyze-app.md**
- **Flutter detected (acknowledged out of scope):** optional analysis / diagrams /
  report only to record Tier C + unsupported Flutter — then stop Dynamics migration
