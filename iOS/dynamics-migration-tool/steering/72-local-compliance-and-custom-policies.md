# Steering: Local Compliance and Custom Policies (iOS)

## Local Compliance Actions

The app can programmatically block its own UI based on local security
conditions using `GDiOS.executeBlock` and `GDiOS.executeUnblock`:

```swift
// [BB_DYNAMICS-MIGRATION] Block app UI due to local compliance violation
GDiOS.sharedInstance().executeBlock(
    withMessage: "App blocked: untrusted network detected"
)

// Later, when compliance is restored:
GDiOS.sharedInstance().executeUnblock()
```

### Use Cases

- App detects a security condition not covered by UEM policy
- App needs to enforce custom business rules
- Temporary blocking while performing a critical security check

---

## Custom Policies (UEM Console)

Apps can define custom policies managed through the UEM console. The
UEM admin configures values, and the app reads them at runtime:

```swift
// [BB_DYNAMICS-MIGRATION] Reading application policy from UEM
let config = GDiOS.sharedInstance().getApplicationConfig()

// Access configuration values
if let servers = config[GDAppConfigKeyServers] as? [[String: Any]] {
    for server in servers {
        let host = server["server"] as? String
        let port = server["port"] as? Int
    }
}
```

### Policy Update Handling

Register for policy updates:

```swift
// Delegate pattern
func handle(_ anEvent: GDAppEvent) {
    case .policyUpdate:
        let policy = GDiOS.sharedInstance().getApplicationPolicy()
        applyPolicy(policy)
}

// Notification pattern
NotificationCenter.default.addObserver(
    self,
    selector: #selector(policyUpdated),
    name: NSNotification.Name(rawValue: GDPolicyUpdateNotification),
    object: nil
)
```

### Policy timing and cache rules

- Read policy only after authorization is complete.
- Do not keep sensitive policy state in unmanaged `UserDefaults` or local files.
- Re-evaluate DLP/export/ICC feature gates when policy update events arrive.
- Define explicit default/fallback behavior for missing policy keys.

---

## Threat Detection

The Dynamics SDK provides threat detection APIs for checking device and
application security:

- `GDThreatApplicationSecurity` — app integrity
- `GDThreatDeviceSecurity` — device security (jailbreak, debug)
- `GDThreatDeviceSoftware` — OS version compliance
- `GDThreatNetworkSecurity` — network security
- `GDThreatWiFiSecurity` — WiFi security

These are available through the `GDThreatStatus` framework.
