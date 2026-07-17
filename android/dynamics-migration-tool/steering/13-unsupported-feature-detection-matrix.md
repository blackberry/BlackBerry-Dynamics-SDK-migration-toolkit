# Steering: Android Unsupported Feature Detection Matrix

Use this matrix in Prompt `00` and Prompt `10`.

If a feature is detected and no implemented secure outcome exists, it MUST appear in
`unsupportedFeatures` and in `manualTodos`.

---

## Baseline Policy

Any feature whose purpose is to move protected application data outside the
BlackBerry Dynamics secure container is **not** a normal migration target.
The migration kit must not spend prompt time trying to preserve unmanaged
Android backup/export/share/print/open-with behavior.

Permitted boundaries are limited to:

- Dynamics secure storage inside the container
- AppKinetics / ICC exchange between approved Dynamics applications
- Approved Dynamics-controlled services such as secure clipboard or a configured
  Dynamics browser service

Everything else is treated as an egress decision, not as a routine API swap.

## Outcome Taxonomy

Prompt `00` must classify each detected egress-capability feature into one of
these outcomes:

| Outcome | Meaning |
|---|---|
| `REMOVE` | The feature has no valid unmanaged-Dynamics equivalent and should be stripped: UI action, implementation, helpers, permissions, providers, intent filters, and temporary-file creation. |
| `REPLACE_WITH_DYNAMICS` | The original Android path must be removed and replaced only with an explicitly targeted Dynamics-safe boundary such as ICC/AppKinetics, Dynamics secure clipboard, secure in-container storage, or another approved Dynamics service. |
| `MANUAL_INTERVENTION_REQUIRED` | Product intent, enterprise policy, or a destination-specific design is required. Do not auto-migrate the original path. Surface it for developer review with a safe redesign direction. |
| `BLOCKED_UNTIL_APPROVED` | Disable the original path immediately and make the underlying code unreachable until the developer explicitly chooses permanent removal or an approved Dynamics-safe replacement. |

## Detection Matrix

| Feature | Detection Signals | Default Outcome | Migration Kit Treatment | Validator Coverage |
|---|---|---|---|---|
| Android Auto Backup / extraction rules | `android:allowBackup="true"`, `android:fullBackupContent`, `android:dataExtractionRules`, `BackupAgent`, `BackupManager`, `onBackup()`, `onRestore()` | `REMOVE` | Set `allowBackup="false"`, remove backup rules/agents, remove backup/restore UI and code paths, and record the capability as removed. | Phase 1 manifest checks, Phase 4/report additions |
| Manual backup / restore that leaves the container | "Backup database", "Export backup", "Restore backup", vault/archive export helpers | `REMOVE` | Remove the feature, UI, background jobs, temp files, and outbound storage path when the backup leaves the secure container. | Phase 4 + report contract |
| External / shared / removable storage for protected app data | `getExternal*`, `Environment.getExternalStorage*`, SD-card paths, mounted-drive paths | `REMOVE` | Strip the external-storage path or redesign the feature to stay in secure storage. Do not count app-specific external storage as a successful Dynamics storage migration. | Phase 4 external-storage check |
| Public-folder export | `MediaStore`, `Downloads`, `Documents`, `Pictures`, `Movies`, `Music`, `DCIM`, `MediaScannerConnection` | `REMOVE` | Remove public export/publish behavior. Store bytes in the container and provide an in-container viewer/index instead. | Phase 4 external-storage media scan |
| SAF outbound export (trust-boundary crossing) | `ACTION_CREATE_DOCUMENT`, `ActivityResultContracts.CreateDocument`, `ContentResolver.openOutputStream` for export, writable `ParcelFileDescriptor` to external URIs | `BLOCKED_UNTIL_APPROVED` | Default to blocked: disable the UI, remove picker launch and external write path, and record a pending developer decision. Only after explicit approval may a DLP-gated export be implemented. See `44-saf-trust-boundary.md`. | Phase 4N SAF directional classification |
| SAF external primary storage as app storage of record | `ACTION_OPEN_DOCUMENT_TREE`, `DocumentFile.fromTreeUri`, `takePersistableUriPermission`, persisted `content://` URIs in DB/prefs | `REMOVE` | Replace with container-backed storage. Persisted external document-provider URIs are never considered secure storage closure. | Phase 4N SAF directional classification |
| SAF inbound import / unmanaged-to-container ingestion | `ACTION_OPEN_DOCUMENT`, `ACTION_GET_CONTENT`, `ACTION_PICK`, `ActivityResultContracts.OpenDocument/GetContent`, `ContentResolver.openInputStream` | `MANUAL_INTERVENTION_REQUIRED` | Do not auto-preserve the unmanaged import UX. Surface a manual decision: whether the product may ingest unmanaged data at all, and if so implement a secure-copy/import workflow into the container. | Phase 4N SAF directional classification (warning) |
| Generic Android share sheet / chooser | `ACTION_SEND`, `ACTION_SEND_MULTIPLE`, `Intent.createChooser`, `ShareCompat.IntentBuilder`, share/export/send menu items | `REPLACE_WITH_DYNAMICS` | Replace generic Android sharing with AppKinetics ICC TransferFile + runtime provider discovery/chooser. If no Dynamics receiver is currently available, fail closed with a user message; never fall back to unmanaged sharing. | Phase 4N + Phase 8b |
| Open with / external viewer / external editor | `ACTION_VIEW`, `ACTION_EDIT`, `Intent.setDataAndType`, file-viewer helpers, file chooser-based viewer/editor launch | `REPLACE_WITH_DYNAMICS` | Replace unmanaged open/view/edit paths with ICC provider discovery and Dynamics receiver transfer. Remove unmanaged fallback routes. | Phase 4N + Phase 8b |
| FileProvider URI sharing / URI grants | `FileProvider.getUriForFile`, `FLAG_GRANT_READ_URI_PERMISSION`, `FLAG_GRANT_WRITE_URI_PERMISSION`, `ClipData.newUri`, `Intent.setClipData`, `grantUriPermission` | `REPLACE_WITH_DYNAMICS` | Remove provider-backed unmanaged sharing path and URI grants, then migrate the feature to ICC. Clean up stale provider declarations/resources when no longer required. | Phase 4N + Phase 8b FileProvider hygiene |
| Share to Dynamics app / document viewer / secure mail | ICC service discovery, runtime provider selection, documented enterprise requirement | `REPLACE_WITH_DYNAMICS` | Remove the Android generic share/open/email path and replace it with AppKinetics/ICC or another approved Dynamics service. Runtime receiver availability can change over time; keep discovery dynamic and do not require a hard-coded target at migration time. | Phase 8b ICC / chooser-bypass audit |
| Email via unmanaged app, messaging, social, nearby-device share | generic email intent, attachment send, SMS, WhatsApp, Bluetooth file transfer, Nearby Share, NFC transfer, Wi-Fi Direct | `REMOVE` | Strip the unmanaged route entirely. If the business capability must remain, require a Dynamics-specific replacement and classify it separately. | Phase 8b + report contract |
| Consumer cloud export / sync of protected files | Google Drive, Dropbox, OneDrive personal, Box personal, custom cloud upload/export helpers | `REMOVE` | Remove or disable the consumer cloud path. Only enterprise-approved, Dynamics-secured integrations may remain, and they require explicit product review. | Report/manual review, targeted validator additions |
| Upload/send to non-Dynamics or unapproved server | HTTP upload of container data to unmanaged endpoint, custom `UploadWorker`, export-to-cloud flows | `MANUAL_INTERVENTION_REQUIRED` | Do not treat arbitrary outbound upload as a normal migration. Require review of the destination, authentication, data class, and Dynamics-networking posture before preserving the capability. | Unenforced today; report/manual review |
| External printing / unmanaged print services | `PrintManager`, `PrintDocumentAdapter`, `PrintDocumentInfo`, `createPrintDocumentAdapter`, `android.printservice` | `MANUAL_INTERVENTION_REQUIRED` | Remove Android print integration by default. Only keep printing when a specific Dynamics-compatible secure printing service is approved. | Phase 8 print-surface scan + report/manual TODO |
| Copy to unmanaged clipboard | `android.content.ClipboardManager`, `setPrimaryClip`, `getPrimaryClip`, `CLIPBOARD_SERVICE` | `REPLACE_WITH_DYNAMICS` | Replace with Dynamics secure clipboard handling where supported and policy permits. Do not leave native clipboard access in place. | Phase 8 secure clipboard checks |
| Compose clipboard paths without GD adapter | `LocalClipboardManager.current`, `LocalClipboard.current`, Compose clipboard imports, `setText`, `getText`, `setClipEntry`, `getClipEntry`, `ClipEntry(...)` | `REPLACE_WITH_DYNAMICS` | Replace with `templates/clipboard/GDClipboardAdapter.kt` or an equivalent documented Dynamics-safe route. | Phase 8 Compose clipboard scan |
| Cross-app drag and drop / rich clipboard URI transfer | `startDragAndDrop`, `DragEvent`, `requestDragAndDropPermissions`, `ClipData.newUri`, `ClipData.Item(Uri)` | `REMOVE` | Remove or block cross-app drag/drop and rich URI clipboard paths for protected content. Do not preserve them as unmanaged Android features. | Phase 8 DLP/output scan |
| Screen capture / screen export helpers | in-app screenshot/save-image flows, screen recording export helpers, `PixelCopy`, screen-save/share flows | `REMOVE` | Remove features that persist protected screen content outside the container. DLP policy may govern screenshots, but app-owned export helpers must not remain. | Phase 8 DLP/output scan + report |
| External media publishing / gallery save | Gallery save/publish, MediaStore media insert, camera/video publish flows | `REMOVE` | Keep media in secure storage and provide an in-container viewer. Do not auto-preserve Gallery visibility or public media publishing. | Phase 4 external-storage media scan |
| Export to system contacts / calendar / other public providers | provider writes to contacts/calendar/personal providers, exported content sync | `MANUAL_INTERVENTION_REQUIRED` | Remove unmanaged public-provider export by default. Preserve only approved enterprise integrations with explicit redesign. | Report/manual review |
| Public/exported components that expose protected data | exported `provider`, `service`, `receiver`, `intent-filter`, `grantUriPermissions`, components returning files/records/attachments/auth data | `REMOVE` | Remove, privatize, or redesign around authenticated ICC. Exported components are not safe proof of interoperability. | Phase 7 provider/export audit + report |
| Export logs / diagnostics / crash attachments | "Save logs", diagnostics ZIP, file attachments to unmanaged crash/reporting SDKs | `MANUAL_INTERVENTION_REQUIRED` | Remove external export. Preserve only an approved authenticated support-upload flow with sanitization and auditing. | Report/manual review |
| Local HTTP file server / Wi-Fi or desktop transfer | localhost server, LAN download helpers, USB/Wi-Fi transfer, browser-based file download | `REMOVE` | Strip the feature. If desktop transfer is truly required, require a separate approved redesign. | Report/manual review |
| Unsupported third-party APIs requiring raw filesystem | Glide, Picasso, Coil, Fresco, or other libraries that force `java.io.File` path semantics | `MANUAL_INTERVENTION_REQUIRED` | Use a validated stream/byte[] redesign when available; otherwise leave the capability unresolved and document the safe redesign path. | Phase 4 Glide/path-load rule |
| Unsupported networking stack behavior | Direct sockets/custom TLS paths not migrated | `MANUAL_INTERVENTION_REQUIRED` | Require secure-networking migration or explicit review of the destination/control boundary. | Phase 6 networking checks |
| Pre-auth secure API access | Secure APIs called before `onAuthorized` | `MANUAL_INTERVENTION_REQUIRED` | Not an egress rule, but still a blocking migration gap that must be surfaced. | Phase 3 / 11 authorization checks |
| Complex architecture gaps | Heavy custom frameworks/legacy patterns | `MANUAL_INTERVENTION_REQUIRED` | Surface phased redesign guidance; do not claim closure. | Unenforced — manual review |
| CameraX `OutputFileOptions.Builder(File)` | `ImageCapture.OutputFileOptions.Builder(File)` | `REMOVE` | Replace with in-memory or secure-stream capture; do not accept plaintext file-output fallback. | Phase 4 rule 4H.camerax |
| `MediaMuxer` file/path constructor | `new MediaMuxer(String\|File, format)` | `MANUAL_INTERVENTION_REQUIRED` | Redesign around a GD-backed descriptor or other secure path; do not auto-approve sandbox/public staging. | Phase 4 rules 4H.mediamuxer + 4I |
| `MediaRecorder` file/path output | `MediaRecorder.setOutputFile(path\|file)` or `setNextOutputFile(path\|file)` | `MANUAL_INTERVENTION_REQUIRED` | Prefer direct secure streaming or descriptor import; otherwise leave unresolved and no-go. | Phase 4 rules 4H.mediarecorder + 4I |
| `MediaRecorder`/`MediaMuxer` FD from sandbox source | descriptor from `getFilesDir`, `getCacheDir`, `openFileOutput`, `createTempFile`, `ParcelFileDescriptor.open(non-GD-File)` | `MANUAL_INTERVENTION_REQUIRED` | Do not mark migrated. Private sandbox staging is still a container-boundary violation for this kit. | Phase 4 rule 4I |
| Capture-intent output URI flow | `ACTION_IMAGE_CAPTURE`, `ACTION_VIDEO_CAPTURE`, `IMAGE_CAPTURE_SECURE`, `MediaStore.EXTRA_OUTPUT`, caller-provided output URI handling, exported capture activities | `REMOVE` | Remove/narrow exported capture-provider behavior, reject caller-supplied output URIs, and keep capture in managed in-app flows. | Phase 4 capture-output scan |
| Public gallery restoration / media rescanning | `MediaScannerConnection`, MediaStore restore/rescan, public gallery sync | `REMOVE` | Replace with an in-container gallery/index. Do not treat public media visibility as a secure migration outcome. | Phase 4 external-storage media scan |
| `ZipFile` file/path constructor | `new ZipFile(File\|String)` | `REPLACE_WITH_DYNAMICS` | Replace with `ZipInputStream(GD FileInputStream)` / `ZipOutputStream(GD FileOutputStream)`. | Phase 4 rule 4H.zipfile |
| `ExifInterface` file/path constructor | `new ExifInterface(File\|String)` | `REPLACE_WITH_DYNAMICS` | Read/write via GD stream-backed workflows; do not use file/path constructors on protected data. | Phase 4 rule 4H.exifinterface |
| `PdfRenderer` via file-backed `ParcelFileDescriptor` | `ParcelFileDescriptor.open(File, mode)` for `PdfRenderer` | `MANUAL_INTERVENTION_REQUIRED` | Redesign around pipe/memory + GD input stream or defer secure-file closure. | Phase 4 rule 4H.pdfrenderer |
| Legacy `GDWebView` as a migration target | `com.good.gd.widget.GDWebView` imported, declared in layouts, or extended | `REPLACE_WITH_DYNAMICS` | Replace with `com.blackberry.bbwebview.BBWebView`; `GDWebView` is not a valid migration target. | Phase 8 GDWebView check |
| Native (NDK / C / C++) source bypassing secure container | standard C/POSIX file or socket APIs in app-controlled native sources, or opaque prebuilt `.so` binaries | `MANUAL_INTERVENTION_REQUIRED` | Replace app-controlled sources with Dynamics C APIs; prebuilt binaries remain manual follow-up until proven safe. | Phase 4 / Phase 6 native-call scanner |

---

## Workaround Rule

- If workaround code exists and is validated, do NOT list the feature as unsupported.
- Still record residual risk in:
  - `apisReplaced[*].riskReason`
  - `manualTodos` if further verification is required
