# Steering: Troubleshooting (iOS)

## Output File Issues

## Feedback-Loop Rule

When a migration failure pattern appears in two independent runs, add it to:
- the relevant prompt's `Common Pitfalls` section, and
- this troubleshooting guide with a concrete fix.

Do not keep repeated issues only in ad-hoc analysis notes.

### Immediate exit after install — `Library not loaded: @rpath/….framework`

**Symptoms**: App installs and “launches”, then exits immediately. Console shows
`dyld: Library not loaded: @rpath/Some.framework/Some`. No Dynamics/UEM crash
log / no core dump. `.app/Frameworks/` contains BlackBerryDynamics /
GSEProvider but is missing a pre-existing app framework (e.g. `DGCharts`).

**Cause**: While adding Dynamics Embed Frameworks, the target’s Embed
Frameworks phase was emptied or never updated for that application target.
Multi-target workspaces often embed a product on one target only.

**Fix**:
1. For each migrated **application** target, restore Link + Embed
   (`Code Sign On Copy`) for every local dynamic product the target needs
2. Rebuild/reinstall and confirm `YourApp.app/Frameworks/` contains both
   Dynamics frameworks and the app’s other embedded frameworks
3. See Prompt 01 step **7a. Preserve Embed Frameworks**

### Crash after validate pass — storyboard / idle unlock (NetNewsWire class)

**Symptoms**: Full validate passes; app then crashes (a) on launch before
authorize, (b) right after activation when Launcher attaches, or (c) after
idle lock/unlock.

**Typical causes**:
1. Storyboard root / property initializers reach `AccountManager.shared` or
   `try! GDFileManager` before `GDAppEventAuthorized`
2. Dynamics Launcher probes RVC (`prefersStatusBarHidden`) while coordinator
   IUOs are still nil
3. Idle unlock re-sends `authorized` and Phase 2 calls `start()` again on an
   already-active manager

**Fix**:
1. Placeholder root until first authorize; then instantiate real storyboard root
2. Optional coordinators on storyboard roots; no-op when nil
3. Separate `didStartPostAuthorizationServices` one-shot flag from
   `isAuthorized`; never clear the one-shot on idle `notAuthorized`; make
   `start()` idempotent
4. See `20-auth-initialization.md` Common Mistakes 7–9 and Prompt 03 Check 6

### Flutter app detected (out of scope this release)

**Symptoms**: Prompt `00pre` / `00` reports Flutter hybrid; validator warns
about Flutter signals; agent attempted Dynamics + FlutterEngine / plugin
registrant wiring.

**Cause**: There is no official BlackBerry Dynamics Flutter SDK. This iOS
toolkit release intentionally does **not** migrate Flutter Runner hosts.
Ad-hoc Dynamics wiring under Flutter often yields blank post-auth UI,
`PlatformException(channel-error, …)` from missing plugins, or ProMotion
`VSyncClient` crashes — while static validation can still “pass”.

**Fix / expected agent behavior**:
1. Record Flutter under `unsupportedDetections` / `unsupportedFeatures`
2. Classify Tier C; set release readiness `no-go`
3. **Stop** Dynamics code-migration prompts (`01`–`09`, `11`)
4. Point the developer to native UIKit/SwiftUI Dynamics integration, or an
   officially supported cross-platform path (e.g. Dynamics React Native SDK)

Do **not** invent FlutterEngine / `DynamicsPluginRegistrant` / UIScene-removal
playbooks for Flutter in this toolkit version.

### Share Extension detected (Dynamics-unsupported)

**Symptoms**: Prompt `00pre` / `00` reports a Share Extension; validator warns
about `com.apple.share-services` / Share Extension targets; agent linked
Dynamics into the extension or left App Group bridges active.

**Cause**: BlackBerry Dynamics does not support Share Extensions. Extensions
cannot access the Dynamics secure container after main-app `GDiOS.authorize()`.

**Fix / expected agent behavior**:
1. Record Share Extension under `unsupportedDetections` / `unsupportedFeatures`
2. Continue main-app Dynamics migration
3. **Do not** add Dynamics frameworks or call `authorize()` in the extension
4. Exclude the Share Extension from Dynamics scheme / Archive / Embed App
   Extensions (preferred), or redesign inbound share via main-app URL handoff
   + post-auth `GDFileManager`
5. Remove App Group sensitive bridges between main app and extension
6. Use `go-with-risks` only when non-shipping; `no-go` if still embedded or
   product-required without redesign

See `17-app-extensions-and-share-extensions.md`.

### Corrupted Output Files ("Extra data" / Invalid JSON)

**Symptoms**: `validate.sh` reports "Extra data", "Unexpected token",
or "JSON parse error" on `migration-report.json` or
`migration-analysis.json`. The file may contain multiple JSON root
objects concatenated together (e.g., `{new report}{old report}`).

**Cause**: A patch-based tool (StrReplace, ApplyPatch, or similar)
was used to write an output file instead of a full-file overwrite.
Patch tools append new content to existing files rather than replacing
them. This also happens when stale output files from a previous
migration run were not cleaned before starting a new migration.

**Fix**:
1. Delete the corrupted file:
   ```bash
   rm -f dynamics-migration-tool/output/migration-report.json
   ```
2. Regenerate it using a **full-file overwrite** (Write/CreateFile tool
   in AI IDEs — NOT StrReplace or ApplyPatch)
3. Run `validate.sh` again to confirm the file is valid

**Prevention**:
- Always run the "Clean Output Directory" step (Prompt 00, Step -1)
  before starting a new migration
- Always use full-file overwrite for all output files
- Never use patch-based tools on `.json` output files

---

## Retry Escalation

### `ESCALATION REQUIRED` (Exit Code 3)

**Symptoms**: `validate.sh` or `record-prompt-execution.sh` exits `3` and
prints `ESCALATION REQUIRED`.

**Cause**: The bounded-retry budget is exhausted for repeated failures
(identical failure signatures or broad prompt churn).

**Fix**:
1. Inspect `dynamics-migration-tool/output/migration-loop-state.json`
2. Identify `ownerPrompt`, failing domain/phase, and `safeNextAction`
3. Repair that owning prompt/domain first (do not rerun the same broad gate blindly)
4. Re-run a targeted validation or prompt-scoped check before retrying full validation

---

## Build Errors

### "Framework not found BlackBerryDynamics"

- **CocoaPods**: Run `pod install --repo-update` and open `.xcworkspace`
- **Manual**: Verify Framework Search Paths includes the SDK directory
- Verify both required xcframeworks are added (BlackBerryDynamics, GSEProvider)

### "Undefined symbol: _OBJC_CLASS_$_GDiOS"

- Add `-ObjC` to Other Linker Flags
- Verify BlackBerryDynamics.xcframework is set to "Embed & Sign"

### "Module 'BlackBerryDynamics' not found" (Swift)

This is commonly a workspace-entrypoint failure in CocoaPods projects:

- CocoaPods runs `BlackBerryDynamics-xcframeworks.sh` in the **Pods project**
  build phases to extract the correct XCFramework slice.
- Opening `.xcodeproj` directly skips Pods build phases, so module extraction
  does not run and imports fail.

Fix:
1. Ensure `use_frameworks!` is in `Podfile` (CocoaPods path).
2. Delete stale DerivedData generated from xcodeproj-only builds.
3. Run `xcodebuild clean build` using `.xcworkspace`.
4. Reopen Xcode via `.xcworkspace` only (never `.xcodeproj` while Pods is present).
5. Manual integration path only: verify framework imports/search paths/bridging
   header configuration.

### "Module 'GD_C' not found" (Objective-C)

- `GD_C` is defined inside `BlackBerryDynamics.framework/Modules/module.modulemap`
- The compiler only discovers it after loading that modulemap
- Fix: import any `BlackBerryDynamics.*` module **before** `GD_C.*` in the
  same file or a transitively included header
- Example: add `@import BlackBerryDynamics.SecureStore.File;` before
  `@import GD_C.SecureStore.SQLite;`

### "Unable to find module dependency: 'GD_C'" (Swift)

- This is a **different error** from the ObjC variant above
- Occurs when using `import GD_C.SecureStore.SQLite` in Swift with
  CocoaPods xcframework integration
- Root cause: `GD_C` is declared as `framework module GD_C` in the
  BlackBerryDynamics modulemap, but no standalone `GD_C.framework` exists.
  Swift's module resolver looks for a framework directory matching the
  module name and cannot find one. This does NOT affect Objective-C
  `@import` which resolves modules from any loaded modulemap.
- Fix: do NOT use `import GD_C.SecureStore.SQLite` in Swift. Instead,
  create a bridging header with `#import <BlackBerryDynamics/GD_C/sqlite3enc.h>`
  and set `SWIFT_OBJC_BRIDGING_HEADER` in the target build settings.
  The `sqlite3enc_open` and other C functions will be available in Swift
  automatically through the bridging header.
- See `41-secure-storage-sql.md` → Swift section for complete setup

### "Declaration of 'GDiOSDelegate' must be imported from module 'BlackBerryDynamics.Runtime' before it is required"

Two possible causes:

1. **Wrong import**: Using `@import BlackBerryDynamics;` (bare top-level)
   instead of `@import BlackBerryDynamics.Runtime;`. The SDK's modulemap
   declares Runtime as an `explicit` submodule — the bare umbrella import
   does NOT include `GDiOS`, `GDiOSDelegate`, `GDAppEvent`, etc.
   Fix: change to `@import BlackBerryDynamics.Runtime;`

2. **Import in wrong file**: The `@import BlackBerryDynamics.Runtime;` is
   in the `.m` file but not the `.h` file. The compiler must see the
   protocol declaration before the `@interface` that references it.
   Fix: move the import to the **header** (`.h`) file where
   `<GDiOSDelegate>` conformance is declared.

This applies to ANY Dynamics protocol or type referenced in a `.h` file —
the specific submodule import must be in the header, not just the `.m`.

### "Applications must declare URL scheme" / `GDLibStartupLayer::startup FAILED` — app exits on launch

Responsible migration prompt: `02-configure-info-plist.md`.

One or more required Dynamics URL schemes are missing from `CFBundleURLSchemes`
in Info.plist. This is a fatal startup check — the SDK can terminate the
process immediately before authorization begins.

Fix: ensure Info.plist contains the required schemes using the app's native
bundle identifier, not `GDApplicationID`. Example for an in-house/UEM-managed
app with bundle ID `com.example.myapp` and `GDApplicationVersion` `1.0.0.0`:
```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.example.myapp</string>
<key>CFBundleURLSchemes</key>
<array>
      <string>com.example.myapp.sc2</string>
      <string>com.example.myapp.sc2.1.0.0.0</string>
      <string>com.example.myapp.sc3</string>
    <string>com.good.gd.discovery</string>
      <string>com.good.gd.discovery.enterprise</string>
</array>
  </dict>
</array>
```

Note: `com.good.gd.discovery.enterprise` is NOT a substitute for
`com.good.gd.discovery` — both may appear in logs but only the latter
is checked as the first discovery scheme. Partner/third-party apps must not
register `.enterprise` or `.good`; BlackBerry-developed apps use
`com.good.gd.discovery.good` instead of `.enterprise`. Never register bare
`.sc`, and never register both `.enterprise` and `.good`.

### "Applications must include the NSFaceIDUsageDescription key" — app exits on launch

Responsible migration prompt: `02-configure-info-plist.md`.

The Dynamics SDK requires `NSFaceIDUsageDescription` in Info.plist with a
non-empty purpose string for biometric container unlock. Fix:

```xml
<key>NSFaceIDUsageDescription</key>
<string>Used for secure authentication to unlock the BlackBerry Dynamics container.</string>
```

After fixing, rerun:

```bash
bash ./dynamics-migration-tool/tooling/validate.sh --check-prompt 02
```

### GDiOSDelegate event receiver assertion with notification auth

Responsible migration prompt: `03-add-dynamics-auth.md`.

If the app uses GDState / `GDStateChangeNotification` authorization instead of
implementing `GDiOSDelegate`, the Dynamics runtime's delegate receiver check
must be disabled:

```xml
<key>BlackBerryDynamics</key>
<dict>
    <key>CheckEventReceiver</key>
    <false/>
</dict>
```

After fixing, rerun:

```bash
bash ./dynamics-migration-tool/tooling/validate.sh --check-prompt 03
```

### Deployment target errors

- Set deployment target to iOS **>= 17.0** in both project and Podfile
- If the project already targets a higher version (e.g., 18.0, 26.0), **keep
  the existing target** — do not lower it. Lowering introduces API availability
  errors for modern APIs (e.g., `glassEffect()`, `@Observable`, SwiftData)
- Run `pod install` after changing the Podfile platform line

### API availability errors after deployment target change

- If raising the target from < 17.0 introduces `'X' is only available in
  iOS Y or newer` errors, these are pre-existing compatibility issues
- Add `if #available` guards or raise the deployment target to the required
  version — do NOT silently delete modern API calls

### Generated Info.plist (GENERATE_INFOPLIST_FILE=YES)

- Modern Xcode projects may not have a physical Info.plist file
- If `GENERATE_INFOPLIST_FILE = YES` in build settings, Dynamics keys
  (`GDApplicationID`, `GDApplicationVersion`, URL schemes) must be set via
  an explicit Info.plist file — set `GENERATE_INFOPLIST_FILE = NO` and
  `INFOPLIST_FILE` to the plist path
- Validate by inspecting the built `.app/Info.plist` in DerivedData

### BitCode errors

- Set `Enable Bitcode = NO` in Build Settings
- Add to Podfile post_install: `config.build_settings['ENABLE_BITCODE'] = 'NO'`

### Signed build fails due to provisioning/profile mismatch

Migration policy avoids this class of failure by running build checks in
unsigned simulator mode only:

```bash
xcodebuild -workspace YourApp.xcworkspace -scheme YourApp \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

If a signed-device build is still run manually and fails, treat it as
environment/signing setup issue, not migration-code defect.

### xcodeproj vs xcworkspace ambiguity

If the repo contains both `.xcodeproj` and `.xcworkspace`, running commands
against the wrong entrypoint can produce misleading build/integration failures.

Fix:
- If `Podfile` exists or workspace exists, use workspace for all operational commands.
- Run builds/checks with `xcodebuild -workspace ...` consistently during migration.
- Use `-project` only when workspace is absent.

### Wrong Dynamics integration method selected

If integration friction appears early (linking/import/package resolution),
verify method selection against dependency topology:

- CocoaPods-only dependencies -> Dynamics via CocoaPods
- SPM-only dependencies -> Dynamics via SPM
- Mixed CocoaPods + SPM dependencies -> Dynamics via SPM

Using a non-matrix method can produce avoidable integration churn.

### SPM package resolution fails

Official package URL:
`https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK`

Fix:
1. Confirm `project.pbxproj` uses that repository URL (not a placeholder or
   private mirror).
2. Confirm products `BlackBerryDynamics` and `GSEProvider` are linked to the
   app target.
3. In Xcode: File → Packages → Reset Package Caches, then Resolve Package
   Versions.
4. Ensure network access to GitHub and
   `software.download.blackberry.com` (binary target host).
5. Pin to published tag `15.0.0` (SDK `15.0.8513.67`) or a later official
   `15.*` tag on that repository.

### CocoaPods error: "Unable to find compatibility version string for object version '70'"

This is a tooling compatibility issue (`CocoaPods`/`xcodeproj` vs project
objectVersion), not a Dynamics migration code defect.

Fix (auto-remediation order):
1. Update CocoaPods/xcodeproj toolchain available in the environment.
2. If CocoaPods is bundled (for example Homebrew install), note that
   standalone `gem install xcodeproj` may not affect bundled xcodeproj.
3. Apply supported `objectVersion` workaround for the installed toolchain and retry `pod install`.

Classification:
- If retry succeeds: mark as **resolved pre-existing/tooling issue**.
- If retry fails: mark as **environment/tooling blocker** with manual TODO.

---

## Runtime Crashes

### Crash on launch: "GDInitializationError"

- Missing Keychain Sharing entitlement (must have `com.good.gd.data`)
- Missing `GDApplicationID` in Info.plist
- Missing required URL schemes
- `authorize()` not called in `didFinishLaunchingWithOptions`

### Crash: "Container not authorized" or "Secure store not available"

- Secure API called before `GDAppEventAuthorized`
- Check the authorization deferral audit (Prompt 03b)
- Look for:
  - Core Data initialization in `didFinishLaunchingWithOptions`
  - Data loading in `viewDidLoad` of root ViewController
  - Lazy properties that access secure APIs
  - `@StateObject` inits that access secure storage

### Pre-auth lifecycle executes app logic (two-phase startup violation)

Symptoms:
- nil coordinator/store references
- assertion failures during startup
- unexpectedly unwrapped nil optionals in startup path

Root cause:
- business/account/database/UI-flow logic still executes before authorization

Fix:
- keep Phase 1 as UI shell only
- move secure/business initialization to post-auth handler
- if scenes are enabled, queue scene actions pre-auth and drain after authorization

### Scene callbacks trigger controller/data paths before authorization

Symptoms:
- `scene(_:willConnectTo:)` or `openURLContexts` initializes controllers in invalid state
- race-like behavior around lock/unlock or restoration callbacks

Fix:
- implement scene action queue + post-auth drain
- do not execute scene-driven secure flows until `GDAppEventAuthorized`

### Swift concurrency warnings/errors around GDiOSDelegate

Symptoms:
- actor-isolation/sendability diagnostics around delegate callbacks
- compile failures when callback path touches main-actor app state

Fix:
- keep delegate callback nonisolated
- bridge event handling to `MainActor` via `Task { @MainActor in ... }`
- centralize app startup in a MainActor auth handler

### Crash: EXC_BAD_ACCESS (code=1, address=0x0) during or after SDK activation (Swift)

- **Cause**: `onAuthorized` creates a new `UIWindow` with
  `UIWindow(frame: UIScreen.main.bounds)`. On iOS 16+, `UIScreen.main`
  is deprecated and may return a zero rect, causing the null-pointer crash.
  Even on earlier iOS, creating a new window replaces the SDK-managed
  window and breaks the Dynamics container lifecycle.
- **Fix**: Do NOT create a new `UIWindow` in `onAuthorized`. Set the
  rootViewController on the existing `self.window?`:
  ```swift
  self.window?.rootViewController = UIStoryboard(name: "Main", bundle: nil)
      .instantiateInitialViewController()
  ```
  Remove any calls to `UIWindow(frame:)` and `makeKeyAndVisible()`.
- See `20-auth-initialization.md` → Common Mistakes → item 1.

### Crash: "unrecognized selector sent to instance"

- Missing `-ObjC` linker flag
- Missing framework import in bridging header

### Crash in background: "Container locked"

- Secure API called while container is locked (idle timeout)
- Enable Background Authorize if the app needs background access
- Guard secure API calls with authorization state check

---

## Authorization Issues

### Activation fails: "Invalid entitlement"

- `GDApplicationID` doesn't match UEM configuration
- `GDApplicationVersion` doesn't match UEM configuration
- Entitlement not created in UEM for this app

### Activation fails: "Connection timeout"

- Device cannot reach UEM server
- Check network connectivity
- Verify UEM server address

### Lock screen appears but biometric doesn't work

- Missing `NSFaceIDUsageDescription` in Info.plist
- UEM policy doesn't allow biometric unlock
- Device biometric not enrolled

### "NotAuthorized" event with GDErrorIdleLockout

- Expected behavior — container locked due to idle timeout
- The lock screen appears; user re-authenticates
- App receives `GDAppEventAuthorized` again after unlock

---

## Storage Issues

### GDFileManager: "File not found" / `could not be opened2. Error: 2`

`GDFileManager` is a subclass of `NSFileManager` and uses the **same full
filesystem paths**. It intercepts those paths and redirects to the secure
container.

Common causes:
- **Bare relative filenames** — using `@"data.json"` instead of the full
  Documents directory path. Fix: keep the original app's path-building
  logic (`NSSearchPathForDirectoriesInDomains`, `urls(for:in:)`, etc.)
  and only change the class name from `NSFileManager` to `GDFileManager`.
- **File created before current container session** (may have been wiped)
- **File access before authorization** — `GDFileManager` operations fail
  before the container is unlocked

### GDFileManager temp path warning: "`temporaryDirectory` is unsupported" / empty NSURL

Some SDK/runtime combinations do not provide a usable
`GDFileManager.default.temporaryDirectory`, causing runtime warnings/errors.

Typical log output:
- `ERR 'temporaryDirectory' is unsupported`
- `-[NSURL init] called; this results in an NSURL instance with an empty URL string. Please use one of the documented NSURL initialization methods instead (initWithString:, initFileURLWithPath:, etc.).`

Fix:
- Do NOT use `GDFileManager.default.temporaryDirectory`
- Keep existing temp path-building logic first (for example `NSTemporaryDirectory()`)
  and route writes through `GDFileManager`.
- If that path still fails at runtime, switch to known secure directories:
  - `GDFileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first`
  - fallback to `.documentDirectory` if caches is unavailable
- Add an app-owned temp subdirectory (for example `tmp_secure`) and UUID filename for fallback mode
- Run post-authorization create/read/delete probe to verify temp flow

### Core Data: "Store failed to load"

- Using `NSSQLiteStoreType` instead of `GDEncryptedIncrementalStoreType`
- Using `NSPersistentContainer` instead of custom `GDPersistentStoreCoordinator` setup
- Core Data model version mismatch — add lightweight migration options
- Attempting to open store before authorization

### SQLite: "Database is locked" or fails to open

- Using `sqlite3_open()` instead of `sqlite3enc_open()`
- Database path not relative to secure container
- Database access before authorization

---

## Networking Issues

### "No visible @interface for 'GDSocket' declares the selector 'connect:onPort:andUseSSL:'"

The migration produced an incorrect `GDSocket` API call. `GDSocket` does NOT
have a `connect:onPort:andUseSSL:` selector. The host, port, and SSL flag
are set in the **initializer**, and `connect` takes no arguments.

Wrong:
```objc
[gdSocket connect:host onPort:port andUseSSL:NO]; // WRONG — no such method
```

Correct:
```objc
self.gdSocket = [[GDSocket alloc] init:[host UTF8String]
                                onPort:port
                             andUseSSL:NO];
self.gdSocket.delegate = self;
[self.gdSocket connect]; // no arguments
```

### NSURLSession requests fail or don't route through Dynamics

The SDK auto-swizzles `NSURLSession` / `NSURLConnection` on authorization
(via `GDActivationAdapter::onStartupCallback`). Common causes of failure:

- **Request fires before authorization** — the auto-swizzle is not yet
  active. Defer all network access to post-authorization.
- **Custom `NSURLProtocol` conflicts** — the SDK registers its internal
  URLProtocol interceptor globally via `[NSURLProtocol registerClass:]`.
  A custom protocol may intercept requests before the SDK interceptor.
  Test thoroughly.
- **App explicitly called `disableSecureCommunication()`** — if the app
  explicitly disabled it, re-enable with
  `GDURLLoadingSystem.enableSecureCommunication()`.
- **Legacy code calls `enableSecureCommunication()` before authorization**
  — this asserts. Remove the manual call or move it post-auth. The SDK
  calls it automatically; manual calls are unnecessary.

### Certificate errors

- Custom certificate pinning conflicts with Dynamics infrastructure
- Remove app-level certificate pinning or configure it in UEM
- Server certificate not trusted by UEM infrastructure

---

## DLP / Pasteboard Issues

### Copy/paste doesn't work between Dynamics apps

- DLP policy not configured in UEM
- Apps not on same UEM server
- Pasteboard access not wrapped in `GDNativePasteboardAccess` when needed

### Share sheet shows non-Dynamics apps

- `UIActivityViewController` not replaced with AppKinetics
- DLP policy may restrict this — test with policy enabled

### Swift cannot cleanly call GDNativePasteboardAccess

Symptoms:
- API visibility/signature friction when used directly from Swift
- ad-hoc wrappers diverge across files

Fix:
- add a canonical Objective-C bridge shim (e.g. `AppPasteboardBridge`) that calls `performActionOnNativePasteboard:`
- call shim from Swift, keeping the `GDNativePasteboardAccess` callback scope encapsulated in one place

---

## Debugging Tips

### Enable Console Logging

Add to Info.plist:
```xml
<key>GDConsoleLogger</key>
<array>
    <string>GDFilterNone</string>
</array>
```

### Check Dynamics Logs

Use `GDLogManager` to upload logs for analysis:
```swift
GDLogManager.sharedInstance().openLog()
```

### Enterprise Simulation for Development

Test without UEM by setting:
```xml
<key>GDLibraryMode</key>
<string>GDEnterpriseSimulation</string>
```

### Connectivity Diagnostics

```swift
let diagnostic = GDDiagnostic()
diagnostic.currentSettings() // Check current connectivity settings
```

---

## Core Data Runtime Errors

### EncryptedIncrementalStoreErrorDomain Code=134080 / URL: (null)

The `addPersistentStore` URL parameter is `nil`. Per `GDPersistentStoreCoordinator.h`,
an explicit URL is required. Fix:

```swift
// WRONG — compiles but crashes post-activation
try coordinator.addPersistentStore(ofType: GDEncryptedIncrementalStoreType, ..., at: nil, ...)

// CORRECT
guard let docsURL = GDFileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { ... }
let storeURL = docsURL.appendingPathComponent("Model.sqlite")
try coordinator.addPersistentStore(ofType: GDEncryptedIncrementalStoreType, ..., at: storeURL, ...)
```

### BBFileManagerErrorDomain Code=500 / NSPOSIXErrorDomain Code=17 "File exists"

Using `GDFileManager.default.url(for:in:appropriateFor:create: true)` when
the directory already exists in the secure container. The `create:true` variant
tries to create the directory and fails if it's already there.

Fix: use `.urls(for:in:)` (plural, no create parameter) instead:

```swift
// WRONG — crashes when Documents already exists
let docsURL = try GDFileManager.default.url(for: .documentDirectory,
    in: .userDomainMask, appropriateFor: nil, create: true)

// CORRECT
guard let docsURL = GDFileManager.default.urls(
    for: .documentDirectory, in: .userDomainMask).first else { ... }
```

---

## Activation UI Issues

### SDK activation/unlock screen appears as a floating card (non-full-screen)

**Symptom**: After migration, the BlackBerry Dynamics activation UI
(QR code, username/password prompts) appears as a small card or sheet
rather than filling the full screen.

**Root cause**: `UILaunchScreen` is missing from `Info.plist`. Without
it iOS runs the app in a legacy 320×480 compatibility layout mode and
all system-presented UI is constrained to that frame.

This typically happens when:
1. The project originally used `GENERATE_INFOPLIST_FILE = YES`, and
2. The migration switched to a manual `Info.plist` without transcribing
   the auto-generated `INFOPLIST_KEY_UILaunchScreen_Generation = YES`
   setting. The `INFOPLIST_KEY_*` settings are **silently ignored** when
   `GENERATE_INFOPLIST_FILE = NO`.

**Fix**: Add to `Info.plist`:
```xml
<key>UILaunchScreen</key>
<dict/>
```

Also verify these related keys are present (same root cause if missing):
```xml
<key>LSRequiresIPhoneOS</key>
<true/>

<key>UIApplicationSceneManifest</key>
<dict>
    <key>UIApplicationSupportsMultipleScenes</key>
    <false/>
</dict>

<!-- iPhone orientations -->
<key>UISupportedInterfaceOrientations</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>

<!-- iPad orientations — required for universal (iPhone + iPad) apps -->
<key>UISupportedInterfaceOrientations~ipad</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>
```

Note: `LSRequiresIPhoneOS = true` means "requires the iOS runtime" — it
does **not** restrict the app to iPhone hardware. Omit `~ipad` only if
the original app was explicitly iPhone-only.

**After applying the fix**: Delete the app from the device/simulator
and do a clean build. iOS caches launch screen metadata — a dirty
install will not pick up the newly added `UILaunchScreen` key.

### SDK activation UI shown but window management is broken (SwiftUI apps)

**Symptom**: App activates but the SDK's managed window is not properly
connected — blank screen after activation, or the app window and SDK
window appear to conflict.

**Root cause**: The `UIApplicationDelegateAdaptor` class is missing
`var window: UIWindow?`. The Dynamics SDK's `GDUIManager` calls
`[appDelegate respondsToSelector:@selector(setWindow:)]` at startup to
assign its managed `UIWindow`. If that property is absent, the SDK
cannot take over window management.

**Fix**: Add the property to the adaptor class:
```swift
final class DynamicsAppDelegate: NSObject, UIApplicationDelegate, GDiOSDelegate {
    var window: UIWindow?  // REQUIRED — SDK assigns its managed UIWindow here
    // ...
}
```
