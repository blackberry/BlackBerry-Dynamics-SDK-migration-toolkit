# Steering: Activation and Easy Activation (iOS)

## Activation Methods

### Standard Activation (Email + Access Key)

The user enters their email address and an access key provided by the
UEM administrator. The SDK handles the entire activation flow — the app
has no control over this UI.

### QR Code Activation

The user scans a QR code containing activation credentials. Requires
camera permission:

```xml
<key>NSCameraUsageDescription</key>
<string>Used to scan QR code during activation</string>
```

### Easy Activation

If another Dynamics app is already activated on the device, new apps can
activate automatically without requiring the user to enter credentials.
This is controlled by UEM policy.

Requirements:
- Another Dynamics app is already activated on the device
- Both apps share the same UEM server
- UEM policy allows Easy Activation
- The app has the required URL schemes registered

### Programmatic Activation

For apps that need to activate without user interaction:

```swift
// Programmatic activation with credentials
GDiOS.sharedInstance().programmaticAuthorize(
    withID: userEmail,
    andAccessKey: accessKey
)
```

---

## Migration Impact

Activation is handled entirely by the SDK — no migration work is needed
for the activation flow itself. However:

1. Ensure `NSCameraUsageDescription` is in Info.plist (for QR activation)
2. Ensure URL schemes are registered (for Easy Activation)
3. Do NOT add custom activation UI — the SDK provides it
4. Remove any app-level "first launch" or "onboarding" that conflicts
   with the activation flow — the SDK's activation UI appears first

---

## Activation State Tracking

The `BBActivationState` property on `GDState` tracks activation progress:

```swift
NotificationCenter.default.addObserver(forName: .GDStateChange, object: nil, queue: .main) { notification in
    guard let state = notification.userInfo?[GDStateChangeKeyCopy] as? GDState else { return }
    let activationState = state.activationState
    // Track activation progress
}
```
