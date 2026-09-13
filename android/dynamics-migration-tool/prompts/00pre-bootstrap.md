## Task: Bootstrap the Migration Environment

Goal: Capture every piece of human input, environmental check, and
permission grant the migration depends on, **once, up front**, before any
analysis or code changes begin. This prompt produces
`dynamics-migration-tool/output/bootstrap.json`, which all subsequent
prompts read instead of asking the developer again or re-probing the
environment.

**This prompt MUST be run first, before `00-analyze-app.md`.**

**Why a pre-prompt?** Without it, the migration hits three independent
stop points where it can fail mid-run: UEM credentials might only exist
in ad-hoc notes instead of a machine-readable contract, the SDK class
probe runs at prompt 04, and the SDK class probe runs again at prompt 06.
Any of these can block on permissions the developer didn't know they needed
to grant. This prompt collapses all of those into one gate.

---

## Steps

### 1. Detect Agent and Print Permissions Allowlist

Determine which AI coding agent is running this prompt (`cursor`,
`kiro`, `codex`, or `generic`). The agent's identity changes only the
wording of the allowlist message in this step; the rest of the prompt is
identical across agents.

Show the developer the following message **verbatim** and pause for
confirmation. Do NOT proceed until the developer answers `yes`.

> **Migration permissions checklist**
>
> The migration will run the following command families. Please grant
> "Auto-run / Allow all" for the duration of this session **OR** add
> the following allowlist entries in your IDE before continuing:
>
> | Category | Commands | Why |
> |---|---|---|
> | File search | `rg`, `ls`, `find` | Inventory app source |
> | File read/write | (IDE-native) | Apply migration edits |
> | Build | `./gradlew`, `gradle` | Resolve Dynamics SDK; verify build |
> | Validation | `bash dynamics-migration-tool/tooling/validate.sh` | Phase checks |
> | Bootstrap | `bash dynamics-migration-tool/tooling/bootstrap.sh` | This step |
>
> **Network access is required.** The Dynamics SDK is downloaded from
> the BlackBerry Maven repository. If your IDE sandbox blocks network
> access, the bootstrap will fail at step 7 and the migration cannot
> proceed.
>
> Type `yes` to confirm the permissions are granted, or `no` to abort.

If the developer answers `no`, STOP. Do not write any output files. The
developer must enable the listed permissions in their IDE and re-run
this prompt.

If the developer answers `yes`, record `permissions.developerConfirmedAt`
as the current ISO-8601 UTC timestamp.

### 2. Collect UEM Credentials

UEM credentials are the only required human input for the migration.
They are collected **only** in this prompt; prompt `02-create-settings-json.md`
reads them from `bootstrap.json` and does not ask again.

Show the developer the following message **verbatim** (render the
documentation lines as clickable markdown links) and capture both values:

> **UEM entitlement values required**
>
> These come from your UEM administrator. Do NOT guess them — incorrect
> values will cause activation to fail at first launch.
>
> **Learn more (official BlackBerry Dynamics documentation)**
> - [Using an entitlement ID and version to uniquely identify a BlackBerry Dynamics app](https://docs.blackberry.com/en/blackberry-dynamics-sdk/14.x/blackberry-dynamics-sdk-for-android/blackberry-dynamics-sdk-for-android-development-guide/requirements-and-support-for-platform-specific-features/using-an-entitlement-id-and-version-to-uniquely-identify-a-blackberry-dynamics-app) — explains `GDApplicationID` and `GDApplicationVersion`, how they are set in `assets/settings.json`, and how UEM uses them for end-user entitlement.
>
> 1. `GDApplicationID` — entitlement ID configured in your UEM console.
>    Format: reverse-DNS, e.g. `com.blackberry.dynamics.sample`.
>    Allowed characters: letters, digits, `.`, `_`, `-`.
> 2. `GDApplicationVersion` — entitlement version configured in your UEM
>    console. Format: four numeric components, e.g. `1.0.0.0`.
>
> If you are new to BlackBerry Dynamics, open the link above before
> pasting values. Your UEM administrator must create a matching internal
> app entitlement in the UEM console.
>
> Please paste the values now.

Validate both before recording:

- `GDApplicationID` must match `^[a-zA-Z0-9._-]+$` and be 1–255 characters.
- `GDApplicationVersion` must match `^\d+\.\d+\.\d+\.\d+$`.

If either value fails validation, ask again. Do NOT write `bootstrap.json`
with invalid values.

If the developer does not have the values yet, STOP after sharing the
official documentation link above. Do not invent placeholders — wait for
UEM-admin-confirmed values.

Record `uem.gdApplicationId`, `uem.gdApplicationVersion`, and
`uem.source: "uem-admin-confirmed"`.

### 3. Capture Developer Attestations

Ask the developer for explicit yes/no answers to each of the following.
Record each answer as a boolean. Do NOT proceed past this step until
every attestation is answered.

| Field | Question to ask the developer |
|---|---|
| `cleanBaselineBuild` | "Does this project build cleanly today (`./gradlew assembleDebug` succeeds)?" |
| `ackTwoPhaseStartupChange` | "The migration will restructure your launch Activity into a two-phase startup (UI shell pre-auth, app logic post-auth). Acknowledge?" |
| `ackRedundantEncryptionRemoval` | "The migration will adapt the app for Dynamics SDK constraints, including removing or replacing features such as sharing to external apps, external media storage, and redundant app-level encryption. Acknowledge?" |

If `cleanBaselineBuild` is `false`, STOP. The migration assumes a working
project as input. Ask the developer to fix the baseline build, then
re-run this prompt.

For the other two, both must be acknowledged before proceeding.

> **Bulk-acceptance is forbidden in this step.** Each row above must be
> answered individually. Do NOT batch-prompt the developer with a single
> "yes to all" question. The working-tree check in step 4 is a
> **separate** decision and must NOT be silently rolled into this block.

### 3b. Install model (mandate — not a bootstrap attestation)

Tell the developer the following. Do **not** add a new
`attestations.*` field or other unknown `bootstrap.json` key. Do **not**
ask whether to preserve leftover on-device data.

> This Dynamics conversion is always a **fresh install**
> (`steering/18-fresh-dynamics-install.md`). The agent will replace
> runtime storage APIs (SharedPreferences → secure container files,
> SQLite → Dynamics SQLite, `java.io.File` → `com.good.gd.file.File`).
> It will **not** copy SharedPreferences XML, SQLCipher databases, or
> sandbox files from a previously installed non-Dynamics package. There
> is no leftover-data transfer path in this kit.

### 4. Git Baseline and Working-Tree Check (Standalone — Not Part of Step 3 Bulk Block)

The Android migration recorder depends on Git to compute validation deltas
and to maintain a restore baseline. Git is therefore required for Android
migrations.

Before running `git status`, check whether the project is a Git repository
with at least one commit:

```bash
git rev-parse --git-dir
git rev-parse --verify HEAD
```

If either command fails, show the developer this message **verbatim** and
wait for an explicit answer:

> **Git baseline required**
>
> The Android migration kit needs a Git baseline before code changes begin.
> This baseline is used for incremental validation, prompt-to-prompt change
> tracking, and Git restore if the migration needs to be restarted.
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

If the helper succeeds, continue with the filtered working-tree check below.

Run the **filtered** working-tree check (excludes expected migration-kit
paths — see below):

```bash
bash dynamics-migration-tool/tooling/git-working-tree.sh porcelain
```

`git-working-tree.sh` ignores uncommitted paths under
`dynamics-migration-tool/`, `.cursor/`, `.kiro/`, and `AGENTS.md` (the
toolkit copy and agent wiring installed by `tooling/migrate.sh` — Cursor,
Kiro, and Codex respectively). Every migration run introduces those
paths; they must not trigger a dirty-tree override by themselves.

This is a **separate, standalone prompt** — do NOT merge it into the
attestation block in step 3. Bundling it allowed earlier kit versions to
silently flip `cleanWorkingTree` to `true` under a "yes to all"
shortcut. The dirty-tree state lives in its own `workingTree`
top-level object (see `steering/02-bootstrap-schema.md`).

**Case A — filtered output is empty (clean tree for app sources):**
- Record `workingTree.dirty: false` and `workingTree.override: null`.
- Proceed to step 5.

**Case B — filtered output is non-empty (dirty tree):**
- Count untracked vs modified **relevant** files:
  ```bash
  bash dynamics-migration-tool/tooling/git-working-tree.sh counts
  ```
- Show the developer the filtered porcelain output from
  `git-working-tree.sh porcelain` (do NOT summarise — they need to see
  which **app** paths are dirty). Do not prompt for override when the
  only dirty paths are under the ignored prefixes above.
- Ask **explicitly and individually** (this is its own prompt, never
  combined with step 3):

  > ⚠ Your working tree has uncommitted changes. The migration will add
  > commits on top of these, which means the migration commits and your
  > pre-existing changes will be intermingled in the diff and harder to
  > review.
  >
  > Recommended: stash or commit your changes, then re-run this prompt.
  >
  > Do you want to override and continue with a dirty tree? **[y/N]**

- If the developer answers **N or anything other than an explicit `y`**:
  STOP. Do not write `bootstrap.json`. Tell them to commit/stash and
  re-run.
- If the developer answers **`y`** explicitly:
  - Record:
    ```json
    "workingTree": {
      "dirty": true,
      "override": {
        "acknowledged": true,
        "acknowledgedAt": "<ISO-8601 UTC timestamp>",
        "untrackedFiles": <count>,
        "modifiedFiles": <count>
      }
    }
    ```
  - Proceed to step 5.

The override field is auditable: prompt 10 surfaces it in the migration
report's `releaseReadiness.blockingItems` if `workingTree.override.acknowledged`
is `true`, so reviewers know the diff was intermingled.

> **Forbidden**: setting `workingTree.dirty: true` together with
> `workingTree.override: null`. If the tree is dirty, the override block
> must be present and `acknowledged: true`. A dirty tree without an
> explicit override means the developer was never asked — re-run this
> step.

### 5. Create Backup Branch

A backup branch is required so `--rerun-domain` and `--resume` (added in
later commits) can reset cleanly, and so the developer has a one-line
Git restore anchor.

Generate a timestamp in the format `YYYYMMDD-HHMMSS` (UTC). Run:

```bash
TS=$(date -u +%Y%m%d-%H%M%S)
git branch "migration-backup-$TS"
```

Note: this creates the branch but does NOT switch to it. The developer
stays on whichever branch they invoked the migration from. The backup
branch points at the same commit and serves as a rescue anchor.

Record `backup.branch` (the branch name) and `backup.createdFromCommit`
(the SHA at the time of branch creation, captured via `git rev-parse HEAD`).

### 6. Run Environment, Network, and SDK Class Probes

Invoke the bootstrap script, which performs all deterministic checks in
one shot:

```bash
bash dynamics-migration-tool/tooling/bootstrap.sh probe
```

The script writes two artifacts to `dynamics-migration-tool/output/`:

- `.bootstrap-probe.json` — a temporary JSON describing the environment,
  the resolved Dynamics SDK version, a class-availability index for
  every `com.good.gd.*` class the migration prompts depend on, and
  **`processModel`** (multi-process manifest classification). It also
  includes run-level provenance fields (`runId`, `catalogVersion`, and
  `provenance`). The agent merges this with the human-collected fields
  below into the final `bootstrap.json`. Copy `processModel`, `runId`,
  `catalogVersion`, and `provenance` verbatim from the probe file — do
  not re-scan manifests or regenerate provenance identifiers by hand
  unless the probe failed.
- `module-map.json` — the v1.0.0 project-shape artifact (see
  `steering/04-multi-module-projects.md`). Every subsequent prompt
  reads this file to discover the primary application module, library
  modules in scope, source sets, and convention plugin references.
  The agent must NOT regenerate the module map by hand; it is owned
  by `bootstrap.sh`.

The script exits 0 only when **all** of the following pass:

- `JAVA_HOME` set, JDK ≥ 17 resolvable.
- `ANDROID_HOME` or `ANDROID_SDK_ROOT` set.
- Gradle wrapper present and executable.
- Module discovery resolved a single primary application module
  (either via the canonical `app/` fallback, via `settings.gradle(.kts)`
  parse, or via developer-supplied `--app-module`).
- Either primary-module runtimeClasspath probing
  (`:<primary>:dependencies` / `:dependencies`) resolves a
  `com.blackberry.blackberrydynamics:*` artifact, **or** the internal
  fallback resolver preloads a pinned Dynamics SDK version for probing
  after verifying that the effective Gradle repository list contains
  the BlackBerry Maven repository in the repository plane Gradle will
  actually use (settings-level and/or project-level, depending on
  `repositoriesMode`).
- Every required Dynamics class is found in the resolved AAR(s).

If the project is fresh and prompt 01 has not run yet, the script now
auto-runs an internal fallback resolver (using the toolkit's pinned SDK
version) to populate the Gradle cache for class-index probing. This is
automatic — do not interrupt the developer to do manual Gradle edits for
this case.

The fallback resolver must be repository-mode aware. Some projects use
project-level `repositories {}` blocks that override
`dependencyResolutionManagement.repositories` (for example
`RepositoriesMode.PREFER_PROJECT`), while other projects forbid
project-level repositories (`PREFER_SETTINGS` /
`FAIL_ON_PROJECT_REPOS`). The script therefore injects and verifies the
BlackBerry repository in both settings-level and project-level scopes
before resolving artifacts. If Gradle still reports the repository as
absent from the effective scope, STOP and show the remediation patch
guidance printed by `bootstrap.sh` verbatim; do not continue with a
hand-written `bootstrap.json`.

**Exit code 3 — multi-application disambiguation required.** When a
project contains multiple `com.android.application` modules **and**
none of them lives in the canonical `app/` directory (and similar
multi-app codebases), the script halts with exit 3 and
prints the candidate list to stderr. STOP, show the developer the
candidate list verbatim, ask which module they want to migrate, and
re-run with the selection:

```bash
bash dynamics-migration-tool/tooling/bootstrap.sh probe --app-module <name>
```

Only one application module is migrated per run. Other application
modules are recorded in `module-map.json` under `otherAppModules[]`
for transparency in the migration report; if the developer also wants
to migrate them, they re-run the entire migration on each, one at a
time, against a fresh backup branch.

If the script exits non-zero for any other reason, STOP. Show the
developer the script's stderr output verbatim. Do NOT write
`bootstrap.json`. The developer must remediate true environment
blockers (typically: enable network access in the IDE, set
`JAVA_HOME`, set `ANDROID_HOME`, or add the BlackBerry Maven repository
to the Gradle repository scope identified by the bootstrap remediation)
and re-run this prompt.

### 7. Assemble and Write `bootstrap.json`

Merge the JSON output from step 6 with the values collected in steps
1–5 to form the complete `bootstrap.json`. The full schema is defined
in `steering/02-bootstrap-schema.md`.

Skeleton (alphabetical key ordering inside each object, per kit
convention):

```json
{
  "agent": { "approvalMode": "auto", "type": "codex", "version": "..." },
  "attestations": {
    "ackBackupBranchCreated": false,
    "ackRedundantEncryptionRemoval": true,
    "ackTwoPhaseStartupChange": true,
    "ackDlpPolicyOwnership": true,
    "cleanBaselineBuild": true
  },
  "backup": { "branch": "migration-backup-20260429-095512", "createdFromCommit": "<git sha>" },
  "catalogVersion": "1.0.0",
  "deferredDomains": [],
  "environment": { /* from bootstrap.sh probe */ },
  "executedPrompts": [],
  "generatedAt": "2026-04-29T09:55:12Z",
  "moduleMap": {
    "discoveryMethod": "fallback-app-dir",
    "libraryModulesInScopeCount": 0,
    "otherAppModulesCount": 0,
    "path": "dynamics-migration-tool/output/module-map.json",
    "primaryAppModule": { "name": "app", "path": "app" },
    "projectShape": "single-module"
  },
  "permissions": {
    "developerConfirmedAt": "2026-04-29T09:54:48Z",
    "fileRead": true, "fileWrite": true, "fullNetwork": true, "shellExec": true
  },
  "provenance": {
    "catalogContract": "contracts/api-catalog.v1.0.0.json",
    "catalogSha256": "<from probe; null when unavailable>",
    "catalogVersion": "1.0.0",
    "generatedAt": "2026-04-29T09:55:12Z",
    "gitCommit": "<from probe; null when unavailable>",
    "runId": "550e8400-e29b-41d4-a716-446655440000",
    "sdkArtifact": "<from probe>",
    "sdkResolvedVersion": "<from probe>",
    "toolkitVersion": "<value from VERSION file>"
  },
  "processModel": { /* from bootstrap.sh probe — see steering/22-multi-process-app-handling.md */ },
  "runId": "550e8400-e29b-41d4-a716-446655440000",
  "schemaVersion": "1.1.0",
  "sdkClassIndex": { /* from bootstrap.sh probe */ },
  "sdkProbe": { /* from bootstrap.sh probe */ },
  "toolkit": { "name": "dynamics-migration-tool", "platform": "Android", "version": "..." },
  "uem": {
    "gdApplicationId": "...",
    "gdApplicationVersion": "...",
    "source": "uem-admin-confirmed"
  },
  "workingTree": {
    "dirty": false,
    "override": null
  }
}
```

> **Schema migration note**: `cleanWorkingTree` was previously a member
> of `attestations`. It has been promoted to its own top-level
> `workingTree` object so a "yes to all" through the attestation block
> cannot silently override a dirty-tree warning. Validators that read
> `attestations.cleanWorkingTree` must be updated to read
> `workingTree.dirty` (note inverted polarity) and the optional
> `workingTree.override` sub-object. See
> `steering/02-bootstrap-schema.md`.
> Emit only the top-level keys defined by this schema. Phase 0 rejects
> any unknown key. The toolkit has no line-level exception mechanism;
> non-migrated call-sites must either be finished or covered by a
> domain-level `deferredDomains[]` entry authored by the developer.
>
> **Run provenance rule:** `runId`, `catalogVersion`, and `provenance.*`
> are run-owned identifiers generated in `bootstrap.sh probe`. Copy them
> into `bootstrap.json` exactly once during 00pre and preserve them for
> the rest of the migration run.
>
> **Timestamp invariant (required):** set top-level `generatedAt` to the
> exact same value as `provenance.generatedAt` from the probe artifact.
> Do not regenerate one timestamp for the root and another for provenance.

**Required write method**: full-file overwrite using the IDE's
Write/CreateFile tool. Per `steering/00-context.md`, do NOT use
StrReplace or any patch-based tool on JSON output files — they can
append rather than replace and produce invalid multi-root JSON. If
`output/bootstrap.json` already exists from a prior aborted run, delete
it first and write the fresh contents.

Validate the file after writing:

```bash
python3 -m json.tool dynamics-migration-tool/output/bootstrap.json > /dev/null
python3 - <<'PY'
import json
path = "dynamics-migration-tool/output/bootstrap.json"
data = json.load(open(path, encoding="utf-8"))
assert data.get("generatedAt") == (data.get("provenance") or {}).get("generatedAt"), \
    "bootstrap.generatedAt must equal provenance.generatedAt"
print("✅ bootstrap timestamp invariant ok")
PY
```

If parsing fails, the file is corrupt — delete it and rewrite from
scratch using a single full-file write.

### 8. Print One-Line Summary

After `bootstrap.json` is written, show the developer a single confirmation
line so they know the bootstrap completed. Include the primary
application module so the developer can confirm the right module was
selected on multi-application projects:

```
Bootstrap complete. Resolved Dynamics SDK <version>. Primary module:
<primaryAppModule.path> (<projectShape>). Proceeding to prompt 00 (analyze). Prompt 00b (architecture diagrams) is optional and may be run after 00.
```

Then continue to `00-analyze-app.md`.

---

## Output

- `dynamics-migration-tool/output/bootstrap.json` — required.
- `dynamics-migration-tool/output/module-map.json` — required, written
  by `bootstrap.sh`. Owned by the script; the agent must not edit it.
- A backup git branch named `migration-backup-<timestamp>`. Android
  migrations require a Git baseline; non-Git runs must stop in step 4
  unless the developer authorizes the kit to initialize Git and create the
  pre-migration baseline commit.
- A printed summary of resolved environment, SDK version, and the
  primary application module selected for migration.

---

## Critical Rules

- **Network access is mandatory.** There is no offline / docs-only mode.
  If the network probe fails, the prompt aborts with a clear remediation
  message; the migration does not continue.
- **No agent-driven permission grants.** The agent never modifies
  `.cursor/`, `.kiro/`, `AGENTS.md`, or any IDE configuration to grant itself
  permissions. The developer enables the allowlist manually.
- **Validate UEM credentials before writing.** Both `GDApplicationID` and
  `GDApplicationVersion` must match the regex contracts in step 2 — never
  write them to `bootstrap.json` if they fail.
- **Git is required.** If the project is not a Git repository, or has no
  commit baseline, ask for explicit consent to initialize Git and create
  the pre-migration baseline. If the developer declines, STOP. Do not write
  `bootstrap.json`.
- **Exclude toolkit artifacts from the baseline.** When Git is initialized
  by the kit, use `.git/info/exclude` so `dynamics-migration-tool/`,
  `.cursor/`, `.kiro/`, and `AGENTS.md` are not committed as app baseline
  content.
- **Full-file overwrite only** for `bootstrap.json`. Patch-based writes
  on JSON output files are forbidden across this kit.
- **Do not invent fields.** If a probe didn't return a value, omit the
  field — do not guess. The schema in `steering/02-bootstrap-schema.md`
  marks every field required vs optional.
- **The agent does not write `deferredDomains`.** That array is only
  populated by the developer if they explicitly opt out of a domain.

---

## Record execution

After writing `bootstrap.json` and `module-map.json`, record prompt `00pre`
completion:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 00pre \
    --status completed \
    --files-touched "dynamics-migration-tool/output/bootstrap.json,dynamics-migration-tool/output/module-map.json"
```

`00pre` now runs the Phase-0 bootstrap contract gate at record time, so
timestamp/provenance drift (including `generatedAt` mismatch) is rejected
immediately instead of surfacing later at prompt 10.

---

## Next Step

After this prompt completes successfully, run **`00-analyze-app.md`**.
After `00`, you may optionally run **`00b-generate-architecture-diagrams.md`**
for diagnostics before continuing to prompt `01`.
Prompt 00 will (in a future commit) read `bootstrap.json` to skip
re-asking for UEM credentials and to consult the SDK class index instead
of re-running its own probes. Until that wiring lands, the bootstrap
data sits as an audit artifact — but the env+network checks have already
de-risked the rest of the run.
