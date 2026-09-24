# Steering: Testing Against UEM (iOS)

After migration, the app must be tested against a real UEM server to
verify authorization, policy enforcement, and secure API functionality.

---

## Prerequisites

1. UEM server accessible from the test device/simulator
2. Entitlement created in UEM matching `GDApplicationID` and `GDApplicationVersion`
3. Native bundle identifier registered in UEM
4. Test user account with appropriate policies
5. Access key or QR code for activation

---

## Test Sequence

### 1. First-Time Activation

1. Install the app on a device (not simulator — activation requires server connectivity)
2. Launch the app
3. Enter email address and access key (or scan QR code)
4. Verify: SDK activation UI appears and completes
5. Verify: `GDAppEventAuthorized` / `GDState.isAuthorized` fires
6. Verify: App shows main UI after authorization

### 2. Container Lock / Unlock

1. Background the app and wait for idle timeout (configured in UEM policy)
2. Return to the app
3. Verify: SDK lock screen appears
4. Enter password or use biometric
5. Verify: App resumes to previous state

### 3. Policy Retrieval

1. Configure a custom policy in UEM for the app
2. Launch the app (or trigger policy update)
3. Verify: `GDAppEventPolicyUpdate` fires
4. Verify: `getApplicationPolicy()` returns expected values

### 4. Secure Storage

1. Store data using `GDFileManager` / `GDPersistentStoreCoordinator` /
   `GDSecureModelContainer` (SwiftData, SDK 15.1)
2. Lock and unlock the container
3. Verify: Data persists across lock/unlock cycles
4. Verify: Data is not accessible via standard `FileManager`
5. If SwiftData is in use: container is created after authorization (not
   via App/scene `.modelContainer(for:)`); `@Query` views render after unlock

### 5. Secure Networking

1. Access an enterprise resource through `GDURLLoadingSystem`
2. Verify: Request succeeds through Dynamics infrastructure
3. Verify: Direct access (without Dynamics) would fail (resource behind firewall)
4. Regress TLS 1.3 AES-GCM endpoints (SDK 15.1; AES-CCM is not supported)

### 5b. Screenshot / Siri DLP (SDK 15.1)

1. Enable UEM **Do not allow screenshots**
2. Verify: screenshots of the Dynamics app are blocked
3. Verify: Siri / Apple Intelligence cannot read on-screen or selected text
   from the Dynamics app (policy-driven; no extra API)

### 6. Remote Wipe

1. Initiate a remote wipe from the UEM console
2. Verify: `GDAppEventNotAuthorized` fires with wipe error code
3. Verify: All secure container data is deleted
4. Verify: App returns to activation state

---

## Simulator Testing

Some Dynamics features work on the iOS Simulator:
- Enterprise Simulation mode (no UEM needed)
- Secure storage APIs
- Core Data migration
- SwiftData (`GDSecureModelContainer`) persistence after unlock
- File system operations

Features that require a real device:
- UEM activation
- Push channel
- Biometric unlock
- Easy Activation

---

## Common Test Failures

| Symptom | Likely Cause |
|---------|-------------|
| Activation fails immediately | `GDApplicationID` doesn't match UEM entitlement |
| Activation hangs | Network connectivity to UEM server |
| Crash on launch | Missing Keychain Sharing or URL schemes |
| Crash after authorization | Secure API called before `onAuthorized` |
| Data not persisting | Using `FileManager` instead of `GDFileManager` |
| Network requests failing | `GDURLLoadingSystem` not enabled post-auth |
