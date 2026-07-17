# Steering: Storage Access Framework Trust Boundary

> **Principle:** Android Storage Access Framework is not BlackBerry
> Dynamics secure storage. SAF APIs access document providers outside
> the Dynamics container (Downloads, Google Drive, OneDrive, removable
> media, other apps). Every SAF operation is a trust-boundary crossing
> and must be classified by data-flow direction.

> **Related steering:**
> - `40-secure-file-storage.md` — container file I/O
> - `60-icc-transferfileservice.md` — ICC / AppKinetics
> - `14-api-provenance-and-replacement-catalog.md` — API catalog rows
>   `saf-*`

---

## 1. SAF Classifications

Every SAF or content-URI call site must be assigned exactly one
classification before migration proceeds.

### 1a. SAF_INBOUND_IMPORT

External content is read into the Dynamics application.

**Detection signals:**

- `ACTION_OPEN_DOCUMENT`
- `ACTION_GET_CONTENT`
- `ACTION_PICK` (when the picked result is read via content resolver)
- `ActivityResultContracts.OpenDocument`
- `ActivityResultContracts.OpenMultipleDocuments`
- `ActivityResultContracts.GetContent`
- `ActivityResultContracts.GetMultipleContents`
- `ContentResolver.openInputStream` against an external content URI
- `ContentResolver.openFileDescriptor` in read mode
- `ContentResolver.openAssetFileDescriptor`

**Required migration:**

1. Classify the source as external / untrusted.
2. Process data in memory where practical.
3. Copy accepted data directly into Dynamics secure storage via
   `com.good.gd.file.FileOutputStream`.
4. Do not stage through plaintext files.
5. Validate file type, size, and parsing assumptions.
6. Close all streams and descriptors on success, failure, and
   cancellation.
7. Record the import boundary in the migration report.

Inbound imports are not automatically unsafe but must be explicitly
migrated as trust-boundary operations.

### 1b. SAF_OUTBOUND_EXPORT

Secure or enterprise data is written to a SAF URI or external provider.

**Detection signals:**

- `ACTION_CREATE_DOCUMENT`
- `ActivityResultContracts.CreateDocument`
- `ContentResolver.openOutputStream` against an external URI
- Writable `ParcelFileDescriptor` against an external URI
- Writing through `DocumentFile` to a selected location
- Writing into a selected tree URI
- Exporting to `MediaStore`
- Saving to Downloads
- Uploading into an external document provider

**Default migration decision:** `BLOCKED_PENDING_DEVELOPER_APPROVAL`

**Required migration (when blocked):**

1. Make the UI action a safe no-op or disabled action.
2. Do not launch the SAF picker or share sheet.
3. Do not open an output stream to the external URI.
4. Do not generate, expose, or grant URI permissions.
5. Present a user-facing message: "Export is unavailable in the
   secured application."
6. Record the blocked capability in `migration-plan-state.json`
   `dispositions[]` (domain `"secureFileStorage"`, note includes
   `SAF_OUTBOUND_EXPORT | BLOCKED_PENDING_DEVELOPER_APPROVAL`, and
   `safDecision.migrationDecision` is
   `BLOCKED_PENDING_DEVELOPER_APPROVAL`). Prompt 10 expands that
   structured decision into a `manualTodos[]` entry with
   `blocking: true` in the final report.

**Required migration (when developer-approved):**

1. Check runtime outbound DLP policy via
   `GDAndroid.getInstance().getApplicationPolicy()`.
2. Deny when policy prohibits outbound transfer.
3. Keep the picker, stream open, and URI grants behind the policy check.
4. Stream directly from Dynamics secure storage.
5. Do not create plaintext temporary files.
6. Minimise plaintext buffer lifetime.
7. Close and clear resources on completion or error.
8. Avoid broad or persistent URI permissions.
9. Record approval and DLP enforcement in the report.

### 1c. SAF_EXTERNAL_PRIMARY_STORAGE

The application uses a SAF directory, persisted tree URI, or external
document location as its canonical data store.

**Detection signals:**

- `ACTION_OPEN_DOCUMENT_TREE`
- `takePersistableUriPermission`
- `DocumentFile.fromTreeUri`
- Persisted `content://` strings in preferences, databases, or config
- URI-backed repositories
- Application startup depending on an external directory grant

**Required migration:**

1. Move canonical enterprise data into Dynamics secure storage.
2. Replace the external repository with a secure repository
   abstraction backed by `com.good.gd.file.*`.
3. Preserve SAF only as an explicit import or approved export boundary.
4. Do not consider persisted URI permission equivalent to secure
   storage.
5. Require manual review where behaviour cannot be preserved
   automatically.

### 1d. SAF_URI_SHARING

A URI or URI permission is passed to another component or application.

**Detection signals:**

- `ACTION_SEND` / `ACTION_SEND_MULTIPLE`
- `ACTION_VIEW` / `ACTION_EDIT` with content or file URIs
- `Intent.EXTRA_STREAM`
- `Intent.setData` / `Intent.setDataAndType` with content URIs
- `Intent.setClipData` with content URIs
- `ClipData.newUri`
- Share sheets: `Intent.createChooser`, `ShareCompat.IntentBuilder`
- `FLAG_GRANT_READ_URI_PERMISSION`
- `FLAG_GRANT_WRITE_URI_PERMISSION`
- `FileProvider.getUriForFile`

**Default migration decision:** `BLOCKED_PENDING_DEVELOPER_APPROVAL`

Write grants are especially sensitive — an external component may
modify data later consumed by the Dynamics application.

**Required migration (when blocked):**

Disabling the visible Share button alone does **not** close the
finding. The entire share flow must be dismantled:

1. **Remove the external intent launch.** Delete `startActivity`,
   `startActivityForResult`, or activity-result launcher calls
   that fire `ACTION_SEND`, `ACTION_SEND_MULTIPLE`, `ACTION_VIEW`,
   `ACTION_EDIT`, `Intent.createChooser`, or `ShareCompat.IntentBuilder`
   for Dynamics-owned data.
2. **Remove all `EXTRA_STREAM` values.** Delete `putExtra(EXTRA_STREAM, …)`
   and `putParcelableArrayListExtra(EXTRA_STREAM, …)` calls.
3. **Remove `Intent.data` / `Intent.setDataAndType`.** Delete
   `setData(uri)`, `setDataAndType(uri, …)`, and any
   `Intent(ACTION_*, uri)` constructor that passes a content or file
   URI carrying Dynamics data to an external target.
4. **Remove `ClipData`.** Delete `ClipData.newUri(…)`,
   `Intent.setClipData(…)`, and any `ClipData.Item` construction
   that wraps Dynamics URIs.
5. **Remove URI permission flags.** Delete
   `Intent.addFlags(FLAG_GRANT_READ_URI_PERMISSION)` and
   `Intent.addFlags(FLAG_GRANT_WRITE_URI_PERMISSION)`. After
   blocking, no URI permissions should be granted to external
   consumers.
6. **Remove temporary FileProvider files.** If the share flow
   creates files under a `FileProvider`-served directory solely for
   sharing, delete the file-creation code. Remove the
   `FileProvider.getUriForFile(…)` call. If the `<provider>`
   declaration and `res/xml/file_paths.xml` are now orphaned,
   remove them from the manifest and resources.
7. **Remove any asynchronous preparation job used only by the share
   flow.** Background tasks, `CoroutineScope` launches,
   `WorkManager` requests, or `AsyncTask` implementations that
   exist solely to prepare, compress, convert, or stage data for
   the share intent must be removed. Leaving an orphaned
   preparation pipeline is a latent data-exposure risk and a
   maintenance hazard.
8. **Disable the UI entry point.** Set the Share/Export button or
   menu item `isEnabled = false` with an explanatory label, or
   convert it to a safe no-op that displays "Sharing is
   unavailable in the secured application."
9. **Record the disposition** in `migration-plan-state.json`
   `dispositions[]` with `domain: "icc"` when the original call site is
   owned by prompt `08` (or `secureFileStorage` only for a storage
   producer removed by prompt `05a`), `status: "removed"`, and a
   `note` encoding
   `SAF_URI_SHARING — intent removed, EXTRA_STREAM removed,
   ClipData removed, URI flags removed, FileProvider cleaned,
   BLOCKED_PENDING_DEVELOPER_APPROVAL`.
10. **Persist a `safDecision` blocker for prompt 10.** The final report
    does not exist yet; prompt 10 must generate the corresponding
    `manualTodos[]` blocker entry from `dispositions[].safDecision`:
    ```json
    {
      "priority": "blocker",
      "description": "SAF URI sharing blocked — [feature name]: the share intent, EXTRA_STREAM, ClipData, URI permission flags, and FileProvider staging have been removed. The application is secure; no generic data-egress path exists. The pending issue is a PRODUCT DECISION: the developer must decide whether the feature should (a) remain permanently blocked or (b) be replaced with AppKinetics ICC TransferFile.",
      "reason": "Blocked pending explicit developer approval — see steering/44-saf-trust-boundary.md §1d"
    }
    ```

**Required migration (when developer-approved):**

Apply ICC TransferFile (`GDServiceClient.sendTo`) per
`60-icc-transferfileservice.md`. Generic URI sharing to unmanaged apps is
not re-enabled by prompt `05a`; if the developer requests an unmanaged
URI-sharing exception, leave it as a blocker/manual redesign item for
security review rather than marking the `icc` call site migrated.

### 1e. SAF_PLAINTEXT_STAGING

Data is copied through an unprotected intermediate location while
entering or leaving the secure container.

**Detection signals:**

- `cacheDir` / `externalCacheDir` for SAF-related content
- `filesDir` via ordinary Java/Kotlin APIs for content staging
- `getExternalFilesDir` as a transfer buffer
- `File.createTempFile` in a SAF import/export flow
- Shared storage as staging
- Hard-coded filesystem paths as intermediates
- Temporary files created for sharing or upload

**Required migration:**

1. Eliminate plaintext staging.
2. Use in-memory streams for small/bounded content.
3. Otherwise use Dynamics-secure temporary file.
4. Ensure cleanup on success, failure, cancellation, and process death.
5. Classify unresolved plaintext staging as a migration failure, not
   a warning.

---

## 2. Developer-Decision Contract

Each outbound or URI-sharing finding must have a stable identifier and
be presented to the developer with a precise question.

### 2a. Decision structure

**Storage location:** The decision is persisted as a structured
`safDecision` object on the relevant `dispositions[]` entry in
`migration-plan-state.json`. The `note` string still carries concise
human-readable markers for review, but prompt 10 must read
`safDecision` instead of parsing arbitrary prose from `note`.

Disposition entry during migration:
```json
{
  "callSiteId": "ExportViewModel.kt:42",
  "domain": "secureFileStorage",
  "status": "removed",
  "module": "app",
  "note": "SAF_OUTBOUND_EXPORT | ACTION_CREATE_DOCUMENT | BLOCKED_PENDING_DEVELOPER_APPROVAL | uiDisabled | codePathRemoved",
  "safDecision": {
    "classification": "SAF_OUTBOUND_EXPORT",
    "direction": "outbound",
    "migrationDecision": "BLOCKED_PENDING_DEVELOPER_APPROVAL",
    "developerApprovalRequested": true,
    "developerDecision": null,
    "decisionTimestamp": null,
    "uiEntryPoint": "Export button in reports toolbar",
    "targetMechanism": "ACTION_CREATE_DOCUMENT",
    "runtimeDlpEnforced": false,
    "outboundCodeReachable": false,
    "uiDisposition": "disabled",
    "plaintextStagingRemoved": true
  }
}
```

Expanded report-time shape (§7):
```json
{
  "findingId": "saf-export-001",
  "callSiteId": "ExportViewModel.kt:42",
  "classification": "SAF_OUTBOUND_EXPORT",
  "direction": "outbound",
  "module": "app",
  "sourceFile": "app/src/main/java/.../ExportViewModel.kt",
  "sourceLine": 42,
  "uiEntryPoint": "Export button in toolbar",
  "dataSource": "Dynamics secure container (reports/quarterly.pdf)",
  "targetMechanism": "ACTION_CREATE_DOCUMENT",
  "migrationDecision": "BLOCKED_PENDING_DEVELOPER_APPROVAL",
  "developerDecision": null,
  "featureStatus": "blocked",
  "runtimeDlpEnforced": false,
  "outboundCodeReachable": false,
  "uiDisposition": "disabled",
  "plaintextStagingRemoved": true,
  "validationResult": "pending",
  "note": "Export blocked pending explicit developer approval"
}
```

### 2b. Supported decisions

| Decision | Meaning |
|----------|---------|
| `BLOCK` | Feature disabled permanently. |
| `ALLOW_WITH_DLP_ENFORCEMENT` | Feature enabled behind runtime DLP check. |
| `REPLACE_WITH_SECURE_INTERNAL_FLOW` | Replace external export with ICC or in-app secure flow. |
| `MANUAL_REDESIGN_REQUIRED` | Requires structural redesign beyond agent automation. |

Absence of a decision is treated as `BLOCK`.

### 2c. Developer question template

The agent must ask a precise question such as:

> "This feature exports data from the BlackBerry Dynamics secure
> container to an Android document provider or external application
> via [specific API]. The exported copy will no longer be protected by
> Dynamics secure storage.
>
> Options:
> 1. BLOCK — disable the export feature (default)
> 2. ALLOW_WITH_DLP_ENFORCEMENT — enable subject to runtime DLP policy
> 3. REPLACE_WITH_SECURE_INTERNAL_FLOW — replace with ICC or internal secure workflow
> 4. MANUAL_REDESIGN_REQUIRED — defer for manual architectural redesign
>
> Should this feature remain blocked, be replaced with a secure
> internal workflow, or be explicitly enabled subject to Dynamics
> outbound DLP policy?"

Do not ask vague questions like "Should SAF be supported?"

---

## 3. Approved Outbound Implementation Pattern

When the developer explicitly approves `ALLOW_WITH_DLP_ENFORCEMENT`:

Before generating code, verify the exact Dynamics policy accessor, key
name, value type, and default-deny semantics against the locally resolved
SDK and the API catalog. If the policy API cannot be verified, leave the
export blocked. Do not invent a DLP API from the sample below.

```kotlin
// 1. Check DLP policy BEFORE showing picker or opening stream
val policy = GDAndroid.getInstance().getApplicationPolicy()
val dlpEnabled = policy?.get("preventDataLeakageOut") as? Boolean ?: true

if (dlpEnabled) {
    // Show user-facing message: export blocked by enterprise policy
    showExportBlockedByPolicy()
    return
}

// 2. Only now launch the SAF picker
val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
    addCategory(Intent.CATEGORY_OPENABLE)
    type = mimeType
    putExtra(Intent.EXTRA_TITLE, suggestedName)
}
createDocumentLauncher.launch(intent)

// 3. On result, stream directly from secure storage
fun onDocumentCreated(uri: Uri) {
    val secureInput = com.good.gd.file.FileInputStream(containerPath)
    val output = contentResolver.openOutputStream(uri) ?: return
    try {
        secureInput.copyTo(output)
    } finally {
        output.close()
        secureInput.close()
    }
    // [BB_DYNAMICS-MIGRATION] SAF export — developer-approved, DLP-gated
}
```

Key rules:
- DLP check must precede picker launch, not follow it.
- `dispositions[].safDecision.migrationDecision` must be
  `ALLOW_WITH_DLP_ENFORCEMENT` before this code is present.
- No `File.createTempFile` staging.
- No broad `takePersistableUriPermission` for export.
- No `FLAG_GRANT_WRITE_URI_PERMISSION` back to the caller.
- Close streams in finally/use blocks.

---

## 4. Blocked Outbound UI Pattern

When blocked (no developer decision or explicit `BLOCK`):

```kotlin
// Disable the export menu item at render time
exportMenuItem.isEnabled = false
exportMenuItem.title = getString(R.string.export_unavailable_secured)

// OR: keep clickable but safe no-op
exportButton.setOnClickListener {
    Snackbar.make(view,
        R.string.export_unavailable_in_secured_app,
        Snackbar.LENGTH_LONG
    ).show()
    // [BB_DYNAMICS-MIGRATION] SAF export blocked — no developer approval
}
```

String resource:
```xml
<string name="export_unavailable_in_secured_app">
    Export is unavailable in the secured application.
</string>
```

The blocked pattern must NOT:
- Leave the original callback reachable
- Keep an unused but callable export path
- Launch `ACTION_CREATE_DOCUMENT` and then refuse the write
- Create a plaintext temporary file
- Pass data through an unmanaged cache
- Suppress the finding after only a cosmetic UI change

---

## 4b. Blocked URI Sharing Pattern

When a `SAF_URI_SHARING` finding is blocked (no developer decision
or explicit `BLOCK`), the full share pipeline must be removed — not
just the visible button.

**Complete removal checklist:**

```kotlin
// ✗ INSUFFICIENT — UI-only disabling leaves the share pipeline intact
shareButton.isEnabled = false  // NOT ENOUGH

// ✓ REQUIRED — dismantle the entire share flow:

// 1. Remove the share intent construction and launch
// DELETE: val shareIntent = Intent(Intent.ACTION_SEND).apply { ... }
// DELETE: startActivity(Intent.createChooser(shareIntent, ...))

// 2. Remove EXTRA_STREAM
// DELETE: shareIntent.putExtra(Intent.EXTRA_STREAM, fileUri)
// DELETE: shareIntent.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uriList)

// 3. Remove Intent.data / setDataAndType
// DELETE: shareIntent.data = contentUri
// DELETE: shareIntent.setDataAndType(contentUri, mimeType)

// 4. Remove ClipData
// DELETE: shareIntent.clipData = ClipData.newUri(resolver, label, uri)

// 5. Remove URI permission flags
// DELETE: shareIntent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
// DELETE: shareIntent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)

// 6. Remove FileProvider URI generation and temp files
// DELETE: val fileUri = FileProvider.getUriForFile(ctx, authority, tempFile)
// DELETE: val tempFile = File(shareDir, "export.pdf")
// DELETE: FileOutputStream(tempFile).use { ... }

// 7. Remove async preparation (if share-only)
// DELETE: sharePreparationScope.launch { prepareSharePayload() }

// 8. Disable the UI entry point
shareButton.isEnabled = false
shareButton.text = getString(R.string.share_unavailable_secured)
// OR: safe no-op
shareButton.setOnClickListener {
    Snackbar.make(view,
        R.string.share_unavailable_in_secured_app,
        Snackbar.LENGTH_LONG
    ).show()
    // [BB_DYNAMICS-MIGRATION] SAF URI sharing blocked — no developer approval
}
```

String resource:
```xml
<string name="share_unavailable_in_secured_app">
    Sharing is unavailable in the secured application.
</string>
```

The blocked URI sharing pattern must NOT:
- Disable only the Share button while leaving the intent
  construction, `EXTRA_STREAM`, `ClipData`, URI permission flags,
  or `FileProvider` staging reachable from any path (deep link,
  `BroadcastReceiver`, `WorkManager`, saved callback, alternate
  navigation, or programmatic trigger)
- Leave an orphaned `FileProvider` declaration in the manifest
  after its only consumer is removed
- Leave orphaned `res/xml/file_paths.xml` path resources
- Keep an async preparation job that stages data for a share
  intent that no longer fires
- Treat a no-op Toast stub as a complete migration (the share
  pipeline behind it must also be deleted)
- Leave `FileProvider.getUriForFile` calls that generate URIs
  for data that is no longer shared

---

## 5. Inbound Import Pattern

Inbound imports use a direct secure-copy approach:

```kotlin
fun onDocumentOpened(uri: Uri) {
    val input = contentResolver.openInputStream(uri) ?: return
    val secureOutput = com.good.gd.file.FileOutputStream(containerDestPath)
    try {
        input.copyTo(secureOutput)
    } finally {
        secureOutput.close()
        input.close()
    }
    // [BB_DYNAMICS-MIGRATION] SAF inbound import — direct to secure storage
}
```

Key rules:
- Do not write to `cacheDir`, `filesDir` (non-GD), or temp files first.
- Validate file type and size before processing.
- Close streams in all exit paths.

---

## 6. Validation Rules

Phase 4 SAF scanner must fail the migration when:

1. An outbound SAF operation remains reachable without a developer
   decision recorded in `dispositions[]` (with SAF classification in
   the `note` field).
2. Absence of a decision is treated as approval.
3. `openOutputStream` remains reachable for enterprise data without
   approval and DLP enforcement.
4. An external intent carrying Dynamics data via URI remains reachable
   without approval.
5. URI permission grants remain active on a blocked path.
6. A blocked UI action still reaches the export implementation.
7. Plaintext temporary staging remains in a SAF flow.
8. SAF-backed external storage remains the canonical store for
   enterprise data.
9. An outbound finding is omitted from the final report.
10. An approved flow lacks runtime DLP enforcement.

### 6a. URI-Sharing-Specific Validation

Phase 4N and Phase 8b must additionally fail when a
`SAF_URI_SHARING` finding is marked blocked but any of the
following remain reachable:

11. `ACTION_SEND` or `ACTION_SEND_MULTIPLE` intent construction
    for Dynamics-owned data.
12. `ACTION_VIEW` or `ACTION_EDIT` intent with a `content://` or
    `file://` URI carrying container data to an external target.
13. `Intent.EXTRA_STREAM` (`putExtra` or
    `putParcelableArrayListExtra`) referencing Dynamics data.
14. `Intent.setData` / `Intent.setDataAndType` with a content URI
    derived from the secure container.
15. `ClipData.newUri` or `Intent.setClipData` wrapping Dynamics URIs.
16. `FLAG_GRANT_READ_URI_PERMISSION` or
    `FLAG_GRANT_WRITE_URI_PERMISSION` on an intent targeting an
    external component.
17. `FileProvider.getUriForFile` for files that exist solely for
    sharing.
18. Orphaned `<provider>` declaration or `res/xml/file_paths.xml`
    whose only consumer (the share flow) has been removed.
19. Async preparation jobs (`CoroutineScope`, `WorkManager`,
    background thread) that stage data exclusively for the
    removed share flow.
20. A Share/Export button is disabled but the intent-construction
    code behind it is still callable via any alternate path
    (deep link, broadcast, saved callback, worker).

---

## 7. Data Flow: Interim Storage vs Report

**Interim (during migration prompts 05a–08):**

SAF findings are recorded using the **existing** mechanisms — not a
separate ledger:

- **Discovery:** `migration-analysis.json` `executionPlan[].callSites[]`
  with SAF-classified `kind` values (e.g. `SAF_OUTBOUND_EXPORT`,
  `ACTION_CREATE_DOCUMENT`, `ContentResolver.openOutputStream`).
- **Closure:** `migration-plan-state.json` `dispositions[]` with
  `domain: "secureFileStorage"` for storage-owned SAF export/import
  call sites, or `domain: "icc"` for URI-sharing call sites owned by
  prompt `08`, and structured `safDecision` encoding classification,
  direction, and decision.
- **Blocked items:** generated by prompt 10 as `manualTodos[]` with
  `blocking: true` from `safDecision` entries whose
  `migrationDecision` is `BLOCKED_PENDING_DEVELOPER_APPROVAL` or
  `MANUAL_REDESIGN_REQUIRED`.

**Do NOT** write a `safFindings[]` key to `migration-plan-state.json`.
That file has a fixed schema; adding unknown top-level keys violates
the contract (see prompt 08 step 0b for the same rule).

**Report (prompt 10 only):**

Prompt 10 aggregates the `dispositions[]` entries whose `safDecision`
object is present into the report-only `safFindings[]` and `safSummary`
sections of `migration-report.json`:

Each SAF-related finding is reported in `migration-report.json` under
`safFindings[]`:

```json
{
  "safFindings": [
    {
      "findingId": "saf-export-001",
      "callSiteId": "existing-call-site-id-from-migration-analysis",
      "classification": "SAF_OUTBOUND_EXPORT",
      "direction": "outbound",
      "module": "app",
      "sourceFile": "app/src/main/java/.../ExportViewModel.kt",
      "sourceLine": 42,
      "uiEntryPoint": "Export button in reports toolbar",
      "dataSource": "Dynamics secure file",
      "targetMechanism": "ACTION_CREATE_DOCUMENT",
      "migrationDecision": "BLOCKED_PENDING_DEVELOPER_APPROVAL",
      "developerDecision": null,
      "featureStatus": "blocked",
      "runtimeDlpEnforced": false,
      "outboundCodeReachable": false,
      "uiDisposition": "disabled",
      "plaintextStagingRemoved": true,
      "changedFiles": ["ExportViewModel.kt", "ReportFragment.kt"],
      "validationResult": "pass",
      "note": "Export blocked pending explicit developer approval"
    }
  ],
  "safSummary": {
    "inboundImportsSecured": 2,
    "outboundExportsBlocked": 3,
    "outboundExportsApproved": 0,
    "uriSharingFlowsBlocked": 1,
    "externalPrimaryStorageReplaced": 0,
    "plaintextStagingPathsRemoved": 2,
    "unresolvedFlowsRequiringManualIntervention": 0
  }
}
```

**Relationship to `dispositions[]`:**

The `callSiteId` field links each report entry back to the
`dispositions[]` entry in `migration-plan-state.json` that was
written during migration. This is not a parallel ledger — it is
a report-time aggregation of existing disposition data, enriched
with SAF-specific fields for the compliance dashboard.

---

## 8. Idempotency

Repeated migration runs must not:
- Repeatedly disable the same UI action
- Create duplicate report findings (match on `findingId`)
- Re-ask a developer question after a recorded decision exists
- Overwrite an explicit developer decision
- Re-enable a blocked operation
- Duplicate wrapper or policy checks
- Create conflicting string resources
- Lose provenance from earlier sessions

If a developer decision changes, the tool updates the implementation
and report deterministically.

---

## 9. API Detection Checklist

The following must be detected by the Phase 4 SAF scanner:

### Intent actions
- `Intent.ACTION_OPEN_DOCUMENT`
- `Intent.ACTION_CREATE_DOCUMENT`
- `Intent.ACTION_OPEN_DOCUMENT_TREE`
- `Intent.ACTION_GET_CONTENT`
- `Intent.ACTION_PICK`

### Activity Result Contracts
- `ActivityResultContracts.OpenDocument`
- `ActivityResultContracts.OpenMultipleDocuments`
- `ActivityResultContracts.CreateDocument`
- `ActivityResultContracts.OpenDocumentTree`
- `ActivityResultContracts.GetContent`
- `ActivityResultContracts.GetMultipleContents`
- Custom `ActivityResultContract` implementations wrapping SAF intents

### Content and document APIs
- `ContentResolver.openInputStream`
- `ContentResolver.openOutputStream`
- `ContentResolver.openFileDescriptor`
- `ContentResolver.openAssetFileDescriptor`
- `ContentResolver.query` against document URIs
- `ContentResolver.takePersistableUriPermission`
- `ContentResolver.releasePersistableUriPermission`
- `DocumentsContract`
- `DocumentFile`
- `ParcelFileDescriptor`
- `AssetFileDescriptor`
- `ContentProviderClient`
- `FileProvider`
- `MediaStore` (write operations)

### URI and permission indicators
- `content://` string literals
- `DocumentsContract.isDocumentUri`
- `DocumentsContract.isTreeUri`
- `FLAG_GRANT_READ_URI_PERMISSION`
- `FLAG_GRANT_WRITE_URI_PERMISSION`
- Persisted URI strings in preferences or databases
- URI serialisation into bundles or saved state

---

## 10. Integration with Existing Prompts

| Prompt | SAF responsibility |
|--------|-------------------|
| `00` (analyze) | Detect SAF patterns, classify direction, populate `executionPlan.callSites[]` |
| `05a` (filesystem) | Migrate inbound imports, block outbound exports, remove plaintext staging |
| `08` (ICC) | Handle URI-sharing flows alongside generic sharing |
| `10` (report) | Generate `safFindings[]` and `safSummary` sections |

SAF findings use `secureFileStorage` / `icc` for migration-plan closure,
and the validator reports trust-boundary violations under the existing
non-waivable `externalStorage` security-blocker category. The `surface`
field in `security_blocker` calls distinguishes SAF sub-types:
`saf-inbound-import`, `saf-outbound-export`,
`saf-external-primary-storage`, `saf-uri-sharing`,
`saf-plaintext-staging`.
