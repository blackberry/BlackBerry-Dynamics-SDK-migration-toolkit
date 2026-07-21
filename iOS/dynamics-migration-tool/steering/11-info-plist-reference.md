# Steering: Info.plist Configuration Reference

The iOS Dynamics SDK uses `Info.plist` for configuration instead of the
Android `settings.json`. All Dynamics-related keys go in the app's main
`Info.plist`.

---

## Required System Keys (when switching to manual Info.plist)

When a project migrates from `GENERATE_INFOPLIST_FILE = YES` to a manual
`Info.plist`, the following system keys are no longer auto-generated.
Their absence causes critical runtime failures:

| Key | Effect if absent |
|-----|-----------------|
| `UILaunchScreen` | iOS runs app in legacy 320×480 compatibility mode — **SDK activation UI appears as a non-full-screen card** |
| `LSRequiresIPhoneOS` | App may not be recognised as an iOS app by the system. Note: this key means "requires the iOS runtime" — it does **not** restrict the app to iPhone hardware; iPad also runs iOS |
| `UIApplicationSceneManifest` | Scene lifecycle not configured; may prevent scene-based apps from launching correctly |
| `UISupportedInterfaceOrientations` | iPhone orientation defaults to undefined behaviour |
| `UISupportedInterfaceOrientations~ipad` | iPad falls back to portrait-only (missing on universal apps causes orientation regression on iPad) |

**Include these in any manual `Info.plist`** — use the universal template
for apps that support both iPhone and iPad:

```xml
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

<!-- iPad orientations — include for universal (iPhone + iPad) apps -->
<key>UISupportedInterfaceOrientations~ipad</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>
```

**Key rules:**
- The bare `UISupportedInterfaceOrientations` key applies to **iPhone only**.
  iPad reads the `~ipad` variant. Without `~ipad`, iPad defaults to
  portrait-only regardless of what the iPhone key says.
- Omit `UISupportedInterfaceOrientations~ipad` only if the original app
  was explicitly iPhone-only (`TARGETED_DEVICE_FAMILY = 1`).
- Preserve whatever orientations the **original** app declared. Do not
  narrow the supported orientations during migration.
- `LSRequiresIPhoneOS = true` marks the app as requiring the iOS runtime
  (not macOS/Catalyst). It does **not** limit the app to iPhone hardware.

**If applying a fix to a device/simulator**, the app must be deleted and
rebuilt clean — iOS caches launch screen metadata and a dirty install will
not pick up a newly added `UILaunchScreen` key.

---

## Required Keys (Dynamics-specific)

### GDApplicationID

The entitlement ID assigned by the UEM administrator. This value MUST
come from the developer — never guess or use the bundle identifier.

```xml
<key>GDApplicationID</key>
<string>com.company.appname</string>
```

### GDApplicationVersion

The entitlement version configured in UEM. This may differ from the
app's `CFBundleShortVersionString`.

```xml
<key>GDApplicationVersion</key>
<string>1.0.0.0</string>
```

---

## Required URL Schemes

URL schemes are registered under `CFBundleURLTypes`. The following are
required for Dynamics:

### Discovery (CRITICAL — always required)

**CRITICAL**: The scheme `com.good.gd.discovery` is mandatory for ALL app types.
Without it the SDK will `assert` and exit immediately on launch with:
`ERROR: Applications must declare URL scheme (com.good.gd.discovery)`

### Second Discovery Scheme (varies by app setup type)

The SDK enforces strict rules on the second discovery scheme at runtime:

| App Setup Type | Second Discovery Scheme | Rule |
|---------------|------------------------|------|
| **In-house** (set up in UEM) | `com.good.gd.discovery.enterprise` | Required |
| **Partner / third-party** (developer portal) | None | Must NOT register `.enterprise` or `.good` |
| **BlackBerry-developed** | `com.good.gd.discovery.good` | Only for `com.good.*` / `com.blackberry.*` / `com.rim.*` GDApplicationIDs |

**Runtime constraints (from SDK source — `GDDeviceApple.mm`):**
- An app may NOT register both `.good` and `.enterprise` — runtime will exit.
- Only BlackBerry-owned apps may register `.good` — runtime checks GDApplicationID prefix.
- The bare `.sc` scheme (without `2` or `3`) is rejected as unsupported.
- Typos like `com.good.discovery.good` or `com.good.discovery.enterprise`
  (missing `.gd.`) are detected and rejected with helpful error messages.

### Service Communication & Auth Delegation (always required)

The URL type must use the app's **native bundle identifier**. Do not use
`GDApplicationID` for `.sc2` / `.sc3` schemes; `GDApplicationID` is the UEM
entitlement ID and may differ from the native bundle ID.

Prefer the literal bundle identifier from `CFBundleIdentifier` or
`PRODUCT_BUNDLE_IDENTIFIER`. `$(PRODUCT_BUNDLE_IDENTIFIER)` is acceptable only
when the built app's `Info.plist` resolves it correctly. The
`.sc2.<GDApplicationVersion>` scheme must include the literal
`GDApplicationVersion` value.

For in-house/UEM-managed apps, all schemes should be in a single
`CFBundleURLSchemes` array:

```xml
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

Where `com.example.myapp` is the native bundle identifier and `1.0.0.0` is the
value of the `GDApplicationVersion` Info.plist key.

Example with `GDApplicationVersion` `1.0.0.0`:

```xml
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

---

## Conditional Required Keys

### BlackBerryDynamics Dictionary (Notification-Based Auth)

To use the notification-based authorization pattern instead of the
delegate pattern, this top-level dictionary is required. Without it, the
runtime can assert because it expects a `GDiOSDelegate` event receiver:

```xml
<key>BlackBerryDynamics</key>
<dict>
    <key>CheckEventReceiver</key>
    <false/>
</dict>
```

When `CheckEventReceiver` is `false`, the SDK does not require a
`GDiOSDelegate` and instead posts `GDStateChangeNotification`.

---

## Optional Keys

### GDEnableBackgroundAuthorize

Enable background authorization for apps that need to process data
while in the background:

```xml
<key>GDEnableBackgroundAuthorize</key>
<true/>
```

### GDConsoleLogger

Configure console logging verbosity for development:

```xml
<key>GDConsoleLogger</key>
<array>
    <string>GDFilterErrors_</string>
    <string>GDFilterWarnings_</string>
    <string>GDFilterInfo</string>
    <string>GDFilterDetailed</string>
</array>
```

Categories with trailing underscore (`_`) are included. Use
`GDFilterNone` for maximum verbosity during development.

### NSFaceIDUsageDescription

Mandatory for Dynamics biometric container unlock. If this key is missing or
empty, the SDK can terminate the app at startup with an error that
`NSFaceIDUsageDescription` must be present.

```xml
<key>NSFaceIDUsageDescription</key>
<string>Used for secure authentication to unlock the BlackBerry Dynamics container.</string>
```

### Privacy — Camera Usage Description

Mandatory for QR-code activation readiness:

```xml
<key>NSCameraUsageDescription</key>
<string>Used to scan QR codes during BlackBerry Dynamics activation.</string>
```

---

## Complete Example

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Existing app keys... -->

    <!-- [BB_DYNAMICS-MIGRATION] Dynamics entitlement configuration -->
    <key>GDApplicationID</key>
    <string>com.company.appname</string>
    <key>GDApplicationVersion</key>
    <string>1.0.0.0</string>

    <!-- [BB_DYNAMICS-MIGRATION] Required URL schemes for Dynamics -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>None</string>
            <key>CFBundleURLName</key>
            <string>com.company.appname</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>com.company.appname.sc2</string>
                <string>com.company.appname.sc2.1.0.0.0</string>
                <string>com.company.appname.sc3</string>
                <string>com.good.gd.discovery</string>
                <string>com.good.gd.discovery.enterprise</string>
            </array>
        </dict>
    </array>

    <!-- [BB_DYNAMICS-MIGRATION] Face ID for biometric unlock -->
    <key>NSFaceIDUsageDescription</key>
    <string>Used for secure authentication to unlock the BlackBerry Dynamics container.</string>

    <!-- [BB_DYNAMICS-MIGRATION] Camera for QR activation -->
    <key>NSCameraUsageDescription</key>
    <string>Used to scan QR codes during BlackBerry Dynamics activation.</string>

    <!-- [BB_DYNAMICS-MIGRATION] Console logging for development -->
    <key>GDConsoleLogger</key>
    <array>
        <string>GDFilterNone</string>
    </array>
</dict>
</plist>
```

---

## Key Rules

- **GDApplicationID** must exactly match the UEM entitlement — it is NOT
  necessarily the same as the bundle identifier
- **GDApplicationVersion** must exactly match the UEM entitlement version —
  it is NOT necessarily the same as CFBundleShortVersionString
- URL schemes must use the actual `CFBundleIdentifier` value, not the
  `GDApplicationID`
- Register `.sc2`, `.sc2.<GDApplicationVersion>`, `.sc3`,
  `com.good.gd.discovery`, and the setup-specific second discovery scheme
- `NSFaceIDUsageDescription` must be present with a non-empty purpose string
- `NSCameraUsageDescription` must be present with a non-empty purpose string
  for QR-code activation readiness
- Do not register the unsupported bare `.sc` scheme
- Do not register both `com.good.gd.discovery.enterprise` and
  `com.good.gd.discovery.good`
- If the app already has `CFBundleURLTypes`, merge the Dynamics schemes
  into the existing array — do not replace it
