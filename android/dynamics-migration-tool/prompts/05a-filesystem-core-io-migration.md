## Task: Secure Filesystem Migration 05a (Core I/O)

Goal: Migrate core sensitive file I/O writers/readers to Dynamics secure APIs.

**Prerequisite**: Authorization (prompt 03) and deferral audit (prompt 03b)
must be complete. File access requires the container to be unlocked
via `onAuthorized()`.

**Module map context**: Load
`dynamics-migration-tool/output/module-map.json` and resolve
`${in_scope_main_src}` (every primary + library `src/main/java` and
`src/main/kotlin`). Filesystem writers and readers commonly live in
shared `core/data` or `feature/<x>/data` library modules; every
search and audit in this prompt scans the full set, not just the
primary application module. If `module-map.json` is missing, STOP
and re-run `00pre-bootstrap.md`.

---

## Steps

### 0. SDK Class Availability (consult bootstrap)

Confirm these are `"found"` in `dynamics-migration-tool/output/bootstrap.json` `sdkClassIndex`:

- `com.good.gd.file.GDFileSystem`
- `com.good.gd.file.FileInputStream`
- `com.good.gd.file.FileOutputStream`

If missing, STOP and re-run `00pre-bootstrap.md`.

### 0b. Enumerate Egress Features Owned by Prompt 05a

Before editing code, read `migration-analysis.json` and list every
`egressFeatures[]` entry whose `ownerPrompt` is `05a`. These are the feature-
level backup/export/public-storage/media-containment capabilities that this
prompt must strip, block, or redesign. Do **not** treat them as incidental
storage details.

```bash
python3 - dynamics-migration-tool/output/migration-analysis.json <<'PY'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))
for feat in a.get("egressFeatures", []):
    if feat.get("ownerPrompt") == "05a":
        print(
            f"id={feat.get('id')!r} outcome={feat.get('recommendedOutcome')!r} "
            f"feature={feat.get('featureName')!r} target={feat.get('targetMechanism')!r}"
        )
PY
```

After you strip, replace, block, or flag the feature, write a matching
`egressFeatureDecisions[]` entry in `migration-plan-state.json`:

```json
{
  "featureId": "egress-export-downloads-001",
  "domain": "secureFileStorage",
  "outcome": "REMOVE",
  "module": "app",
  "note": "Export-to-Downloads UI, writer, temp-file staging, and manifest/storage affordances removed.",
  "secureAlternative": null,
  "uiDisposition": "removed",
  "codePathReachable": false
}
```

Use:

- `REMOVE` for stripped backup/export/public-storage/media-publish features
- `BLOCKED_UNTIL_APPROVED` when the UI stays visible but disabled and the
  underlying outbound path is unreachable
- `REPLACE_WITH_DYNAMICS` only when the original Android path is gone and the
  feature now uses a documented Dynamics-safe boundary
- `MANUAL_INTERVENTION_REQUIRED` when the product/policy decision is being
  carried forward without preserving the original Android path

### 1. Inventory Core File I/O Call Sites

Search for:

- `java.io.File`, `java.io.FileInputStream`, `java.io.FileOutputStream`
- `Context.openFileInput()`, `Context.openFileOutput()`
- `getFilesDir()`, `getCacheDir()`, external storage APIs
- `File.createTempFile()`

> **SECURITY BLOCKER — external storage is non-waivable. IMPLEMENT THE FIX.**
>
> While inventorying, separately track any hit for:
>
> - `Environment.getExternalStorageDirectory` / `getExternalStoragePublicDirectory`
> - `Context.getExternalFilesDir` / `getExternalFilesDirs` / `getExternalCacheDir` / `getExternalMediaDirs`
> - `Environment.DIRECTORY_DOWNLOADS / PICTURES / DOCUMENTS / MOVIES / MUSIC / DCIM / ...`
> - `MediaStore.{Images,Video,Audio,Downloads,Files,Documents}` writes via `ContentResolver.insert / update / delete`
>   or `MediaStore.createWriteRequest / createDeleteRequest / createTrashRequest`
> - `ContentResolver.openOutputStream(...)` when the target URI comes from `MediaStore`, `ACTION_CREATE_DOCUMENT`,
>   `ACTION_OPEN_DOCUMENT_TREE`, or caller-provided `MediaStore.EXTRA_OUTPUT`
> - `MediaScannerConnection`
> - raw `java.io.File("/sdcard/...")`, `"/storage/emulated/..."`, `"/mnt/sdcard/..."`,
>   `"/storage/<vol>/{Download,Downloads,Pictures,Documents,DCIM,Movies,Music}/..."`
> - `ACTION_OPEN_DOCUMENT_TREE` / `DocumentFile.fromTreeUri` / `takePersistableUriPermission`
> - `ACTION_IMAGE_CAPTURE` / `ACTION_VIDEO_CAPTURE` / `IMAGE_CAPTURE_SECURE`
> - `MediaStore.EXTRA_OUTPUT` or caller-provided output URI handling
> - `MediaRecorder.setOutputFile(...)` / `setNextOutputFile(...)`
> - `getCacheDir()` / `getFilesDir()` staging for photos, videos, thumbnails, gallery exports, or camera output
>
> Every one of these is a **SECURITY BLOCKER**. Application data written
> through them leaves the Dynamics secure container: it is unencrypted,
> included in device backups, accessible to any app with the relevant
> scoped-storage permission, visible over USB, and not cleared by remote
> container wipe. This breaks the Dynamics data-at-rest contract.
>
> Treat the **feature** and the **call site** separately:
>
> - `dispositions[]` closes the underlying API call site(s)
> - `egressFeatureDecisions[]` records the product-level outcome for the
>   backup/export/public-storage capability itself
>
> This prompt is not successful until both are recorded consistently.
>
> **Your job is to FIX these, not to flag them and stop.** A manual
> developer would not pause the project when they find
> `getExternalFilesDir()` — they would replace it. You must do the same.
>
> **IMMEDIATELY resolve** each external-storage call-site by applying,
> in order of preference:
>
> 1. **Migrate to a container path** — replace with
>    `com.good.gd.file.File` rooted in the GD container (see catalog
>    rows `fs-java-ext-001` and `fs-java-ext-002` in
>    `steering/14-api-provenance-and-replacement-catalog.md`).
>    For example:
>    - `context.getExternalFilesDir(null)` → container-relative path
>      via `com.good.gd.file.File`
>    - `Environment.getExternalStorageDirectory()` → remove and use
>      container-relative path
>    - `MediaStore` writes → store in container, remove MediaStore
>      insert
> 2. **Remove or block the feature with explicit product follow-up** — "Save to SD card" / "Export to public
>    Downloads" / "Cache to /sdcard/.../thumbs" affordances are
>    typically obsolete after migration. Delete the toggle, the UI
>    setting, and the writer; collapse any `if (useExternalStorage)`
>    branch to the internal path. **Do the secure removal/block
>    immediately**, but still persist the functional impact as a SAF
>    `safDecision` and prompt-10 blocker TODO when the removed path was
>    user-visible. The developer is not being asked for permission to
>    leave data insecure; they are being asked whether the lost
>    export/save capability is acceptable.
> 3. **Block the outbound path and request developer approval** — when
>    the call site powers a genuinely user-initiated export of a single
>    document and neither container migration nor feature removal is
>    appropriate, apply the SAF outbound export protocol from
>    `steering/44-saf-trust-boundary.md` §1b:
>
>    a. **Immediately disable the UI action** that triggers the export.
>       Preferred: set the action `isEnabled = false` with an
>       explanatory label. Acceptable: convert to a safe no-op that
>       displays "Export is unavailable in the secured application."
>    b. **Remove the unsafe outbound implementation from production
>       source where practical.** Delete `ACTION_CREATE_DOCUMENT`,
>       `ContentResolver.openOutputStream`, picker launches, URI
>       grants, and external intent construction — do not leave them
>       behind the disabled UI. Deleting the unapproved outbound
>       implementation is the strongest security posture. When full
>       deletion is impractical (e.g. shared utility method used by
>       both approved and unapproved flows), place the code behind a
>       **fail-closed, persisted approval gate** and verify that no
>       UI action, deep link, background component, worker, service,
>       broadcast receiver, saved callback, or alternate navigation
>       path can invoke it without the approved decision and a
>       runtime DLP check. The static validator (Phase 4N) must find
>       zero unapproved outbound SAF patterns after this step;
>       guarded-but-present code without DLP enforcement still
>       triggers the scanner.
>    c. **Record the call site in `migration-plan-state.json`
>       `dispositions[]`** with the existing schema shape:
>       ```json
>       {
>         "callSiteId": "<id from migration-analysis.json callSites[]>",
>         "domain": "secureFileStorage",
>         "status": "removed",
>         "module": "<module>",
>         "note": "SAF_OUTBOUND_EXPORT | ACTION_CREATE_DOCUMENT | BLOCKED_PENDING_DEVELOPER_APPROVAL | uiDisabled | codePathRemoved",
>         "safDecision": {
>           "classification": "SAF_OUTBOUND_EXPORT",
>           "direction": "outbound",
>           "migrationDecision": "BLOCKED_PENDING_DEVELOPER_APPROVAL",
>           "developerApprovalRequested": true,
>           "developerDecision": null,
>           "decisionTimestamp": null,
>           "uiEntryPoint": "<button/menu/deep-link name>",
>           "targetMechanism": "ACTION_CREATE_DOCUMENT",
>           "runtimeDlpEnforced": false,
>           "outboundCodeReachable": false,
>           "uiDisposition": "disabled",
>           "plaintextStagingRemoved": true
>         }
>       }
>       ```
>       Use `"status": "removed"` because the SAF API call sites
>       (picker, output stream, intent, URI grants) are deleted from
>       the source. The disabled UI entry point remains but is a safe
>       no-op — the underlying export capability no longer exists.
>    c2. **Persist the blocker for prompt 10.** The final report does
>       not exist yet, so do **not** pretend to append to
>       `manualTodos[]` in this prompt. Instead, the `safDecision`
>       object above is the durable source of truth. Prompt 10 must
>       expand every `BLOCKED_PENDING_DEVELOPER_APPROVAL` SAF decision
>       into a `manualTodos[]` entry with `blocking: true`:
>       ```json
>       {
>         "severity": "P0",
>         "blocking": true,
>         "title": "SAF outbound export blocked — [feature name]",
>         "description": "SAF outbound export blocked — [feature name]: the export UI is disabled and the underlying ACTION_CREATE_DOCUMENT / openOutputStream code path has been deleted. The application is currently secure; no data-exfiltration path exists. The pending issue is a PRODUCT DECISION, not a security gap: the developer must decide whether the feature should (a) remain permanently blocked, (b) be replaced with AppKinetics ICC, or (c) be re-enabled with runtime Dynamics outbound DLP enforcement.",
>         "reason": "Blocked pending explicit developer approval — see steering/44-saf-trust-boundary.md §1b"
>       }
>       ```
>       This blocker TODO ensures the developer reviews the
>       functional impact of the disabled feature even though the
>       application is in a secure state.
>    d. **Ask the developer explicitly:**
>       "This feature exports data from the Dynamics secure container
>       to an external document provider. The exported copy will no
>       longer be protected by Dynamics secure storage. Should this
>       feature remain blocked, be replaced with AppKinetics ICC, or
>       be explicitly enabled subject to Dynamics outbound DLP policy?"
>    e. **If the developer approves** (`ALLOW_WITH_DLP_ENFORCEMENT`):
>       the decision must be persisted in `migration-plan-state.json`
>       `dispositions[].safDecision` (and summarized in `note`) before
>       any export code is written. A free-text `developerApproved`
>       token in `note` alone is not sufficient. Then implement the export with
>       **all** of the following, in order:
>
>       1. **DLP check before picker** — verify the SDK policy API, then
>          check DLP before picker launch. Specifically:
>          first confirm the exact policy accessor, key name, value type,
>          and default semantics against the locally resolved Dynamics SDK
>          and `steering/44-saf-trust-boundary.md`. If the canonical DLP
>          API/key cannot be verified, fail closed and leave the export
>          blocked. After verification, query the policy before launching
>          `ACTION_CREATE_DOCUMENT` or constructing any external URI.
>          If the policy prohibits outbound transfer, show a
>          user-facing message and return. Never launch the picker
>          first and check policy after.
>       2. **Fail closed** — if the policy key is absent or
>          unparseable, treat it as denied. Do not default to
>          allowing the export.
>       3. **Direct secure stream** — stream bytes from
>          `com.good.gd.file.FileInputStream(containerPath)` directly
>          to `ContentResolver.openOutputStream(uri)`. No plaintext
>          intermediate files, no `File.createTempFile`, no
>          `cacheDir` / `filesDir` staging.
>       4. **Minimal buffer lifetime** — close and clear both streams
>          in `finally` / `use` blocks. Minimise the window during
>          which plaintext bytes exist in memory buffers.
>       5. **No broad URI permissions** — do not call
>          `takePersistableUriPermission` for an export URI. Do not
>          grant `FLAG_GRANT_WRITE_URI_PERMISSION` back to callers.
>       6. **Disposition update** — change the call-site disposition
>          `status` from `"removed"` to `"migrated"`, keep
>          `domain: "secureFileStorage"`, update `note` to
>          `"SAF_OUTBOUND_EXPORT | ALLOW_WITH_DLP_ENFORCEMENT |
>          developerApproved | dlpGated"`, and update `safDecision` to
>          `migrationDecision: "ALLOW_WITH_DLP_ENFORCEMENT"`,
>          `developerDecision: "ALLOW_WITH_DLP_ENFORCEMENT"`,
>          `runtimeDlpEnforced: true`, and `outboundCodeReachable: true`.
>
>       See `steering/44-saf-trust-boundary.md` §3 for the full
>       implementation pattern.
>    f. **If the developer chooses ICC**: replace with AppKinetics
>       TransferFile (`GDServiceClient.sendTo`, catalog `icc-java-001`).
>       Update the disposition `note` accordingly.
>    g. **If no response is received**: the finding remains `BLOCK`.
>       The disabled UI and deleted export code are the shipped
>       behaviour. Do NOT re-interpret silence as consent, do NOT
>       implement the export speculatively, and do NOT infer approval
>       from the app's pre-migration behaviour, from the absence of a
>       deny policy, or from the fact that DLP may be currently
>       disabled. The `manualTodos[]` blocker entry from step c2
>       remains: the developer must explicitly address the product
>       decision before the feature can be unblocked.
>    h. **Do NOT write `safFindings[]` to `migration-plan-state.json`.**
>       `safFindings[]` is a **report-only** section generated by
>       prompt 10 from `dispositions[].safDecision`. It does not exist as
>       an interim artifact.
>       See `steering/80-migration-report-schema.md` §safFindings.
>
>    **The default for any outbound SAF operation is BLOCKED.** Do not
>    infer approval from existing app behaviour, from the fact that
>    DLP is currently disabled, or from the absence of a deny policy.
>    Developer silence is denial.
>
> Deferral is **NOT** an option:
>
> - `externalStorage` is on the non-waivable domain list in
>   `tooling/validate.sh`. Phase 4 raises
>   `[SECURITY-BLOCKER][externalStorage/api-surface]` regardless of
>   any `deferredDomains[]` entry.
> - Phase 0 of the validator rejects any attempt to add
>   `externalStorage` to `bootstrap.json.deferredDomains[]`.
> - Phase 10 does **not** subtract external-storage hits from the
>   "Standard APIs remaining" total even when `secureFileStorage` is
>   deferred (earlier toolkit versions allowed MediaStore /
>   external-storage writes to slip past Phase 10 when
>   `secureFileStorage` was deferred — that path is now intentionally
>   blocked).
> - Adding `[BB_DYNAMICS-MIGRATION]` audit markers does NOT silence
>   `security_blocker` — the marker is audit-only and the line still
>   counts.
>
> **Mandatory action sequence for every external-storage finding:**
>
> 1. Identify the user-visible feature the call site powers.
> 2. Classify the direction: is data flowing **into** the container
>    (inbound import — safe to migrate immediately) or **out of** the
>    container (outbound export — requires developer approval)?
> 3. Determine the best fix:
>    - **Options 1 and 2** (container migration or feature removal):
>      **Implement now.** Do not pause to ask. These are inherently safe
>      because data stays inside or is removed entirely. If the fix
>      requires a larger redesign (e.g., replacing a public gallery
>      with an in-container gallery), implement the redesign using
>      the patterns from `steering/40-secure-file-storage.md` §7.
>    - **Option 3** (outbound export boundary): **Block now, ask
>      later.** Disable the UI, remove the reachable export code path,
>      record the finding, and ask the developer. Do NOT implement
>      `ACTION_CREATE_DOCUMENT` or `openOutputStream` to an external
>      URI without explicit developer approval. The default is BLOCKED.
> 4. Re-run scoped validation to confirm:
>    - Options 1/2: the call site no longer appears in Phase 4.
>    - Option 3 blocked state: the source scanner no longer reports
>      `saf-outbound-export` because the outbound code path is deleted
>      or unreachable. The finding still appears in the SAF report
>      ledger through `dispositions[].safDecision`.
> 5. Only if a specific call site genuinely has **no cataloged API
>    replacement, no feasible redesign, AND no safe blocking pattern**
>    (e.g., `MediaRecorder` requiring a native FD with no
>    container-safe alternative), record it in `manualTodos[]` and
>    **continue** to the next call site. Do not abandon the entire
>    prompt for one unresolved site.
>
> **NEVER** report "this migration is blocked by non-waivable findings
> that require product/security decisions" as your conclusion. That is
> not a migration — that is a report. You are here to implement the
> migration. For options 1 and 2, implement. For option 3, implement
> the **block** — a correctly disabled export path IS a valid
> migration outcome when recorded and awaiting developer decision.

> **Camera/media redesign rule — IMPLEMENT this, do not just plan it:**
>
> For camera or gallery apps, do not preserve public Gallery / MediaStore
> behavior as proof of migration success. **Implement** these changes:
>
> 1. **Managed in-container gallery** — store photos/videos/thumbnails and
>    metadata inside the Dynamics container, render previews from the
>    secure index, and remove public Gallery as the source of truth.
>    **Do this now** — create the container-backed storage, update the
>    data layer, and remove MediaStore writes.
> 2. **Direct secure streaming** — use `InputStream`, bounded memory
>    buffers, or `OutputStream` overloads to write directly into
>    `com.good.gd.file.*` paths. Replace `File`-based capture with
>    stream-based capture.
> 3. **Controlled export only** — block all outbound export paths by
>    default. Remove automatic public-storage writes. Any future
>    export must follow the SAF outbound protocol (option 3 above):
>    blocked until explicit developer approval, then DLP-gated at
>    runtime. Do not implement the export path during this prompt
>    unless the developer has already approved it.
>
> Do **not** use app-private cache, app-private files dir, or temp-file
> staging as the default workaround for sensitive media.
>
> **A manual developer would implement these changes, not report them.
> You must do the same.**

> **SAF TRUST-BOUNDARY DETECTION (mandatory alongside external-storage audit):**
>
> While inventorying, also search for these SAF and content-URI patterns.
> These are trust-boundary crossings, not ordinary file operations.
> Full contract: `steering/44-saf-trust-boundary.md`.
>
> Detection patterns (in addition to the external-storage signals above):
>
> - `ACTION_OPEN_DOCUMENT` / `ACTION_GET_CONTENT` / `ACTION_PICK`
> - `ActivityResultContracts.OpenDocument` / `GetContent` / `OpenMultipleDocuments` / `GetMultipleContents`
> - `ActivityResultContracts.CreateDocument` / `OpenDocumentTree`
> - `ContentResolver.openInputStream` / `openOutputStream` / `openFileDescriptor`
> - `FLAG_GRANT_READ_URI_PERMISSION` / `FLAG_GRANT_WRITE_URI_PERMISSION`
> - `ClipData.newUri` / `Intent.setClipData` with content URIs
> - Persisted `content://` strings in databases or preferences
>
> **Direction determines action:**
>
> - **Outbound export** (`SAF_OUTBOUND_EXPORT`, such as
>   `ACTION_CREATE_DOCUMENT` / `ContentResolver.openOutputStream`):
>   owned by this prompt. Follow option 3 above — block immediately,
>   ask developer, implement only after approval with verified DLP. Do
>   not implement the export proactively.
> - **URI sharing / file-open egress** (`SAF_URI_SHARING`, such as
>   `ACTION_SEND`, `ACTION_VIEW`, `EXTRA_STREAM`, URI grants, and
>   `FileProvider`): owned by prompt `08`. In this prompt, remove any
>   plaintext staging or public-storage producer that feeds the share
>   flow, but record the egress call site for ICC handling rather than
>   approving generic URI sharing here.
> - **External primary storage** (`SAF_EXTERNAL_PRIMARY_STORAGE`):
>   follow option 1 — replace with container-backed repository.
>   Non-waivable; implement immediately.
> - **Inbound import** (`SAF_INBOUND_IMPORT`): implement the secure
>   copy immediately — this is safe and does not require developer
>   approval:
>   1. `ContentResolver.openInputStream(uri)` →
>      `com.good.gd.file.FileOutputStream(containerPath)`.
>   2. Do not stage through `cacheDir`, `filesDir`, or temp files.
>   3. Validate file type and size.
>   4. Close all streams safely.
>   5. Record in `migration-plan-state.json` `dispositions[]` with
>      `domain: "secureFileStorage"`, `status: "migrated"`, `note`
>      including `SAF_INBOUND_IMPORT`, and a `safDecision` with
>      `migrationDecision: "MIGRATE_SECURE_COPY"`.
> - **Plaintext staging** (`SAF_PLAINTEXT_STAGING`): eliminate. Use
>   in-memory streams or GD-backed secure temp. Non-negotiable.

Then extend the inventory with the full **stream-layer anti-pattern list**
from `steering/40-secure-file-storage.md` §5. These compile cleanly against
either `java.io.File` or `com.good.gd.file.File` and silently bypass the
secure container:

- Kotlin `kotlin.io.*` extensions on any `File` receiver: `writeText`,
  `readText`, `appendText`, `writeBytes`, `readBytes`, `appendBytes`,
  `forEachLine`, `readLines`, `useLines`, `bufferedReader()`,
  `bufferedWriter()`, `printWriter()`, `inputStream()`, `outputStream()`,
  `copyTo`, `copyRecursively`, `deleteRecursively`.
- JDK helpers: `java.nio.file.Files.{readAllBytes, write, newInputStream,
  newOutputStream, newBufferedReader, newBufferedWriter, lines,
  readString, writeString}`, `FileReader(File|String)`,
  `FileWriter(File|String)`, `PrintWriter(File|String)`, `Scanner(File)`,
  `RandomAccessFile(File|String, ...)` against container paths.
- Image / serialization sinks bound to a path: `BitmapFactory.decodeFile`,
  `Bitmap.compress(..., new FileOutputStream(...))`, `ObjectInputStream` /
  `ObjectOutputStream` over `java.io.File*Stream`,
  `Properties.load(FileInputStream)`, `ZipFile(File|String)` over a
  container path.

### 1a. Stream-Layer Audit (mandatory)

For every call site touching a sensitive (`secureFileStorage`) domain,
record both:

1. The **`File` type** in scope at that call site (GD vs `java.io`), and
2. The **stream/helper** actually used to open the byte stream
   (`com.good.gd.file.FileInputStream` / `FileOutputStream` /
   `GDFileSystem.openFileX` / `SecureFileIO.*`, vs any of the anti-patterns
   above).

Closure requires **both** to be secure. A site whose `File` type is
`com.good.gd.file.File` but whose write goes through `writeText`,
`Files.write`, or `FileWriter` is **not** migrated.

For every Kotlin `File` extension call, record these fields in your closure
notes before marking any call site migrated:

- receiver type (`java.io.File` or `com.good.gd.file.File`)
- unresolved extension call (for example `readText`, `writeBytes`,
  `copyRecursively`, `deleteRecursively`)
- replacement used (`com.good.gd.file.FileInputStream` /
  `FileOutputStream`, `GDFileSystem.openFileX`, or `SecureFileIO.*`)
- status (`migrated` only after extension removal on secure paths)

When recording dispositions in `migration-plan-state.json`
(see step 5), **do not** mark a `secureFileStorage` call site `migrated`
unless its stream layer is also GD-backed. This rule is enforced by
`validate.sh` Phase 4 (stream-layer block) and by
`steering/79-migration-plan-state-and-call-site-closure.md`.

### 1b. Auxiliary-Process Caller Audit (mandatory)

Read `dynamics-migration-tool/output/bootstrap.json` →
`processModel.components[]`. For each component with
`classification: "auxiliary"`:

1. Locate the component's source file in `${in_scope_main_src}`.
2. Trace its call graph (at minimum: `onCreate()`, `onReceive()`,
   `onStartCommand()`, and methods called from them — 1–2 levels deep).
3. For each `java.io.File` call site reachable from that graph:
   - If the utility is **only** reachable from auxiliary processes:
     do NOT migrate to GD APIs and do NOT add a per-call-site
     disposition. Record the auxiliary-only rationale in the prompt
     output and, if prompt 00 incorrectly put the call site in the
     `secureFileStorage` worklist, re-run/fix prompt 00 so the binding
     worklist excludes it. `not-applicable` is not a valid disposition
     status.
   - If the utility is reachable from **both** main and auxiliary
     processes (shared logging, crash reporting, file helpers): add an
     `isContainerAuthorized` guard with standard-API fallback, OR split
     into two implementations (GD-secured for main, standard for
     auxiliary). See `steering/22-multi-process-app-handling.md` §Shared
     Code for guard patterns.

**Why this matters:** Auxiliary processes never receive `onAuthorized()`.
Any `com.good.gd.file.File` construction or GD stream creation in an
auxiliary process throws `GDNotAuthorizedError` — a guaranteed runtime
crash. This is especially dangerous for crash-handler Activities (e.g.
`ErrorActivity` in a `:error_activity` process) because the crash handler
itself crashes, creating an unrecoverable death loop.

**`DocumentFile.fromFile()` trap:** Even in the main process, do NOT wrap
`com.good.gd.file.File` instances with `DocumentFile.fromFile()`. GD
container-relative paths (e.g. `"/logs"`) produce invalid `file://` URIs
that `ContentResolver` cannot resolve. Use direct GD
`FileInputStream`/`FileOutputStream` instead.

If `processModel` is missing or empty, scan `AndroidManifest.xml` for
`android:process=` declarations and classify components manually using the
rules in `steering/22-multi-process-app-handling.md`.

### 2. Classify Data Sensitivity

For each call site classify:

- **Sensitive** -> MUST migrate now
- **Semi-sensitive** -> SHOULD migrate now
- **Non-sensitive** -> MAY remain native only with explicit justification

Non-sensitive native-storage exceptions never apply to public storage,
external storage, SAF outbound transfer, URI sharing, FileProvider
exposure, MediaStore writes, URI permission grants, or plaintext staging
of enterprise data. Those surfaces cross the Dynamics trust boundary and
must be migrated, removed, blocked pending decision, or owned by prompt
`08` for ICC.

### 3. Remove Temp/Plaintext Leakage Patterns (Mandatory)

Disallow container-bound file flows from writing plaintext to the Android filesystem:

- `File.createTempFile(...)`
- write-temp-then-copy into secure container
- CameraX `OutputFileOptions.Builder(File)` for container-bound capture
- Bitmap/EXIF file-based intermediate writes for container-backed media
- `MediaRecorder.setOutputFile(...)` / `setNextOutputFile(...)` to normal Android filesystem paths
- accepting caller `MediaStore.EXTRA_OUTPUT` and writing capture bytes to that URI
- restoring public Gallery / MediaStore as the canonical gallery for app-owned managed media

Use in-memory or secure stream alternatives:

- `ImageCapture.OnImageCapturedCallback` + in-memory bytes
- `OutputFileOptions.Builder(OutputStream)` with secure stream
- `byte[]`/`InputStream` processing pipeline
- in-container media index + in-app gallery/grid/list backed by secure storage
- thumbnail generation in memory, then secure output stream write
- import via `ContentResolver.openInputStream(...)` into secure storage
- explicit controlled export only after secure persistence, never automatic public persistence

#### Library-consumed `File` arguments — migration sub-table

| Before | After |
|---|---|
| `new ImageCapture.OutputFileOptions.Builder(file)` (any `File` type) | `new ImageCapture.OutputFileOptions.Builder(outputStream)` with `outputStream = new com.good.gd.file.FileOutputStream(<container-relative-path>)`, or `OnImageCapturedCallback` for EXIF |
| `new java.util.zip.ZipFile(file or path)` | `new java.util.zip.ZipInputStream(new com.good.gd.file.FileInputStream(path))` for read; `ZipOutputStream` wrapping `com.good.gd.file.FileOutputStream` for write |
| `new androidx.exifinterface.media.ExifInterface(file)` (read) | `new ExifInterface(new com.good.gd.file.FileInputStream(<container-relative-path>))` |
| `new androidx.exifinterface.media.ExifInterface(file)` + `saveAttributes()` (write) | Decode through GD `FileInputStream`, modify, re-encode through GD `FileOutputStream`. **No in-place EXIF write is supported.** |
| `new android.media.MediaMuxer(file or path, format)` | `new MediaMuxer(fd, format)` where `fd` is a `FileDescriptor` obtained from a GD-backed source. If unavailable, STOP and mark manual intervention / no-go rather than introducing filesystem staging. |
| `ParcelFileDescriptor.open(file, mode)` used by `PdfRenderer` | Render via `ParcelFileDescriptor.createPipe()` or `MemoryFile` fed from a `com.good.gd.file.FileInputStream`. |
| `mediaRecorder.setOutputFile(path/file)` / `setNextOutputFile(path/file)` | Prefer redesign to in-memory/direct-secure-stream capture. If the platform writer truly requires unmanaged path or seekable filesystem output and no approved direct-secure pattern exists, STOP and mark manual intervention / no-go. Do **not** introduce cache/files-dir staging as the default workaround. |

#### FD-only media writer decision (mandatory for MediaRecorder / MediaMuxer)

If `MediaRecorder`, `MediaMuxer`, or another file-descriptor-only API
remains after migration, do **NOT** mark the call site `migrated` just
because public storage is gone. Apply this decision tree:

1. **Container-safe descriptor path exists?** (e.g.,
   `ParcelFileDescriptor.createPipe()` backed by a GD stream, or a
   codec that accepts `OutputStream` directly) → use it, mark `migrated`.

2. **No container-safe path — redesign feasible?** (e.g., replace
   `MediaRecorder` with an in-memory codec, or chunk capture into a GD
   `FileOutputStream`) → redesign, mark `migrated`.

3. **No container-safe path, no feasible redesign?** The call site
   remains unresolved after the redesign attempt. You **MUST**:
   - **not** mark the call site `migrated` or `removed`,
   - record the blocked API and affected feature in existing
     `migration-analysis.json` rationale text or
     `migration-plan-state.json` notes if you touched those artifacts,
   - add a `manualTodos[]` entry with `severity: "P1"`, `blocking: true`,
     and a title describing the specific blocked API and the affected feature,
   - **continue to the next call site and subsequent prompts**. A
     single unresolved FD-only media writer does not block
     SharedPreferences migration, networking migration, UI widget
     migration, or any other domain. Complete as much of the
     migration as possible.

   `filesDir`/`cacheDir`/`openFileOutput()` staging is **not** an
   accepted default migration outcome. It is a runtime workaround
   that leaves media unencrypted during the staging window and must be
   surfaced as residual risk. `validate.sh` Phase 4 rule 4I flags
   sandbox-sourced FD provenance; `PRIVATE_SANDBOX_STAGING_HITS` flags
   the staging pattern itself.

Changing the static type of the argument from `java.io.File` to
`com.good.gd.file.File` is **not** a migration. The library constructs a
`java.io` stream internally; the static type of the argument is
irrelevant.

### 3a. listFiles() / list() Guard (Mandatory)

After migrating `java.io.File` → `com.good.gd.file.File`, audit ALL `listFiles()` and
`list()` call sites. For each:

1. Verify the directory is guaranteed to exist at that call point (e.g., `mkdirs()` was
   called earlier in the same method or in the constructor)
2. If existence is NOT guaranteed, add `if (!dir.exists()) return` (or equivalent guard)
   BEFORE the `listFiles()` / `list()` call

**Why:** `com.good.gd.file.File.listFiles()` throws NPE internally (in the native layer
via `FileImpl.cwgjn`) for non-existent directories. Unlike `java.io.File.listFiles()`
which returns `null`, the GD SDK crashes. The Kotlin `?.` safe-call operator does NOT
protect against this because the exception is thrown inside the method, not as a null
return value.

**Pattern — BEFORE (unsafe after migration):**
```kotlin
val pdfDir = com.good.gd.file.File("cache/pdfs")
pdfDir.listFiles()?.forEach { it.delete() }  // CRASHES if cache/pdfs doesn't exist
```

**Pattern — AFTER (safe):**
```kotlin
val pdfDir = com.good.gd.file.File("cache/pdfs")
if (!pdfDir.exists()) return
pdfDir.listFiles()?.forEach { it.delete() }
```

See: `steering/40-secure-file-storage.md` §10 "Known Pitfalls"

### 4. Migrate Core Sensitive File I/O

Use template: `dynamics-migration-tool/templates/file/SecureFileIO.java` (or `.kt`).

Canonical substitutions:

| Before | After |
|---|---|
| `context.openFileOutput(name, MODE)` | `GDFileSystem.openFileOutput(name, MODE)` |
| `context.openFileInput(name)` | `GDFileSystem.openFileInput(name)` |
| `new java.io.FileOutputStream(path)` | `new com.good.gd.file.FileOutputStream(path)` |
| `new java.io.FileInputStream(path)` | `new com.good.gd.file.FileInputStream(path)` |
| `FileOutputStream(path)` in Kotlin with `import java.io.FileOutputStream` | `FileOutputStream(path)` in Kotlin with `import com.good.gd.file.FileOutputStream` |
| `FileInputStream(path)` in Kotlin with `import java.io.FileInputStream` | `FileInputStream(path)` in Kotlin with `import com.good.gd.file.FileInputStream` |
| `ImageCapture.OutputFileOptions.Builder(file)` | `Builder(outputStream)` with `outputStream = new com.good.gd.file.FileOutputStream(path)`, or `OnImageCapturedCallback` for EXIF |
| `new java.util.zip.ZipFile(file or path)` (read) | `new ZipInputStream(new com.good.gd.file.FileInputStream(path))` |
| `ZipOutputStream(new java.io.FileOutputStream(path))` (write) | `ZipOutputStream(new com.good.gd.file.FileOutputStream(path))` |
| `new ExifInterface(file or path)` (read) | `new ExifInterface(new com.good.gd.file.FileInputStream(path))` |
| `new MediaMuxer(file or path, format)` | `new MediaMuxer(fd, format)` with GD-backed `FileDescriptor` |
| `ParcelFileDescriptor.open(file, mode)` for `PdfRenderer` | `ParcelFileDescriptor.createPipe()` or `MemoryFile` fed from GD `FileInputStream` |

Path semantics:

- GD stream constructors must use container-relative paths.
- Do not pass `/data/...`, `File#getAbsolutePath()`, `getFilesDir()`, or `getCacheDir()` derived absolute paths to GD streams.
- Do **not** invent `GDFileSystem.mkdirs(...)`, `GDFileSystem.exists(...)`, or similar static helpers to satisfy validator findings. For directory creation and path operations, use `com.good.gd.file.File(...).mkdirs()` and other `File` instance methods instead.

### 4a. Native (NDK / C / C++) file I/O migration

If prompt 00 (step 2b) recorded `secureFileStorage` `callSites[]` with
`language: "C"` or `"C++"`, migrate them here using the canonical
mapping in `steering/14-api-provenance-and-replacement-catalog.md`
"Native (NDK) Direct Replacement Catalog" and the discovery/classification
rules in `steering/40-secure-file-storage.md` §8.

Canonical substitutions (only those documented in the BlackBerry C
Language Programming Interface or confirmed in the installed
`sdk/libs/handheld/libs/gd/inc/` headers):

| Standard C / POSIX | Dynamics C API |
|---|---|
| `fopen` / `fclose` / `fread` / `fwrite` / `fseek` / `ftell` / `fflush` | `GD_fopen` / `GD_fclose` / `GD_fread` / `GD_fwrite` / `GD_fseek` / `GD_ftell` / `GD_fflush` |
| `remove` / `rename` | `GD_remove` / `GD_rename` |
| `open` / `close` / `read` / `write` / `lseek` | `GD_UNISTD_open` / `GD_UNISTD_close` / `GD_UNISTD_read` / `GD_UNISTD_write` / `GD_UNISTD_lseek` |
| `unlink` / `rmdir` | `GD_UNISTD_unlink` / `GD_UNISTD_rmdir` |
| `mkdir` | `GD_mkdir` |
| `opendir` / `readdir` / `closedir` | `GD_opendir` / `GD_readdir` / `GD_closedir` |
| `stat` / `fstat` | `GD_stat` / `GD_UNISTD_fstat` |

Native rules:

- Use container-relative paths only. Do **not** pass `/data/...`,
  `getFilesDir()`-derived strings, or absolute paths from
  `File#getAbsolutePath()` (e.g. transferred via JNI) to `GD_fopen` /
  `GD_UNISTD_open`. Same path-semantics rule as the Java GD streams.
- Add the Dynamics C headers to the native build's include path
  (`sdk/libs/handheld/libs/gd/inc/`).
- If a POSIX call has no documented `GD_*` / `GD_UNISTD_*` equivalent
  in the catalog or installed headers, **do not invent one** — record
  a manual TODO and mark the call site unsupported.

Prebuilt `.so` libraries with no in-repo source must remain as
non-blocking manual interventions per prompt 00 step 2b unless evidence
shows they violate a non-waivable storage/networking rule. Do not claim
closure of `secureFileStorage` on their behalf.

### 4b. Storage layout redesign decision (when `redesignPath` is set)

If prompt 00 tagged any `secureFileStorage` call site with non-null `redesignPath`,
document the chosen outcome in `migration-analysis.json` rationale or
`migration-plan-state.json` notes **before** claiming writer closure:

- **`in-container`** — canonical GD persistence (default). Implement immediately.
- **`saf-boundary`** — a trust-boundary crossing involving SAF or content
  URIs. The `redesignPath` value alone does not authorise implementation.
  Prompt 00 must also record `direction`, `migrationDecision`, and
  enough SAF metadata to populate `safDecision` on the disposition:

  | `direction` | Default `migrationDecision` | Agent action |
  |---|---|---|
  | `inbound` | `MIGRATE_SECURE_COPY` | Implement immediately — copy external content directly into Dynamics secure storage. |
  | `outbound` | `BLOCKED_PENDING_DEVELOPER_APPROVAL` | Implement the **block** immediately (disable UI, remove code path). Do NOT implement the export. Ask the developer. |

  When `direction` is absent or ambiguous, treat as `outbound` (fail safe).
  The authoritative interim record lives in `migration-plan-state.json`
  `dispositions[].safDecision`; prompt 10 aggregates these into the
  report-only `safFindings[]` and blocker `manualTodos[]` sections.
  Example analysis entry:

  ```json
  {
    "redesignPath": "saf-boundary",
    "direction": "outbound",
    "migrationDecision": "BLOCKED_PENDING_DEVELOPER_APPROVAL",
    "uiEntryPoint": "Export button in reports toolbar",
    "targetMechanism": "ACTION_CREATE_DOCUMENT"
  }
  ```

- **`feature-removal`** — flow removed for DLP compatibility. Implement immediately.

For camera/media apps, `in-container` should normally mean:

- secure media bytes stored under container-relative paths,
- secure metadata/index records for latest-preview and gallery browsing,
- thumbnails generated into secure storage,
- no MediaStore or public Gallery as the canonical media index.

See `steering/40-secure-file-storage.md` §7. ICC (prompt 08) remains blocked until
`secureFileStorage` is fully closed.

### 4c. Implement redesign (mandatory when `redesignPath` is set or public-storage hits remain)

If prompt 00 tagged any `secureFileStorage` call site with non-null
`redesignPath`, or if Phase 4 still reports public-storage /
`externalStorage` blocker hits after the first migration pass,
**implement the redesign now**.

**Default behaviour depends on the flow classification:**

- Container migration, inbound import, plaintext-staging removal, and
  external-primary-storage replacement: implement immediately.
- Outbound SAF export: implement the secure block immediately, then ask
  the developer before implementing any external transfer.
- URI sharing / file-open egress: leave generic URI transfer approval to
  prompt `08`; this prompt only removes public-storage producers and
  plaintext staging that feed that flow.

For each affected feature or call-site cluster:

1. Identify the blocking pattern, the user-visible feature it powers,
   and the appropriate redesign outcome (`in-container`,
   `saf-boundary`, or `feature-removal`).
2. **Act according to the classification:**
   - **Public export / "Save to Downloads"** → **feature-removal**.
     Remove the export toggle, the UI, and the writer. This is the
     expected outcome for Dynamics — public storage fundamentally
     conflicts with the container model. **Implement immediately.**
   - **Gallery / MediaStore as canonical index** → **in-container**.
     Move media storage into the GD container, build an in-app gallery
     backed by secure storage, remove MediaStore as the source of
     truth. **Implement immediately.**
   - **User-initiated document export or share** (call site has
     `redesignPath: "saf-boundary", direction: "outbound"`) →
     **blocked SAF boundary pending developer decision**. Do not
     implement `ACTION_CREATE_DOCUMENT`,
     `ContentResolver.openOutputStream` during the default migration.
     If the same feature also uses `ACTION_SEND`, `ACTION_VIEW`,
     `EXTRA_STREAM`, URI grants, or `FileProvider`, record that part for
     prompt `08` and do not approve it here. Immediately:
     1. Disable or safely no-op the initiating UI action.
     2. **Remove** the outbound SAF implementation from production
        source where practical (picker intents, output streams, URI
        grants, external intent construction). When full deletion is
        impractical, place behind a fail-closed approval gate per
        step b above. Phase 4N must find zero unapproved outbound
        patterns.
     3. Record `BLOCKED_PENDING_DEVELOPER_APPROVAL` in
        `dispositions[].safDecision` with `"domain": "secureFileStorage"`
        and `"status": "removed"` (see option 3 step c above).
     4. Prompt 10 will generate the blocker `manualTodos[]` entry from
        `safDecision` (see option 3 step c2).
     5. Ask the developer whether the feature should: remain blocked;
        be replaced with AppKinetics ICC; or be enabled with runtime
        outbound DLP enforcement.
     Implement the external SAF export only after an explicit
     `ALLOW_WITH_DLP_ENFORCEMENT` decision has been persisted in
     `dispositions[].safDecision`. **No other section of this prompt or any
     later prompt may override the default-blocked state.** The
     blocked state is the secure default and persists until the
     developer makes an explicit decision.
   - **External cache / temp files** → **container migration**. Replace
     `getExternalCacheDir()` with container-relative paths.
     **Implement immediately.**
3. Briefly inform the developer what was changed and why.
   For `in-container`, `feature-removal`, and `container migration`
   outcomes, do **not** wait for approval — these keep data inside the
   container or remove the path entirely, which is inherently safe.
   For `saf-boundary` outcomes, approval IS required before enabling
   the export — the block is the interim shipped behaviour.
4. **Only ask the developer** when a genuine product-level ambiguity
   exists that does NOT involve outbound data movement: e.g., two
   equally valid inbound redesigns with different UX trade-offs.
   For outbound flows, ALWAYS ask — this is not optional.
5. If you want an intermediate diagnostic before finishing the storage
   sequence, optionally run `validate.sh --check-prompt 05a` to spot
   remaining core-I/O issues early. The recorder does not auto-run this
   check; the mandatory acceptance gate remains prompt `10`.
6. **If some call sites remain unresolved** after the redesign (e.g.,
   FD-only media writers with no container-safe alternative):
   - Record each unresolved call site in `manualTodos[]` with
     `severity: "P1"`, the appropriate `blocking` value, and a specific title.
   - Do not add a final disposition for the unresolved call site.
     `manual-intervention` is not a valid disposition status; leaving
     the disposition missing correctly causes the 05c closure gate to
     fail unless the developer defers the whole `secureFileStorage`
     domain.
   - **Continue to `05b`, `05c`, and subsequent prompts.** An
     unresolved FD-only media writer does not block SharedPreferences
     migration, networking migration, or UI widget migration. Complete
     as much of the migration as possible.
7. Record prompt `05a` as `completed` only for the mechanically resolved
   subset; unresolved FD-only sites stay out of the final disposition
   ledger and must be resolved, domain-deferred, or allowed to fail 05c
   closure. Record as `failed` only if you made no meaningful progress
   at all on the domain.

For this minimal pass, persist the redesign choice only in existing
`migration-analysis.json` rationale text or
`migration-plan-state.json` notes if you touch those files. Do **not**
invent a new `bootstrap.json` field in this pass.

### 4d. Save Feature Continuity (Mandatory after external storage removal)

After removing external storage write paths, audit each removed feature
for user-facing save / download / export behavior. A save feature that
silently loses data is worse than a removed feature — at least removal
is honest.

For **every** external storage write path removed in steps 4c / 4b / 1:

1. **Does the user expect to find this file later?**
   - If **YES** → implement a permanent container save (not cache).
     Use a dedicated container directory (e.g., `saved-documents/`)
     distinct from any cache or preparation directory. Write the file
     via `com.good.gd.file.FileOutputStream` and store the
     **container-relative path string** (e.g., `"saved-documents/report.pdf"`)
     as the persisted reference. Do **not** construct a `file://` URI
     from the container path — GD container-relative paths are virtual
     and do not exist on the real Android filesystem; a `file://` URI
     derived from them is invalid for `ContentResolver` operations and
     will fail at runtime (see Phase 4M / `DocumentFile.fromFile()` trap).
   - If **NO** → removal is sufficient (e.g., temporary share staging,
     transient export buffer).

2. **Is there a "recent files" / "saved documents" / "history" list?**
   - If **YES** → update the stored reference to use the
     **container-relative path string** (not a `file://` URI, not a
     `content://` URI, not `Uri.EMPTY`). Verify the retrieval logic
     resolves the path using `com.good.gd.file.File(path).exists()`
     and opens the file via `com.good.gd.file.FileInputStream(path)`.
     Do **not** store `Uri.EMPTY` or `Uri.parse("")` as the file
     reference — these are placeholder URIs that will never resolve
     and indicate a broken save round-trip.
   - Replace any URI-resolution logic that uses `ContentResolver` with
     direct GD File API access using the container-relative path.

3. **Does the UI display the save location?**
   - If **YES** → update string resources to reflect container storage.
     Replace "Downloads", "Saved to Downloads", "SD Card", "External
     Storage" with "Secure Documents" or equivalent phrasing. Stale
     location strings produce a confusing user experience where the
     app claims to save to a location that no longer exists.

4. **Is there an "Open" action for saved files?**
   - If **YES** → implement an in-app viewer or ICC-based open
     (`GDServiceClient.sendTo` to deliver to another Dynamics app).
     Do **NOT** leave `ACTION_VIEW` with a container `file://` URI —
     external apps cannot read from the Dynamics container and the
     open action will silently fail.

5. **Does the app have cleanup / cache-eviction logic?**
   - If **YES** → verify it targets only the cache / preparation
     directory and does NOT sweep the permanent save directory. A
     cleanup routine that accidentally deletes saved documents is
     functionally equivalent to the original data loss bug.

If any of these checks reveal a broken round-trip, **fix it before
proceeding**. Record the save-feature continuity audit in
`migration-plan-state.json` notes.

See `steering/40-secure-file-storage.md` §7a for the full Secure
Container Save Pattern guidance.

### 5. Update Call-Site Dispositions (Partial Closure)

Update `dynamics-migration-tool/output/migration-plan-state.json` with dispositions
for secure file-storage call sites fully closed during 05a.
Preserve the file's existing top-level `runId` unchanged (copy from
`bootstrap.json` if creating the file from scratch).

A `secureFileStorage` call site whose `kind` matches any of the
per-library values from prompt 00 (`cameraXOutputFileOptionsFileBuilder`,
`zipFileFileConstructor`, `exifInterfaceFileConstructor`,
`mediaMuxerFileConstructor`, `pdfRendererFileBackedParcelFileDescriptor`)
may be marked `migrated` only when the post-migration source matches the
corresponding "After" pattern from the library migration sub-table in
step 3. Phase 4 rule 4H enforces this.

Use status:

- `migrated` (completed in this pass — call site converted to Dynamics)
- `removed` (call site eliminated from the source — dead code removal,
  feature removed, or **blocked SAF outbound export** where the SAF
  API call sites have been deleted and the UI is a safe no-op)

**Blocked SAF outbound export call sites** use `"status": "removed"`
with `"domain": "secureFileStorage"`, a `note` encoding
`SAF_OUTBOUND_EXPORT | ... | BLOCKED_PENDING_DEVELOPER_APPROVAL`, and
a structured `safDecision`. The
call site is removed from the source (the export code is deleted, not
guarded). The disabled UI button is not itself a call site — it
contains no SAF API usage. A corresponding `manualTodos[]` blocker
entry must be generated by prompt 10 from `safDecision`.

**Approved SAF outbound export call sites** (`ALLOW_WITH_DLP_ENFORCEMENT`)
use `"status": "migrated"` and a `safDecision` with
`runtimeDlpEnforced: true` because the DLP-gated export code is a
Dynamics-backed replacement for the original unprotected export. Phase
4N only accepts the remaining SAF API surface when the structured
approval record exists and the source contains the verified DLP gate.

Every applicable `secureFileStorage` call site must be migrated or
removed. If a whole domain cannot be migrated this release, the
developer defers the entire domain in `bootstrap.json deferredDomains[]`
and those call sites are excluded from the closure ledger.

Do not record prompt completion until the file is full-file-overwritten and valid JSON.

---

## Output

- Core file I/O migration table (call site, sensitivity, action)
- Temp/plaintext leakage removals performed
- FD-only media writer decisions (for each MediaRecorder / MediaMuxer /
  FD-only call site: container-safe path used, redesigned, or
  unresolved blocker with rationale)
- Files changed in this pass
- `migration-plan-state.json` updated only for call sites actually
  closed in this pass

See `steering/40-secure-file-storage.md` for the full canonical guide
(stream-layer rules §5, canonical replacement table §5d, validator
coverage §11). Phase 4 also fails `.getChannel()` / `FileChannel` transfer /
`BitmapFactory.decodeFile` on GD streams, plus the `kotlin.io` /
`java.nio.file` / `FileReader` / etc. anti-patterns from step 1 — use
`byte[]` or `InputStream` patterns from the canonical guide (or the
`SecureFileIO` helpers).

### Scoped repair loop (mandatory on reruns; recommended on first pass)

If you are re-running prompt `05a` against an **already migrated tree**,
do **not** restart the migration from `00pre`. Repair the existing source
in place:

1. Run:
   ```bash
   bash dynamics-migration-tool/tooling/validate.sh --check-prompt 05a --fix-suggestions
   ```
2. If Phase 4 reports
   `[RUNTIME-NPE][secureFileStorage/listFiles-unguarded]`, fix **every**
   hit by adding an `exists()` / `isDirectory()` guard before
   `com.good.gd.file.File.listFiles()` or `.list()`. Kotlin `?.` is **not**
   sufficient.
3. If Phase 4 reports `[FS-DOCFILE-001]`, replace every
   `DocumentFile.fromFile(gdFile)` path with direct GD stream access
   (`com.good.gd.file.FileInputStream` / `FileOutputStream` or existing
   `SecureFileIO` helpers). Do **not** wrap GD files with `DocumentFile`.
4. Re-run the same scoped validator until prompt `05a` is clean.
5. Only after the scoped validator is clean should you record prompt `05a`
   as `completed`.

---

## Record execution

After 05a completes, append execution record:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 05a \
    --status completed \
    --files-touched <comma-separated relative paths including migration-plan-state.json>
```

If secure file storage is `not-applicable` per execution plan, record skipped:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 05a \
    --status skipped \
    --note "secureFileStorage not-applicable per executionPlan"
```

If some call sites remain unresolved (e.g., FD-only media writers with
no container-safe alternative) but you resolved all mechanically
resolvable sites, leave those unresolved call sites without final
dispositions and continue to 05c, where closure will either be completed
or fail unless the developer defers the whole domain:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 05a \
    --status completed \
    --note "secureFileStorage: N sites migrated, M unresolved FD-only sites left for 05c closure/developer deferral"
```

Record failed **only** if you made no meaningful progress on the domain
(zero call sites resolved):

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 05a \
    --status failed \
    --note "secureFileStorage: no call sites could be resolved"
```
