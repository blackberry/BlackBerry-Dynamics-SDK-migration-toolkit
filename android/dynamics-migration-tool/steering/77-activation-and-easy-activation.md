# Steering: Activation, Easy Activation, and Programmatic Activation

This file covers the different activation methods available in the
Dynamics SDK.

---

## Standard Activation (Default)

After installation, the user activates the app by entering:
- Email address
- Access key (or QR code) provided by the UEM admin or obtained from
  UEM Self-Service

The SDK handles the entire activation UI and flow. The app has no
control over this process — it simply waits for `onAuthorized()`.

### What Happens During Activation

1. SDK presents its activation UI
2. User enters credentials
3. SDK provisions the container (downloads policies, creates encrypted store)
4. SDK registers the app with the management server
5. `onAuthorized()` fires — app can now access secure APIs

---

## Easy Activation

Simplifies activating multiple Dynamics apps on the same device. The
user only activates the first app; subsequent apps delegate activation
to the already-activated app.

### How It Works

- Enabled by default in the Dynamics Runtime
- Any Dynamics app can be an activation delegate
- Priority is given to the app configured as the authentication delegate
- The UEM admin must specify the app's package ID in the Dynamics app
  settings in UEM

### Manual Intervention

No code changes needed. Easy Activation works automatically. The UEM
admin must configure the package ID in the management console.

---

## Programmatic Activation

Allows activation without user interaction — no activation prompts or
progress screens. Useful for:
- Consumer-facing apps
- Kiosk/IoT devices with limited input
- Automated deployment scenarios

### Implementation

```java
// [BB_DYNAMICS-MIGRATION] Programmatic activation — no user interaction
GDAndroid.getInstance().programmaticActivityInit(
    email,
    accessKey,
    false  // ShowUserInterface = false
);
```

### Requirements

1. Your application server must use BlackBerry Web Services REST APIs to:
   - Create or look up a UEM user account
   - Generate an access key
2. Pass credentials to the app
3. Call `programmaticActivityInit()` with `ShowUserInterface = false`
4. Track activation progress via broadcast:
   `GD_STATE_ACTIVATION_ACTION` (NotActivated → InProgress → Activated)
5. Wait for `GD_STATE_AUTHORIZED_ACTION` before accessing secure APIs

### Password Behavior

- The UEM admin can configure whether users must set a password after
  programmatic activation (via BlackBerry Dynamics profile)
- Use `configureUI` to customize the password screen appearance

### Checking Autonomous Authorization

The public SDK exposes a single overload:
`boolean canAuthorizeAutonomously(Context context)` on
[`GDAndroid`](https://developer.blackberry.com/files/blackberry-dynamics/android/classcom_1_1good_1_1gd_1_1_g_d_android.html).
There is **no** no-argument form — pass the current `Activity` or
`Service` instance (`this`).

```java
// Example from an Activity or Service onCreate — context is required
boolean canAutoAuth = GDAndroid.getInstance().canAuthorizeAutonomously(this);
```

This returns `true` when policy and container state permit authorization
without user interaction (for example when the UEM profile has "Do not
require a password" enabled). Background entry points that call
`serviceInit(this)` must call `canAuthorizeAutonomously(this)` first;
see `70-background-authorize.md`.

---

## Authentication Delegation

The UEM admin can configure up to three Dynamics apps as authentication
delegates (primary, secondary, tertiary). When a user opens any Dynamics
app, the delegate app's login screen appears. After successful login,
all Dynamics apps are unlocked.

### Manual Intervention

No code changes needed. The UEM admin configures delegation in the
Dynamics profile. If you want your app to be eligible as a delegate,
provide the package ID to the UEM admin.

---

## Bypass Unlock

A UEM setting that allows an app to completely bypass the password login
screen. Configured per-app in UEM Client settings.

See the `Bypass Unlock` sample app and the Bypass Unlock Developer Guide
for implementation details.

---

## Migration Relevance

- **Standard activation**: Works automatically after migration. No code
  changes needed beyond the normal `activityInit()` setup.
- **Easy Activation**: Works automatically. UEM admin must configure
  the package ID.
- **Programmatic activation**: Only needed if the app targets scenarios
  without user interaction. Not typical for migration.
- **Authentication delegation**: UEM admin configuration only.
- **Bypass Unlock**: Specialized use case. Not typical for migration.

## Enterprise Hardening Addendum (Programmatic activation secrets)

Programmatic activation credentials (email/access key) are secrets in transit. Deliver them only over authenticated, encrypted channels with short-lived token issuance and server-side audit logging.
