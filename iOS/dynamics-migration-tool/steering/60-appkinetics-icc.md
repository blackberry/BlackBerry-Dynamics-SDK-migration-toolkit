# Steering: AppKinetics Inter-Container Communication (iOS)

AppKinetics is the Dynamics framework for secure inter-app communication
(ICC). It allows Dynamics-enabled apps to exchange data securely without
exposing it to non-Dynamics apps.

---

## Key Classes

| Class | Role |
|-------|------|
| `GDService` | Service provider — receives requests from other apps |
| `GDServiceClient` | Service consumer — sends requests to other apps |
| `GDServiceProvider` | Service discovery — find available services |
| `GDServiceDetail` | Service metadata |

---

## When to Use AppKinetics

Use AppKinetics when the app:
- Shares files with other Dynamics apps
- Opens documents in other Dynamics apps (e.g., "Open In" functionality)
- Provides a service to other Dynamics apps
- Consumes a service from other Dynamics apps

Do **not** invent generic services when no provider/consumer contract exists.
If a contract is unknown, keep the call site blocked with explicit
product/security follow-up evidence.

Replace standard iOS sharing mechanisms:
- `UIActivityViewController` → AppKinetics for secure sharing
- URL schemes → AppKinetics for inter-Dynamics-app communication
- `UIDocumentInteractionController` → AppKinetics for document handling

---

## Required Import

Always use the AppKinetics submodule. Do NOT use bare `import BlackBerryDynamics`:

```swift
import BlackBerryDynamics.AppKinetics
```

For ObjC:
```objc
@import BlackBerryDynamics.AppKinetics;
```

## GDTForegroundOption Enum Constants

Use exact names from `GDServices.h` — do not abbreviate:
- `GDEPreferMeInForeground` — current app stays in foreground
- `GDEPreferPeerInForeground` — target app comes to foreground
- `GDENoForegroundPreference` — no preference

## Service Consumer (Sending Data)

The `sendTo:` method returns `BOOL` and takes an `NSError**` + `requestID` out-pointer.
In Swift, use the BOOL-return pattern — this is NOT a `throws` function:

```swift
// [BB_DYNAMICS-MIGRATION] Using GDServiceClient to send file to another Dynamics app
import BlackBerryDynamics.AppKinetics

func sendFileToApp(providerAddress: String, filePaths: [String]) {
    var requestID: NSString? = nil
    var sendError: NSError? = nil
    let sent = GDServiceClient.send(
        to: providerAddress,
        withService: "com.good.gdservice.transfer-file",
        withVersion: "1.0.0.0",
        withMethod: "transferFile",
        withParams: nil,
        withAttachments: filePaths,
        bringServiceToFront: .GDEPreferPeerInForeground,
        requestID: &requestID,
        error: &sendError
    )
    if !sent {
        print("AppKinetics send failed: \(sendError?.localizedDescription ?? "unknown")")
    }
}
```

## Service Provider (Receiving Data)

The required `GDServiceDelegate` callback includes `forRequestID` — it is
part of the required protocol; omitting it causes a compile error:

```swift
// [BB_DYNAMICS-MIGRATION] Implementing GDServiceDelegate to receive files
import BlackBerryDynamics.AppKinetics

class AppDelegate: UIResponder, UIApplicationDelegate, GDServiceDelegate {

    func gdServiceDidReceiveFrom(
        _ application: String,
        forService service: String,
        withVersion version: String,
        forMethod method: String,
        withParams params: Any?,
        withAttachments attachments: [String],
        forRequestID requestID: String
    ) {
        guard service == "com.good.gdservice.transfer-file" else { return }
        for filePath in attachments {
            processReceivedFile(at: filePath)
        }
    }
}
```

## UIActivityViewController Decision Gate

Do NOT replace all `UIActivityViewController` usage. Only replace where the
shared data is enterprise-sensitive (protected files, business data, credentials).
Standard share sheets for public/non-sensitive content may remain native.

---

## Service Discovery

Find apps that provide a specific service:

```swift
let providers = GDiOS.sharedInstance().getServiceProviders(
    for: "com.good.gdservice.transfer-file",
    andVersion: "1.0.0.0",
    andServiceType: .application
)

for provider in providers ?? [] {
    print("Provider: \(provider.identifier) - \(provider.name)")
}
```

---

## Info.plist Registration

If the app acts as a service provider, register services in Info.plist:

```xml
<!-- [BB_DYNAMICS-MIGRATION] AppKinetics service registration -->
<key>GDServices</key>
<array>
    <dict>
        <key>GDServiceID</key>
        <string>com.good.gdservice.transfer-file</string>
        <key>GDServiceVersion</key>
        <string>1.0.0.0</string>
        <key>GDServiceType</key>
        <string>application</string>
    </dict>
</array>
```

Registration keys and values must be verified against the installed SDK and
official docs used by your target app baseline. Prompt validation requires
both source closure and plist registration closure evidence.

---

## Common ICC Patterns

### "Open In" Replacement

```swift
// Before: UIDocumentInteractionController (opens in any app)
let controller = UIDocumentInteractionController(url: fileURL)
controller.presentOpenInMenu(from: rect, in: view, animated: true)

// After: AppKinetics (opens only in Dynamics apps)
// [BB_DYNAMICS-MIGRATION] Replaced UIDocumentInteractionController with
// AppKinetics for secure document sharing
let providers = GDiOS.sharedInstance().getServiceProviders(
    for: "com.good.gdservice.transfer-file",
    andVersion: "1.0.0.0",
    andServiceType: .application
)
// Present provider selection UI, then send via GDServiceClient
```

### Share Sheet Replacement

```swift
// Before: UIActivityViewController (shares with any app)
let activityVC = UIActivityViewController(activityItems: [data], applicationActivities: nil)

// After: AppKinetics
// [BB_DYNAMICS-MIGRATION] Replaced UIActivityViewController with AppKinetics
// for DLP-compliant sharing between Dynamics apps
```

---

## Common Issues

1. **Service not found** — ensure the target app is installed, activated,
   and registered with the same UEM server
2. **File path format** — attachment paths must be relative to the Dynamics
   secure container
3. **UIActivityViewController still present** — may leak data to
   non-Dynamics apps; replace with AppKinetics or restrict activities

### SDK 15.0 UEM share / receive posture

UEM may enable:

- **Open files unencrypted in other selected non-Dynamics apps** — policy
  may allow limited unencrypted open/transfer to allow-listed non-Dynamics
  apps. Do not broaden share sheets by default; keep protected outbound on
  Dynamics-controlled paths unless the customer explicitly requires the
  policy-backed unmanaged path (document the decision).
- **Do not require authentication when securely receiving a file from an
  authenticated Dynamics app** — receive UX may skip an unlock prompt when
  the sending Dynamics app is already authenticated. Do **not** invent an
  app-level auth bypass; keep receive on `GDService` / AppKinetics and the
  normal authorization model.

SDK 15.0 also restores the ability to share **text** (for example a URL)
from a Dynamics app via the native iOS share menu into BlackBerry Work as
email. Treat that as an optional product capability — it does not replace
AppKinetics for protected file transfer.
4. **Residual custom URL/universal-link payload path** — if protected payloads
   still move over unmanaged URL handoff, the path must be removed/blocked
