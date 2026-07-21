## Task: Xcode Project Integration for BlackBerry Dynamics

Goal: Add the BlackBerry Dynamics SDK to the iOS project, configure
Keychain Sharing, set the deployment target, and ensure the project builds.

**Prerequisites**: Prompt 00 (analyze-app) and Prompt 00b (architecture
diagrams) must be complete. The analysis tells you what the app needs.

**This prompt makes project configuration changes only — no source code
changes.**

---

## Steps

### 1. Detect Integration Method

- Check for `Podfile` → CocoaPods integration
- Check for `Package.swift` / SPM packages / Xcode package references → SPM integration
- Apply integration decision matrix:
  - **CocoaPods-only dependencies** → use CocoaPods for Dynamics
  - **SPM-only dependencies** → use SPM for Dynamics
  - **Mixed CocoaPods + SPM dependencies** → use SPM for Dynamics
- If neither exists → manual framework embedding
- **Canonical entrypoint rule**:
  - If `Podfile` exists or `.xcworkspace` exists, run operational builds and
    integration checks via `-workspace` (not `-project`).
  - If both `.xcodeproj` and `.xcworkspace` exist, treat workspace as canonical.
  - Use `-project` only when workspace is absent.
  - If workspace exists and a command uses `-project`: **STOP and correct the command**.

#### Why workspace is mandatory for CocoaPods

When CocoaPods integrates `BlackBerryDynamics` as an XCFramework, the
platform-slice prepare script (`BlackBerryDynamics-xcframeworks.sh`) runs in the
**Pods project** build phases. Opening `.xcodeproj` directly bypasses the Pods
project, so the XCFramework slice is not prepared and module resolution fails
(`Module 'BlackBerryDynamics' not found` / stale index errors).

Recovery steps:
1. Delete stale DerivedData for the xcodeproj-only build context.
2. Run `xcodebuild clean build` through `.xcworkspace`.
3. Reopen Xcode using `.xcworkspace` only.
4. Re-run compile checks with `-workspace` commands only.

### 2a. CocoaPods Integration

If using CocoaPods:

1. Add or update `Podfile`.
   Use the project's current deployment target if it is >= 17.0, otherwise
   use '17.0' as the floor:
   ```ruby
   # Use max(current_target, '17.0') — do NOT lower a higher target
   platform :ios, '17.0'  # or keep existing if already >= 17.0
   use_frameworks!

   target 'YourApp' do
     # [BB_DYNAMICS-MIGRATION] Added BlackBerryDynamics SDK
     pod 'BlackBerryDynamics', '~> 15.0'
   end

   post_install do |installer|
     installer.pods_project.targets.each do |target|
       target.build_configurations.each do |config|
         # Only raise — never lower the deployment target
         current = config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].to_f
         config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0' if current < 17.0
         config.build_settings['ENABLE_BITCODE'] = 'NO'
       end
     end
   end
   ```

2. Run `pod install --repo-update`
3. Verify `.xcworkspace` opens without errors

#### 2a.1 CocoaPods/Xcodeproj Compatibility Preflight (Required)

Before treating `pod install` failures as migration failures, check for known
tooling incompatibility errors:

- `Unable to find compatibility version string for object version '70'`

If detected, classify as **pre-existing/tooling issue** (not migration code
failure), then run auto-remediation in this order:

1. Retry with updated CocoaPods/xcodeproj toolchain available in the environment.
2. If environment uses bundled CocoaPods (for example Homebrew), note that
   standalone gem updates may not affect bundled xcodeproj.
3. Apply project object version workaround to a value supported by installed
   toolchain, then retry `pod install`.

After remediation:
- If `pod install` succeeds: record as `resolved pre-existing/tooling issue`.
- If it still fails: record as `environment/tooling blocker` with exact
  command output and required manual action.

#### 2a.2 Application targets only — never Dynamics-enable Share Extensions

When adding `BlackBerryDynamics` / `GSEProvider` via CocoaPods, SPM, or manual
embed:

- Add Dynamics **only** to the main **application** target(s) being migrated
- **Do not** add Dynamics pods/packages/frameworks to Share Extension, Widget,
  Intents, Safari, or Notification Service targets
- **Do not** call `GDiOS.authorize()` from an extension
- If a Share Extension exists: exclude it from the Dynamics scheme / Archive /
  Embed App Extensions (see `17-app-extensions-and-share-extensions.md`)

### 2b. Manual Framework Integration

If not using CocoaPods **and** not using SPM:

1. Add frameworks to the project:
   - `BlackBerryDynamics.xcframework` → Embed & Sign
   - `GSEProvider.xcframework` → Embed & Sign

   **Version note**: This toolkit targets public SDK `15.0` (`15.0.8513.67`).
   SDK 15.0 replaced `BlackBerryCerticom.xcframework` /
   `BlackBerryCerticomSBGSE.xcframework` with a single `GSEProvider.xcframework`.
   Do not keep the old Certicom pair when integrating 15.0+.

2. Configure Build Settings:
   - Framework Search Paths → add SDK directory
   - Header Search Paths → add BlackBerryDynamics headers directory
   - Other Linker Flags → add `-ObjC`
   - Enable Bitcode → `NO`

3. Create bridging header (if Swift project with manual framework
   integration — not needed for CocoaPods since modules are available):
   ```objc
   // YourApp-Bridging-Header.h
   // [BB_DYNAMICS-MIGRATION] BlackBerry Dynamics imports
   #import <BlackBerryDynamics/GD/GDiOS.h>
   #import <BlackBerryDynamics/GD/GDState.h>
   ```
   For CocoaPods projects, use Swift module imports instead:
   `import BlackBerryDynamics.Runtime` (no bridging header needed).

### 2c. SPM Integration (Official Package)

If the integration matrix selects SPM:

1. Add the **official** BlackBerry Dynamics Swift package — do not invent
   alternate URLs:
   - URL: `https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK`
   - Xcode: File → Add Package Dependencies… → paste the URL
2. Dependency rule: **Up to Next Major** from `15.0.0`, or **Exact**
   `15.0.0` for a reproducible migration pin.
   - Tag `15.0.0` ships SDK build `15.0.8513.67` (this toolkit's target).
3. Link both products required by SDK 15.0 on the **app target**:
   - `BlackBerryDynamics` (required)
   - `GSEProvider` (required)
   - Do **not** link `BlackBerryDynamicsAutomatedTestSupportLibrary` to the
     production app target (test targets only, if needed).
4. If the repo owns a `Package.swift`, declare the same dependency:

   ```swift
   // [BB_DYNAMICS-MIGRATION] Official BlackBerry Dynamics SPM (prompt 01)
   .package(
       url: "https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK",
       from: "15.0.0"
   )
   ```

   And link products:

   ```swift
   .product(name: "BlackBerryDynamics", package: "BlackBerry-Dynamics-iOS-SDK"),
   .product(name: "GSEProvider", package: "BlackBerry-Dynamics-iOS-SDK"),
   ```

5. Resolve package dependencies (File → Packages → Resolve Package Versions).
6. Verify `project.pbxproj` contains
   `repositoryURL = "https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK"`.
7. Verify the project builds after package resolution.

If the repository also contains a Podfile (mixed setup), keep existing pods
as-is unless Prompt 00 identified an explicit cleanup requirement. Do not
migrate unrelated dependencies across package managers during this step.

See `10-xcode-integration.md` Method 1b for the full SPM reference.

### 3. Enable Keychain Sharing (REQUIRED)

1. Select the app target → Signing & Capabilities
2. Add "Keychain Sharing" capability
3. Add keychain group: `com.good.gd.data`
4. Verify the `.entitlements` file contains:
   ```xml
   <key>keychain-access-groups</key>
   <array>
       <string>$(AppIdentifierPrefix)com.good.gd.data</string>
   </array>
   ```

### 4. Ensure Deployment Target is at Least iOS 17

BlackBerry Dynamics SDK 15.x requires iOS **>= 17.0** (CocoaPods platform).
Do NOT force the target to exactly 17.0 — preserve higher targets.

- **If current target < 17.0**: raise to 17.0 in Xcode and Podfile
- **If current target >= 17.0** (e.g., 18.0, 26.0): **keep the existing
  target** — do not lower it. Lowering introduces API availability errors
  for modern APIs the app already uses (e.g., `glassEffect`, `@Observable`)
- Update Podfile platform to match: `platform :ios, '<current-or-17>'`
- After changing (if target was raised), search for `#available` / `@available`
  checks against iOS < 17 — these become dead code
- **If raising the target introduces new build errors** (e.g., availability
  warnings becoming errors), classify them as pre-existing compatibility issues
  and add them to `manualTodos` rather than blocking the migration

### 5. Disable BitCode

- Set `Enable Bitcode = NO` in Build Settings
- Or in Podfile post_install (shown above)

### 6. Remove Conflicting Dependencies

Based on Prompt 00 analysis, remove from Podfile or project:
- SQLCipher pods (if migrating to sqlite3enc)
- App-level encryption libraries (redundant with container encryption)
- Custom keychain wrappers that conflict with `com.good.gd.data`

### 7. Post-Integration Availability Scan

If the deployment target was raised in step 4, scan for API availability
issues introduced by the change:

```bash
# Check for availability errors after deployment target change
xcodebuild -workspace YourApp.xcworkspace -scheme YourApp \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "'.*' is only available|@available"
```

If errors appear for APIs above the new target (e.g., iOS 18+ APIs now that
target is 17.0), classify each as:
- **Pre-existing**: app was already using APIs above its old target
- **Target-change introduced**: API was valid at the old target but not at 17.0

For target-change introduced errors, either:
- Keep the higher target (preferred, if currently >= 17.0)
- Add `if #available` guards and log as `manualTodos`
- Do NOT silently delete modern API usage

### 7a. Preserve Embed Frameworks (multi-target / workspace products)

When adding BlackBerry Dynamics / `GSEProvider` to **Embed Frameworks**:

1. **Never clear or replace** an existing Embed Frameworks / Copy Files
   (Frameworks) phase. Only **append** Dynamics products.
2. For **every migrated application target** (Swift and ObjC, etc.), verify
   that local workspace dynamic products already linked by that target
   (for example `DGCharts.framework`) remain **linked and embedded**
   (`Code Sign On Copy`) after Dynamics integration.
3. Multi-target workspaces often embed a product on one app target only —
   do not assume the other target inherits Embed Frameworks. Check each
   app target’s `PBXFrameworksBuildPhase` and Embed Frameworks phase.
4. After a device/simulator build, inspect
   `YourApp.app/Frameworks/` and confirm both Dynamics frameworks **and**
   pre-existing app frameworks are present. A dyld
   `Library not loaded: @rpath/Some.framework` immediate exit after install
   usually means Embed Frameworks was emptied or incomplete for that target.

### 8. Build and Verify

```bash
# CocoaPods project
xcodebuild -workspace YourApp.xcworkspace -scheme YourApp \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build

# Non-CocoaPods project
xcodebuild -project YourApp.xcodeproj -scheme YourApp \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

**Build failure classification**: The developer attested a clean pre-migration
build in Prompt 00. If the build fails here, classify failures as:
- **integration-introduced**: caused by Prompt 01 changes
- **pre-existing/tooling**: CocoaPods/xcodeproj or environment incompatibility
- **unrelated**: transient machine-specific issues

Only integration-introduced failures block Prompt 02 unconditionally.
Pre-existing/tooling failures should trigger auto-remediation first.

Build commands in this migration flow must use unsigned simulator mode
(`-sdk iphonesimulator CODE_SIGNING_ALLOWED=NO`) to avoid signing-only churn.

---

## Output

- List of project configuration changes
- Dependencies added and removed
- Deployment target change documented
- Keychain Sharing capability confirmed
- Canonical build entrypoint documented (`.xcworkspace` or `.xcodeproj`)
- CocoaPods compatibility remediation result (if applicable)
- Build verification result

See `10-xcode-integration.md` for the full steering reference.
