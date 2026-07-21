# Steering: FIPS Compliance (iOS)

The BlackBerry Dynamics SDK includes FIPS-validated cryptographic modules.
On SDK 15.0+, crypto is provided via `GSEProvider.xcframework` (FIPS 140-3).
Pre-15.0 releases used `BlackBerryCerticom.xcframework` and
`BlackBerryCerticomSBGSE.xcframework` (FIPS 140-2).

---

## What This Means for Migration

- FIPS compliance is handled automatically by the SDK for Dynamics
  container crypto — most apps need no FIPS mode code changes
- The SDK uses its own cryptographic library for secure storage, TLS, etc.
- The app does NOT need to implement its own FIPS-compliant crypto for
  container data-at-rest

### FIPS 140-3 algorithm posture (SDK 15.0)

- Algorithms restricted under FIPS 140-2 remain restricted under 140-3
- Prefer **AES-128-CBC** or **AES-256-CBC** for S/MIME message encryption
  when FIPS is enabled in the Dynamics profile
- If FIPS is enabled and an S/MIME API uses **Triple-DES** for message
  encryption, the SDK returns an error
- The SDK continues to support Triple-DES and PKCS12KDF for migration
  compatibility, but apps should migrate off Triple-DES as soon as practical
- SecureStorage cipher for **new** activations is AES-GCM; existing
  activations remain on AES-CBC — no app API swap; note in the report if
  crypto posture matters to the customer

When Prompt 00 finds app-owned S/MIME / `GDPKCS7_*` call sites, record a
`manualTodo` to review FIPS cipher choice and OpenSSL 3.x flag rules
(see `14-api-provenance-and-replacement-catalog.md`).

---

## App-Level Crypto Removal

If the app uses its own cryptographic libraries for FIPS compliance:

1. **Remove app-level FIPS crypto** — the Dynamics container provides
   FIPS-validated encryption for all data at rest and in transit
2. **Keep business-logic crypto** — if the app encrypts data for purposes
   beyond local storage (e.g., generating signed tokens for a server),
   keep that crypto but consider whether the Dynamics SDK's
   `GDUtility` auth token APIs can replace it

---

## BitCode

BitCode is NOT supported by the Dynamics SDK. If the project has BitCode
enabled:

1. Set `Enable Bitcode = NO` in Build Settings
2. Or add to Podfile post_install:
   ```ruby
   config.build_settings['ENABLE_BITCODE'] = 'NO'
   ```

This is because the FIPS-validated crypto libraries are pre-compiled and
cannot be recompiled from BitCode representation.
