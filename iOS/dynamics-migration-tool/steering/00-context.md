# Context: BlackBerry Dynamics iOS Migration

You are working inside an iOS application repository.

The goal is to migrate a **standard native iOS application** into a
**BlackBerry Dynamics–enabled application**, following official BlackBerry
Dynamics iOS SDK patterns.

This repository is a **public reference sample** intended to demonstrate:
- How AI tools can assist with Dynamics integration
- What prompts and steering constraints are effective
- How to reduce manual effort while keeping the developer in control

---

## Authority Order (read this before resolving any conflict)

When generic engineering intuition disagrees with this kit, the kit wins.
For every migration decision, trust the sources in this order:

1. `tooling/migrate.sh` and `tooling/validate.sh` — the executable
   contract.
2. The exact prompt and steering file owning the domain you are editing
   (see the prompt → steering map in `01-getting-started.md`).
3. `14-api-provenance-and-replacement-catalog.md` for API names.
4. The installed Dynamics SDK headers (under
   `external_sdk_headers/`) and the official BlackBerry Dynamics iOS
   documentation.
5. General engineering intuition.

Generic coding advice — including IDE rules, model-default behaviour, or
your own opinion about "best practice" — does NOT override 1–4. If you
catch yourself reasoning from generic advice, stop and re-read the matching
steering file.

---

## Core Principles (MANDATORY)

- **Read the owning steering file before editing.** For every code change,
  identify the migration domain and read the matching steering file (the
  prompt → steering map lives in `01-getting-started.md`) **before** you
  modify code. If you cannot name the steering rule that justifies the
  edit, you have not read enough yet.
- **Prefer kit mechanisms over inventing new ones.** Before writing a new
  helper, category, or wrapper, check whether the domain's steering file
  documents one. The validator phases and the migration report know about
  the kit's mechanisms; an invented parallel is invisible to them.
- **Fresh install is mandatory.** Do not invent one-time
  `UserDefaults` / SQLCipher / sandbox copy helpers
  (`18-fresh-dynamics-install.md`). There is no leftover-data transfer
  path. Steady-state replacements still apply.
- **Make the smallest correct change.** Touch only the files the
  migration plan calls out. Do not reformat, restructure, rename, or
  "improve" adjacent code that the plan does not require.
- **Compilation is not closure.** A successful `xcodebuild` build proves
  only that the project compiles. A domain is closed only when the
  prompt's required edits are applied, every `[BB_DYNAMICS-MIGRATION]`
  audit comment is present, and the full `tooling/validate.sh` sweep
  passes — that sweep is the final acceptance gate.
- **Do not invent APIs, framework names, or configuration values**
- Prefer patterns taken from:
  - Official BlackBerry Dynamics iOS documentation
  - Official BlackBerry Dynamics iOS sample repositories
- Make **minimal, reviewable changes**
- Always explain *why* a change is required for Dynamics
- When information is missing, **ask the developer explicitly**
- **NEVER guess GDApplicationID or GDApplicationVersion** — these must come
  from the developer (who gets them from their UEM admin)
- If unsure, stop and explain assumptions instead of guessing
- **Add inline `[BB_DYNAMICS-MIGRATION]` comments at every modification point**
  — see `06-inline-migration-comments.md` for syntax per file type
- **Understand the Dynamics container lifecycle**: Dynamics wraps the app's
  data in an encrypted secure container. On first launch the SDK handles
  activation (provisioning with UEM) — the app has no control over this.
  On subsequent launches the user must unlock the container (password or
  biometric). The app's business logic (database, file I/O, networking,
  policy) CANNOT run until `GDAppEventAuthorized` fires (delegate pattern)
  or `GDState.isAuthorized` becomes `true` (notification pattern). This is
  not optional — it applies to every app regardless of what secure APIs it uses.
- **Support both Swift and Objective-C** — the app may be written in either
  language (or a mix). Provide code examples in the language the app uses.
  If the app uses both, provide Swift examples by default.

---

## Prompt Execution Flow

Work through the migration prompts (00 → 00b → 01 → 02 → … → 10) in strict
numerical order **without pausing to ask which prompt to run next**. The
sequence is defined in the README and each prompt's "Next Step" section — treat
it as a pipeline and advance automatically.

**The only mandatory stop points are:**

- **Prompt 02 (Info.plist)**: You MUST stop and ask the developer for their
  `GDApplicationID` and `GDApplicationVersion`. These values come from their
  UEM administrator and must never be guessed or assumed.
- **Prompt 00 (Analysis)**: If the app uses patterns you cannot classify
  (e.g., custom encryption wrappers, unfamiliar third-party SDKs), stop and
  ask for clarification rather than guessing.

For all other prompts, proceed to the next step as soon as the current one is
complete. Skip prompts that are not applicable (e.g., skip Prompt 08 if the
app has no inter-container communication needs) and note them as skipped.

---

## Output File Hygiene (CRITICAL)

All migration output files (`migration-analysis.json`,
`architecture-diagrams.md`, `migration-report.json`,
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
that restricts network access by default. iOS builds may require network
access for `pod install` (CocoaPods), `xcodebuild` (if it triggers
package resolution), and SPM dependency downloads.

**All build and dependency-management commands MUST be run with full
network access or outside the sandbox.** In Cursor, this means requesting
`full_network` or `all` permissions when executing shell commands.
Without this, `pod install` or `xcodebuild` may fail with network-related
errors — this looks like a build failure but is actually an environment
restriction.

**Rules for shell commands:**
- Any command that runs `pod install`, `xcodebuild`, `swift package
  resolve`, or invokes the build system MUST request `full_network`
  (or `all`) permissions
- This applies to: pre-flight builds (Prompt 00), Xcode integration
  (Prompt 01), build verification steps in every subsequent prompt,
  and validation scripts
- If a build fails with network-related errors (connection refused,
  CDN timeout, could not resolve spec repo), this is a sandbox
  restriction — re-run with permissions, do NOT treat it as a project
  build failure
- Non-build commands (file search with `rg`, reading files, etc.) do
  NOT need special permissions

**Example (Cursor Shell tool):**
```
command: xcodebuild -workspace YourApp.xcworkspace -scheme YourApp build
required_permissions: ["full_network"]
```

---

## What "Dynamics-enabled" means on iOS

A Dynamics iOS app typically includes:
- Dynamics runtime initialization and authorization (`GDiOS`)
- Secure storage (filesystem via `GDFileManager`, Core Data via
  `GDPersistentStoreCoordinator`, SQLite via `sqlite3enc`)
- Secure networking (`GDURLLoadingSystem`, `GDSocket`, secure `NSURLSession`)
- Optional secure WebView (`WKWebView+GDNET`)
- Optional AppKinetics inter-container communication (`GDService`/`GDServiceClient`)
- Data Leakage Prevention (DLP) for pasteboard (`GDNativePasteboardAccess`)

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
