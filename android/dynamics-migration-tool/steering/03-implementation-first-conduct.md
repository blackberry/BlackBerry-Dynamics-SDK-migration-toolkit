# Steering: Implementation-First Agent Conduct

This steering file defines **how the migration agent should behave** when
it encounters non-waivable findings, security blockers, or complex
migration patterns. The core principle is: **implement first, report only
what remains genuinely unresolvable after exhausting all options.**

---

## The Problem This Solves

Without this guidance, AI agents frequently:

- Flag every non-waivable finding as "requires product/security decision"
- Stop at the first `SECURITY-BLOCKER` instead of implementing the fix
- Report `java.io.File` construction, SharedPreferences, and external
  storage as "blockers that require manual intervention" when the API
  catalog contains direct replacements
- Produce long lists of "remaining findings" instead of migrating code
- Treat the validator as a stop signal rather than a verification tool

A manual developer would not stop at these findings — they would look up
the replacement API and implement it. **The agent must do the same.**

---

## Container-Egress Baseline (MANDATORY)

Implementation-first does **not** mean "preserve every original Android
feature." Features whose purpose is to move protected data outside the
BlackBerry Dynamics secure container are **not** normal migration targets.

For those features, the implementation-first behavior is:

1. **Remove** the unmanaged path when no safe Dynamics equivalent exists.
2. **Replace with Dynamics** only when a documented, explicitly approved
   Dynamics boundary exists (for example ICC/AppKinetics or secure
   clipboard).
3. **Block until approved** when the product capability may remain, but only
   after the original chooser/export/open-with path has been disabled and
   made unreachable.
4. **Flag manual intervention** when enterprise policy, product intent, or a
   destination-specific redesign is required.

Do not spend migration time trying to preserve unmanaged Android backup,
public export, generic share/open-with, unmanaged email, consumer-cloud,
nearby-device, or unmanaged printing behavior. Those are egress decisions,
not normal API migrations.

---

## Pre-Implementation Discipline (MANDATORY before every code change)

"Implement first" does **not** mean "skip the steering and start coding."
It means: once you have read the kit's rule for the domain, do not stall
on findings that the kit already tells you how to fix. Before touching
any source file in a migration prompt, work through this short list
in order:

1. **Name the domain.** Map the call site to one of:
   `authorization | backgroundAuthorize | securePush | secureSql |
   secureFileStorage | secureNetworking | webview | icc |
   secureUiWidgets | secureClipboard | policyManagement | playIntegrity`.
   If you cannot name it, the change does not belong in the current
   prompt.
2. **Read the owning steering file.** The prompt → steering map lives
   in `01-getting-started.md`. Read at least:
   - the domain's main steering file (e.g. `30-secure-networking.md`,
     `40-secure-file-storage.md`, `41-secure-storage-sql.md`,
     `45-secure-ui-widgets.md`, `60-icc-transferfileservice.md`,
     `70-background-authorize.md`),
   - `14-api-provenance-and-replacement-catalog.md` for the exact
     replacement symbol, and
   - `06-inline-migration-comments.md` for the `[BB_DYNAMICS-MIGRATION]`
     comment syntax.
   If you cannot quote the rule that justifies the edit, you have not
   read enough yet.
3. **Prefer kit mechanisms over inventing new ones.** Before writing a
   new helper class, wrapper, or bridge, check `templates/` and the
   domain's steering for an existing solution:
   - SQL → `templates/sql/raw/`, `templates/sql/room-bridge/`
   - SharedPreferences → `SecurePreferencesHelper` pattern in
     `42-secure-storage-sharedpreferences.md`
   - Compose clipboard → `templates/clipboard/GDClipboardAdapter.kt`
   - Compose ICC chooser → `templates/icc/GDICCProviderShareDialog.kt`
   - Stream-layer reads/writes → the `SecureFileIO` helper pattern in
     `40-secure-file-storage.md` §5
   Inventing a parallel abstraction when the kit ships one is a
   regression — it bypasses the validator phases that know about the
   kit's helpers and confuses subsequent prompts.
4. **Make the smallest correct change.** Touch only the files required
   by the call sites in `executionPlan[].callSites[*]` and the
   redesign(s) the steering documents for this domain. Do not reformat,
   restructure, rename, or "improve" adjacent code that the migration
   plan does not call out. Every changed line must trace to one of:
   (a) a call site disposition in `migration-plan-state.json`, (b) a
   documented redesign in the domain's steering file, or (c) an
   unavoidable consequence of (a) or (b) (e.g. an import the IDE removes).
5. **Then implement.** Follow the decision ladder below.

If validation fails after you implement, re-read the steering files
above before changing more code. New findings or unexpected app patterns
also send you back to step 2 — they are evidence that the steering you
consulted was not the right one.

---

## Decision Ladder (MANDATORY for every finding)

When the validator or prompt inventory reports a finding, work through
this ladder **in order**. Only move to the next step when the current
step genuinely does not apply:

### Step 1: Direct API Replacement

Is there a documented Dynamics equivalent in
`14-api-provenance-and-replacement-catalog.md` or the relevant steering?

| Finding | Direct replacement |
|---|---|
| `java.io.File` construction | `com.good.gd.file.File` |
| `java.io.FileInputStream` | `com.good.gd.file.FileInputStream` |
| `java.io.FileOutputStream` | `com.good.gd.file.FileOutputStream` |
| `context.openFileInput()` | `GDFileSystem.openFileInput()` |
| `context.openFileOutput()` | `GDFileSystem.openFileOutput()` |
| `getFilesDir()` in file paths | Container-relative path |
| `getCacheDir()` in file paths | Container-relative path |
| `android.database.sqlite.*` | `com.good.gd.database.sqlite.*` |
| `HttpURLConnection` | `GDHttpClient` or `BBCustomInterceptor` |
| `java.net.Socket` | `com.good.gd.net.GDSocket` |
| Sensitive `SharedPreferences` | `SecurePreferencesHelper` pattern (see `42-secure-storage-sharedpreferences.md`) |
| `EncryptedSharedPreferences` | Remove — redundant inside Dynamics container |
| `android.content.ClipboardManager` | `com.good.gd.content.ClipboardManager` |
| Standard `EditText`/`TextView` | `com.good.gd.widget.*` equivalents |
| Native `fopen`/`open`/etc. | `GD_fopen`/`GD_UNISTD_open`/etc. |

**If a direct replacement exists: implement it now. Do not ask.**

### Step 2: Pattern Redesign

Can the feature be restructured using a documented pattern?

| Finding | Redesign |
|---|---|
| `getExternalFilesDir()` | Remove external path; use container-relative path |
| `getExternalCacheDir()` | Remove external path; use container-relative path |
| `MediaStore` writes | Store in GD container; remove MediaStore insert |
| Public Gallery as index | Build in-container gallery backed by secure storage |
| "Save to SD card" toggle | Remove toggle; use container storage |
| "Export to Downloads" | Remove by default; if the capability might remain, block it pending approval or replace it with a documented Dynamics-safe boundary |
| `File.createTempFile()` | Use in-memory buffers or GD container path |
| Camera capture to public storage | Use `OnImageCapturedCallback` + GD stream |
| `FileProvider` sharing | Remove the generic path; only reintroduce it as targeted ICC after the destination is explicitly approved |

**If a redesign exists: implement it now. Briefly tell the developer what
you changed. Do not wait for approval unless there is a genuine
product-level ambiguity (two viable redesigns with different UX).**

### Step 3: Feature Removal

Can the public-storage feature be removed entirely?

Features that fundamentally conflict with the Dynamics container model
should be removed without asking:

- "Save to device" / "Export to public Downloads"
- "Share to Gallery" / MediaStore auto-registration
- "Cache to /sdcard" / external cache
- Automatic backup to unmanaged public locations
- Generic share sheet / open-with flows that are not replaced with Dynamics ICC
- Unmanaged email attachment, messaging, nearby-share, and consumer-cloud export
- Direct Android printing through unmanaged print services

**Remove the UI toggle, the writer, and the supporting code. Collapse
`if (useExternalStorage)` branches to the internal path.**

### Step 4: Partial Migration with Residual Risk

If the platform API genuinely requires a native file descriptor (e.g.,
`MediaRecorder.setOutputFile`) and no container-safe alternative exists:

1. Implement the best available safe workaround
2. Document the residual risk in `manualTodos[]` with `severity: "P1"` and
   the appropriate `blocking` value
3. Do not add a final `migration-plan-state.json` disposition until the
   call site is resolved, removed, or the developer defers the whole domain
4. **Continue to the next call site and the next prompt**

### Step 5: True Blocker (LAST RESORT)

Only after exhausting steps 1–4:

1. Record the specific call site in `manualTodos[]`
2. Explain what was attempted and why it didn't work
3. **Continue the migration.** A single true blocker in one domain does
   not block work in other domains.

---

## What You Must NEVER Do

- **NEVER** report "this migration is blocked by non-waivable findings
  that require product/security decisions" as your conclusion when the
  API catalog contains direct replacements for those findings.
- **NEVER** stop at `java.io.File` construction findings — replace them
  with `com.good.gd.file.File`.
- **NEVER** stop at SharedPreferences findings — implement the
  `SecurePreferencesHelper` pattern.
- **NEVER** stop at external storage findings without first trying to
  migrate to container paths or remove the feature.
- **NEVER** treat one unresolved domain as a reason to skip all
  remaining domains.
- **NEVER** produce a summary of "remaining findings" without first
  attempting to fix each one.
- **NEVER** describe your output as a "report" when the user asked you
  to perform a migration. Reports list problems. Migrations fix them.
- **NEVER** invent a new helper, wrapper, or bridge when `templates/` or
  the domain's steering already ships one. Use the kit's mechanism —
  validators and report generators know about it; your invented one is
  invisible to them.
- **NEVER** modify, refactor, rename, or reformat code that is not
  required by the migration plan. The migration is the request; "while
  I'm in here" edits dilute the diff and break the per-call-site
  closure model.
- **NEVER** declare a domain closed because the project builds. A green
  `assembleDebug` proves nothing about migration coverage. Closure is
  call-site disposition + scoped validator phases + recorder gate.

---

## When to Ask the Developer

Ask **only** when:

1. **UEM/entitlement values** are needed (GDApplicationID, etc.) — these
   are captured in `00pre-bootstrap.md` and must come from the developer.
2. **Genuine product-level ambiguity** exists: e.g., a feature could be
   either removed entirely or redesigned with different UX, and both
   options are viable. Present the two options and ask which to
   implement.
3. **A blocked non-ICC egress capability needs explicit developer approval**
   before it can return. Example: a removed SAF outbound export path can only
   come back once the developer approves a DLP-gated export design.
4. **The API catalog has no entry** and the installed SDK headers/docs do
   not document a replacement. In this case, do not invent an API — ask.

Do **NOT** ask when:

- The API catalog has a documented replacement — just use it
- The pattern is "remove public storage feature" — just remove it
- The pattern is "replace `java.io.File` with `com.good.gd.file.File`" —
  just replace it
- The pattern is "strip unmanaged backup/share/export/print behavior and
  record it as removed or blocked" — just do it per
  `13-unsupported-feature-detection-matrix.md`
- The validator reports a finding that has a documented fix — fix it

---

## Continuation Principle

The migration has many domains: authorization, SQL, file storage,
networking, UI widgets, ICC, etc. An unresolved finding in one domain
does **not** block progress in unrelated domains:

- SharedPreferences findings remaining? Continue to networking.
- One FD-only media writer unresolved? Continue to UI widgets.
- External storage removal incomplete? Continue to ICC.

The only hard gates are:

- Prompt `10` is the only hard validation gate; open `secureFileStorage`
  work still blocks final acceptance even if intermediate prompts were
  recorded
- Prompt 10 requires all applicable domains to have either a completed
  prompt or a developer-signed-off deferral

For the `requires[]` gates, focus on resolving as many findings as
possible in each domain before moving on. Record remaining items in
`manualTodos[]` and proceed.

---

## No-Edit Re-Run Discipline

Do not re-run the same validation gate without code or state changes.

- If `validate.sh` fails and your next command is the same `validate.sh`
  invocation, you are creating a no-edit re-run.
- Before each retry, make at least one concrete remediation change tied to
  the reported owner prompt/domain and record it with
  `[BB_DYNAMICS-MIGRATION]`.
- If source/report gates keep failing with the same signature and the toolkit
  emits `ESCALATION REQUIRED` (exit code `3`), stop and move to targeted owner
  prompt repair; do not continue blind prompt-10 sweeps.
