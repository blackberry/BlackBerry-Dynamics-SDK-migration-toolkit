# Steering: Redundant Feature Removal (iOS)

When an app is migrated to BlackBerry Dynamics, several features that the
app previously implemented itself become redundant because the Dynamics
SDK provides them at the container level. These features must be identified
during analysis (Prompt 00) and removed during migration.

Leaving redundant features in place causes problems:
- **Conflicts**: Two lock screens, two encryption layers
- **User confusion**: Double password prompts, inconsistent behavior
- **Maintenance burden**: Dead code that still compiles but never executes
- **Security gaps**: App-level features may bypass Dynamics policy enforcement

## Guard Instead of Delete (Default Policy)

When a feature is unsupported in a managed-Dynamics flow but still valuable in
an unmanaged/non-Dynamics variant, prefer **graceful guards** over deletion.

- Replace hard crashes (`fatalError`, forced unwrap on unavailable containers)
  with availability checks (`isAvailable`, early return, disabled UI state).
- Keep feature codepaths present but no-op/disable when secure prerequisites are
  unavailable.
- Delete functionality only when explicitly requested by the developer.

This avoids unnecessary product regressions while still enforcing secure
container rules.

---

## Category 1: App-Level Biometric / Lock Screen

### Why It's Redundant

The Dynamics SDK provides its own lock screen with password and biometric
support (Touch ID, Face ID), controlled by UEM policy. The UEM admin
configures password complexity, biometric unlock, idle timeout, and
maximum authentication attempts.

Any app-level lock screen runs on top of the Dynamics lock, creating a
double-authentication experience.

### What to Look For

During Prompt 00 analysis, flag:
- `import LocalAuthentication` and `LAContext` usage
- `LAContext().evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, ...)`
- `LAContext().evaluatePolicy(.deviceOwnerAuthentication, ...)` for passcode fallback
- Custom lock screen ViewControllers (PIN entry, pattern lock)
- `UIApplication.shared.isProtectedDataAvailable` checks for custom data protection
- `UserDefaults`/Keychain keys like `biometric_enabled`, `app_lock`, `lock_timeout`
- Settings UI that lets users enable/disable biometric lock
- Keychain items with `kSecAttrAccessControl` biometric access control for
  encryption keys (not for business-logic biometric confirmation)

### How to Remove

1. **Remove LocalAuthentication usage** for lock purposes — delete
   `LAContext` calls that guard app access

2. **Remove lock screen ViewControllers** — delete the ViewController
   class, its storyboard scene, and any segue leading to it

3. **Remove lock-related settings** — remove the UI toggle and the
   preference storage for app-level lock settings

4. **Remove biometric-bound Keychain keys** — if the app used biometric
   auth to unlock a local encryption key, remove this mechanism (Dynamics
   container encryption replaces it)

5. **Keep biometric if used for non-lock purposes** — if the app uses
   biometric for a specific business action (e.g., confirming a financial
   transaction), that is NOT redundant and should be kept

### Migration Comment

```swift
// [BB_DYNAMICS-MIGRATION] Removed app-level biometric lock — Dynamics SDK
// provides container lock/unlock with biometric support via UEM policy
```

---

## Category 2: App-Level Data-at-Rest Encryption

### Why It's Redundant

The Dynamics SDK encrypts all data in the secure container. Any app-level
encryption layer wrapping file or database I/O is redundant — double
encryption with no security benefit, added complexity, and potential
conflicts with the container lifecycle.

### What to Look For

During Prompt 00 analysis, flag:
- `CryptoKit` usage for file/data encryption (`AES.GCM`, `ChaChaPoly`,
  `SymmetricKey` used for data-at-rest, NOT for TLS or server authentication)
- `CommonCrypto` / `CCCrypt` for AES encryption of files or database content
- `SecKeyCreateEncryptedData` / `SecKeyCreateDecryptedData` for data-at-rest
- Keychain items storing encryption keys for local data protection
  (`kSecAttrKeyClass: kSecAttrKeyClassSymmetric`)
- Custom `EncryptionManager`, `CryptoHelper`, `DataEncryptor` classes
- `RNCryptor` or similar third-party encryption libraries
- `Data.write(to:options:.completeFileProtection)` with custom key management
- `SQLCipher` for database encryption (if using raw SQLite)

### How to Remove

1. **Remove encryption/decryption wrappers** — delete custom encryption
   classes and their Keychain key management

2. **Remove SQLCipher** (if present):
   - Remove `GRDB-SQLCipher` or `SQLCipher` pod from Podfile
   - Remove passphrase-based database open calls
   - Migrate to `sqlite3enc` (Dynamics encrypted SQLite)

3. **Remove CryptoKit/CommonCrypto** for data-at-rest — keep only usage
   related to TLS, server communication signing, or business-logic crypto

4. **Do not copy leftover encrypted data** — a Dynamics conversion is
   always a fresh install (`18-fresh-dynamics-install.md`). Remove
   SQLCipher / leftover data-at-rest crypto and write to the Dynamics
   container. Do **not** invent an export/import helper.

### Migration Comment

```swift
// [BB_DYNAMICS-MIGRATION] Removed app-level encryption — Dynamics container
// provides data-at-rest encryption for all secure storage
```

---

## Category 3: App-Level Screenshot / Screen-Recording Prevention

### Why It's Redundant

On iOS, the Dynamics SDK enforces screen capture prevention via UEM DLP
policy. Unlike Android (which uses `FLAG_SECURE`), iOS apps have limited
ability to prevent screenshots natively. The Dynamics SDK handles this
through its own mechanisms controlled by UEM policy.

### What to Look For

During Prompt 00 analysis, flag:
- `UIScreen.isCaptured` observation for screen recording detection
- `NotificationCenter` observers for `UIScreen.capturedDidChangeNotification`
- Custom screen-hiding overlays when app enters background
  (`applicationWillResignActive` → show blur/overlay)
- `UITextField.isSecureTextEntry` used beyond password fields as a
  screenshot prevention hack

### How to Remove

1. **Remove screen capture detection** that triggers app-level responses
   (blanking screen, showing warnings) — DLP policy handles this

2. **Keep background blur overlays** only if they serve a UX purpose
   beyond screenshot prevention (e.g., privacy in app switcher)

3. **Keep `isSecureTextEntry`** on actual password fields — this is
   standard iOS behavior, not a screenshot prevention measure

### Migration Comment

```swift
// [BB_DYNAMICS-MIGRATION] Removed app-level screen capture prevention —
// Dynamics DLP policy controls this via UEM
```

---

## Category 4: App-Level Data Protection / Backup

### Why It's Redundant

The Dynamics SDK manages its own secure container. iOS Data Protection
(`NSFileProtectionComplete`, etc.) is separate from Dynamics container
encryption. App-level backup mechanisms for data protection purposes
are redundant.

### What to Look For

- Custom backup implementations writing encrypted data to iCloud/local
- `NSFileProtection` attributes set explicitly for security (the Dynamics
  container handles this)
- `excludeFromBackup` flags set for security that may conflict with
  Dynamics container backup behavior

### What to Keep

- **User-facing export** (e.g., "Export as PDF") — these are user features.
  Route through Dynamics secure file APIs or AppKinetics ICC.
- **Server sync** — this is a feature, not a backup. Route through
  Dynamics secure networking.

### Migration Comment

```swift
// [BB_DYNAMICS-MIGRATION] Removed app-level data protection backup —
// Dynamics container manages encrypted backup via UEM policy
```

---

## When to Remove

The ideal sequence is:

1. **Prompt 00 (analysis)** — flag all redundant features in the inventory
2. **Prompt 01 (Xcode integration)** — remove redundant dependencies from Podfile
3. **Prompt 03 (auth)** — remove app-level lock screen, add Dynamics auth
4. **Prompt 04/04b (SQL/Core Data)** — remove SQLCipher, add Dynamics secure storage
5. **Prompt 05 (filesystem)** — remove app-level encryption wrappers

Each prompt should check for these redundancies in its domain and remove
them as part of the migration.

---

## Key Principle

**Dynamics replaces app-level security with container-level security.**
The app no longer needs its own lock screen, encryption, or backup.
These are managed by the Dynamics SDK and controlled by UEM policy. The
app's job is to defer all secure API access until authorization completes
and let the SDK handle the rest.
