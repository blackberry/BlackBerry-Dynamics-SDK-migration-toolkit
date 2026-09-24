# Steering: Xcode Project Integration

## Deployment Target

BlackBerry Dynamics SDK 15.x requires iOS **>= 18.0** (minimum). CocoaPods
and the official SPM package both declare this floor — follow the package's
declared platform when using SPM.

**Rule**: Only raise the deployment target, never lower it.
- If the project targets < 18.0: raise to 18.0 in Xcode and Podfile.
- If the project already targets >= 18.0 (e.g., 18.0, 26.0): **keep the
  existing target**. Lowering it breaks modern APIs the app depends on
  (e.g., `glassEffect()`, `@Observable`, SwiftData APIs).

Update:
- Xcode project settings (General > Minimum Deployments)
- `Podfile` platform line: `platform :ios, '<current-or-18>'`

After raising (if applicable), search for `#available` or `@available`
checks against iOS versions below 18 — these become dead code.

If the target was raised and new availability errors appear, add
`if #available` guards or classify them as pre-existing issues in the
migration report — do not silently delete modern API usage.

---

## Integration Selection Matrix

Choose Dynamics integration method using existing dependency topology:

- **CocoaPods-only dependencies**: use CocoaPods
- **SPM-only dependencies**: use SPM
- **Mixed CocoaPods + SPM dependencies**: use SPM
- **No package manager**: use manual framework embedding

Do not migrate unrelated app dependencies between package managers in this
step. Only integrate Dynamics using the selected method.

---

## Method 1: CocoaPods

### Canonical Entrypoint Rule

If a `Podfile` exists or `.xcworkspace` exists, use workspace as the canonical
entrypoint for all operational commands (`xcodebuild`, integration checks,
prompt execution). If both `.xcodeproj` and `.xcworkspace` exist, do not switch
between them during migration. Use `.xcodeproj` only when workspace is absent.
If workspace exists and a command uses `-project`, stop and correct the command
before continuing.

### Podfile Setup

If the project does not have a Podfile, create one:

```ruby
# Use max(current_target, '18.0') — do NOT lower a higher target
platform :ios, '18.0'  # or keep existing if already >= 18.0
use_frameworks!

target 'YourApp' do
  # [BB_DYNAMICS-MIGRATION] Added BlackBerryDynamics SDK
  pod 'BlackBerryDynamics', '~> 15.1'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      current = config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].to_f
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0' if current < 18.0
    end
  end
end
```

If the project already has a Podfile, add the `BlackBerryDynamics` pod to
the appropriate target.

### Installation

```bash
pod install --repo-update
```

After installation, open the `.xcworkspace` file (not `.xcodeproj`).

### CocoaPods/Xcodeproj Compatibility

If `pod install` fails with:

- `Unable to find compatibility version string for object version '70'`

classify this as a **pre-existing/tooling** issue, not a migration code issue.

Remediation sequence:
1. Update CocoaPods/xcodeproj toolchain available in the environment.
2. If using bundled CocoaPods (for example Homebrew), note that standalone
   `gem install xcodeproj` may not affect bundled xcodeproj.
3. Apply supported `objectVersion` workaround for the current toolchain and
   retry `pod install`.

If remediation succeeds, record as resolved tooling issue and continue.
If it fails, treat as environment/tooling blocker with explicit manual TODO.

---

## Method 1b: SPM (Official Package)

If the integration matrix selects SPM, add the **official** BlackBerry
Dynamics Swift package. Do not invent alternate package URLs.

| Field | Value |
|-------|-------|
| Repository | https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK |
| Package name | `BlackBerryDynamics` |
| Toolkit-approved pin | SPM tag / version `v15.1.18` (ships SDK build `15.1.8766.18`) |
| Declared platform | iOS 18+ |
| Required products | `BlackBerryDynamics`, `GSEProvider` |
| Optional product | `BlackBerryDynamicsAutomatedTestSupportLibrary` (test targets only) |

### Xcode UI steps

1. File → Add Package Dependencies…
2. Enter URL: `https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK`
3. Set Dependency Rule to **Up to Next Major** from `15.1.18`, or pin
   **Exact Version** `15.1.18` for reproducible migrations.
4. Add products to the **app target**:
   - `BlackBerryDynamics` (required)
   - `GSEProvider` (required — FIPS crypto provider for SDK 15.0+)
5. Resolve packages (File → Packages → Resolve Package Versions) before
   build verification.

### `Package.swift` / app-package declaration

When the app owns a `Package.swift` (or an Xcode project that mirrors one),
declare the dependency explicitly:

```swift
// [BB_DYNAMICS-MIGRATION] Official BlackBerry Dynamics SPM (prompt 01)
.package(
    url: "https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK",
    from: "15.1.18"
)
```

And link products on the app target:

```swift
.product(name: "BlackBerryDynamics", package: "BlackBerry-Dynamics-iOS-SDK"),
.product(name: "GSEProvider", package: "BlackBerry-Dynamics-iOS-SDK"),
```

### SPM rules

- Use only the official GitHub URL above (with or without a trailing `.git`).
- Pin to `15.1.18` (tag `v15.1.18`) or a later published `15.1.*` / `15.*` release that
  BlackBerry tags on that repository — do not invent checksums or mirror URLs.
- Link both `BlackBerryDynamics` and `GSEProvider` on every production app
  target that uses Dynamics APIs.
- Do **not** link Dynamics products to Share Extension, Widget, Intents,
  Safari, or Notification Service targets (see
  `17-app-extensions-and-share-extensions.md`).
- Do **not** link `BlackBerryDynamicsAutomatedTestSupportLibrary` to the
  production app target.
- Resolve package dependencies before build verification.
- Keep existing CocoaPods dependencies unchanged in mixed setups unless
  Prompt 00 explicitly flagged cleanup.
- After resolution, `project.pbxproj` should contain
  `repositoryURL = "https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK"`
  (validators detect this URL).

### Import Header

In Swift (CocoaPods or SPM), prefer specific submodule imports. The bare
top-level `import BlackBerryDynamics` compiles in Swift but is less clear:

```swift
import BlackBerryDynamics.Runtime          // GDiOS, GDiOSDelegate, authorization
import BlackBerryDynamics.SecureStore.File  // GDFileManager, GDFileHandle
import BlackBerryDynamics.AppKinetics       // GDServiceClient, GDServiceDelegate
```

In Objective-C with CocoaPods:
```objc
@import BlackBerryDynamics.Runtime;
@import BlackBerryDynamics.SecureStore.File;
```

In Objective-C with manual framework integration:
```objc
#import <BlackBerryDynamics/GD/GDiOS.h>
```

---

## Method 2: Manual Framework Embedding

### Required Frameworks

Add these frameworks to the Xcode project (General > Frameworks, Libraries,
and Embedded Content):

| Framework | Embed Setting |
|-----------|--------------|
| `BlackBerryDynamics.xcframework` | Embed & Sign |
| `GSEProvider.xcframework` | Embed & Sign |

SDK 15.0 replaced the previous `BlackBerryCerticom.xcframework` +
`BlackBerryCerticomSBGSE.xcframework` pair with `GSEProvider.xcframework`.
Do not embed the old Certicom frameworks when targeting 15.0+.

**Preserve existing embeds:** Append Dynamics products to Embed Frameworks —
never clear the phase. For multi-app workspaces, verify Link + Embed on
**each** application target for local dynamic products (e.g. `DGCharts`) as
well as Dynamics. A post-install dyld `Library not loaded: @rpath/…` exit
usually means Embed Frameworks is incomplete for that target (see
`95-troubleshooting.md` and Prompt 01 step 7a).

### Build Settings

| Setting | Value |
|---------|-------|
| Framework Search Paths | `$(DYNAMICS_SDK)/frameworks` (adjust to actual path) |
| Header Search Paths | `$(DYNAMICS_SDK)/frameworks/BlackBerryDynamics.xcframework/Headers` |
| Other Linker Flags | `-ObjC` |
| Runpath Search Paths | `@executable_path/Frameworks` |

### Import Header

In Swift, use specific submodule imports (same rule as CocoaPods — bare
`import BlackBerryDynamics` does not expose SDK types):

```swift
import BlackBerryDynamics.Runtime
import BlackBerryDynamics.SecureStore.File
```

In Objective-C with manual integration, use the traditional header imports:
```objc
#import <BlackBerryDynamics/GD/GDiOS.h>
#import <BlackBerryDynamics/GD/GDState.h>
#import <BlackBerryDynamics/GD/GDFileManager.h>
```

---

## Import Syntax Reference

The Dynamics SDK provides Clang modules. When using CocoaPods with
`use_frameworks!` (the recommended setup), use `@import` (ObjC) or
`import` (Swift) with the module submodule paths. When using manual
framework integration, the `#import <...>` header paths may be needed.

### Module Import Reference (CocoaPods / SPM)

**CRITICAL — ObjC: Do NOT use `@import BlackBerryDynamics;` (bare top-level)**.
The SDK's modulemap declares all functional submodules as `explicit`, which
means headers assigned to named submodules (Runtime, SecureStore, etc.) are
**excluded** from the top-level umbrella import. `@import BlackBerryDynamics;`
only imports unclaimed utility headers — it does NOT include `GDiOS`,
`GDiOSDelegate`, `GDFileManager`, `GDSocket`, etc. Always import the
specific submodule.

**Swift exception**: `import BlackBerryDynamics` (bare top-level) does
compile in Swift because the Swift compiler transitively resolves all
submodules. However, **prefer specific submodule imports** for clarity and
to match the ObjC behavior. The bare import is acceptable as a shorthand
only when the file uses types from multiple submodules; in ObjC `@import`
the bare form does NOT work.

**NOTE**: Encrypted SQLite is under `GD_C` (a C API), not `BlackBerryDynamics`.
Do NOT use `@import BlackBerryDynamics.sqlite3enc` — it does not exist.

**Module discovery**: `GD_C` is defined inside `BlackBerryDynamics.framework`'s
modulemap. The compiler only discovers it after loading that file. Any source
file using `@import GD_C.*` MUST also import a `BlackBerryDynamics.*` module
first (or in a transitively included header). Without this, you get
"Module 'GD_C' not found".

| API Area | Swift Import | ObjC Import |
|---|---|---|
| Runtime / Authorization (`GDiOS`, `GDAppEvent`, `GDState`) | `import BlackBerryDynamics.Runtime` | `@import BlackBerryDynamics.Runtime;` |
| Secure File Storage (`GDFileManager`, `GDFileHandle`) | `import BlackBerryDynamics.SecureStore.File` | `@import BlackBerryDynamics.SecureStore.File;` |
| **Encrypted SQLite** (`sqlite3enc_open`) | Bridging header required (see `41-secure-storage-sql.md`) | `@import GD_C.SecureStore.SQLite;` |
| Secure Core Data (`GDPersistentStoreCoordinator`) | `import BlackBerryDynamics.SecureStore.CoreData` | `@import BlackBerryDynamics.SecureStore.CoreData;` |
| Secure Networking (`GDSocket`) | `import BlackBerryDynamics.SecureCommunication` | `@import BlackBerryDynamics.SecureCommunication;` |
| GDNET category (`WKWebView+GDNET`) | `import BlackBerryDynamics.GDNET` | `@import BlackBerryDynamics.GDNET;` |
| Authentication Token | `import BlackBerryDynamics.AuthenticationToken` | `@import BlackBerryDynamics.AuthenticationToken;` |
| Top-level (Swift only) | `import BlackBerryDynamics` | **Do NOT use `@import BlackBerryDynamics;` in ObjC** |

### Header Import Reference (Manual Framework Integration)

| API Area | ObjC Header Import |
|---|---|
| Runtime / Authorization | `#import <BlackBerryDynamics/GD/GDiOS.h>` |
| Secure File Storage | `#import <BlackBerryDynamics/GD/GDFileManager.h>` |
| Encrypted SQLite | `#import <BlackBerryDynamics/GD_C/sqlite3enc.h>` |
| Secure Core Data | `#import <BlackBerryDynamics/GD/GDPersistentStoreCoordinator.h>` |
| Secure Networking | `#import <BlackBerryDynamics/GD/GDSocket.h>` |
| WKWebView category | `#import <BlackBerryDynamics/GD/WKWebView+GDNET.h>` |

**Rule**: If the project uses CocoaPods (has a `Podfile`) or SPM (official
package linked), always use `@import` / `import` module syntax. If manual
framework integration, use `#import <...>` header syntax.

### ObjC Type-to-Submodule Lookup (CocoaPods)

When you encounter a Dynamics type or protocol in ObjC code, use this
table to determine the exact `@import` needed. Import in the `.h` if
the type appears in the `@interface` declaration; import in the `.m`
if only used in the implementation.

| Type / Protocol | Required `@import` | Modulemap Source |
|---|---|---|
| `GDiOS`, `GDAppEvent`, `GDiOSDelegate`, `GDState`, `GDAppResultCode` | `@import BlackBerryDynamics.Runtime;` | `GDiOS.h`, `GDState.h` |
| `GDFileManager`, `GDFileHandle`, `GDCReadStream`, `GDCWriteStream`, `GDFileStat` | `@import BlackBerryDynamics.SecureStore.File;` | `GDFileManager.h`, `GDFileHandle.h` |
| `sqlite3enc_open`, `sqlite3enc_open_v2` | `@import GD_C.SecureStore.SQLite;` (must also import a `BlackBerryDynamics.*` module first) | `sqlite3enc.h` |
| `GDPersistentStoreCoordinator`, `GDEncryptedIncrementalStoreType` | `@import BlackBerryDynamics.SecureStore.CoreData;` | `GDPersistentStoreCoordinator.h` |
| `GDSocket`, `GDSocketDelegate`, `GDDirectByteBuffer` | `@import BlackBerryDynamics.SecureCommunication;` | `GDNETiOS.h` |
| `GDURLLoadingSystem`, `WKWebView+GDNET`, `NSMutableURLRequest+GDNET` | `@import BlackBerryDynamics.SecureCommunication;` (re-exports `.URLLoadingSystem`) | `GDURLLoadingSystem.h`, `WKWebView+GDNET.h` |
| `GDConnectivityManager`, `GDReachability`, `GDNetUtility` | `@import BlackBerryDynamics.SecureCommunication;` (re-exports `.Utility`) | `GDNetUtility.h` |
| `GDPush` | `@import BlackBerryDynamics.SecureCommunication.PushChannel;` | `GDPush.h` |
| `GDServices`, `GDServiceClient` | `@import BlackBerryDynamics.AppKinetics;` | `GDServices.h` |
| `GDUtility` (auth tokens) | `@import BlackBerryDynamics.AuthenticationToken;` | `GDUtility.h` |
| `GDNativePasteboardAccess` | `@import BlackBerryDynamics.NativePasteboardAccess;` | `GDNativePasteboardAccess.h` |
| `GTLauncherViewController` | `@import BlackBerryDynamics.Launcher;` | `GTLauncherViewController.h` |
| `GDThreat*` classes | `@import BlackBerryDynamics.Threat;` | `GDThreat.h` etc. |
| `GDCacheController`, `NSURLCache(GDURLCache)` | `@import BlackBerryDynamics.GDNET;` (wildcard submodule) | `GDNET.h` |

---

## Keychain Sharing (REQUIRED)

Keychain Sharing must be enabled for the Dynamics SDK to function:

1. Select the app target in Xcode
2. Go to Signing & Capabilities
3. Add "Keychain Sharing" capability (if not present)
4. Add keychain group: `com.good.gd.data`
5. If the app uses crypto tokens, also add: `com.apple.token`

This creates or updates the `.entitlements` file:

```xml
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)com.good.gd.data</string>
</array>
```

---

## System Frameworks

The Dynamics SDK requires these system frameworks (usually auto-linked):
- `Security.framework`
- `SystemConfiguration.framework`
- `LocalAuthentication.framework`
- `CoreData.framework`
- `CoreTelephony.framework`
- `QuartzCore.framework`
- `MessageUI.framework`
- `SafariServices.framework`
- `AuthenticationServices.framework`
- `WebKit.framework`
- `Network.framework`

If using CocoaPods, these are handled automatically. For manual integration,
verify they are linked.

---

## Removing Conflicting Dependencies

Based on the analysis from Prompt 00, remove dependencies that Dynamics
replaces:
- App-level encryption libraries (CryptoKit usage for at-rest encryption)
- Biometric lock libraries (beyond what iOS provides natively)
- Custom keychain wrappers that conflict with `com.good.gd.data`
- SQLCipher or similar database encryption (if migrating to sqlite3enc)

---

## Build Verification

After integration, verify the project builds:

```bash
# CocoaPods project
xcodebuild -workspace YourApp.xcworkspace -scheme YourApp \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build

# Non-CocoaPods project
xcodebuild -project YourApp.xcodeproj -scheme YourApp \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

Common build issues:
- Missing Keychain Sharing entitlement → runtime crash on launch
- Wrong deployment target → compilation errors in SDK headers
- Missing `-ObjC` linker flag → runtime crash with unrecognized selector
- Conflicting module maps → duplicate symbol errors

Migration build policy: always use unsigned simulator mode
(`-sdk iphonesimulator CODE_SIGNING_ALLOWED=NO`) for AI-driven build checks.
