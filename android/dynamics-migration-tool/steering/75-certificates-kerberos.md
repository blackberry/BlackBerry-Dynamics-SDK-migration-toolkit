# Steering: Certificate Deployment and Kerberos

Dynamics apps can use client certificates for two-way SSL/TLS
authentication and Kerberos for service authentication. These are
configured primarily through UEM — minimal app code changes are needed.

---

## Certificate Deployment Methods

Certificates can be deployed to Dynamics apps through UEM using:

| Method | Description |
|--------|-------------|
| Personal Information Exchange (PKCS12) | `.p12` or `.pfx` files with CA, public key, and private key |
| CA certificate profile | Push CA certificates to devices |
| User credential profile | Push client certificates per user |
| SCEP profile | Automated certificate enrollment |
| Shared certificate profile | Same certificate to multiple devices |

### How It Works

1. UEM admin configures certificate deployment
2. After activation, the app receives certificates automatically
3. User is prompted for the PKCS12 password (if applicable)
4. The Dynamics Runtime handles SSL/TLS client authentication
   automatically — no additional app code needed

### Certificate Requirements

- PKCS12 format with `.p12` or `.pfx` extension
- Must be password-protected
- CA, public key, and private key in the same file
- If FIPS is enabled (SDK 15.0 = FIPS 140-3), must use FIPS-strength
  ciphers (re-encrypt with OpenSSL if needed). Prefer AES-128-CBC or
  AES-256-CBC — Triple-DES S/MIME encryption returns an error when FIPS
  is enabled:
  ```bash
  openssl pkcs12 -in weak.p12 -nodes -out decrypted.pem
  openssl pkcs12 -export -in decrypted.pem -keypbe AES-128-CBC -certpbe AES-128-CBC -out strong.p12
  rm decrypted.pem
  ```

### Certificate Selection (Multiple Certificates)

When multiple certificates are available, the SDK selects automatically:
1. Only certificates suitable for SSL/TLS client auth
2. Filtered by server-advertised CA (if specified in handshake)
3. Expired/not-yet-valid certificates excluded
4. Most recently issued certificate selected

### App-Based Certificate Import

For programmatic certificate import, use the
`com.good.gd.pki` package (Certificate Credential Import API).
See the `AppBasedCertImport` sample app.

---

## Kerberos

Dynamics supports two Kerberos implementations (mutually exclusive):

### Kerberos PKINIT

- Authentication directly between the app and Windows KDC
- Based on certificates from Microsoft AD Certificate Services
- No additional app code required
- Configured entirely in UEM

### Kerberos Constrained Delegation (KCD)

- Authentication via trust between UEM server and KDC
- UEM communicates with the service on behalf of the app
- No additional app code required
- Configured entirely in UEM

### OkHttp Kerberos Support

If using OkHttp with `BBCustomInterceptor`:
- Kerberos PKINIT and KCD are supported
- User-supplied credentials supported via `BBCustomAuthenticator`
- SPNEGO is NOT supported

---

## Migration Relevance

Certificate and Kerberos support is handled by the Dynamics Runtime
and UEM configuration. No app code changes are typically needed unless:
- The app does programmatic certificate import (`com.good.gd.pki`)
- The app needs to handle authentication challenges manually

For most migrations, inform the developer that certificate deployment
is a UEM admin task and the SDK handles it automatically.
