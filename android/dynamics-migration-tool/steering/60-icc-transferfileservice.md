# Steering: Inter-Container Communication (ICC) — TransferFile Service

> **Secure-container-only (kit ≥ 0.3.0):** `GDServiceClient.sendTo` attachment paths
> must already live in the Dynamics secure container. If business files still use the
> normal Android sandbox or public storage, **storage migration failed** — close
> `secureFileStorage` before ICC (`40-secure-file-storage.md` §7). This kit does
> **not** provide a canonical `stageFilesInGDContainer` / copy-from-`java.io.File`
> helper at send time.

> **Multi-module note**: `rg ... app/src/main/java/` examples below
> are canonical-shape. Scan `${in_scope_main_src}` from
> `dynamics-migration-tool/output/module-map.json` — share/export
> paths and FileProvider helpers are routinely scattered across
> feature library modules. See `04-multi-module-projects.md`.

## Data Leakage Policy

Dynamics apps **must not** expose app-owned files to unmanaged or
non-Dynamics applications through generic Android sharing mechanisms.

Any general file-sharing flow (share sheets, chooser intents, FileProvider
URIs) must be replaced with the AppKinetics **TransferFile** service so
files are transferred only between authorized Dynamics containers. All
data in transit between containers is encrypted by the Dynamics runtime.

This steering is self-contained and is the canonical ICC guidance for migration runs.

This applies regardless of whether the data is classified as "sensitive"
— the UEM administrator controls data-loss-prevention policy, and generic
Android sharing bypasses those controls entirely.

---

## Required Analysis (Prompt 00 / Prompt 08)

### Detection Signals — Generic Sharing

Search the source tree for any of these patterns:

```bash
rg "Intent\.ACTION_SEND|ACTION_SEND_MULTIPLE" -g "*.java" -g "*.kt" -n
rg "Intent\.createChooser" -g "*.java" -g "*.kt" -n
rg "ShareCompat\.IntentBuilder" -g "*.java" -g "*.kt" -n
rg "EXTRA_STREAM|EXTRA_TEXT" -g "*.java" -g "*.kt" -n
rg "FileProvider\.getUriForFile" -g "*.java" -g "*.kt" -n
rg "ACTION_VIEW.*intent" -g "*.java" -g "*.kt" -n
```

If **any** match is found, prompt 08 (ICC) is **applicable** — do not skip it.

### Classification

For each sharing path found (enterprise hardening removes keep-as-is file sharing):

| Classification | Criteria | Action |
|---|---|---|
| **Must migrate** | Shares enterprise data, user-generated content, or files from the secure container | Replace with AppKinetics TransferFile |
| **Keep as-is** | No app data leaves the container (for example, opening an allowlisted public `https://` link) | Document justification in report |
| **Remove** | Share feature no longer needed under Dynamics | Remove code, document in report |

---

## TransferFile Service Constants

| Constant | Value |
|---|---|
| Service ID | `com.good.gdservice.transfer-file` |
| Service Version | `1.0.0.0` |
| Method Name | `transferFile` |
| Parameters | `null` (no JSON params for file transfer) |

---

## Implementation Pattern

### 1. Service Discovery

Find all installed Dynamics apps that accept file transfers:

```java
import com.good.gd.GDAndroid;
import com.good.gd.GDServiceProvider;
import com.good.gd.GDServiceType;

Vector<GDServiceProvider> providers = GDAndroid.getInstance().getServiceProvidersFor(
        "com.good.gdservice.transfer-file",
        "1.0.0.0",
        GDServiceType.GD_SERVICE_TYPE_APPLICATION);
```

Filter out the current app by comparing `provider.getAddress()` against
`context.getPackageName()`.

Each `GDServiceProvider` exposes:
- `getName()` — human-readable app name (for UI chooser)
- `getAddress()` — package name (target for `sendTo()`)
- `getIcon()` — app icon bitmap (optional, for UI)

**Positive wiring requirement:** any migrated sender that calls
`GDServiceClient.sendTo(...)` must also perform runtime provider discovery
with `GDAndroid.getInstance().getServiceProvidersFor(...)`. Do not hardcode a
target package, cache a stale provider address as the only path, or send to the
first discovered provider without user choice when multiple providers exist.

### 2. Sending Files

```java
import com.good.gd.icc.GDServiceClient;
import com.good.gd.icc.GDICCForegroundOptions;

// File paths MUST be absolute paths in the GD secure container
// e.g., "/media/photos/IMG_123.jpg" — prepend "/" to relative paths
List<String> absolutePaths = new ArrayList<>();
for (String relativePath : gdContainerPaths) {
    absolutePaths.add(relativePath.startsWith("/") ? relativePath : "/" + relativePath);
}

GDServiceClient.sendTo(
    targetAddress,                               // from GDServiceProvider.getAddress()
    "com.good.gdservice.transfer-file",
    "1.0.0.0",
    "transferFile",
    null,                                        // no params for file transfer
    absolutePaths.toArray(new String[0]),
    GDICCForegroundOptions.PreferPeerInForeground);
```

**Threading requirement:** `sendTo()` performs I/O. Dispatch the call from a
background executor/coroutine/thread and marshal user feedback back to the UI
thread. Do not call `sendTo()` directly from click handlers, `onCreate`,
`onActivityResult`, `@Composable` callbacks, or adapter bindings unless those
callbacks immediately hop to a background dispatcher.

### 3. Listener Registration

Register listeners using an authorization-aware lifecycle. Official samples
register listeners during model/app setup, then gate secure ICC operations
behind authorized state checks.

```java
import com.good.gd.icc.GDService;
import com.good.gd.icc.GDServiceClient;
import com.good.gd.icc.GDServiceClientListener;
import com.good.gd.icc.GDServiceListener;

// Register in model/app setup or onAuthorized():
GDServiceClient.setServiceClientListener(myListener);   // required for senders; handles responses
GDService.setServiceListener(myListener);                // required only when this app receives transfers
```

The listener class should implement both `GDServiceClientListener` and
`GDServiceListener` when the app both sends and receives files. Sender-only
apps still need `GDServiceClient.setServiceClientListener(...)` so they can
receive errors, acknowledgements, and attachment progress callbacks. Apps that
declare/provide a TransferFile service, implement `GDServiceListener`, call
`GDService.replyTo(...)`, or handle incoming AppKinetics messages must also
call `GDService.setServiceListener(...)`.

### 4. Handling Responses (Client Side)

```java
// GDServiceClientListener.onReceiveMessage
@Override
public void onReceiveMessage(String application, Object params,
                             String[] attachments, String requestId) {
    if (params instanceof GDServiceError) {
        // Handle error from peer app
    }
    // Otherwise: transfer acknowledged
}
```

### 5. Receiving Files (Service Side)

```java
// GDServiceListener.onReceiveMessage (7-arg overload)
@Override
public void onReceiveMessage(String application, String service, String version,
                             String method, Object params, String[] attachments,
                             String requestId) {
    // Validate service/version/method
    if (!"com.good.gdservice.transfer-file".equals(service)) {
        GDService.replyTo(application,
            new GDServiceError(GDServiceErrorCode.GDServicesErrorServiceNotFound),
            GDICCForegroundOptions.PreferPeerInForeground, null, requestId);
        return;
    }

    // Process attachments — paths are in the GD secure container
    for (String path : attachments) {
        // Read with com.good.gd.file.FileInputStream
        // Save to app's storage area if needed
    }
}
```

### 6. UI — Provider Chooser

Replace the generic Android share sheet with a Dynamics-only chooser:

```java
List<GDServiceProvider> providers = transferFileService.getAvailableProviders(context);
if (providers.isEmpty()) {
    // Show "No compatible apps available"
    return;
}

String[] names = new String[providers.size()];
for (int i = 0; i < providers.size(); i++) {
    names[i] = providers.get(i).getName();
}

new MaterialAlertDialogBuilder(context)
    .setTitle("Share to")
    .setItems(names, (dialog, which) -> {
        String address = providers.get(which).getAddress();
        executor.execute(() -> {
            try {
                transferFileService.sendFiles(address, filePaths);
            } catch (GDServiceException e) {
                // Handle error
            }
        });
    })
    .setNegativeButton("Cancel", null)
    .show();
```

### 6a. Compose-First Provider Chooser

When ICC share UI is implemented in Jetpack Compose, use the kit-authored
`GDICCProviderShareDialog` (`templates/icc/GDICCProviderShareDialog.kt`)
instead of `MaterialAlertDialogBuilder` or `AlertDialog.Builder` inside
`@Composable` functions.

- **Compose screens:** `GDICCProviderShareDialog` + `sendFiles` / `sendTo`
  on selection (background thread).
- **View/XML screens:** `MaterialAlertDialogBuilder` example in §6 remains
  valid.
- **Do not** call `TransferFileService.showShareChooser(Activity, …)` from
  `@Composable` entry points — hoist chooser state into Compose.

Phase 8b runs `compose-icc-chooser-scan.py` to hard-fail unmanaged patterns.

### 6b. Forbidden Chooser Shortcuts

Do not bypass destination selection with hardcoded first-entry logic:

```kotlin
// [NOT OK] WRONG — silently sends to first provider
val target = providers.first()
transferFileService.sendFiles(target.address, gdPaths)

// [OK] CORRECT — user chooses target when multiple providers exist
if (providers.size == 1) {
    transferFileService.sendFiles(providers[0].address, gdPaths)
} else {
    // Show chooser UI and dispatch selected provider
}
```

If a single-provider fast path is used, it must be explicitly guarded by
`providers.size == 1` and the multi-provider chooser path must remain.

---

## Correct Import Paths

All ICC classes reside in `com.good.gd.icc`:

```java
import com.good.gd.icc.GDService;
import com.good.gd.icc.GDServiceClient;
import com.good.gd.icc.GDServiceListener;
import com.good.gd.icc.GDServiceClientListener;
import com.good.gd.icc.GDServiceError;
import com.good.gd.icc.GDServiceErrorCode;
import com.good.gd.icc.GDServiceException;
import com.good.gd.icc.GDICCForegroundOptions;
```

Service discovery uses:

```java
import com.good.gd.GDAndroid;
import com.good.gd.GDServiceProvider;
import com.good.gd.GDServiceType;
```

---

## UEM Configuration

The app must be registered in UEM as a provider/consumer of the
TransferFile service. This is done in the UEM console — no
`settings.json` changes required for consuming the service.

If the app acts as a **service provider** (receives files from other
Dynamics apps), register the service in the UEM console or optionally
declare it in `settings.json`:

```json
{
    "GDServices": [
        {
            "identifier": "com.good.gdservice.transfer-file",
            "version": "1.0.0.0",
            "type": "application"
        }
    ]
}
```

---

## CRITICAL: GD Container Filesystem Staging (Lessons from Real Migration)

`GDServiceClient.sendTo()` requires file paths within the **GD secure
container virtual filesystem** — the filesystem accessed by
`com.good.gd.file.File`, `com.good.gd.file.FileInputStream`, and
`com.good.gd.file.FileOutputStream`.

### When Staging Is Required

| App stores files using... | GD container path? | Staging needed? |
|---|---|---|
| `com.good.gd.file.File` / `com.good.gd.file.FileOutputStream` | Yes | No — paths are already GD container paths |
| `java.io.File` / `java.io.FileOutputStream` / `Context.getFilesDir()` | No | **Yes** — must copy into GD container before sending |

**This is the #1 cause of silent ICC transfer failures.** The sender
reports success, but the receiving app gets a transfer notification with
no file data and hangs on a loading animation.

### Why It Fails Silently

- `GDServiceClient.sendTo()` does NOT throw an exception when given an
  Android OS path that doesn't exist in the GD container
- The call appears to succeed from the sender's perspective
- The failure only manifests at the receiving end as a stuck transfer
- Android OS absolute paths like `/data/data/com.example/files/photo.jpg`
  look valid and the files genuinely exist on the OS filesystem

### File Path Audit (MANDATORY — Prompt 08 Step 3)

Before implementing ICC, determine how the app stores its files:

```bash
# Check if the app uses GD file APIs
rg "com\.good\.gd\.file\." -g "*.java" -g "*.kt" -l app/src/main/java/

# Check if the app uses standard Java file APIs for data storage
rg "java\.io\.File\b|java\.io\.FileOutputStream|java\.io\.FileInputStream" \
  -g "*.java" -g "*.kt" -l app/src/main/java/
```

If the app still stores shareable business data using standard `java.io.File` /
sandbox / public storage APIs, **stop ICC implementation** and complete storage
migration (prompts `05a`–`05z`, `40-secure-file-storage.md` §7). Prompt `08`
may still be recorded mid-run, but prompt `10` will fail the final gate while
`secureFileStorage` remains open.

### Common Mistake: Using java.io.File for ICC attachments

```kotlin
// [NOT OK] WRONG — writes to Android filesystem, not GD container
val tempFile = java.io.File(activity.cacheDir, "shared_note.txt")
tempFile.writeText(textContent)
allPaths.add(tempFile.absolutePath)  // OS path, not GD path

// [OK] CORRECT — writes to GD container filesystem
com.good.gd.file.FileOutputStream("icc_outbox/shared_note.txt").use { fos ->
    fos.write(textContent.toByteArray(Charsets.UTF_8))
}
gdPaths.add("icc_outbox/shared_note.txt")  // GD container path
```

---

## sendTo() Threading Guidance

`GDServiceClient.sendTo()` performs I/O. Prefer dispatching on a background
executor for large attachments and resilient UX:

```kotlin
private val executor = Executors.newSingleThreadExecutor()

executor.execute {
    try {
        // gdContainerPaths must already be in-container paths from secure storage migration
        sendFiles(target.address, gdContainerPaths)
        activity.runOnUiThread {
            Toast.makeText(activity, R.string.share_sent, Toast.LENGTH_SHORT).show()
        }
    } catch (e: GDServiceException) {
        activity.runOnUiThread {
            Toast.makeText(activity, R.string.share_failed, Toast.LENGTH_SHORT).show()
        }
    }
}
```

---

## ICCServiceListener: Complete Method Catalog

When implementing `GDServiceClientListener`, you must implement **all four**
methods. Missing any causes a compile error. The two commonly forgotten
methods are:

| Method | Purpose |
|--------|---------|
| `onReceiveMessage(app, params, attachments, requestId)` | Response to your outgoing transfer |
| `onMessageSent(app, requestId, attachments)` | Confirmation that sendTo() completed |
| `onReceivingAttachments(app, numberOfAttachments, requestID)` | Progress: peer is sending N attachments |
| `onReceivingAttachmentFile(app, path, size, requestID)` | Progress: receiving a specific file |

The last two (`onReceivingAttachments`, `onReceivingAttachmentFile`) are
easily missed because they are progress callbacks, not completion callbacks.
Stub them with logging if the app does not need progress tracking.

---

## Migration Rules

1. Replace all generic Android sharing (`ACTION_SEND`, `createChooser`,
   `FileProvider` to non-Dynamics apps) with AppKinetics TransferFile.
2. Preserve the user experience — show a chooser of available Dynamics apps.
3. File paths in `attachments[]` **must** be absolute paths in the GD
   secure container (prefix with `/` if relative). If the app still
   stores files using `java.io.File`, stop and complete
   secure-file-storage migration first; do **not** add send-time
   sandbox-to-container staging as a workaround.
4. ICC requires authorization — sending and attachment processing must only run when authorized.
5. Every sender must include runtime provider discovery
   (`GDAndroid.getInstance().getServiceProvidersFor(...)`) and
   `GDServiceClient.setServiceClientListener(...)` before `sendTo()`.
6. Provider/receiver code must register `GDService.setServiceListener(...)`.
7. Run `GDServiceClient.sendTo()` on a background executor/coroutine/thread;
   keep UI-thread callbacks limited to chooser display and success/failure
   feedback. Some SDK samples call it from UI handlers, but enterprise
   migrations should avoid UI stalls and make the threading decision visible.
8. If no Dynamics providers are found, show a user-friendly message and
   do not fall back to generic Android sharing.
9. If the app currently opens secure-container-owned media in another
   native app via `ACTION_VIEW`, `MediaStore.ACTION_REVIEW`, or
   `CATEGORY_APP_GALLERY`, that path must be removed, replaced with an
   in-app secure viewer/gallery, or replaced with ICC. Native viewer
   invocation is not an acceptable "controlled export" path for secure
   media.
   **Caller-audit rule:** before classifying any `ACTION_VIEW` path as
   "removed", verify that the containing method has no active callers.
   If UI elements (buttons, list items, menu actions) still invoke the
   method, the feature has active users — classify as "must migrate" and
   replace with ICC TransferFile, or remove the calling UI elements.
   Replacing the method body with a no-op Toast while leaving callers
   intact is a **silent functional regression** that passes all
   validation but breaks the user-facing feature.
   `ACTION_VIEW` for opening files uses the same `GDServiceClient.sendTo()`
   mechanism as `ACTION_SEND` for sharing: both are inter-container file
   transfers from the Dynamics perspective.

---

## Validation

The migration is complete when:

- No `Intent.ACTION_SEND` / `ACTION_SEND_MULTIPLE` remain for app-owned files or container data
- No `Intent.createChooser` remains for file/data sharing to unmanaged apps
- No `FileProvider.getUriForFile` shares container data externally
- No `ACTION_VIEW`, `MediaStore.ACTION_REVIEW`, or `CATEGORY_APP_GALLERY`
  path remains for secure-container-owned media; only allowlisted
  `https://` public-link UX may use `ACTION_VIEW`
- `GDServiceClient.sendTo` present with `transfer-file` service ID
- `getServiceProvidersFor` present for runtime service discovery
- `GDServiceClient.setServiceClientListener` present for sender responses and errors
- `GDService.setServiceListener` present when the app contains provider/receiver
  code (`GDServiceListener`, `GDService.replyTo`, incoming AppKinetics message handling,
  or TransferFile service declaration)
- ICC operations gated by authorization state
- File paths passed to `sendTo()` are GD container paths (not Android OS paths)
- `sendTo()` has background-dispatch evidence (`Executor`, coroutine
  `Dispatchers.IO`, worker thread, or equivalent); direct UI-handler calls are
  not left as the final migration state
- All 4 `GDServiceClientListener` methods are implemented
- No `providers.first()` / `providers[0]` / `providers.get(0)` shortcuts remain in production share paths
- If `FileProvider.getUriForFile` is removed, no stale
  `androidx.core.content.FileProvider` manifest declaration remains
- If FileProvider is removed, no stale `res/xml/file_paths.xml` (or equivalent
  FILE_PROVIDER_PATHS resource) remains

---

## Output

- Sharing paths identified (before/after)
- ICC integration code changes
- File path audit result (GD container vs Android filesystem)
- Confirmation that no native gallery/viewer invocation remains for
  secure-container-owned media
- Service registration changes (if app is a provider)
- Validation that no generic sharing to unmanaged apps remains

## Enterprise Hardening Addendum (DLP closure)

- After migrating share flows to ICC, run a manifest/resource hygiene sweep:
  - remove `androidx.core.content.FileProvider` provider declarations when
    `FileProvider.getUriForFile` call sites are gone;
  - remove `android.support.FILE_PROVIDER_PATHS` metadata and
    `res/xml/file_paths.xml` (or equivalent) when no longer used.
- If FileProvider must remain for a non-sharing path, the migration report must
  explicitly document:
  - why the provider is still required,
  - exposed path tags (`files-path`, `cache-path`, etc.),
  - whether those paths can contain container-backed or app-owned data,
  - why the retained surface is safe under the Dynamics DLP contract.
- Treat `external-path`, `external-files-path`, `external-cache-path`, and
  `root-path` in FileProvider path resources as hard-fail DLP findings unless
  manually justified and remediated.
- Public-link UX may use `ACTION_VIEW` on allowlisted `https://` hosts only; no file URI handoff.
- User acceptance is not a waiver for exporting secure media to unmanaged
  apps. If the product still requires unmanaged external viewing/export,
  keep the migration partial / no-go and require developer-owned
  remediation or explicit developer domain deferral rather than treating
  the UX prompt as approval.
