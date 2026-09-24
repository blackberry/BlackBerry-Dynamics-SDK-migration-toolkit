## Task: Add ICC Secure Sharing (AppKinetics TransferFile)

**Prerequisite**: Prompts 03 and 03b must be complete. ICC services require
the Dynamics authorization lifecycle to be in place. **`secureFileStorage` must
be closed** (all applicable call sites `migrated`/`removed`, domain
`not-applicable`, or a valid `deferredDomains[]` entry) — `record-prompt-execution.sh`
enforces this via `requires[]` before prompt `08` can be recorded `completed`.

Goal: Prevent data leakage via standard Android sharing by replacing it
with Dynamics Inter-Container Communication (ICC / AppKinetics).

**Module map context**: Load
`dynamics-migration-tool/output/module-map.json` and resolve
`${in_scope_main_src}` (every primary + library `src/main/java` and
`src/main/kotlin`), `${in_scope_res_dirs}` (every primary + library
resource directory), and `${in_scope_manifests}` (every primary +
library manifest). Every `rg` below scans those sets — share/export
paths, FileProvider call sites, menus, provider-path resources, and
manifest declarations are commonly distributed across feature modules.
If `module-map.json` is missing, STOP and re-run `00pre-bootstrap.md`.

**Important — Data Leakage Policy**: Dynamics apps must not share files
with non-Dynamics apps via generic Android mechanisms. Any general
share/export flow found during analysis (Prompt 00) should default to
**Dynamics ICC/AppKinetics replacement**. Do not keep unmanaged Android
share/open paths as fallbacks.
Generic sharing to unmanaged apps is a data-loss-prevention (DLP) violation
regardless of whether the shared data is classified as "sensitive" — the
UEM administrator controls DLP policy, and generic Android sharing bypasses
those controls entirely.

This prompt is self-contained. Use only the patterns and guardrails defined
here and in `steering/60-icc-transferfileservice.md`.

If generic sharing cannot be fully replaced or removed this release, STOP and
hand the developer this exact `deferredDomains[]` template. The agent must not
write it:

```json
{
  "deferredAt": "2026-06-25T12:00:00Z",
  "deferredBy": "developer",
  "developerSignedOff": true,
  "classification": "acceptedResidualRisk",
  "domain": "icc",
  "expiresAt": "2026-09-25T12:00:00Z",
  "reason": "ICC replacement requires product-owned DLP and sharing decisions before release."
}
```

Do not add a partial placeholder entry. Missing `developerSignedOff`,
`classification`, or `expiresAt` means the validator ignores the deferral and
prompt 10 still hard-fails.

---

## Steps

### 0. Enumerate ICC Call Sites (MANDATORY — do this before editing any code)

Before writing migration code, read `migration-analysis.json` and list
the ICC call sites that prompt 00 assigned to this prompt. Do **not**
pre-register final `migrated` dispositions before the corresponding code
is actually migrated or removed; the ledger is a closure record, not a
worklist.

**Step 0a — List all applicable ICC call sites:**

```bash
python3 - dynamics-migration-tool/output/migration-analysis.json <<'PY'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))
for row in a.get("executionPlan", []):
    if row.get("domain") == "icc" and row.get("applicable"):
        for cs in row.get("callSites", []):
            print(f"  id={cs['id']!r}  file={cs.get('file')}:{cs.get('line')}  kind={cs.get('kind')}")
PY
```

If this prints nothing and `applicable: true`, re-run `00-analyze-app.md` —
`callSites[]` must be non-empty when the domain is applicable.

**Step 0b — List Prompt-00 egress features owned by prompt 08:**

```bash
python3 - dynamics-migration-tool/output/migration-analysis.json <<'PY'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))
for feat in a.get("egressFeatures", []):
    if feat.get("ownerPrompt") == "08":
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
  "featureId": "egress-share-main-001",
  "domain": "icc",
  "outcome": "REPLACE_WITH_DYNAMICS",
  "module": "app",
  "note": "Generic ACTION_SEND share flow replaced with ICC TransferFile and runtime provider chooser.",
  "secureAlternative": "AppKinetics ICC TransferFile with runtime Dynamics-provider discovery",
  "uiDisposition": "replaced",
  "codePathReachable": true
}
```

**Step 0c — Plan one final `dispositions[]` entry per call site, then
write it only after migration/removal:**

After each call site is replaced with ICC or fully removed, write an
entry with this exact shape:

```json
{
  "callSiteId": "<exact id from migration-analysis.json callSites[].id>",
  "domain": "icc",
  "status": "migrated",
  "module": "<module path from module-map.json, e.g. app>",
  "note": "<brief description of what replaced the call site>"
}
```

Use `"status": "removed"` when the sharing path is eliminated rather than
migrated. The only valid status values are `migrated` and `removed`.
For blocked URI-sharing decisions, include a `safDecision` object with
`classification: "SAF_URI_SHARING"` and the recorded product decision so
prompt 10 can generate `safFindings[]` and blocker TODOs.

> **CRITICAL — do NOT invent custom top-level keys.** The following shapes
> are incorrect and will be rejected by the schema validator:
>
> ```json
> { "iccDispositions": [ ... ] }          ← WRONG: unknown top-level key
> { "callSiteDispositions": [ ... ] }     ← WRONG: unknown top-level key
> ```
>
> `dispositions[]` is the **only** canonical array for all closure-gated
> domains (`secureSql`, `secureFileStorage`, `secureNetworking`, **`icc`**,
> `secureUiWidgets`, `secureClipboard`). Always write to
> `migration-plan-state.json` at the top level key `dispositions`.

**Step 0c — Verify the file parses correctly after writing dispositions:**

```bash
python3 -c "import json; json.load(open('dynamics-migration-tool/output/migration-plan-state.json'))" \
  && echo "✅ valid JSON" || echo "❌ invalid JSON — fix before proceeding"
```

---

### 1. Inventory All Share/Export Paths

Search the entire source tree for **all** outbound sharing patterns:

```bash
# Intent-based sharing
rg "Intent\.ACTION_SEND|ACTION_SEND_MULTIPLE" -g "*.java" -g "*.kt" -n
rg "Intent\.createChooser" -g "*.java" -g "*.kt" -n
rg "ShareCompat\.IntentBuilder" -g "*.java" -g "*.kt" -n

# File sharing via URIs
rg "FileProvider\.getUriForFile|FileProvider" -g "*.java" -g "*.kt" -n
rg "EXTRA_STREAM|EXTRA_TEXT" -g "*.java" -g "*.kt" -n

# External viewers / file openers
rg "ACTION_VIEW.*intent" -g "*.java" -g "*.kt" -n
rg "ACTION_VIEW" -g "*.java" -g "*.kt" -n
```

**Open vs Share — same ICC mechanism:** `ACTION_VIEW` for opening files in
a viewer and `ACTION_SEND` for sharing files to another app are both
file transfers between apps. From the Dynamics perspective, both are
inter-container egress and use the same ICC TransferFile mechanism
(`GDServiceClient.sendTo()`). When inventorying paths, classify open/view
paths separately from share paths so each can be tracked, but apply the
same ICC migration pattern to both. The existing `TransferFileService` /
helper class handles both — pass the file with the appropriate MIME type.

```bash
# Generic "upload" or "send" patterns that send data outside
rg "upload|Upload|UPLOAD" -g "*.java" -g "*.kt" -l
rg "share|Share|SHARE" -g "*.java" -g "*.kt" -l
rg "export|Export|EXPORT" -g "*.java" -g "*.kt" -l
```

Also check UI resources for share/upload/export menu items and buttons:

```bash
rg "upload|share|export|send" -g "*.xml" -i -l ${in_scope_res_dirs}
```

### 2. Classify Each Sharing Path

For each path found, determine one of four outcomes:

| Outcome | Criteria | Action |
|---|---|---|
| **REPLACE_WITH_DYNAMICS** | The feature is app-to-app transfer of protected data | Remove the Android share/open path and replace it with ICC/AppKinetics using runtime provider discovery |
| **BLOCKED_UNTIL_APPROVED** | The capability cannot yet be safely migrated to ICC (for example unresolved policy constraints) | Disable the UI, remove the reachable Android sharing/open code path, and record the blocked state |
| **REMOVE** | The share/open capability is no longer needed or clearly conflicts with the Dynamics boundary | Remove UI and implementation entirely |
| **MANUAL_INTERVENTION_REQUIRED** | Policy/product review is needed and the kit must not guess the destination or redesign | Record the decision and safe next options without preserving the Android path |

**Default classification**: classify generic share/open/email/viewer flows as
`REPLACE_WITH_DYNAMICS` and implement ICC TransferFile with runtime provider
discovery. If no compatible Dynamics receiver app is currently installed or
activated, show a deterministic user message and fail closed (no unmanaged
fallback).

### ACTION_VIEW / Native Viewer: Caller Audit (Mandatory)

When classifying an `ACTION_VIEW` / native-viewer path as **remove**, verify
that removing the functionality does not silently break active UI flows:

1. Identify all callers of the method containing the `ACTION_VIEW` intent
2. If ANY caller is reachable from a user-visible UI element (button, list
   item, menu, click listener), the path has **active users** and cannot be
   classified as "remove" without also removing the UI elements
3. If the UI elements should remain functional, reclassify as
   **REPLACE_WITH_DYNAMICS** and implement ICC provider discovery + chooser.
   Do not require a hard-coded target app at migration time.

**Anti-pattern — no-op Toast replacement:** Replacing `ACTION_VIEW` with a
no-op `Toast.makeText(...)` while leaving the calling UI intact creates a
**silent functional regression** that compiles cleanly, passes all
validation checks, and produces no runtime crash. The user sees a list of
files, taps one, gets a confusing toast, and the feature appears broken.
The validator will flag methods with `@Suppress("UNUSED_PARAMETER")` +
Toast-only bodies as potential no-op replacements. A pending-decision
safe no-op is acceptable only when the entire share/open pipeline behind
it has been dismantled: no reachable intent construction, `EXTRA_STREAM`,
URI grants, `FileProvider` staging, or async preparation job remains.

**Note:** `ACTION_VIEW` for opening files in a viewer uses the same ICC
TransferFile mechanism as `ACTION_SEND` for sharing. From the Dynamics
perspective, "open in viewer" and "share to app" are both file transfers
between containers. The existing `TransferFileService` / helper class
can handle both — pass the single file with the appropriate MIME type.

**Native viewer rule for secure media:** If the app opens
secure-container-owned media with `Intent.ACTION_VIEW`,
`MediaStore.ACTION_REVIEW`, or `Intent.CATEGORY_APP_GALLERY`, classify
that path as **must migrate** or **remove**. Do not treat it as a
"controlled export" just because the end user tapped the gallery button.
User action is not a waiver for unmanaged egress of secure media.
If the product insists on unmanaged external viewing/export, do not silently
preserve it. Remove or block the unmanaged path and record the decision in
`egressFeatureDecisions[]` and the final report.

### 3. Audit File Storage Paths (MANDATORY)

Before implementing the helper class, determine how the app stores files:

```bash
# Does the app use GD file APIs already?
rg "com\.good\.gd\.file\." -g "*.java" -g "*.kt" -l ${in_scope_main_src}

# Does the app use standard Java file APIs for data storage?
rg "java\.io\.File\b|Context\.getFilesDir|java\.io\.FileOutputStream" \
  -g "*.java" -g "*.kt" -l ${in_scope_main_src}
```

| App stores files using... | ICC-ready? | Action |
|---|---|---|
| `com.good.gd.file.*` APIs (container-relative paths) | Yes | Pass container paths to `sendTo()` |
| `java.io.File` / `getFilesDir()` / public storage for app data | **No** | **STOP** — complete prompts `05a`–`05z` / `40-secure-file-storage.md` §7 first |

**Do not** implement sandbox-to-container staging at ICC send time. ICC still
depends on `secureFileStorage` being genuinely closed, but that closure is
enforced at prompt `10`'s final gate rather than by blocking prompt `08`
recording mid-run.

### 3b. Create TransferFileService Helper (container paths only)

Create a helper class that encapsulates AppKinetics service discovery and
sending. Attachment paths must already be GD container paths from secure storage
migration. This keeps ICC logic out of Activities/Fragments.

The helper must provide positive sender wiring evidence:

- `GDAndroid.getInstance().getServiceProvidersFor(...)` for runtime Dynamics
  provider discovery.
- `GDServiceClient.sendTo(...)` only after the user has selected a discovered
  provider address.
- A background executor/coroutine/thread path for the `sendTo(...)` call; UI
  handlers should only launch the chooser and dispatch work.

```java
package com.yourpackage.data;

import android.app.Activity;
import android.content.Context;
import com.good.gd.GDAndroid;
import com.good.gd.GDServiceProvider;
import com.good.gd.GDServiceType;
import com.good.gd.icc.GDICCForegroundOptions;
import com.good.gd.icc.GDServiceClient;
import com.good.gd.icc.GDServiceException;
import java.util.ArrayList;
import java.util.List;
import java.util.Vector;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class TransferFileService {

    public static final String SERVICE_ID = "com.good.gdservice.transfer-file";
    public static final String SERVICE_VERSION = "1.0.0.0";
    public static final String SERVICE_METHOD = "transferFile";
    private static final ExecutorService executor = Executors.newSingleThreadExecutor();

    /**
     * Discover Dynamics apps on this device that accept file transfers.
     * Excludes the calling app itself.
     */
    public List<GDServiceProvider> getAvailableProviders(Context context) {
        Vector<GDServiceProvider> all = GDAndroid.getInstance()
                .getServiceProvidersFor(SERVICE_ID, SERVICE_VERSION,
                        GDServiceType.GD_SERVICE_TYPE_APPLICATION);
        List<GDServiceProvider> filtered = new ArrayList<>();
        String self = context.getPackageName();
        for (GDServiceProvider p : all) {
            if (!self.equals(p.getAddress())) {
                filtered.add(p);
            }
        }
        return filtered;
    }

    /**
     * Send files to a target Dynamics app.
     * MUST be called on a background thread.
     *
     * @param targetAddress  package name from GDServiceProvider.getAddress()
     * @param gdContainerPaths  paths in the GD secure container
     */
    public void sendFiles(String targetAddress, List<String> gdContainerPaths)
            throws GDServiceException {
        String[] absolute = new String[gdContainerPaths.size()];
        for (int i = 0; i < gdContainerPaths.size(); i++) {
            String p = gdContainerPaths.get(i);
            absolute[i] = p.startsWith("/") ? p : "/" + p;
        }
        GDServiceClient.sendTo(
                targetAddress,
                SERVICE_ID,
                SERVICE_VERSION,
                SERVICE_METHOD,
                null,
                absolute,
                GDICCForegroundOptions.PreferPeerInForeground);
    }

    /**
     * Show chooser and send on background thread.
     * gdContainerPaths must already live in the Dynamics secure container.
     */
    public void showShareChooser(Activity activity, List<String> gdContainerPaths) {
        // ... discovery UI, then:
        executor.execute(() -> {
            try {
                sendFiles(targetAddress, gdContainerPaths);
                activity.runOnUiThread(() -> /* show success toast */);
            } catch (Exception e) {
                activity.runOnUiThread(() -> /* show failure toast */);
            }
        });
    }
}
```

### 4. Create ICC Listener (Client + Service)

Create a singleton listener for ICC callbacks. Sender code that calls
`GDServiceClient.sendTo(...)` must register a `GDServiceClientListener` for
outgoing transfer responses, errors, and progress callbacks.

If the app also provides/receives the TransferFile service, declare provider
handling in the same listener (or a second provider listener) by implementing
`GDServiceListener` and registering `GDService.setServiceListener(...)`.
Provider evidence includes `GDServiceListener`, `GDService.replyTo(...)`,
incoming AppKinetics message handling, or a TransferFile service declaration.

**IMPORTANT**: `GDServiceClientListener` has **four** abstract methods, not
two. The commonly forgotten methods are `onReceivingAttachments()` and
`onReceivingAttachmentFile()`. Missing either causes a compile error.

```java
import com.good.gd.icc.GDServiceClientListener;
import com.good.gd.icc.GDServiceListener;
import com.good.gd.icc.GDServiceError;
import com.good.gd.icc.GDServiceErrorCode;
import com.good.gd.icc.GDService;
import com.good.gd.icc.GDICCForegroundOptions;

public class ICCServiceListener implements GDServiceClientListener, GDServiceListener {

    // Singleton — one listener per process
    private static final ICCServiceListener INSTANCE = new ICCServiceListener();
    public static ICCServiceListener getInstance() { return INSTANCE; }

    // --- GDServiceClientListener (4 required methods) ---

    // Response to our outgoing transfer
    @Override
    public void onReceiveMessage(String application, Object params,
                                 String[] attachments, String requestId) {
        if (params instanceof GDServiceError) {
            // Log error; show user feedback via callback/event bus
        }
    }

    // Confirmation that sendTo() completed
    @Override
    public void onMessageSent(String application, String requestId,
                               String[] attachments) {
        // Transfer sent successfully
    }

    // Progress: peer is sending N attachments (stub if not needed)
    @Override
    public void onReceivingAttachments(String application,
                                       int numberOfAttachments,
                                       String requestID) {
        // Optional: track progress
    }

    // Progress: receiving a specific file (stub if not needed)
    @Override
    public void onReceivingAttachmentFile(String application,
                                          String path, long size,
                                          String requestID) {
        // Optional: track progress
    }

    // --- GDServiceListener (incoming transfers) ---

    @Override
    public void onReceiveMessage(String application, String service,
                                 String version, String method, Object params,
                                 String[] attachments, String requestId) {
        if (!"com.good.gdservice.transfer-file".equals(service)) {
            sendError(GDServiceErrorCode.GDServicesErrorServiceNotFound,
                      application, requestId);
            return;
        }
        if (!"transferFile".equals(method)) {
            sendError(GDServiceErrorCode.GDServicesErrorMethodNotFound,
                      application, requestId);
            return;
        }

        // Process received files — paths are in the GD secure container
        for (String path : attachments) {
            // Copy to app's media directory, insert into DB, etc.
            // Use com.good.gd.file.FileInputStream to read
        }
    }

    private void sendError(GDServiceErrorCode code, String app, String reqId) {
        try {
            GDService.replyTo(app, new GDServiceError(code),
                    GDICCForegroundOptions.PreferPeerInForeground, null, reqId);
        } catch (Exception e) { /* log */ }
    }
}
```

### 5. Register ICC Listeners with Authorization-Aware Lifecycle

Use one of the sample-backed patterns:
- Register listeners during initialized app/model setup, then execute ICC operations only after authorization.
- Or register listeners from `onAuthorized()`.

Both are acceptable if secure API usage (sending/processing attachments) is gated by authorization state.
For sender-only apps, `GDServiceClient.setServiceClientListener(...)` is
required. `GDService.setServiceListener(...)` is required when provider code
exists; do not add it as a meaningless stub if the app is not a provider.

```java
// Example registration point (Application/model setup or onAuthorized):
try {
    ICCServiceListener listener = ICCServiceListener.getInstance();
    GDServiceClient.setServiceClientListener(listener);
    // Required only when this app receives/provides the TransferFile service:
    GDService.setServiceListener(listener);
} catch (GDServiceException e) {
    Log.e(TAG, "Failed to register ICC listeners", e);
}
```

### 6. Replace Share/Export UI

For each sharing path classified as "must migrate" in Step 2:

1. **Remove** the existing `ACTION_SEND` / `createChooser` / `FileProvider` code.
2. **Add** a Dynamics provider chooser dialog:

```java
List<GDServiceProvider> providers = transferFileService.getAvailableProviders(context);
if (providers.isEmpty()) {
    Snackbar.make(view, "No compatible apps available for sharing.",
            Snackbar.LENGTH_SHORT).show();
    return;
}

String[] names = new String[providers.size()];
for (int i = 0; i < providers.size(); i++) {
    names[i] = providers.get(i).getName();
}

new MaterialAlertDialogBuilder(context)
        .setTitle(R.string.icc_share_to)
        .setItems(names, (dialog, which) -> {
            String address = providers.get(which).getAddress();
            executor.execute(() -> {
                try {
                    transferFileService.sendFiles(address, filePaths);
                    runOnUiThread(() -> Snackbar.make(view,
                            R.string.icc_share_sent,
                            Snackbar.LENGTH_SHORT).show());
                } catch (GDServiceException e) {
                    runOnUiThread(() -> Snackbar.make(view,
                            R.string.icc_share_failed,
                            Snackbar.LENGTH_SHORT).show());
                }
            });
        })
        .setNegativeButton(android.R.string.cancel, null)
        .show();
```

3. **Update UI labels**: Use "Share" (not "Share via AppKinetics") — the
   user should see a natural UX. It is understood that only Dynamics apps
   will appear as share targets.
4. **Update string resources**: Add strings for the chooser title,
   success/failure feedback, and empty state.

### 6a. Post-ICC FileProvider Manifest/Resource Cleanup (MANDATORY)

After replacing share-sheet egress with ICC, audit manifest + XML resources:

```bash
# Source call-sites (must be gone for migrated paths)
rg "FileProvider\.getUriForFile" -g "*.java" -g "*.kt" -n ${in_scope_main_src}
rg "Intent\.ACTION_SEND|ACTION_SEND_MULTIPLE|Intent\.createChooser|EXTRA_STREAM" \
  -g "*.java" -g "*.kt" -n ${in_scope_main_src}

# Manifest provider declarations + FILE_PROVIDER_PATHS metadata
rg "androidx\.core\.content\.FileProvider|android\.support\.FILE_PROVIDER_PATHS|android:authorities" \
  -g "AndroidManifest.xml" -n ${in_scope_manifests}

# Path resources (file_paths.xml or equivalent)
rg "<files-path|<cache-path|<external-path|<external-files-path|<external-cache-path|<root-path" \
  -g "*.xml" -n ${in_scope_res_dirs}
```

Rules:

1. If migrated ICC paths no longer use `FileProvider.getUriForFile`, remove:
   - `<provider android:name="androidx.core.content.FileProvider" ...>`
   - `android.support.FILE_PROVIDER_PATHS` metadata
   - `res/xml/file_paths.xml` (or equivalent provider path resources)
2. If `FileProvider` must remain for a non-sharing path, add an explicit
   migration-report entry (blocking item + manual TODO) covering:
   - **why** FileProvider is still required,
   - **exact path tags** exposed (`files-path`, `cache-path`, etc.),
  - whether those paths can hold container-derived or app-owned data,
   - why the retained surface is safe under the Dynamics DLP contract.
3. Treat these tags as security-critical review:
   - `external-path`, `external-files-path`, `external-cache-path`, `root-path`
     are hard-fail surfaces for Dynamics migration unless manually justified
    as not carrying app data and approved for follow-up remediation.
   - `files-path` / `cache-path` still require explicit DLP review when
     retained after ICC migration.

### 6b. Compose-First Provider Chooser (MANDATORY when `@Composable` ICC UI exists)

When share/export UI lives in Jetpack Compose screens, **do not** use
`MaterialAlertDialogBuilder`, `AlertDialog.Builder`, or
`TransferFileService.showShareChooser(Activity, …)` from `@Composable`
code paths.

1. Copy `templates/icc/GDICCProviderShareDialog.kt` into the app
   package (replace `__APP_PACKAGE__`).
2. Map `GDServiceProvider` rows to `ICCProviderOption(displayName, targetAddress)`.
3. Show `GDICCProviderShareDialog` from Compose state (`remember { mutableStateOf(false) }`).
4. On provider selection, call existing `sendFiles(address, gdContainerPaths)` or
   `GDServiceClient.sendTo(...)` on a background executor — secure transfer
   behavior is unchanged; only the chooser UX layer is Compose-native.

```kotlin
var showChooser by remember { mutableStateOf(false) }
val options = remember {
    transferFileService.getAvailableProviders(context)
        .map { ICCProviderOption(it.name, it.address) }
}
Button(onClick = { showChooser = true }) { Text("Share") }
if (showChooser) {
    GDICCProviderShareDialog(
        title = stringResource(R.string.icc_share_to),
        providers = options,
        onProviderSelected = { option ->
            showChooser = false
            executor.execute {
                transferFileService.sendFiles(option.targetAddress, gdPaths)
            }
        },
        onDismiss = { showChooser = false },
    )
}
```

**Forbidden in Compose ICC screens:**
- `MaterialAlertDialogBuilder` / `AlertDialog.Builder` for provider lists
- Calling legacy `showShareChooser(activity, paths)` from `@Composable` buttons

**View/XML-only modules** may keep `MaterialAlertDialogBuilder` per §6 below.
Record any non-deterministic Compose ICC chooser remnants in prompt 10
`manualTodos[]` with `coverage.icc.status` = `partial`.

### 6c. Provider Chooser Anti-Pattern Sweep (MANDATORY)

After wiring `sendTo()`, verify no production shortcut bypasses user
destination choice:

```bash
rg "providers\\.first\\(|providers\\[0\\]|providers\\.get\\(0\\)" \
  -g "*.java" -g "*.kt" -n ${in_scope_main_src}
```

Rules:
- A bare `providers.first()` / index shortcut in a share path is not
  allowed for production.
- If a single-provider fast path is intentionally retained, it must be
  guarded by `if (providers.size == 1)` and include a comment explaining
  why the multi-provider chooser path still exists for `size > 1`.

### 7. Handle Incoming Transfers (if app is also a service provider)

If the app should receive files from other Dynamics apps:

1. Process attachments in `GDServiceListener.onReceiveMessage()`.
2. Attachment paths are in the ICC inbox within the GD container — read
   with `com.good.gd.file.FileInputStream`.
3. Copy received files to the app's own storage directory.
4. Generate thumbnails and insert database records as needed.
5. Reply to the sender with success or error via `GDService.replyTo()`.

### 8. UEM Registration

The app must be registered as a TransferFile service consumer (and
optionally provider) in the UEM console. No `settings.json` change is
required for consuming the service.

For service providers, optionally declare in `settings.json`:

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

## Common Pitfalls

1. **File paths must be GD container paths, NOT Android OS paths** —
   This is the most common ICC failure. If the app stores files using
   `java.io.File` (standard Android), complete prompts 05a-05z first so
   bytes live in the Dynamics container from the moment they are written.
   Do not add sandbox-to-container staging at ICC send time. Android OS
   paths like `/data/data/com.example/files/photo.jpg` look valid but
   are invisible to the GD container. The transfer will appear to
   succeed but the receiving app gets no file data and hangs. See Step 3
   above for the mandatory file path audit.
2. **`sendTo()` threading** — prefer a background executor
   (`Executors.newSingleThreadExecutor()`) for large attachments and robust UX.
   Some samples call `sendTo()` directly from UI handlers; enterprise apps should
   avoid long-running transfers on the UI thread.
3. **`GDServiceClientListener` has FOUR methods, not two** — Missing
   `onReceivingAttachments()` or `onReceivingAttachmentFile()` causes a
   compile error. Stub them if the app does not need progress tracking.
4. **Listener lifecycle mismatch** — listeners may be registered early, but
   do not call ICC send/receive file operations until authorization is complete.
   Keep authorization gating explicit.
5. **The 7-arg and 4-arg `onReceiveMessage` overloads serve different
   purposes**: the 7-arg form is for incoming service requests (you are
   the provider); the 4-arg form is for responses to requests you sent.
6. **`GDAndroid.getServiceProvidersFor()` can return the current app** —
   always filter out `context.getPackageName()` from the chooser list.
7. **No fallback to generic sharing** — if no Dynamics providers are
   found, show a user-friendly message. Do **not** fall back to
   `ACTION_SEND` or `createChooser`.

---

## Critical Notes

- ICC only works between Dynamics-enabled apps on the same device
- File paths in `attachments` must be within the secure container
  (use `com.good.gd.file` APIs, not standard `java.io.File`)
- ICC operations require authorization — send/receive file operations must be gated by authorized state
- Standard Android sharing (`ACTION_SEND`) bypasses the Dynamics container
  and leaks data to unmanaged apps — this is why migration is required
- **Do not keep generic sharing as a fallback** even if no Dynamics
  providers are available — this defeats the entire DLP policy

See `60-icc-transferfileservice.md` for the full steering reference.

---

## Output

- Sharing path inventory (path, data sensitivity, classification, action taken)
- File-origin audit table (attachment producer, API family, in-container path, implementation)
- ICC integration code changes (TransferFileService, ICCServiceListener,
  listener registration, UI changes)
- Positive ICC wiring evidence:
  `getServiceProvidersFor`, `GDServiceClient.setServiceClientListener`,
  `GDService.setServiceListener` when provider code exists, and background
  dispatch for `GDServiceClient.sendTo`
- Service registration changes (if app is a provider)
- String resource additions
- Code diffs with explanation
- Confirmation that no generic Android sharing to unmanaged apps remains
- Confirmation that no chooser bypass shortcuts remain (`providers.first`, index shortcuts)
- Confirmation that stale FileProvider manifest/resource surfaces were removed
- If FileProvider retained: explicit DLP justification (why, exposed paths, sensitivity, contract safety)
- Testing notes (verify secure sharing between Dynamics apps)

---

## Record execution

After this prompt completes — whether it migrated ICC paths or skipped
because `icc` is `not-applicable` — append the execution record so
prompt 10's hard gate sees that the plan was honored:

```bash
# Migrated case
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 08 \
    --status completed \
    --files-touched <comma-separated relative paths>

# Skipped case (domain marked not-applicable in migration-analysis.json)
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 08 \
    --status skipped \
    --note "icc not-applicable per executionPlan"
```

## Enterprise Hardening Addendum (No generic sharing)

- Generic Android sharing (`ACTION_SEND`, chooser/file-provider file sharing) must not remain.
- Public-link scenarios use explicit `ACTION_VIEW` with allowlisted `https://` hosts only.
- No "keep as-is" exception exists for file/content egress to unmanaged apps.
