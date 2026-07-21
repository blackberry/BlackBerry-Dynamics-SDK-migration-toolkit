# Task: Configure Info.plist for BlackBerry Dynamics

**Prerequisite**: Prompt 01 (xcode-integration) must be complete.

## INTERACTION_REQUIRED: Developer Input Needed

This prompt CANNOT proceed without developer input. Do NOT use placeholder
values. Do NOT continue to prompt 03 until both GDApplicationID and
GDApplicationVersion are provided by the developer.

## Goal
Configure the required Info.plist entries for BlackBerry Dynamics.

---

## Steps

### 0. Detect Info.plist Strategy

Modern Xcode projects may use **generated Info.plist** files
(`GENERATE_INFOPLIST_FILE = YES` in build settings) instead of a physical
`Info.plist` file. Check this first:

```bash
# Check if the project uses a generated Info.plist
xcodebuild -showBuildSettings -scheme YourApp 2>/dev/null | grep GENERATE_INFOPLIST_FILE
```

**If `GENERATE_INFOPLIST_FILE = YES`:**

The project has no physical `Info.plist` — Xcode generates it from build
settings at build time. Dynamics requires keys (`GDApplicationID`, URL
schemes) that are not supported by the `INFOPLIST_KEY_*` build-settings
mechanism, so migration must switch to a manual `Info.plist`.

**[WARN] CRITICAL — INFOPLIST_KEY_* build settings are silently dropped when
switching to a manual plist.** Xcode only processes `INFOPLIST_KEY_*`
settings (e.g. `INFOPLIST_KEY_UILaunchScreen_Generation`) when
`GENERATE_INFOPLIST_FILE = YES`. When you set it to `NO`, every
`INFOPLIST_KEY_*` value is silently ignored and never written to the
compiled `Info.plist`. If these are not manually transcribed, the SDK
activation UI will appear as a non-full-screen card on device (a legacy
layout mode iOS activates when `UILaunchScreen` is absent), and other
runtime behaviour will be broken.

**Before switching to `GENERATE_INFOPLIST_FILE = NO`**, audit the current
`INFOPLIST_KEY_*` build settings and note their values:

```bash
xcodebuild -showBuildSettings -scheme YourScheme 2>/dev/null \
  | grep "INFOPLIST_KEY_"
```

Record every `INFOPLIST_KEY_*` value found. These must be converted to
their Info.plist XML equivalents and added to the manual plist.

**Check `TARGETED_DEVICE_FAMILY` before switching** — this setting controls
whether the app targets iPhone (1), iPad (2), or both (1,2 = universal):

```bash
xcodebuild -showBuildSettings -scheme YourScheme 2>/dev/null \
  | grep "TARGETED_DEVICE_FAMILY"
```

If the original app is universal (`1,2`), the manual plist **must** include
`UISupportedInterfaceOrientations~ipad` in addition to the base key.
Do **not** narrow the device family during migration — preserve whatever
the original app supported.

The following keys must **always** be present in the manual plist —
they are either auto-generated (and thus silently lost) or required for
Dynamics window management:

| INFOPLIST_KEY_* Setting | Manual Info.plist Key | Why it matters |
|------------------------|----------------------|----------------|
| `INFOPLIST_KEY_UILaunchScreen_Generation = YES` | `UILaunchScreen` | **Absence causes legacy layout mode — SDK activation UI appears as a card instead of full-screen** |
| `INFOPLIST_KEY_LSRequiresIPhoneOS = YES` | `LSRequiresIPhoneOS` | Requires the iOS runtime environment (does NOT restrict to iPhone hardware — iPad runs iOS too) |
| `INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES` | `UIApplicationSceneManifest` | Required for scene lifecycle |
| `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = …` | `UISupportedInterfaceOrientations` | Declares supported orientations on iPhone |
| `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = …` | `UISupportedInterfaceOrientations~ipad` | Declares supported orientations on iPad (universal apps only) |

Add these to the manual `Info.plist` (see XML template below).
Then transcribe any other `INFOPLIST_KEY_*` values found in the audit.

**Procedure:**
- **Preferred approach**: Run one build first to get a complete generated
  plist from `DerivedData/.../Build/Products/.../YourApp.app/Info.plist`,
  copy it as the manual `Info.plist` base, then set
  `GENERATE_INFOPLIST_FILE = NO` and `INFOPLIST_FILE = <path>`.
  This guarantees no auto-generated key is accidentally dropped, including
  both orientation keys and the correct `TARGETED_DEVICE_FAMILY` values.
- Place the manual `Info.plist` at the **project root** (or another location
  outside source-synced target folders). Putting it inside a source-synced
  target directory can trigger duplicate build outputs:
  `Multiple commands produce .../Info.plist`.
- **Alternative**: Create a new `Info.plist` manually. You must then
  manually include all required keys plus any app-specific
  `INFOPLIST_KEY_*` values found in the audit.

**Template (universal iPhone + iPad app):**
```xml
<!-- [BB_DYNAMICS-MIGRATION] Keys previously auto-generated — must be explicit now -->
<key>LSRequiresIPhoneOS</key>
<true/>

<key>UILaunchScreen</key>
<dict/>

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

<!-- iPad orientations (required for universal apps — omit for iPhone-only apps) -->
<key>UISupportedInterfaceOrientations~ipad</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>

<!-- Required synthesized bundle identity keys when GENERATE_INFOPLIST_FILE = NO -->
<key>CFBundleDevelopmentRegion</key>
<string>$(DEVELOPMENT_LANGUAGE)</string>
<key>CFBundleExecutable</key>
<string>$(EXECUTABLE_NAME)</string>
<key>CFBundleIdentifier</key>
<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
<key>CFBundleInfoDictionaryVersion</key>
<string>6.0</string>
<key>CFBundleName</key>
<string>$(PRODUCT_NAME)</string>
<key>CFBundlePackageType</key>
<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
<key>CFBundleShortVersionString</key>
<string>$(MARKETING_VERSION)</string>
<key>CFBundleVersion</key>
<string>$(CURRENT_PROJECT_VERSION)</string>
```

**Orientation notes:**
- `UISupportedInterfaceOrientations` (no suffix) = iPhone. iPad reads the
  `~ipad` variant; without it iPad defaults to portrait-only.
- iPad typically supports all four orientations including
  `PortraitUpsideDown`, which iPhone usually omits.
- Preserve the orientations the original app declared — do not narrow them
  during migration.
- `LSRequiresIPhoneOS = true` means "requires the iOS runtime" — it does
  **not** mean "iPhone hardware only". iPad runs iOS so this key is correct
  for universal apps.

If the app uses a scene configuration (SceneDelegate / scene-based
lifecycle), the `UIApplicationSceneManifest` will need the full
`UISceneConfigurations` sub-dictionary copied from the generated plist.
The minimal template above is a safe default for apps without explicit
scene configurations. Use the "Preferred approach" (DerivedData copy)
to preserve any scene configuration the app already has.

**If `GENERATE_INFOPLIST_FILE = NO` or a physical `Info.plist` already exists:**
- Proceed with the standard steps below.
- Verify that `UILaunchScreen`, `UIApplicationSceneManifest`,
  `UISupportedInterfaceOrientations`, and (for universal apps)
  `UISupportedInterfaceOrientations~ipad` are present. If any are
  missing, add them now using the template above.
- Verify synthesized bundle identity keys are present:
  `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundleName`,
  `CFBundlePackageType`, `CFBundleShortVersionString`, and `CFBundleVersion`.

1. **STOP and ask the developer for GDApplicationID**
   - Do NOT guess, infer, or use the app's bundle identifier as the GDApplicationID
   - This value is assigned by the UEM administrator and must match the
     entitlement configuration in UEM exactly
   - The developer must obtain this from their UEM admin before proceeding
   - Example format: "com.company.appname" (but it may differ from the
     app's actual bundle identifier)
   - **Do not proceed until the developer provides this value**

2. **STOP and ask the developer for GDApplicationVersion**
   - Do NOT assume this matches the app's CFBundleShortVersionString
   - This is the entitlement version configured in UEM, which may differ
     from the app's build version
   - Format: "X.Y.Z.W" (e.g., "1.0.0.0")
   - **Do not proceed until the developer provides this value**

3. **Add Dynamics keys to Info.plist** (only after receiving both values)

   ```xml
   <!-- [BB_DYNAMICS-MIGRATION] Dynamics entitlement configuration -->
   <key>GDApplicationID</key>
   <string>DEVELOPER_PROVIDED_VALUE</string>
   <key>GDApplicationVersion</key>
   <string>DEVELOPER_PROVIDED_VALUE</string>
   ```

4. **Determine application setup type (REQUIRED)**

   **STOP and ask the developer** which setup type applies to their app.
   The SDK enforces different URL scheme rules per setup type (the runtime
   validates this at startup and will `assert` + exit on violation):

   | Setup Type | Description | Second Discovery Scheme |
   |------------|-------------|------------------------|
   | **In-house** | Set up directly in UEM console | `com.good.gd.discovery.enterprise` (required) |
   | **Partner / third-party** | Set up via developer portal | None (do NOT register `.enterprise` or `.good`) |
   | **BlackBerry-developed** | Internal BlackBerry apps only | `com.good.gd.discovery.good` (do NOT use for customer apps) |

   **Constraint (from SDK runtime):** An app may NOT register both
   `com.good.gd.discovery.good` and `com.good.gd.discovery.enterprise`.
   Only BlackBerry-owned apps (GDApplicationID starting with `com.good.`,
   `com.blackberry.`, or `com.rim.`) may register `.good`.

   Record the answer in `dynamics-migration-tool/output/bootstrap.json` under
   `uemValues.applicationSetupType` as one of:
   - `in-house`
   - `partner-third-party`
   - `blackberry-developed`

   If the developer is unsure and the app is managed directly in UEM, treat it
   as `in-house`.

5. **Add required URL schemes**

   Use the app's **native bundle identifier** and the `GDApplicationVersion`
   from step 2. Do **not** use `GDApplicationID` for `.sc2` / `.sc3` schemes.
   `GDApplicationID` is the UEM entitlement ID and may differ from the native
   bundle identifier.

   **CRITICAL**: The `com.good.gd.discovery` scheme is mandatory for ALL app
   types. Without it the SDK will terminate the app on launch with:
   `ERROR: Applications must declare URL scheme (com.good.gd.discovery)`

   **CRITICAL**: The `.sc2`, `.sc2.<GDApplicationVersion>`, and `.sc3`
   schemes are also mandatory. If they are missing, startup can fail with:
   `GDLibStartupLayer::startup FAILED - applications must now declare URL schemes`.

   The SDK also validates that `.sc` (without `2` or `3`) is NOT registered —
   it will reject it as an unsupported scheme.

   **Bundle identifier rule**:
   - Preferred: use the literal native bundle identifier from `CFBundleIdentifier`
     or Xcode `PRODUCT_BUNDLE_IDENTIFIER` (for example,
     `com.example.myapp.sc2`).
   - `$(PRODUCT_BUNDLE_IDENTIFIER)` is acceptable only where Xcode resolves it
     in the built app's `Info.plist`; verify by inspecting the built
     `.app/Info.plist` if you choose this form.
   - The `.sc2.<version>` scheme must include the literal
     `GDApplicationVersion` value (for example, `.sc2.1.0.0.0`), not a version
     build variable.

   **For in-house apps (5 schemes)** — example with `GDApplicationVersion`
   `1.0.0.0` and bundle ID `com.example.myapp`:
   ```xml
   <!-- [BB_DYNAMICS-MIGRATION] Required URL schemes for Dynamics (in-house) -->
   <key>CFBundleURLTypes</key>
   <array>
       <dict>
           <key>CFBundleTypeRole</key>
           <string>None</string>
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

   **For partner / third-party apps (4 schemes)** — example with
   `GDApplicationVersion` `1.0.0.0`:
   ```xml
   <!-- [BB_DYNAMICS-MIGRATION] Required URL schemes for Dynamics (partner) -->
   <key>CFBundleURLTypes</key>
   <array>
       <dict>
           <key>CFBundleTypeRole</key>
           <string>None</string>
           <key>CFBundleURLName</key>
           <string>com.example.myapp</string>
           <key>CFBundleURLSchemes</key>
           <array>
               <string>com.example.myapp.sc2</string>
               <string>com.example.myapp.sc2.1.0.0.0</string>
               <string>com.example.myapp.sc3</string>
               <string>com.good.gd.discovery</string>
           </array>
       </dict>
   </array>
   ```

   Replace `com.example.myapp` with the native bundle identifier and
   `1.0.0.0` with the actual `GDApplicationVersion` provided by the developer
   in step 2.

   If the app already has `CFBundleURLTypes`, merge the Dynamics schemes
   into the existing array.

6. **Add Face ID usage description (MANDATORY)**

   This key is a Dynamics startup requirement. Without a non-empty purpose
   string, the SDK can terminate the app with:
   `ERROR: Applications must include the NSFaceIDUsageDescription key in Info.plist file and provide a purpose string for this key.`

   ```xml
   <!-- [BB_DYNAMICS-MIGRATION] Face ID for Dynamics biometric unlock -->
   <key>NSFaceIDUsageDescription</key>
   <string>Used for secure authentication to unlock the BlackBerry Dynamics container.</string>
   ```

   If an `NSFaceIDUsageDescription` already exists, keep it only if it is a
   production-appropriate non-empty purpose string. Otherwise replace it with
   the Dynamics purpose above.

7. **Add Camera usage description (MANDATORY for QR activation readiness)**

   ```xml
   <!-- [BB_DYNAMICS-MIGRATION] Camera for QR code activation -->
   <key>NSCameraUsageDescription</key>
   <string>Used to scan QR codes during BlackBerry Dynamics activation.</string>
   ```

   If an `NSCameraUsageDescription` already exists, keep the existing
   description — do NOT replace it with the generic Dynamics string.

8. **Advisory: cross-check privacy usage keys**

   Prompt 02 is not a full privacy audit, but if analysis found framework usage
   requiring usage-description keys, surface a manual todo:
   - `PhotosUI` / photo library access -> `NSPhotoLibraryUsageDescription`
   - camera capture APIs -> `NSCameraUsageDescription`
   - location APIs -> `NSLocationWhenInUseUsageDescription`

   Do not invent new app copy text automatically. Ask the developer to provide
   production-appropriate wording.

9. **Add console logging** (for development only)

   ```xml
   <!-- [BB_DYNAMICS-MIGRATION] Console logging for development — REMOVE before release -->
   <key>GDConsoleLogger</key>
   <array>
       <string>GDFilterNone</string>
   </array>
   ```

   **WARNING**: `GDFilterNone` logs all SDK activity including tokens and
   policy data. Add a `[MANUAL-TODO]` comment reminding the developer to
   remove or restrict this key before production release.

10. **Verify Info.plist syntax**
   - Confirm the plist is valid XML
   - Confirm no duplicate keys
   - Confirm URL schemes resolve to the app bundle identifier (not GDApplicationID)
   - Confirm `.sc2`, `.sc2.<GDApplicationVersion>`, `.sc3`,
     `com.good.gd.discovery`, and the setup-specific discovery scheme policy
     are all satisfied
   - Confirm `NSFaceIDUsageDescription` is present with a non-empty purpose
     string
   - Confirm `NSCameraUsageDescription` is present with a non-empty purpose
     string for QR activation readiness
   - Confirm no bare `.sc` scheme is registered
   - In manual plist mode, confirm required `CFBundle*` identity keys exist
   - Ensure manual `Info.plist` is not included in Copy Bundle Resources

---

## Common Pitfalls (Prompt 02)

- Switching to `GENERATE_INFOPLIST_FILE = NO` without adding required
  synthesized `CFBundle*` keys causes install-time bundle validation failures.
- Creating manual `Info.plist` inside a source-synced target folder can cause
  `Multiple commands produce .../Info.plist`.
- Placeholder/inferred `GDApplicationID` or `GDApplicationVersion` values lead
  to authorization and entitlement failures.
- Missing `CFBundleURLTypes` or missing `.sc2` / `.sc2.<version>` / `.sc3`
  schemes causes fatal Dynamics startup failures before the migration reaches
  authorization.
- Missing `NSFaceIDUsageDescription` causes a fatal Dynamics startup failure
  when biometric container unlock support is initialized.

---

## Output

- Info.plist updated with developer-provided GDApplicationID and GDApplicationVersion
- `CFBundleURLTypes` added or merged with the required Dynamics URL schemes
  using the native bundle identifier
- Face ID and Camera usage descriptions added
- Configuration explanation provided to developer
- Next steps: entitlement setup in UEM

---

## Critical Notes

- **NEVER use the app's bundle identifier or build version as defaults** —
  these values come from UEM and may be completely different
- The app will NOT authorize without GDApplicationID in Info.plist
- GDApplicationID must exactly match UEM configuration
- GDApplicationVersion must exactly match UEM entitlement version
- URL schemes must use the bundle identifier, NOT the GDApplicationID
- Required URL schemes are `.sc2`, `.sc2.<GDApplicationVersion>`, `.sc3`,
  `com.good.gd.discovery`, and the setup-specific second discovery scheme
- `NSFaceIDUsageDescription` is mandatory for Dynamics biometric unlock
- `NSCameraUsageDescription` is mandatory for QR activation readiness
- If the developer doesn't know these values, instruct them to contact
  their UEM administrator before continuing

See `11-info-plist-reference.md` for the full reference.
