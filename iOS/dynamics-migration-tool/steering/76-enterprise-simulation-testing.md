# Steering: Enterprise Simulation Testing (iOS)

Enterprise Simulation mode allows developers to test Dynamics-enabled apps
without a UEM server. This is useful for development and testing before
the UEM infrastructure is available.

---

## Enabling Enterprise Simulation

Enterprise Simulation is configured in the `Info.plist`:

```xml
<!-- [BB_DYNAMICS-MIGRATION] Enable Enterprise Simulation for development -->
<key>GDLibraryMode</key>
<string>GDEnterpriseSimulation</string>
```

**Important**: This must be changed to `GDEnterprise` for production builds.
Never ship with `GDEnterpriseSimulation`.

---

## What Enterprise Simulation Provides

- Bypasses UEM activation — the app authorizes immediately
- Secure container still encrypts data
- Secure APIs (`GDFileManager`, `GDPersistentStoreCoordinator`, etc.) work
- No server connectivity required
- DLP policy is not enforced (no UEM policy source)
- Push channel (`GDPushChannel`) is not available

---

## Testing Workflow

1. Set `GDLibraryMode` to `GDEnterpriseSimulation` during development
2. Build and run — the app skips activation and goes straight to authorized
3. Test all secure API usage (storage, networking, Core Data, etc.)
4. Before submitting for QA/production, change to `GDEnterprise` and test
   with a real UEM server

---

## Automated Testing

The BlackBerry Dynamics Automated Test Support Library (ATSL) provides
tools for automated testing:

```swift
// XCTest integration
import XCTest

class DynamicsTests: XCTestCase {
    func testSecureStorage() {
        // Test GDFileManager operations
        let fm = GDFileManager.default
        fm.createFile(atPath: "/test.txt", contents: "test".data(using: .utf8), attributes: nil)
        XCTAssertTrue(fm.fileExists(atPath: "/test.txt"))
    }
}
```

Run tests via:
```bash
xcodebuild test -workspace YourApp.xcworkspace -scheme YourApp \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```
