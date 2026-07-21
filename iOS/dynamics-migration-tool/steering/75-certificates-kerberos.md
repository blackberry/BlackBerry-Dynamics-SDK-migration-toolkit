# Steering: Certificates and Kerberos (iOS)

## Client Certificates

The Dynamics SDK supports client certificate authentication through the
`GDPKI` module.

### Certificate Import

Apps can import PKCS12 certificates:

```swift
import BlackBerryDynamics

// [BB_DYNAMICS-MIGRATION] Import client certificate
let pkcs12Data: Data = ... // PKCS12 data
let password = "certificate-password"

// The SDK manages certificate storage in the secure container
```

### FIPS 140-3 certificate / S/MIME posture (SDK 15.0)

If FIPS is enabled in the Dynamics profile:

- Prefer AES-128-CBC or AES-256-CBC for PKCS12 / S/MIME encryption
- Triple-DES S/MIME message encryption returns an error under FIPS
- See `74-fips-compliance.md` and the SDK 15.0 crypto notes in
  `14-api-provenance-and-replacement-catalog.md`

### Certificate Notifications

Register for certificate change notifications:

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(certificateChanged),
    name: NSNotification.Name(GDPKINotificationCertificateAdded),
    object: nil
)
```

### GDCredentialManagerUI

For user-facing certificate management:

```swift
let credentialManager = GDCredentialManagerUI()
// Present certificate management UI
```

---

## Kerberos Authentication

The Dynamics SDK supports Kerberos authentication for enterprise SSO:

- `GDNegotiateScheme` — Negotiate authentication scheme
- `GDKerberosAuthHandler` — Kerberos authentication handler

Kerberos is typically configured through UEM policy. The app receives
Kerberos tokens automatically when accessing Kerberos-protected resources
through `GDURLLoadingSystem`.

---

## SCEP (Simple Certificate Enrollment Protocol)

SCEP certificate enrollment is configured in the UEM console:
- The admin creates a SCEP certificate profile
- The profile is assigned to the app
- The SDK handles enrollment automatically

No app-level code is needed for SCEP.

---

## Migration Notes

If the app implements its own certificate management:
1. Evaluate whether Dynamics certificate management can replace it
2. Remove custom certificate pinning that conflicts with Dynamics
   infrastructure certificates
3. Keep certificate handling for business-logic purposes (e.g., signing
   documents) — but use `GDPKI` for storage
