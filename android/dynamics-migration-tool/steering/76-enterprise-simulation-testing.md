# Steering: Enterprise Simulation Mode and Automated Testing

These features support development and testing of Dynamics apps without
requiring a full UEM environment.

> **Multi-module note**: `app/src/main/assets/...` references below are
> canonical-shape illustrations. Place
> `com.blackberry.dynamics.settings.json` at every entry in
> `${primary_assets_dirs}` from
> `dynamics-migration-tool/output/module-map.json`. Simulation flags
> must be identical across every flavor target — divergent flags are
> a release-readiness blocker.
> See `04-multi-module-projects.md`.

---

## Enterprise Simulation Mode

Simulation mode lets you test the app on an Android emulator without
connecting to a UEM server. Useful for early development and CI/CD.

### Enabling Simulation Mode

Add to `app/src/main/assets/com.blackberry.dynamics.settings.json`:

```json
{
  "GDEnterpriseSimulation": true
}
```

### Behavior in Simulation Mode

- A `[Simulated]` label appears in the Dynamics UI
- Any email address and activation key (PIN) is accepted
- Provisioning and policy setup are simulated
- Hard-coded profiles and policies are applied
- Authentication delegation is NOT supported

### What Works

- Secure Storage APIs (file I/O, SQLite)
- Secure Communication APIs (but cannot reach servers behind enterprise
  firewall via Dynamics proxy)
- Push Channel APIs
- Direct connections to servers on the same LAN/VPN

### What Does NOT Work

- Real UEM policy enforcement
- Inter-Container Communication (ICC) / Shared Services Framework
- Lost password recovery
- Background Authorize
- Connection through Dynamics proxy infrastructure

### Important Warnings

- Running a simulation-mode build on a real device will WIPE the app
- Switching to simulation mode on an already-installed app will WIPE it
- The BlackBerry Dynamics NOC must still be accessible during initial
  activation (even in simulation mode)

### Migration Use

Enable simulation mode during development to test the migration without
UEM. Remove or set to `false` before production deployment.

---

## Automated Testing (ATSL)

The BlackBerry Dynamics Automated Test Support Library provides helper
functions for testing activation, authorization, and UI interactions.

### Gradle Setup

```groovy
// [BB_DYNAMICS-MIGRATION] Automated testing support
androidTestImplementation 'com.blackberry.blackberrydynamics:atsl:$DYNAMICS_SDK_VERSION'
androidTestImplementation 'androidx.test:rules:1.5.0'
androidTestImplementation 'androidx.test:runner:1.5.2'
androidTestImplementation 'androidx.test.uiautomator:uiautomator:2.2.0'

android {
    defaultConfig {
        testInstrumentationRunner "androidx.test.runner.AndroidJUnitRunner"
    }
}
```

### Test Credentials File

Create `tests/assets/test_credentials.json`:

```json
{
  "GD_TEST_PROVISION_EMAIL": "user@example.com",
  "GD_TEST_PROVISION_ACCESS_KEY": "012345678901234",
  "GD_TEST_PROVISION_PASSWORD": "testpassword",
  "GD_TEST_UNLOCK_KEY": "012345678901234"
}
```

Notes:
- Access key and unlock key must be 15 characters, no dashes
- Automated testing works in Enterprise Simulation mode (with its
  limitations)

### Using ATSL Helpers

```java
// Activate the app
assertTrue("Failed to activate",
    BBDActivationHelper.loginOrActivateApp());

// Manual credential entry
BBDActivationUI activationScreen = new BBDActivationUI(
    uiAutomatorUtils.getAppPackageName());
activationScreen.enterUserLogin("user@example.com");
activationScreen.enterKey("12345", "12345", "12345");
activationScreen.clickOK();

// Check UI elements
uiAutomatorUtils.isTextShown("Expected text");
```

### Running Tests

```bash
# All tests
./gradlew connectedAppDebugAndroidTest

# Specific test class
./gradlew connectedAppTestDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.example.MyTest
```

### Compliance and Debugging

- If UEM compliance profile detects rooted OS, it may stop the app when
  a debugger is attached
- In UEM 12.11 MR1+, the admin can disable "Enable anti-debugging for
  BlackBerry Dynamics apps"
- Vanilla Android emulators are considered rooted — use Google Play
  system images (API 26+) or disable root detection in UEM for dev

---

## Migration Relevance

- **Simulation mode**: Useful during migration to test without UEM.
  Enable it early, remove before production.
- **ATSL**: Consider adding automated tests after the core migration is
  complete. Not required for the migration itself.
