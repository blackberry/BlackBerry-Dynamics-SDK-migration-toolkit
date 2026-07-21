## Task: Analyze iOS Application for Dynamics Migration

Goal: Understand the existing application's architecture, APIs, and data
flows before making any changes. This analysis drives the migration plan.

**This prompt MUST be run first, before any other migration prompt.**

Classify the app's **complexity tier** (A/B/C) per
`steering/12-capability-and-support-model.md` and record it in the analysis
output. This tier drives release-readiness expectations in Prompt 10.

**Flutter gate:** If Prompt `00pre` (or this prompt) detects a Flutter hybrid,
classify **Tier C**, record Flutter in `unsupportedDetections`, and do **not**
plan Dynamics code migration of the Flutter Runner in this toolkit release.
See `steering/13-unsupported-feature-detection-matrix.md`.

---

## Steps

### -1. Clean Output Directory (MANDATORY — Run Before Anything Else)

The `dynamics-migration-tool/output/` directory may contain stale files
from a previous migration run (possibly for a different project). These
MUST be removed before starting a new migration to prevent:
- Corrupted JSON from appending new content to old files
- Validation failures from stale `migration-report.json` or
  `migration-analysis.json` that don't match the current project
- The agent entering a delete/retry loop when `validate.sh` reports
  "Extra data" on a file containing multiple JSON objects

```bash
# Note: bootstrap.sh (called from 00pre) already cleaned stale artifacts.
# If you are re-running only prompt 00, remove just analysis and downstream artifacts:
rm -f dynamics-migration-tool/output/migration-analysis.json \
      dynamics-migration-tool/output/migration-plan-state.json \
      dynamics-migration-tool/output/migration-report.json \
      dynamics-migration-tool/output/architecture-diagrams.md \
      dynamics-migration-tool/output/.last-check.json
# Create the directory if it doesn't exist
mkdir -p dynamics-migration-tool/output
```

**Verify the directory is empty** (only `.gitkeep` should remain, if present):
```bash
ls -la dynamics-migration-tool/output/
```

If any `.json` or `.md` files remain, delete them now. Do NOT proceed
with analysis while stale output files exist.

### 0. Build Readiness Attestation (Developer Responsibility)

Do **not** run a baseline build in this prompt.

The developer is responsible for starting migration from a project that
already builds successfully. Ask for explicit confirmation before
proceeding:

> "Confirm that the app builds cleanly on your machine before migration
> starts (yes/no)."

If the answer is **no**, STOP and ask the developer to fix build issues
before continuing.

If needed, the developer can run optional diagnostics manually:
- `./dynamics-migration-tool/validate.sh --preflight`

### 0b. Detect Flutter Hybrid (Out of Scope This Release)

Before deep API inventory, re-confirm Flutter signals (even if `00pre` already
gated). Treat **any** of the following as Flutter hybrid detection:

```bash
# From the app project root (adjust paths if the iOS host lives under ios/)
test -f pubspec.yaml && echo "pubspec.yaml"
ls GeneratedPluginRegistrant.* ios/Runner/GeneratedPluginRegistrant.* 2>/dev/null
rg -l "FlutterEngine|FlutterViewController|GeneratedPluginRegistrant|import Flutter" \
  --glob '*.swift' --glob '*.m' --glob '*.h' . 2>/dev/null | head
```

Also check for a `Flutter/` directory, CocoaPods `Flutter` pod, or
`Flutter.framework` linkage on the Runner target.

**If Flutter is detected:**

1. Set complexity tier to **C**.
2. Add an `unsupportedDetections[]` entry, for example:
   ```json
   {
     "feature": "Flutter-hybrid",
     "files": ["pubspec.yaml", "ios/Runner/AppDelegate.swift"],
     "reason": "No official BlackBerry Dynamics Flutter SDK; this toolkit release does not migrate Flutter hosts",
     "workaroundDetected": false
   }
   ```
3. Add a high-priority `manualTodoCandidates` item: redesign on native
   UIKit/SwiftUI Dynamics, or use an officially supported cross-platform SDK
   (e.g. Dynamics React Native) — do not use this kit to wire FlutterEngine /
   plugin registrants under Dynamics.
4. In the ordered migration plan, mark Dynamics implementation prompts
   (`01`–`09`, `11`) as **not applicable / blocked — Flutter out of scope**.
   Analysis (`00`/`00b`) and report (`10`/`12`) may still document the finding.
5. **Do not** invent or prescribe Flutter + Dynamics window/engine/plugin
   migration steps in this analysis.

If Flutter is **not** detected, continue normally.

### 0c. Detect Share Extensions / App Extensions (Dynamics-unsupported)

Scan `target-map.json` and Info.plist files for Share Extensions and related
app extensions. Prefer:

```bash
rg -n "com\\.apple\\.share-services|NSExtensionPointIdentifier" --glob '*.plist' .
```

Also read `output/target-map.json` for `type: extension|widget` targets and
any `extensionPointIdentifier` / Share-named targets.

**If a Share Extension is detected:**

1. Add `unsupportedDetections[]`:
   ```json
   {
     "feature": "Share-Extension",
     "files": ["<ShareExtension>/Info.plist"],
     "reason": "BlackBerry Dynamics does not support Share Extensions — no secure container access",
     "workaroundDetected": false
   }
   ```
2. Add high-priority `manualTodoCandidates`: exclude Share Extension from
   Dynamics shipping (scheme/Archive/Embed); remove App Group sensitive
   bridges; redesign share-in via main-app URL handoff + post-auth
   `GDFileManager` if product requires it.
3. Follow `steering/17-app-extensions-and-share-extensions.md` — continue
   main-app migration; **never** Dynamics-authorize or link Dynamics into
   the extension.
4. Apply the same isolate / non-shipping treatment to WidgetKit / Intents /
   Safari / Notification Service extensions.

If none detected, continue normally.

### 0a. Detect Swift Language Version and Deployment Target Compatibility

Capture the project's Swift version and deployment target early — these drive API
usage patterns throughout the migration.

```bash
# Swift version from build settings
xcodebuild -showBuildSettings -scheme YourApp 2>/dev/null | grep SWIFT_VERSION

# Deployment target from build settings
xcodebuild -showBuildSettings -scheme YourApp 2>/dev/null | grep IPHONEOS_DEPLOYMENT_TARGET
```

**Record both values** in the analysis output.

**Deployment target rules for Dynamics:**
- BlackBerry Dynamics SDK 15.x requires iOS **>= 17.0**.
- If the project already targets 17.0 or higher, **keep the existing target**.
  Only raise it to 17.0 if it is below 17.0. Never lower a higher target.
- If the project targets a version above 17.0 (e.g., iOS 18, 26), it may use
  APIs unavailable at iOS 17. Lowering the target would introduce compile errors
  unrelated to Dynamics. Flag these as `preExistingApiAvailabilityRisks` in the
  analysis artifact if the target must change.
- Flag BlackBerry Protect Mobile / SafeBrowsing usage for removal (unsupported
  as of SDK 15.0).
- Flag native `GDCryptoPKCS7` / PKCS#7 call sites (`GDPKCS7_*`) for OpenSSL 3.x
  flag review (`GDPKCS7_BINARY`, `GDPKCS7_DETACHED`) and FIPS cipher posture
  (prefer AES over Triple-DES when FIPS is enabled).

**Swift version awareness:**
- Detect whether the project uses Swift 5 or Swift 6 (strict concurrency).
- Swift 6 projects may use `Sendable`, `@MainActor`, structured concurrency
  (`async/await`) — the migration must preserve these patterns.
- Some ObjC-bridged APIs (e.g., `GDSocket`, `GDDirectByteBuffer`) have different
  Swift-bridged signatures depending on the Swift version. Always verify against
  the installed SDK headers rather than assuming a particular bridging.

### 0b. SDK Header Availability Check (Mandatory Before Analysis)

Before analyzing which Dynamics APIs to use, verify the SDK headers are
accessible. This prevents the agent from using incorrect type names or
signatures. Run:

```bash
# Check that the primary Dynamics headers are resolvable
rg "GDiOS\|GDFileManager\|GDURLLoadingSystem\|GDServiceClient" \
  Pods/BlackBerryDynamics --include="*.h" -l 2>/dev/null | head -5
```

If the Pods directory does not exist yet (pre-`pod install`), note it in the
analysis output and use the public documentation references from
`99-docs-and-references.md` as fallback. Do NOT fabricate API signatures —
mark them as `"confidence": "docs-only"` in the analysis artifact domains.

**SDK Symbol Verification Rule**: Before proposing any non-standard helper API
as a migration replacement (e.g., `bbGlassEffect`, custom wrappers), verify
the symbol exists in the installed SDK headers. Run:

```bash
rg "symbolName" Pods/BlackBerryDynamics --include="*.h" 2>/dev/null
```

If the symbol is not found in headers or public documentation, do NOT propose
it as a migration path. Use only documented, verifiable SDK APIs.


### 1. Project Structure Discovery

- Identify the project type (`.xcodeproj` only, or `.xcworkspace` with CocoaPods/SPM)
- **Record integration method** using this decision matrix:
  - CocoaPods-only dependencies -> Dynamics via CocoaPods
  - SPM-only dependencies -> Dynamics via official SPM
    (`https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK`)
  - Mixed CocoaPods + SPM dependencies -> Dynamics via official SPM
    (`https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK`)
  - Neither package manager present -> manual framework
  This determines import statements and integration commands used later.
- Read `Podfile` (if present) — note all dependencies
- Read `Package.swift` or SPM packages (if present)
- **Resolve canonical build/integration entrypoint (required)**:
  - If `Podfile` exists or `.xcworkspace` exists, set canonical entrypoint to
    `.xcworkspace` for all operational commands (`xcodebuild`, Prompt 01 checks,
    pod-related integration).
  - Use `.xcodeproj` only when workspace is truly absent.
  - If both `.xcodeproj` and `.xcworkspace` exist, record this as
    `entrypointAmbiguityDetected: true` and explicitly select workspace.
- **Detect mixed dependency boundaries (required)**:
  - Map each file-storage call site to its owning target/module.
  - If file-storage call sites are in an SPM target while Dynamics SDK is
    integrated only in the app target (for example via CocoaPods), verify
    whether the SPM target can import Dynamics modules.
  - If the SPM target cannot import Dynamics and there is a clear app
    composition root (`AppDelegate`, app bootstrap, or DI container), mark
    Prompt 05 strategy as: **auto-apply app-level adapter injection**.
  - If uncertain (no stable composition root, broad constructor redesign,
    or ownership ambiguity), mark strategy as: **suggest/manual refactor**.
- Read `Info.plist` — note:
  - `CFBundleIdentifier` (bundle ID)
  - `CFBundleDisplayName`
  - Existing URL schemes (`CFBundleURLTypes`)
  - Existing capabilities and entitlements
  - Deployment target
  - Privacy usage descriptions
- Read `.entitlements` file — note:
  - Existing Keychain groups
  - App Groups
  - Other capabilities
- Read the Xcode project structure:
  - Identify all targets (main app, extensions, test targets, etc.)
  - Identify build configurations
  - Note if BitCode is enabled

### 1a. SPM Dependency Source Inspection (Required When Wrappers Are Used)

SPM packages can hide migration-relevant storage/network logic behind helper APIs.
Do not assume wrapper behavior from call-site names alone.

1. Read `<project>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
   and capture package identities/versions.
2. Locate package checkouts under DerivedData:
   `~/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/<PackageName>/`
3. For each package used by the app target, scan checkout sources for:
   - storage: `FileManager`, `ModelContainer`, `NSPersistentContainer`, `sqlite3`
   - networking: `URLSession`, `NWConnection`, `URLProtocol`
4. If a package wraps persistence/networking setup, record wrapper details in
   `migration-analysis.json` call-site evidence and lower confidence until
   wrapper semantics are verified.

If checkouts are unavailable in the local machine cache, record this as
`manualTodoCandidates` with `reason: "SPM source not present in DerivedData"`.

### 2. Source Code Inventory

Read ALL Swift and Objective-C source files in the project. For each file, identify:

- **File I/O**: `FileManager.default`, `FileHandle`, `InputStream`,
  `OutputStream`, `Data.write(to:)`, `String.write(to:)`,
  `contentsOfFile:`, `NSKeyedArchiver`/`NSKeyedUnarchiver` to disk
- **Core Data**: `NSPersistentContainer`, `NSPersistentStoreCoordinator`,
  `NSManagedObjectContext`, `@FetchRequest`, `NSFetchedResultsController`,
  `.xcdatamodeld` files
  - Cross-check `.xcdatamodeld` directories against `project.pbxproj` file
    references and source usage. If a model directory is orphaned (not
    referenced by project/code), flag it as `manualTodoCandidates`:
    "abandoned Core Data schema candidate for removal".
- **SwiftData** (UNSUPPORTED): `@Model`, `ModelContainer`, `ModelContext`,
  `@Query`, `#Predicate` — flag as unsupported feature. If detected, produce
  a `swiftDataRedesignPlan` section in the analysis artifact listing affected
  entities, repositories, and a recommended Core Data migration path. Mark the
  Core Data prompt (04b) as "design-only pending developer approval".
- **Raw SQLite**: `sqlite3_open()`, `sqlite3_prepare_v2()`, FMDB usage,
  GRDB usage, SQLite.swift usage
- **Networking**:
  - Foundation networking: `URLSession.shared`, custom `URLSession`,
    `URLSessionConfiguration`, `dataTask`/`uploadTask`/`downloadTask`,
    async `data(for:)`, delegate/auth challenge methods
  - Reachability-triggered startup requests and other pre-auth initiators
  - Background sessions (`background(withIdentifier:)`,
    `handleEventsForBackgroundURLSession`)
  - Custom protocol and trust surfaces: `URLProtocol`, `NSURLProtocol`,
    certificate pinning, trust evaluation (`SecTrust`, server-trust delegate
    handling), proxies/custom connection behavior
  - Legacy Foundation networking: `NSURLConnection`
  - Direct sockets and wrappers: `NWConnection`, Network framework listeners,
    `CFSocket`, `CFStreamCreatePairWithSocketToHost`, `NSStream`,
    `GCDAsyncSocket`/CocoaAsyncSocket, POSIX socket wrappers, WebSocket wrappers
- **WebView**:
  - `WKWebView`, `WKWebViewConfiguration`, `WKNavigationDelegate`,
    `WKUIDelegate`, `WKScriptMessageHandler`
  - Support initialization evidence: `WKWebView+GDNET`,
    `GDURLLoadingSystem.supportWKWebView`
  - Content loading and routing: `load(_:)`, `loadFileURL`, `loadHTMLString`,
    HTML `baseURL`, custom scheme handlers (`WKURLSchemeHandler`), process pools,
    website data stores/cookies, navigation/auth challenges
  - High-risk/unsupported paths: downloads/uploads, content-rule lists,
    non-page-world `WKContentWorld`, `removeAllUserScripts()`,
    `SFSafariViewController`
- **Pasteboard/Clipboard**: `UIPasteboard.general`, programmatic copy/paste,
  `UIPasteConfiguration`, drag and drop handlers
- **External Data Movement + ICC**:
  - `UIActivityViewController`
  - `UIDocumentPickerViewController`
  - `UIDocumentInteractionController`
  - Files app integrations / file providers / document providers
  - iCloud/CloudKit document movement surfaces
  - Photos import/export APIs
  - AirDrop and drag/drop handoff
  - Quick Look file exposure paths
  - URL scheme handling (`application(_:open:options:)`) and Universal Links
  - third-party share/export SDKs and opaque wrappers
  - temporary export/staging files and archive-before-share flows
  - WebView downloads/uploads that become external movement
  - app extensions/widgets/share extensions touching protected data
- **UserDefaults for Sensitive Data**: `UserDefaults.standard` storing tokens,
  credentials, PII, or business data
- **Keychain**: `SecItemAdd`, `SecItemCopyMatching`, keychain wrapper
  libraries (KeychainAccess, SwiftKeychainWrapper)
- **Background Processing**: `BGTaskScheduler`, background fetch,
  `beginBackgroundTask(withName:)`, push notification handling,
  silent notifications
- **Startup Flow**: What happens in `application(_:didFinishLaunchingWithOptions:)`,
  `SceneDelegate` setup, root ViewController's `viewDidLoad` — specifically
  what data access (database, files, network, policy) happens during initialization
- **Share Extension** (UNSUPPORTED by Dynamics): `com.apple.share-services`,
  Share Extension targets — **call out + isolate** per
  `17-app-extensions-and-share-extensions.md` (do not Dynamics-enable the
  extension; exclude from Dynamics shipping; remove App Group bridges)
- **Other App Extensions** (UNSUPPORTED): WidgetKit, Intents, Safari,
  Notification Service/Content, Action Extensions — same isolate doctrine
- **App Clips** (UNSUPPORTED): App Clip targets — flag as unsupported
- **Flutter hybrid** (UNSUPPORTED / out of scope this release): `pubspec.yaml`,
  `GeneratedPluginRegistrant`, `FlutterEngine` / `FlutterViewController`,
  Flutter Runner host — flag immediately; do **not** plan Dynamics migration of
  Flutter UI or Dart plugins with this toolkit version (see step 0b)
- **CloudKit / iCloud** (UNSUPPORTED for secure data): `CKContainer`,
  `NSUbiquitousKeyValueStore`, iCloud document storage — flag as
  unsupported for sensitive data
- **SwiftUI vs UIKit**: Note which UI framework is used (or both)
- **Third-Party Libraries**: Libraries that read/write files and may be
  incompatible with Dynamics secure container — Kingfisher, SDWebImage
  (image caching), zip libraries, document viewers, CameraX equivalents
- **Redundant Features** (see `15-redundant-feature-removal.md`): Features
  that Dynamics replaces at the container level — flag for removal:
  - App-level biometric lock (`LocalAuthentication`, `LAContext`, custom
    lock ViewControllers, lock-related UserDefaults keys)
  - App-level data-at-rest encryption (`CryptoKit` for files, `CommonCrypto`,
    `RNCryptor`, `SecKeyCreateEncryptedData`, SQLCipher)
  - App-level screenshot prevention (`UIScreen.isCaptured` observers,
    background blur overlays solely for screenshot prevention)
  - App-level data protection backup (`NSFileProtection` for security,
    custom backup managers)
- **SDK 15.0 removed / crypto audit surfaces**:
  - Protect Mobile / SafeBrowsing / SMS URL-scan integrations — plan removal
  - `GDPKCS7_*` / S/MIME call sites — record OpenSSL 3.x flag + FIPS cipher
    `manualTodos` (see `14-api-provenance-and-replacement-catalog.md`)

### 3. Storyboard and XIB Inventory

Read ALL storyboard and XIB files. Identify:
- `UITextField` instances (note which handle sensitive data)
- `UITextView` instances (note which display sensitive data)
- `WKWebView` instances
- Custom views that wrap sensitive data
- Navigation flows that may trigger before authorization

### 4. Data Sensitivity Classification

For each API usage found, classify the data as:
- **Sensitive**: Must be migrated to Dynamics secure APIs (credentials,
  PII, business data, tokens, encryption keys)
- **Semi-sensitive**: Should be migrated (user-generated content, messages,
  app state)
- **Non-sensitive**: May remain native with justification (UI cache,
  temporary layout data, public static content)

### 5. Produce Migration Plan

Based on the analysis, produce a structured migration plan:

```
## Application Summary
- App name: [from Info.plist]
- Bundle ID: [from Info.plist]
- Language: [Swift / Objective-C / Mixed]
- UI Framework: [UIKit / SwiftUI / Both]
- Deployment target: [current]
- AppDelegate: [exists / SceneDelegate / SwiftUI App]
- ViewControllers: [list all with their roles]
- App Extensions: [list any — flag as unsupported]

## API Usage Inventory

| Category | File | API Used | Data Sensitivity | Migration Action |
|----------|------|----------|-----------------|-----------------|
| File I/O | DataManager.swift | FileManager.default | Sensitive | → GDFileManager.default |
| Core Data | CoreDataStack.swift | NSPersistentContainer | Sensitive | → GDPersistentStoreCoordinator |
| SQLite | DBHelper.m | sqlite3_open() | Sensitive | → sqlite3enc_open() |
| Network | APIClient.swift | URLSession.shared | Sensitive | Keep URLSession (auto-routed post-auth) |
| Network | SocketClient.swift | NWConnection | Sensitive | → GDSocket or blocker |
| Pasteboard | ShareVC.swift | UIPasteboard.general | Semi-sensitive | → Review for DLP |

## Unsupported Features Detected

| Feature | Files | Impact |
|---------|-------|--------|
| SwiftData | Models.swift | Must rewrite to Core Data + GDPersistentStoreCoordinator |
| WidgetKit | WidgetExtension/ | Cannot access secure container from extension |
| CloudKit | SyncManager.swift | Data must stay in secure container |

## Startup Flow Analysis
- AppDelegate.didFinishLaunchingWithOptions: [list secure APIs called]
- SceneDelegate setup: [list secure APIs called]
- Root ViewController.viewDidLoad: [list secure APIs called]
- Data that must be deferred to onAuthorized(): [list]

## Migration Phases (in order)

1. [ ] Xcode integration (framework, Keychain Sharing, deployment target)
2. [ ] Info.plist configuration (STOP — ask developer for GDApplicationID)
3. [ ] Authorization & initialization (GDiOS, delegate/notification,
       two-phase startup restructuring)
3b.[ ] Authorization deferral audit (ViewControllers, SwiftUI, Combine,
       async/await, singletons)
4. [ ] Secure SQL database (if applicable)
4b.[ ] Secure Core Data (if applicable)
5. [ ] Secure file storage (if applicable)
6. [ ] Secure networking (if applicable)
7. [ ] Secure WKWebView (if applicable)
8. [ ] AppKinetics ICC (if applicable)
9. [ ] DLP / Pasteboard migration (if applicable)
10.[ ] Migration report generation

## Risks and Considerations
- [List any complex patterns, third-party libraries, or edge cases]
- [Note any startup code that accesses secure APIs before authorization]
- [Note any background processing that needs container access]
- [Flag SwiftData usage — must be rewritten]
- [Flag App Extensions — unsupported]
- [Flag CloudKit/iCloud — data cannot be in secure container]
- [Flag third-party libraries that read/write files]
- [Flag app-level encryption — redundant with Dynamics]
- [Flag app-level biometric lock — redundant with Dynamics]
- [For mixed SPM + CocoaPods boundaries, declare Prompt 05 execution mode:
   `auto-apply-injection` or `suggest-manual`, with reason]
```

### 6. Write Structured Analysis Artifact (Required)

**Prerequisites**: `bootstrap.json` and `target-map.json` must exist in
`dynamics-migration-tool/output/` before writing this file. Read
`bootstrap.json.runId` and carry it forward into this artifact.

**IMPORTANT — File Write Method**: Use a **full-file overwrite** (not a
patch or append) to create this file. In AI IDEs, use the Write/CreateFile
tool — do NOT use StrReplace, ApplyPatch, or any patch-based tool on JSON
output files.

Create `dynamics-migration-tool/output/migration-analysis.json` with:

```json
{
  "schemaVersion": "1.2.0",
  "platform": "iOS",
  "runId": "<must match bootstrap.json runId>",
  "generatedAt": "ISO-8601",
  "entrypointAmbiguityDetected": "boolean",
  "canonicalEntrypoint": "string",
  "entrypointEnforcementApplied": "boolean",
  "developerBuildAttestation": {
    "confirmedCleanBuild": "yes|no",
    "notes": ["string"]
  },
  "appSummary": {
    "name": "string",
    "bundleIdentifier": "string",
    "language": "Swift|Objective-C|Mixed",
    "uiFramework": "UIKit|SwiftUI|Both",
    "deploymentTarget": "string",
    "swiftVersion": "string or null",
    "deploymentTargetAction": "keep|raise-to-17",
    "preExistingApiAvailabilityRisks": ["string"]
  },
  "domains": [
    {
      "name": "authorization|secureFileStorage|secureSql|secureCoreData|secureNetworking|webview|icc|dlpPasteboard|policyManagement",
      "tier": "tier1|tier2|tier3",
      "status": "applicable|not-applicable",
      "evidence": ["string"],
      "risks": ["string"]
    }
  ],
  "executionPlan": [
    {
      "domainId": "authorization|secureFileStorage|secureSql|secureCoreData|secureNetworking|webview|icc|dlpPasteboard|policyManagement",
      "promptId": "03|04|04b|05|06|07|08|09|09b",
      "applicability": "applicable|not-applicable",
      "applicabilityRationale": "string",
      "risk": "high|medium|low",
      "targetIds": ["target-UUID-from-target-map"],
      "callSites": [
        {
          "id": "<domain>:<relative-path>:<line>",
          "targetId": "string",
          "relativePath": "string",
          "symbol": "string",
          "matchedApi": "string",
          "line": "number or null",
          "storageFamily": "sql|coredata|swiftdata|file|stream|archive|cache|preferences|keychain|localCrypto|other",
          "operation": "open|create|read|write|delete|migrate|encrypt|decrypt|unknown",
          "pathOwnership": "secure-container|unmanaged|app-group|shared-container|policy-decision-required|unknown",
          "surface": "share-sheet|document-picker|document-interaction|files|icloud|cloudkit|photos|airdrop|drag-drop|quick-look|file-provider|custom-url|universal-link|pasteboard|third-party-sdk|webview-transfer|other",
          "movementDirection": "unmanaged-to-managed|managed-to-unmanaged|managed-to-managed|metadata-only|unknown-or-bidirectional",
          "sourceEndpoint": "managed|unmanaged|unknown|not-applicable",
          "destinationEndpoint": "managed|unmanaged|unknown|not-applicable",
          "payloadKind": "file|data|metadata|mixed|unknown",
          "policyDependency": "required|optional|none|unknown",
          "inboundSecureCopyStatus": "copied-to-secure-storage|not-required|pending|unknown",
          "outboundApprovalStatus": "approved-managed-destination|approved-exception|blocked|pending|unknown|not-applicable",
          "plaintextStagingStatus": "none|present|unknown",
          "selectedTreatment": "migrated-appkinetics|managed-approved|inbound-secure-copy|removed|blocked|deferred|not-applicable",
          "wrapperLibrary": "raw-sqlite|fmdb|grdb|sqlite.swift|sqlcipher|coredata|swiftdata|native-filemanager|custom-wrapper|none",
          "auxiliaryFiles": ["string"],
          "downstreamReaders": ["string"],
          "proposedTreatment": "migrate|remove|block|defer|not-applicable",
          "transportFamily": "foundation-session|nsurlconnection|direct-socket|websocket|custom-wrapper|wkwebview|other",
          "requestInitiationPoint": "startup|authorized-callback|user-action|background-callback|unknown",
          "sessionConfiguration": "default|ephemeral|background|custom|not-applicable|unknown",
          "delegateHandling": "none|standard|custom-auth-challenge|custom-trust|unknown",
          "executionMode": "foreground|background|mixed|unknown",
          "customProtocolDecision": "none|compatible|conflict-blocked|manual-review|unknown",
          "pinningTrustDecision": "none|compatible|conflict-blocked|manual-review|unknown",
          "backgroundSessionDecision": "none|foreground-deferred|g12-blocker|required-manual|unknown",
          "socketHost": "string|null",
          "socketPort": "number|null",
          "socketTlsMode": "tls|plain|unknown|not-applicable",
          "socketMigrationDecision": "migrated-to-gdsocket|blocked-wrapper|not-applicable|unknown",
          "replacementApi": "string|null",
          "catalogRowId": "string|null",
          "webviewSupportState": "gdnet-imported|supportWKWebView-enabled|both|missing|not-applicable|unknown",
          "webviewInitPoint": "post-auth|pre-auth|unknown|not-applicable",
          "webContentSource": "remote-http|remote-https|local-file|html-string|custom-scheme|mixed|unknown",
          "webContentClassification": "remote-managed|local-managed|local-unmanaged|custom-scheme-reviewed|custom-scheme-unreviewed|unsupported-active|unknown",
          "customSchemeDecision": "none|safe-reviewed|block-required|manual-review|unknown",
          "processPoolDecision": "default|custom-reviewed|conflict-blocked|unknown",
          "dataStoreDecision": "default|nonPersistent-reviewed|custom-reviewed|conflict-blocked|unknown",
          "unsupportedFeatureDecision": "none|active-unsupported-blocked|active-unsupported-unresolved|manual-review|unknown",
          "downloadUploadDecision": "none|managed|unmanaged-blocked|manual-review|unknown",
          "localFileProducerEvidence": "tranche3-linked|self-contained|not-applicable|unknown",
          "iccRole": "provider|consumer|both|none|unknown",
          "serviceId": "string|null",
          "serviceVersion": "string|null",
          "serviceMethod": "string|null",
          "serviceRegistrationStatus": "verified|missing|not-required|unknown",
          "transferFileBehavior": "managed-attachment|unmanaged-staging-blocked|not-applicable|unknown",
          "iccErrorHandling": "implemented|partial|missing|unknown",
          "iccCancellationHandling": "implemented|partial|missing|unknown",
          "residualSharePathStatus": "none|blocked|removed|active-unmanaged|unknown",
          "policyApi": "getApplicationConfig|getApplicationPolicy|getApplicationPolicyString|GDAppEventPolicyUpdate|GDPolicyUpdateNotification|other|none",
          "policyReadTiming": "post-auth|pre-auth|n/a|unknown",
          "policyUpdateHandling": "event-handled|notification-handled|both|ignored|not-applicable|unknown",
          "policyCacheLocation": "none|secure-container|userdefaults|file|memory-only|unknown",
          "policyDefaultStrategy": "deny-by-default|allow-by-default|feature-off-by-default|unknown",
          "policyFeatureBinding": "dlp|export|icc|multiple|none|unknown",
          "keychainPolicyDecision": "retain-system-keychain-for-device-secret-only|migrate-to-secure-file-storage|blocked|not-applicable|unknown",
          "cryptoDecision": "required-independent-control|redundant-remove|conflicting-block|manual-review",
          "lifecycleReachability": "pre-auth|post-auth|unknown",
          "sensitivity": "sensitive|semi-sensitive|non-sensitive",
          "confidence": "high|medium|low",
          "evidenceSnippet": "string (first 2 lines, no secrets)"
        }
      ],
      "dependencies": ["other-domainId"]
    }
  ],
  "lifecycleModel": {
    "primaryPattern": "UIApplicationDelegate|UISceneDelegate|SwiftUI-main|storyboard-driven",
    "hasSceneDelegate": "boolean",
    "hasSwiftUIApp": "boolean",
    "selectedAuthorizationPattern": "delegate|notification|mixed|unknown",
    "postAuthBoundary": {
      "entrySymbol": "string",
      "stateSignal": "GDAppEventAuthorized|GDState.isAuthorized|other-verified",
      "rootUiStrategy": "sdk-window-reuse|scene-window-update|swiftui-state-gate|mixed"
    },
    "allowedPreAuthBehavior": [
      "placeholder-ui-shell",
      "observer-registration",
      "queue-non-sensitive-callback-context"
    ],
    "prohibitedPreAuthBehavior": [
      "secure-storage-init",
      "secure-networking-init",
      "policy-read",
      "icc-or-dlp-sensitive-payload-processing"
    ],
    "roots": [
      {
        "id": "root:<relative-path>:<symbol>:<line>",
        "targetId": "string",
        "language": "swift|objc",
        "rootType": "app-didFinishLaunching|scene-willConnect|swiftui-app-init|objc-load|...",
        "sourceLocation": {"relativePath": "string", "line": "number"},
        "authorizationState": "pre-auth|post-auth|unknown",
        "callEdges": ["root-or-symbol-id"],
        "sensitiveDescendantCallSiteIds": ["<callsite-id>"],
        "confidence": "high|medium|low",
        "reason": "direct-evidence|pattern-inferred|opaque-dynamic"
      }
    ],
    "preAuthRisks": ["string"],
    "backgroundCandidates": ["string"],
    "extensionCandidates": ["string"]
  },
  "unsupportedDetections": [
    {
      "feature": "string",
      "files": ["string"],
      "reason": "string",
      "workaroundDetected": true
    }
  ],
  "manualTodoCandidates": [
    {
      "priority": "high|medium|low",
      "description": "string",
      "reason": "string"
    }
  ],
  "recommendedPromptOrder": ["00pre","00","00b","01","02","03","03b","04","04b","05","06","07","08","09","09b","11","10","12"]
}
```

**Call-site ID format**: Use `{domainId}:{relative-path-from-project-root}:{line}`.
Example: `secureFileStorage:Sources/DataManager.swift:42`

IDs must be deterministic for unchanged source and unique within the run.
These IDs are used by domain prompts when writing dispositions to
`migration-plan-state.json`.

For storage domains (`secureSql`, `secureCoreData`, `secureFileStorage`),
populate `storageFamily`, `operation`, `pathOwnership`, `wrapperLibrary`,
`auxiliaryFiles`, `downstreamReaders`, and `proposedTreatment`.

For `secureNetworking`, also populate:
`transportFamily`, `requestInitiationPoint`, `sessionConfiguration`,
`delegateHandling`, `executionMode`, `customProtocolDecision`,
`pinningTrustDecision`, `backgroundSessionDecision`, `socketHost`,
`socketPort`, `socketTlsMode`, `socketMigrationDecision`, `replacementApi`,
and `catalogRowId`.

For `webview`, also populate:
`webviewSupportState`, `webviewInitPoint`, `webContentSource`,
`webContentClassification`, `customSchemeDecision`, `processPoolDecision`,
`dataStoreDecision`, `unsupportedFeatureDecision`, `downloadUploadDecision`,
`localFileProducerEvidence`, and `catalogRowId`.

For `dlpPasteboard`, also populate:
`surface`, `movementDirection`, `sourceEndpoint`, `destinationEndpoint`,
`payloadKind`, `policyDependency`, `inboundSecureCopyStatus`,
`outboundApprovalStatus`, `plaintextStagingStatus`, `selectedTreatment`,
and `residualSharePathStatus`.

For `icc`, also populate:
`iccRole`, `serviceId`, `serviceVersion`, `serviceMethod`,
`serviceRegistrationStatus`, `transferFileBehavior`, `iccErrorHandling`,
`iccCancellationHandling`, and `residualSharePathStatus`.

For `policyManagement`, also populate:
`policyApi`, `policyReadTiming`, `policyUpdateHandling`,
`policyCacheLocation`, `policyDefaultStrategy`, and `policyFeatureBinding`.
Low-confidence/opaque wrapper detections must not be silently treated as
"safe"; classify them with `confidence: low` and route them to
`proposedTreatment: block|defer` with rationale.

**Lifecycle model**: Populate `lifecycleModel` from the iOS lifecycle
entry points found in steps 1-3. Record pre-auth risk call sites (APIs
called before authorization could complete).

For lifecycle roots and edges:
- include directly proven edges (`callEdges`)
- include pattern-inferred edges when static resolution is partial
- explicitly mark unresolved dynamic/opaque startup edges with `confidence: low`
  and `reason: opaque-dynamic` rather than silently treating them as safe.

This artifact is mandatory input for Prompt 10 report generation.

When mixed dependency boundaries are detected, include explicit risk and
execution notes in:
- `domains[].risks` (for `secureFileStorage`)
- `manualTodoCandidates` when execution mode is `suggest-manual`

Use this policy:
- `auto-apply-injection`: conditions are clear and composition root is stable.
- `suggest-manual`: architecture is uncertain or broad refactor risk is high.

---

## Common Pitfalls (Prompt 00)

- Treating SPM wrapper calls as transparent without inspecting checkout source.
- Marking SwiftData wrappers as understood without tracing the underlying
  persistence configuration.
- Ignoring orphan `.xcdatamodeld` directories that confuse later Core Data work.

---

## Output

- Complete API usage inventory table
- Data sensitivity classification for each usage
- Startup flow analysis (what runs before authorization is possible)
- Ordered migration plan with applicable/not-applicable phases marked
- Unsupported features list (SwiftData, Flutter hybrid, App Extensions, CloudKit, etc.)
- Risks, edge cases, and items requiring developer input
- `dynamics-migration-tool/output/migration-analysis.json` (required)

---

## Critical Rules

- Do NOT make any code changes during this step — analysis only
- Do NOT skip reading any **app source** file — every file must be inventoried.
  Scope: `<AppTarget>/` source directories only. Exclude `Pods/`,
  `Carthage/`, `.build/`, and third-party framework directories.
  DerivedData remains excluded **except** for targeted SPM checkout reads in
  step 1a (`SourcePackages/checkouts`) when wrapper behavior must be audited.
- Do NOT assume what the app does — read the code
- Flag any patterns that will require special handling (e.g., Core Data
  access in `didFinishLaunchingWithOptions`, background tasks, SwiftUI
  `@StateObject` with secure data access)
- If the app uses SwiftData, flag it prominently — there is NO Dynamics equivalent
- If the app is Flutter-based, flag it prominently — **out of scope** for this
  toolkit release; do NOT prescribe FlutterEngine / plugin-registrant Dynamics
  wiring
- If the app has a **Share Extension**, flag it prominently — Dynamics does
  **not** support Share Extensions; isolate / non-shipping + no Dynamics in
  the extension (`17-app-extensions-and-share-extensions.md`)
- If the app has other App Extensions, flag them — they cannot access the
  secure container; apply the same isolate doctrine
- Write `migration-analysis.json` even if some sections are mostly empty

---

## Next Step

After this analysis is complete, run **00b-generate-architecture-diagrams.md**
to produce data flow diagrams, storage/network classification maps, lifecycle
dependency maps, a secure API call graph, authorization boundary declarations,
and a migration risk heatmap.
