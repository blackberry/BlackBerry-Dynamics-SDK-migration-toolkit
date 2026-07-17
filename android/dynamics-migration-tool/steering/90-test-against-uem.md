# Steering: Testing Against UEM

Dynamics apps must be tested under UEM management for production
readiness. During development, enterprise simulation mode can be used
for basic testing without UEM.

> **Multi-module note**: `app/src/main/assets/...` references below are
> canonical-shape illustrations. Place
> `com.blackberry.dynamics.settings.json` at every entry in
> `${primary_assets_dirs}` from
> `dynamics-migration-tool/output/module-map.json`.
> See `04-multi-module-projects.md`.

---

## Testing Approaches

### 1. Enterprise Simulation Mode (Development)

For early development and CI/CD, use simulation mode to test without UEM.
See `76-enterprise-simulation-testing.md` for setup details.

Enable in `app/src/main/assets/com.blackberry.dynamics.settings.json`:
```json
{ "GDEnterpriseSimulation": true }
```

**Limitations**: No real policy enforcement, no ICC, no Background
Authorize, no Dynamics proxy connections.

### 2. UEM Test Environment (Pre-Production)

Coordinate with the UEM admin to get access to a dedicated test
environment. Do NOT test against production UEM.

### 3. Production UEM (Final Validation)

Final testing with production policies and infrastructure.

---

## UEM Entitlement Setup

Before the app can activate against UEM:

1. UEM admin creates an app entitlement with the GDApplicationID
2. UEM admin assigns the entitlement to test users
3. UEM admin generates access keys for test users
4. Developer enters email + access key in the app's activation screen

---

## Activation Flow Testing

### First Launch (Activation)

1. Install the app on a device or emulator
2. Launch the app — SDK presents activation UI
3. Enter email address and access key
4. SDK provisions the container (downloads policies, creates encrypted store)
5. SDK prompts for password creation
6. `onAuthorized()` fires — app should load its data

### Subsequent Launch (Unlock)

1. Launch the app — SDK presents unlock screen
2. Enter password (or use biometric if enabled)
3. `onAuthorized()` fires — app should load its data

### Idle Lock

1. Leave the app idle past the timeout configured in UEM policy
2. SDK overlays lock screen
3. Container stays decrypted in memory — background tasks continue
4. Re-authenticate to dismiss lock screen
5. `onAuthorized()` fires again

### Remote Lock (UEM Admin Action)

1. UEM admin remotely locks the container
2. Container becomes inaccessible
3. User must obtain Temporary Unlock Key from admin
4. After reactivation, `onAuthorized()` fires

### Remote Wipe (UEM Admin Action)

1. UEM admin wipes the container
2. `onWiped()` fires
3. All secure data is destroyed
4. App should handle this gracefully (show clean state)

---

## Policy Enforcement Testing

1. Configure test policies in UEM (DLP, network restrictions, etc.)
2. Verify `onUpdatePolicy()` fires when policy changes
3. Test blocked domains (should fail with Dynamics networking)
4. Test DLP settings (screenshot prevention, clipboard restrictions)
5. Test compliance rules (rooted device detection, etc.)

---

## Emulator Considerations

- Vanilla Android emulators are considered "rooted" by compliance checks
- Use Google Play system images (API 26+) to avoid rooted detection
- Or disable root detection in UEM compliance profile for development
- Play Integrity attestation does NOT work on emulators
- FIPS compliance is NOT supported on x86 emulators

---

## Debugging with Compliance Enabled

If the UEM compliance profile detects a debugger:
- UEM 12.11 MR1+: Admin can disable "Enable anti-debugging for
  BlackBerry Dynamics apps"
- Earlier UEM: Anti-debugging is always on when root detection is enabled
- Use a non-debug build to test with compliance enabled

---

## Diagnostics

### Enable Verbose Logging

In `settings.json`:
```json
{
  "GDConsoleLogger": ["GDFilterNone"]
}
```

### View Logs

```bash
adb logcat | grep GD
adb logcat | grep "GD.*ERROR"
```

### Connectivity Diagnostics

Use the `GDDiagnostic` class to test connectivity to application servers.
See the official BlackBerry Dynamics sample applications (for example the
AppKinetics samples) for usage patterns.

---

## Common Failure Modes

| Symptom | Likely Cause |
|---------|-------------|
| Stuck on activation screen | GDApplicationID mismatch, app not provisioned in UEM, network issues |
| "Not Authorized" error | Missing settings.json, wrong GDApplicationID |
| Crash after activation | Secure API called in onCreate() before onAuthorized() |
| Policy not updating | GDStateListener not implemented, UEM policy not published |
| Network requests fail | Domain blocked by UEM policy, not using Dynamics networking APIs |
| Build fails on emulator | Compliance profile detects rooted OS — use simulation mode or Google Play image |

---

## Test Checklist

- [ ] First activation with valid credentials
- [ ] Subsequent unlock with password
- [ ] Biometric unlock (if enabled in UEM)
- [ ] Idle lock and re-authentication
- [ ] Data persistence across app restarts
- [ ] Policy enforcement (DLP, network restrictions)
- [ ] Secure storage (files, databases)
- [ ] Secure networking
- [ ] Remote wipe handling
- [ ] Build with minification (ProGuard/R8)
- [ ] Test on physical device (not just emulator)
