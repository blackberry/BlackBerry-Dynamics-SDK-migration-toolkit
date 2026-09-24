# Steering: External Data Movement, DLP, and Pasteboard (iOS)

The Dynamics SDK enforces Data Leakage Prevention (DLP) policy and this
tranche extends closure to broader external data movement surfaces (share
sheet, document picker, Files, iCloud/CloudKit, Photos, AirDrop, drag/drop,
Quick Look, custom URL/universal-link payload paths, and pasteboard).

---

## How DLP Works on iOS

Unlike Android (which has `GDEditText`/`GDTextView` replacements), iOS
Dynamics DLP works at the system level through conditional method
swizzling:

1. The Dynamics SDK checks DLP policy at startup. If the
   `GDDataLeakageKey` plist setting or UEM policy enables DLP:
   - `GDUIPasteboardProxyLayer.setupProxy` swizzles `UIPasteboard`
     operations
   - `GDUITouchProxyLayer.setupProxy` intercepts touch events for DLP
     compliance (e.g., blocking force-touch on embedded links)
   - Drag-and-drop operations are intercepted
2. When DLP policy is active, the SDK restricts pasteboard access to
   only Dynamics-enabled apps
3. Standard `UITextField`, `UITextView`, and other text controls
   automatically respect the DLP policy — no widget replacement needed

This means **no UI widget migration is needed on iOS** (unlike Android's
`EditText` → `GDEditText` pattern).

### Reading DLP Policy Programmatically

To check the current DLP policy state in code:

```swift
// [BB_DYNAMICS-MIGRATION] Reading DLP policy to conditionally enable sharing
let config = GDiOS.sharedInstance().getApplicationConfig()
let preventOut = config[GDAppConfigKeyPreventDataLeakageOut] as? Bool ?? false
let preventIn = config[GDAppConfigKeyPreventDataLeakageIn] as? Bool ?? false
```

These keys are useful when the app needs to conditionally enable or
restrict sharing features based on the active DLP policy.

---

## GDNativePasteboardAccess

In some cases, the app needs to access the native pasteboard even when
DLP policy is active. `GDNativePasteboardAccess` provides a controlled
escape hatch via the verified public API
`performActionOnNativePasteboard:`, which takes a block/closure.

All native pasteboard operations must run inside this block:

**Swift:**

```swift
// [BB_DYNAMICS-MIGRATION] Native pasteboard access while DLP policy is active
var content: String?
GDNativePasteboardAccess.performAction(onNativePasteboard: {
    content = UIPasteboard.general.string
})
// use content after the block
```

**Objective-C:**

```objc
// [BB_DYNAMICS-MIGRATION] Native pasteboard access while DLP policy is active
__block NSString *content = nil;
[GDNativePasteboardAccess performActionOnNativePasteboard:^{
    content = [UIPasteboard generalPasteboard].string;
}];
// use content after the block
```

**Do not** use `open()` or `close()` methods on `GDNativePasteboardAccess` —
these method names do not exist in the public BlackBerry Dynamics SDK API.

### When to Use GDNativePasteboardAccess

- The app needs to paste content from non-Dynamics apps (e.g., pasting a
  URL from Safari)
- The app needs to copy content for use by non-Dynamics apps
- The UEM admin has approved this exception to DLP policy

### When NOT to Use

- For normal intra-app copy/paste — DLP handles this automatically
- For copy/paste between Dynamics apps — DLP allows this by policy
- As a blanket override — defeats the purpose of DLP

---

## Swift Interop Bridge Shim

If a reusable application-owned helper is needed (for example, when call
sites are in Objective-C files), write a thin wrapper that calls the
verified public API `performActionOnNativePasteboard:`:

```objc
// Application-owned bridge shim — calls public BlackBerry Dynamics SDK API
@interface AppPasteboardBridge : NSObject
+ (nullable NSString *)readStringFromNativePasteboard;
+ (void)writeString:(nullable NSString *)string toNativePasteboard:(void (^)(void))completion;
@end

@implementation AppPasteboardBridge
+ (nullable NSString *)readStringFromNativePasteboard {
    __block NSString *value = nil;
    [GDNativePasteboardAccess performActionOnNativePasteboard:^{
        value = [UIPasteboard generalPasteboard].string;
    }];
    return value;
}
+ (void)writeString:(nullable NSString *)string toNativePasteboard:(void (^)(void))completion {
    [GDNativePasteboardAccess performActionOnNativePasteboard:^{
        [UIPasteboard generalPasteboard].string = string;
    }];
    if (completion) completion();
}
@end
```

Then expose a thin Swift wrapper for app code. Prefer this shared shim over
per-file ad-hoc bridging.

---

## Programmatic Pasteboard Usage

If the app programmatically accesses `UIPasteboard`, audit each usage:

### Pattern 1: Reading from Pasteboard

```swift
// Before
let text = UIPasteboard.general.string

// After — if reading from non-Dynamics source is needed:
// [BB_DYNAMICS-MIGRATION] Native pasteboard access for external content
var text: String?
GDNativePasteboardAccess.performAction(onNativePasteboard: {
    text = UIPasteboard.general.string
})

// Or if DLP-restricted copy/paste is acceptable (most cases):
// No change needed — DLP policy handles restriction automatically
```

### Pattern 2: Writing to Pasteboard

```swift
// Before
UIPasteboard.general.string = sensitiveData

// After — DLP policy will prevent non-Dynamics apps from reading this
// No code change needed unless external access is required
```

---

## Directional External-Movement Rules

Classify each call site as:
- unmanaged-to-managed
- managed-to-unmanaged
- managed-to-managed
- metadata-only
- unknown-or-bidirectional

### Inbound unmanaged-to-managed

- Prefer approved picker/provider ingestion paths
- Copy inbound protected files into secure storage early
- Avoid long-lived unmanaged staging files

### Outbound managed-to-unmanaged

- Default protected export to blocked unless approved managed design exists
- Do not silently preserve sensitive `UIActivityViewController` export paths
- Do not stage decrypted plaintext in unmanaged temp files
- In-memory transfer alone is not policy approval

### Residual URL/share paths

Custom URL schemes and universal links that transfer protected payloads must be
removed, migrated to managed paths, or blocked with rationale/evidence.

### Pattern 3: Custom UIPasteConfiguration

```swift
// Before
view.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: ["public.text"])

// After — works the same; DLP policy applies at the system level
// No code change needed
```

---

## What NOT to Migrate

- **UITextField / UITextView** — no replacement needed (unlike Android).
  DLP is enforced at the pasteboard level, not the widget level.
- **UIMenuController** — copy/cut/paste actions work with DLP automatically
- **Drag and Drop** — DLP policy controls inter-app drag and drop

---

## Screen Capture Prevention

On iOS, the Dynamics SDK handles screen capture prevention through UEM
DLP policy. Unlike Android's `FLAG_SECURE`, there is no direct API the
app needs to call.

If the app has custom screen capture prevention:
- Remove `UIScreen.isCaptured` observers that trigger app-level responses
- Remove background blur overlays intended solely for screenshot prevention
- Document in the migration report that UEM DLP policy now controls this

SDK 15.1: when UEM **Do not allow screenshots** is enabled, Dynamics also
prevents Siri / Apple Intelligence from reading on-screen and selected
text in the Dynamics app. This is policy-driven — there is no extra
public API. Include it in UEM runtime tests with screenshot restriction.

---

## Audit Checklist

- [ ] All `UIPasteboard.general` reads audited for DLP compliance
- [ ] All `UIPasteboard.general` writes audited for DLP compliance
- [ ] `GDNativePasteboardAccess` used only where native access is required
- [ ] Custom pasteboard types reviewed
- [ ] Drag and drop operations reviewed for DLP
- [ ] Screen capture prevention code removed (if app-level)
- [ ] `UIActivityViewController` sharing reviewed (may need AppKinetics ICC)
