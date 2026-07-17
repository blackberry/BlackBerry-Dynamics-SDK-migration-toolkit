# Steering: Play Integrity Attestation

Play Integrity extends BlackBerry root/exploit detection and enhances
app security and integrity verification. It replaces the deprecated
SafetyNet attestation.

> **Multi-module note**: `app/build.gradle` references below are
> canonical-shape illustrations. The Play Integrity dependency lives
> in `${primary_build_file}` from
> `dynamics-migration-tool/output/module-map.json`.
> See `04-multi-module-projects.md`.

---

## When to Use

- Organization requires device integrity verification
- UEM admin wants to verify the app is the official signed version
- Required by security policy for production deployment

---

## Implementation

### 1. Add GDSafetyNet Library

Add to `app/build.gradle`:

```groovy
// [BB_DYNAMICS-MIGRATION] Play Integrity attestation support
implementation 'com.blackberry.blackberrydynamics:android_handheld_gd_safetynet:$DYNAMICS_SDK_VERSION'
```

If the app also uses Google Play Services:

```groovy
implementation 'com.google.android.gms:play-services-safetynet:<your-play-services-version>'
implementation 'com.google.android.play:integrity:<your-play-integrity-version>'
implementation('com.blackberry.blackberrydynamics:android_handheld_gd_safetynet:$DYNAMICS_SDK_VERSION') {
    transitive = false
}
```

### 2. Create Application Policy File

Create an XML policy definition file with the app's signing certificate
digest and package name:

```xml
<?xml version="1.0" encoding="utf-8"?>
<apd:AppPolicyDefinition xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:apd="urn:AppPolicySchema1.good.com"
    xsi:schemaLocation="urn:AppPolicySchema1.good.com AppPolicySchema.xsd">
    <pview>
        <pe ref="apkCertificateDigestSha256"/>
        <pe ref="apkPackageName"/>
    </pview>
    <setting name="apkCertificateDigestSha256">
        <hidden>
            <key>blackberry.appMetadata.android.apkCertificateDigestSha256</key>
            <value>YOUR_SHA256_DIGEST_HERE</value>
        </hidden>
    </setting>
    <setting name="apkPackageName">
        <hidden>
            <key>blackberry.appMetadata.android.apkPackageName</key>
            <value>com.example.yourapp</value>
        </hidden>
    </setting>
</apd:AppPolicyDefinition>
```

### 3. Get the SHA-256 Digest

From Google Play Console: Setup > App signing > SHA-256 fingerprint.

Or from your keystore:

```bash
keytool -list -v -keystore <KEYSTORE_NAME> -alias <KEY_NAME>
```

Look for the `SHA256:` line in the output.

### 4. Upload to UEM

Coordinate with the UEM admin to upload the policy file in the
management console (App configuration > Upload a template).

---

## Important Notes

- Play Integrity does NOT work on emulators — the app will fail to
  provision. Disable Play Integrity in UEM for emulator testing.
- After uploading a new policy file, it can take up to 24 hours to
  sync across all UEM instances.
- Google Play Console must have `MEETS_BASIC_INTEGRITY` and
  `MEETS_STRONG_INTEGRITY` enabled in the Device Integrity section.

---

## Migration Relevance

Play Integrity is a deployment/security feature, not a code migration
task. It requires coordination with the UEM admin and Google Play Console.
Consider adding it after the core migration is complete and the app is
ready for production deployment.

## Enterprise Hardening Addendum (Release gate)

Treat Play Integrity and anti-debug posture as default release-readiness checks unless a documented approved exception exists.
