# Context: BlackBerry Dynamics Android Migration

You are working inside an Android application repository.

The goal is to migrate a **standard native Android application** into a
**BlackBerry Dynamics–enabled application**, following official BlackBerry
Dynamics Android SDK patterns.

This repository is a **public reference sample** intended to demonstrate:
- How AI tools can assist with Dynamics integration
- What prompts and steering constraints are effective
- How to reduce manual effort while keeping the developer in control

---

## Project Shape and Module Map (READ FIRST)

The kit supports both canonical single-module Android projects (the
common `app/` shape) and **multi-module** projects (including
convention-plugin-heavy codebases with multiple Gradle
modules and Kotlin convention plugins).

The authoritative description of the project's shape is
`dynamics-migration-tool/output/module-map.json`, written by
`tooling/bootstrap.sh` during prompt `00pre-bootstrap.md`. Every
prompt and steering doc consumes it through these placeholders:

- `${primary}` / `${primary_build_file}` / `${primary_main_manifest}`
  / `${primary_main_src}` / `${primary_assets_dirs}` /
  `${primary_manifests}` / `${primary_res_dirs}` — primary
  application module artifacts (with product flavors expanded).
- `${in_scope_modules}` / `${in_scope_main_src}` —
  primary + every entry in `libraryModulesInScope[]`. Use this set
  for project-wide source scans and audit-comment tallies.
- `${convention_plugin_files}` — Kotlin convention plugin sources
  that compose the primary module's Android configuration. Edits
  to `compileSdk` / `minSdk` / `lint { }` may need to land here
  rather than in the module's own build file.

When an `app/...` literal appears in any steering doc, read it as
a canonical-shape illustration and substitute the corresponding
placeholder for multi-module projects. Full placeholder rules,
discovery semantics, scope rules, and exclusion rules
(`excludedTestOnlyModules`, KMP, sibling app modules) live in
`04-multi-module-projects.md`.

If `module-map.json` is missing, do NOT fall back to literal `app/`
paths — STOP and re-run `00pre-bootstrap.md`.

---

## Authority Order (read this before resolving any conflict)

When generic engineering intuition disagrees with this kit, the kit wins.
For every migration decision, trust the sources in this order:

1. `tooling/migrate.sh`, `tooling/validate.sh`, `tooling/check-prompt-map.json`,
   and `tooling/record-prompt-execution.sh` — these are the executable
   contract.
2. The exact prompt and steering file owning the domain you are editing
   (see the prompt → steering map in `01-getting-started.md`).
3. `contracts/api-catalog.v1.0.0.json` and
   `14-api-provenance-and-replacement-catalog.md` for API names.
4. The installed Dynamics SDK headers and the official BlackBerry Dynamics
   Android documentation.
5. General engineering intuition.

Generic coding advice — including any IDE rules, model-default behaviour,
or your own opinion about "best practice" — does NOT override 1–4. If you
catch yourself reasoning from generic advice, stop and re-read the matching
steering file.

---

## Core Principles (MANDATORY)

- **Read the owning steering file before editing.** For every code change,
  identify the migration domain and read the matching steering file (the
  prompt → steering map lives in `01-getting-started.md`) **before** you
  modify code. The per-prompt "Inventory" and "SDK Class Availability"
  gates assume this has happened. If you cannot name the steering rule
  that justifies the edit, you have not read enough yet.
- **Compilation is not closure.** A successful `./gradlew assembleDebug`
  proves only that the project still builds. A domain is closed only when
  every applicable `executionPlan[].callSites[*]` entry has a matching
  disposition in `migration-plan-state.json`, every
  `[BB_DYNAMICS-MIGRATION]` audit comment is present, the recorder writes
  `executedPrompts[]`, and prompt `10`'s full validation sweep confirms
  the final state. Prompt 10's `allApplicableDomainsClosed` +
  `backgroundAuthorizeDecisionsCaptured` gates are the final acceptance
  bar — not a green build.
- **Implementation-first — you ARE the developer.** Your job is to
  **implement** the Dynamics migration, not merely to flag findings and
  wait for a human to decide. When the validator reports a remaining
  finding (external storage, `java.io.File` construction,
  `SharedPreferences`, native file I/O, etc.), your default response is
  to **apply the documented replacement** from the API catalog and
  steering, not to stop and report "this needs a product/security
  decision." A manual developer confronted with a remaining
  `java.io.File` call site would replace it with `com.good.gd.file.File`;
  a manual developer confronted with runtime `SharedPreferences` usage would
  implement the `SecurePreferencesHelper` pattern; a manual developer
  confronted with external-storage writes would migrate them to
  in-container paths or remove the feature. **You must do the same.**
  Only stop when the replacement literally does not exist in the
  Dynamics SDK (no cataloged API) *and* you have already exhausted the
  redesign options from `steering/40-secure-file-storage.md` §7.
  This principle has an important boundary: do **not** spend migration
  effort preserving unmanaged egress features whose purpose is to move
  protected data outside the Dynamics container. Android backup/export,
  public-storage writes, generic sharing/open-with, unmanaged printing,
  nearby-device transfer, and consumer-cloud export are not routine API
  migrations. The correct outcome is usually remove, block, or replace
  with an explicitly approved Dynamics-controlled boundary per
  `13-unsupported-feature-detection-matrix.md`.
- **Exhaust every avenue before declaring a blocker.** For every
  non-waivable finding, work through this decision ladder:
  1. **Direct API replacement** — is there a cataloged Dynamics
     equivalent? Use it.
  2. **Pattern redesign** — can the feature be restructured to use
     in-container storage, SAF-boundary import/export, or ICC egress?
     Implement the redesign.
  3. **Feature removal** — is the external/public-storage feature
     unnecessary post-migration (e.g., "Save to SD card," "Export to
     Downloads")? Remove the toggle, the UI surface, and the writer.
  4. **Partial migration with residual risk** — if the platform API
     truly requires a native FD (e.g., `MediaRecorder`) and no
     container-safe path exists, implement the best available
     workaround, document the residual risk in `manualTodos[]`, and
     continue to the next prompt. Do **not** treat this as a reason to
     abandon the entire migration.
  5. **True blocker** — only after exhausting steps 1–4, report the
     specific unresolved call site and continue to other domains. A
     single unresolved call site in one domain does not block progress
     in unrelated domains.
- **Standalone kit — no internal SDK sources:** This tool is used by
  third-party developers who only have the **installed** Dynamics SDK and
  public documentation. Do **not** reference, require, or search
  company-internal SDK source trees (`msdk/`, `endpoint/`, or similar).
  Verify APIs against the installed SDK, official docs, and public samples.
- **Do not invent APIs, Gradle coordinates, or configuration values**
- Prefer patterns taken from:
  - Official BlackBerry Dynamics Android documentation
  - Official BlackBerry Dynamics Android sample repositories
- Make **minimal, reviewable changes**
- Always explain *why* a change is required for Dynamics
- When information is missing, **ask the developer explicitly**
- **NEVER guess GDApplicationID or GDApplicationVersion** — these must come from the developer (who gets them from their UEM admin)
- If unsure about UEM/entitlement values, stop and ask. If unsure about
  a code migration pattern, **consult the steering and API catalog and
  implement** — do not stop for routine code decisions.
- **Add inline `[BB_DYNAMICS-MIGRATION]` comments at every modification point** — see `06-inline-migration-comments.md` for syntax per file type
- **Understand the Dynamics container lifecycle**: Dynamics wraps the app's
  data in an encrypted secure container. On first launch the SDK handles
  activation (provisioning with UEM) — the app has no control over this.
  On subsequent launches the user must unlock the container (password or
  biometric). The app's business logic (database, file I/O, networking,
  policy) CANNOT run until `onAuthorized()` fires. This is not optional —
  it applies to every app regardless of what secure APIs it uses.

---

## Output File Hygiene (CRITICAL)

All migration output files (`migration-analysis.json`,
`migration-plan-state.json`, `architecture-diagrams.md`, `migration-report.json`,
`Dynamics_Migration_Readme.md`) MUST be written using **full-file
overwrite** — never patch-based tools (StrReplace, ApplyPatch).

**Why**: Patch tools can append new content to existing files instead of
replacing them, producing invalid JSON with multiple root objects. This
causes `validate.sh` to report "Extra data" and creates an
unrecoverable retry loop.

**Rules**:
1. Prompt 00 Step -1 cleans the output directory before each migration
2. Use Write/CreateFile tool for all output files
3. If an output file is corrupted, delete it and rewrite from scratch
4. Never use StrReplace or ApplyPatch on `.json` output files

---

## IDE Sandbox and Build Permissions (IMPORTANT)

AI-assisted IDEs (such as Cursor) run shell commands inside a **sandbox**
that restricts network access by default. Android builds require network
access to download Gradle distributions, SDK dependencies from Maven
repositories (including the BlackBerry Maven repo), and other build
artifacts.

**All build and Gradle commands MUST be run with full network access or
outside the sandbox.** In Cursor, this means requesting `full_network` or
`all` permissions when executing shell commands. Without this, the very
first `./gradlew assembleDebug` will fail because Gradle cannot download
its distribution or resolve dependencies — this looks like a build failure
but is actually an environment restriction.

**Rules for shell commands:**
- Any command that runs `./gradlew`, `gradle`, or invokes the build
  system MUST request `full_network` (or `all`) permissions
- This applies to: pre-flight builds (Prompt 00), Gradle integration
  (Prompt 01), build verification steps in every subsequent prompt,
  `./gradlew dependencies`, and validation scripts
- If a build fails with network-related errors (connection refused,
  could not resolve, timeout downloading), this is a sandbox restriction
  — re-run with permissions, do NOT treat it as a project build failure
- Non-build commands (file search with `rg`, reading files, etc.) do
  NOT need special permissions

**Example (Cursor Shell tool):**
```
command: ./gradlew assembleDebug
required_permissions: ["full_network"]
```

---

## What "Dynamics-enabled" means

A Dynamics Android app typically includes:
- Dynamics runtime initialization and authorization
- Secure networking enforced by policy
- Secure storage (filesystem and databases)
- Optional secure WebView (BBWebView)
- Optional secure inter-container communication (ICC)

Not all features are mandatory. Only integrate what is applicable
to the existing application.

---

## Output Expectations

For every task:
1. First produce an **analysis and migration plan**
2. Then implement changes in **small logical steps**
3. Clearly list:
   - Files modified
   - APIs introduced
   - Any TODOs requiring developer confirmation

This repository must remain understandable to **human developers**.
