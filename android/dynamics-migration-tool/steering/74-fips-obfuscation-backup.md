# Steering: FIPS Compliance, Obfuscation, and Backup

These are deployment and build considerations for production-ready
Dynamics apps.

---

## FIPS Compliance

Dynamics SDK 15.0 upgrades the FIPS provider to **FIPS 140-3** (replacing
140-2). Compliance is still enforced by the UEM admin via a BlackBerry
Dynamics profile. When enabled:

- MD4 and MD5 are prohibited (NTLM/NTLM2-protected resources are blocked)
- Ephemeral key exchanges with insufficient Diffie-Hellman key length
  fall back to static RSA cipher suites
- User certificates must use FIPS-compliant encryption
- Algorithms restricted under 140-2 remain restricted under 140-3
- Algorithms no longer supported for new use under 140-3 include (legacy
  exceptions may apply — see NIST CMVP): 3-key/2-key TDEA encryption,
  Skipjack encryption, SHA-1 for digital signatures, RSA signatures
  < 2048 bits, most DSA signatures, ECDSA curves < 224-bit (for example
  P-192)
- The SDK continues to support Triple-DES and PKCS12KDF for migration
  continuity, but apps should move to FIPS 140-3–approved algorithms
- If FIPS is enabled and an S/MIME API uses Triple-DES for message
  encryption, the SDK returns an error — use AES-128-CBC or AES-256-CBC
- X.509 Basic Constraints path-length is properly enforced

### Android-Specific

- FIPS linking happens automatically at build time — no special directives
- FIPS is NOT supported on x86 emulators. Disable FIPS in UEM for
  emulator testing.
- To verify FIPS is active, check for this log line at app launch:
  `IDeviceBase::initInstance: FIPS MODE REQUESTED`
- SDK 15.0 ships `libgdndk.so` (Dynamics JNI) and `libsbgse.so` (Certicom
  native). No extra app integration steps are required for these libraries.

### Migration Relevance

Most apps need no FIPS code changes. Inform the developer that:

1. Certificate imports must use FIPS-strength ciphers when FIPS is
   enabled (re-encrypt weak PKCS12 files with AES-128-CBC / AES-256-CBC
   using OpenSSL if needed).
2. Any app-owned S/MIME or PKCS#7 call sites that still use Triple-DES
   under a FIPS-enabled profile must migrate to AES-CBC.
3. Apps that call the Dynamics Crypto C PKCS#7 APIs must review OpenSSL
   3.x flag handling (see `steering/14-api-provenance-and-replacement-catalog.md`
   § SDK 15.0 crypto notes).

---

## ProGuard / R8 Obfuscation

Use ProGuard (or R8) for production builds. The Dynamics SDK typically
includes consumer ProGuard rules automatically.

### Recommended Rules

```proguard
# [BB_DYNAMICS-MIGRATION] Keep Dynamics SDK classes
-keep class com.good.gd.** { *; }

# Keep GDStateListener implementations
-keep class * implements com.good.gd.GDStateListener { *; }

# Suppress warnings for Dynamics SDK internal API usage
-dontwarn com.good.gd.**
```

The `-dontwarn com.good.gd.**` rule is important because the SDK uses
Platform APIs that may be above the app's target SDK level. The SDK
handles runtime checks internally.

### Testing After Obfuscation

1. Build a release APK with minification enabled
2. Test the full authorization flow
3. Test all Dynamics features (storage, networking, etc.)
4. Check logs for reflection errors or missing class exceptions

---

## Backup Compatibility

The default Android Auto Backup is partially compatible with Dynamics
but has limitations:

- Not all secure container data can be backed up via standard Android backup
- After a data restore, the user will need an unlock key
- The UEM admin controls backup policy via the Dynamics profile

### Options

1. **Modify Android Auto Backup** to be Dynamics-compatible (see the
   Android Auto Backup appendix in the API reference)
2. **Disable Auto Backup** and implement a custom backup strategy:
   ```xml
   <!-- [BB_DYNAMICS-MIGRATION] Disable auto backup — Dynamics manages secure backup -->
   <application android:allowBackup="false" ...>
   ```
3. **Use Dynamics backup support library**:
   ```groovy
   implementation 'com.blackberry.blackberrydynamics:android_handheld_backup_support:$DYNAMICS_SDK_VERSION'
   ```

### Migration Relevance

For most migrations, set `android:allowBackup="false"` in the manifest
(which is already recommended for manifest merger conflict resolution).
The Dynamics SDK manages its own secure container backup.

---

## Supported Launch Modes

Dynamics apps support these Android launch modes in AndroidManifest.xml:
- `android:launchMode="standard"`
- `android:launchMode="singleTop"`
- `android:launchMode="singleTask"`

`singleInstance` is NOT listed as supported. If the app uses it, test
thoroughly or consider changing to `singleTask`.
