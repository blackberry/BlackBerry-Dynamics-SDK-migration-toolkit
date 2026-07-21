## Task: Add AppKinetics Inter-Container Communication

Goal: Replace standard iOS sharing mechanisms with AppKinetics for
secure inter-container communication between Dynamics-enabled apps.

**Prerequisites**:
- Prompts 00-03b must be complete
- The analysis (Prompt 00) identified sharing/ICC usage

**Skip this prompt if the app does not share data with other apps.**

---

## SDK Header Verification (Mandatory Before Changes)

Before writing any AppKinetics code, verify the `GDServices.h` header is
accessible and confirm the exact Swift-bridged signatures:

```bash
rg "sendTo:|GDServiceClientDelegate|GDServiceDelegate" \
  Pods/BlackBerryDynamics --include="*.h" -l 2>/dev/null | head -5
```

Specifically confirm:
- `sendTo:` return type and parameter list (especially `requestID:` out-pointer)
- Whether `sendTo:` is bridged as `throws` or BOOL+error in your SDK version
- `GDServiceDelegate` required callback name and argument count

If headers are not found, run `pod install` first.

---

## Steps

### 1. Identify and classify ICC/share surfaces

From the Prompt 00 analysis, locate:
- `UIActivityViewController` usage
- `UIDocumentInteractionController` usage
- Custom URL scheme handling (`application(_:open:options:)`)
- Universal Links handling
- `FileProvider` usage
- Any other inter-app data sharing

For every applicable `icc` call site, classify:
- role (`provider|consumer|both`)
- direction (`managed-to-managed`, `managed-to-unmanaged`, etc.)
- payload kind (`file|data|metadata`)
- whether flow is metadata-only or carries protected payloads
- residual native path status (removed/blocked/migrated)

### 2. Replace only verified enterprise-sensitive flows

**Decision gate** — do NOT globally replace `UIActivityViewController`.
Only replace where the shared data is enterprise-sensitive (credentials,
business documents, protected files). Standard share sheets for public
content (system clipboard, Photos, etc.) may remain native.

For applicable cases, use a verified provider/consumer contract. If no real
service contract exists, do **not** invent one; mark the call site as
`blocked` with rationale and required product/security decision.

```swift
// Before: generic share sheet — only replace if data is enterprise-sensitive
let activityVC = UIActivityViewController(activityItems: [data], applicationActivities: nil)
present(activityVC, animated: true)

// After (enterprise-sensitive data only):
// [BB_DYNAMICS-MIGRATION] Replaced UIActivityViewController with AppKinetics
// for DLP-compliant sharing between Dynamics apps
import BlackBerryDynamics.AppKinetics

let providers = GDiOS.sharedInstance().getServiceProviders(
    for: "com.good.gdservice.transfer-file",
    andVersion: "1.0.0.0",
    andServiceType: .application
)
// REQUIRED: present a deterministic provider selection UI to the user.
// Do NOT auto-select the first provider — this is weak UX and a security
// concern (user must confirm where enterprise data is being sent).
// Implement a list/action sheet showing provider names, then send via
// GDServiceClient (step 3) with the user-selected providerAddress.
```

### 3. Implement GDServiceClient (Sending)

**Before editing, verify the exact Swift-bridged signature by inspecting the
installed header** at `<BlackBerryDynamics/GD/GDServices.h>` (or
`Pods/BlackBerryDynamics/Frameworks/BlackBerryDynamics.xcframework/.../GDServices.h`).

The canonical ObjC signature (Swift-bridged):

```objc
// GDServices.h
+ (BOOL)sendTo:(NSString*)application
   withService:(NSString*)service
   withVersion:(NSString*)version
    withMethod:(NSString*)method
    withParams:(nullable id)params
withAttachments:(nullable NSArray<NSString *>*)attachments
bringServiceToFront:(GDTForegroundOption)option
     requestID:(NSString * _Nullable * _Nullable)requestID
         error:(NSError**)error;
```

Swift usage — use BOOL return + NSError pattern, NOT `try`:

```swift
// [BB_DYNAMICS-MIGRATION] AppKinetics file transfer
// import the correct submodule — NOT bare 'import BlackBerryDynamics'
import BlackBerryDynamics.AppKinetics

var requestID: NSString? = nil
var sendError: NSError? = nil
let sent = GDServiceClient.send(
    to: providerAddress,
    withService: "com.good.gdservice.transfer-file",
    withVersion: "1.0.0.0",
    withMethod: "transferFile",
    withParams: nil,
    withAttachments: [secureFilePath],
    bringServiceToFront: .GDEPreferPeerInForeground,
    requestID: &requestID,
    error: &sendError
)
if !sent {
    print("AppKinetics send failed: \(sendError?.localizedDescription ?? "unknown")")
}
```

**Note on GDTForegroundOption enum**: use the exact constant names from the
header: `.GDEPreferMeInForeground`, `.GDEPreferPeerInForeground`, or
`.GDENoForegroundPreference`. Do not abbreviate.

### 4. Implement GDServiceDelegate (Receiving, if applicable)

If the app receives files from other Dynamics apps, implement
`GDServiceDelegate` **and** register the service in Info.plist under the
`GDServices` key. Without this registration the app is invisible to
`getServiceProviders` callers:

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

Replace `com.good.gdservice.transfer-file` and `1.0.0.0` with the actual
service identifier and version agreed with the sending app. If the app
defines a custom service, use a reverse-DNS identifier that is unique to
your organisation.

**Canonical callback signature includes `forRequestID` — do not omit it:**

```swift
// [BB_DYNAMICS-MIGRATION] AppKinetics service provider receiving files
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

### 5. Build and Verify

Run `xcodebuild` to verify compilation. Classify any failures as
pre-existing (per developer clean-build attestation/history), step-introduced, or unrelated.

### 6. Close residual URL/share payload paths

After migration, residual payload transfer over:
- `UIActivityViewController`
- `UIDocumentInteractionController`
- custom URL schemes
- universal links carrying protected payloads

must be removed, migrated to AppKinetics, or explicitly blocked with evidence.
Metadata-only navigation can remain with proof.

---

## Closure Ledger Update (Required)

Before recording Prompt 08 as `completed`, write call-site dispositions for
the `icc` domain using the atomic updater:

```bash
python3 dynamics-migration-tool/tooling/update-migration-plan-state.py \
  --analysis dynamics-migration-tool/output/migration-analysis.json \
  --plan dynamics-migration-tool/output/migration-plan-state.json \
  --run-id "<run-id-from-output/bootstrap.json>" \
  --prompt-id "08" \
  --domain-id "icc" \
  --updates-file /tmp/icc-updates.json
```

Do not edit `output/migration-plan-state.json` directly.
Missing dispositions block recorder completion.

---

## Scoped Validation (Required)

Run prompt-scoped validation before recorder completion:

```bash
bash ./dynamics-migration-tool/tooling/validate.sh --check-prompt 08
```

---

## Output

- Applicable ICC/share paths migrated to verified AppKinetics contracts
- GDServiceClient configured for sending
- GDServiceDelegate configured for receiving (if applicable)
- Service registrations in Info.plist verified (if applicable)
- Residual unmanaged URL/share payload paths closed
- Build verification result

See `60-appkinetics-icc.md` for the full steering reference.
