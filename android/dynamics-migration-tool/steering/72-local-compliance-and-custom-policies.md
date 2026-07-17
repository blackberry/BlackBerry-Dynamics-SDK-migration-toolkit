# Steering: Local Compliance and Custom Policies

These features allow apps to enforce security rules locally and define
app-specific policies managed through UEM.

---

## Local Compliance: executeBlock / executeUnblock

The SDK provides APIs to temporarily block user access to the app UI
under certain conditions (e.g., untrusted Wi-Fi, jailbreak detection,
custom compliance checks).

### API

```java
// Block the app UI with a message
// [BB_DYNAMICS-MIGRATION] Block app access for compliance violation
GDAndroid.getInstance().executeBlock("Access blocked: untrusted network detected. "
    + "Please connect to a trusted network to continue.");

// Unblock when compliance is restored
// [BB_DYNAMICS-MIGRATION] Restore app access after compliance check
GDAndroid.getInstance().executeUnblock();
```

### Behavior

- While blocked, the app displays a message to the user explaining why
- Network activity and container storage access are NOT affected during
  a UI block — only the UI is locked
- The block can be circumvented if the user restores a backup created
  before the block. Account for this in your security model.

### Migration Relevance

Most apps do not need local compliance enforcement during initial
migration. Consider adding it if the original app had custom security
checks (network trust, device posture, etc.).

---

## Custom Policies (UEM App Policy Definition Files)

You can define app-specific policies that UEM administrators can configure
and push to devices. These are in addition to the standard Dynamics
policies.

### How It Works

1. Create an XML policy definition file following the BlackBerry
   Application Policies Definition schema
2. Upload it to UEM via the management console
3. The app reads policy values using `GDAndroid.getApplicationPolicy()`
4. Policy updates arrive via the `onUpdatePolicy()` callback

### Policy Definition File Example

```xml
<?xml version="1.0" encoding="utf-8"?>
<apd:AppPolicyDefinition xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:apd="urn:AppPolicySchema1.good.com"
    xsi:schemaLocation="urn:AppPolicySchema1.good.com AppPolicySchema.xsd">
    <pview>
        <pview type="tabbed">
            <title>App Settings</title>
            <desc>Configure app-specific settings</desc>
            <pe ref="maxItemsPerPage"/>
            <pe ref="enableOfflineMode"/>
        </pview>
    </pview>
    <setting name="maxItemsPerPage">
        <text>
            <key>maxItemsPerPage</key>
            <label>Maximum items per page</label>
            <value>25</value>
        </text>
    </setting>
    <setting name="enableOfflineMode">
        <checkbox>
            <key>enableOfflineMode</key>
            <label>Enable offline mode</label>
            <value>true</value>
        </checkbox>
    </setting>
</apd:AppPolicyDefinition>
```

### Reading Custom Policies in Code

```java
// In onUpdatePolicy() or after onAuthorized()
Map<String, Object> policy = GDAndroid.getInstance().getApplicationPolicy();
String maxItems = (String) policy.get("maxItemsPerPage");
Boolean offlineMode = (Boolean) policy.get("enableOfflineMode");
```

### DLP Watermark Policy

A common custom policy is the DLP watermark, which overlays the user's
username and current date/time on all app screens:

```xml
<setting name="blackberry.security.EnableDLPWatermark">
    <checkbox>
        <key>blackberry.security.EnableDLPWatermark</key>
        <label>Enable DLP Watermark</label>
        <value>false</value>
    </checkbox>
</setting>
```

The watermark does NOT apply to views outside interactive use
(notifications, widgets). Use DLP settings in the Dynamics profile for
additional protection.

### Key Prefix Restriction

The key prefix `"blackberry"` is reserved by BlackBerry. Do not use it
for your own custom policy keys unless using a BlackBerry-defined key
(like `blackberry.security.EnableDLPWatermark`).

---

## Migration Relevance

- **Local compliance**: Add only if the app has custom security checks
- **Custom policies**: Add if the app needs UEM-configurable settings
  beyond what standard Dynamics profiles provide
- **DLP watermark**: Add if the organization requires visual deterrence
  against data leakage via photos
- These are post-migration enhancements — focus on core migration first


## Enterprise Hardening Addendum (Policy key and parsing safety)

- Avoid reserved `blackberry.*` namespace for custom keys except documented BlackBerry keys.
- Treat policy values as untrusted input for parsing/SQL/url-building; avoid concatenation into executable queries or URLs.
