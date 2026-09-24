# Steering: Redundant Feature Removal

When an app is migrated to BlackBerry Dynamics, several features that the
app previously implemented itself become redundant because the Dynamics
SDK provides them at the container level. These features must be identified
during analysis (Prompt 00) and removed during or after Gradle integration
(Prompt 01).

> **Multi-module note**: every `rg ... app/src/main/...` example below
> is canonical-shape. Operationally, scan `${in_scope_main_src}` from
> `dynamics-migration-tool/output/module-map.json` (primary +
> `libraryModulesInScope[]`). Redundant features (SQLCipher, biometric
> locks, app-side backup) frequently live in feature/library modules.
> See `04-multi-module-projects.md`.

Leaving redundant features in place causes problems:
- **Conflicts**: Two lock screens, two encryption layers, two backup systems
- **User confusion**: Double password prompts, inconsistent behavior
- **Maintenance burden**: Dead code that still compiles but never executes
- **Security gaps**: App-level features may bypass Dynamics policy enforcement

---

## Category 1: App-Level Biometric / Lock Screen

### Why It's Redundant

The Dynamics SDK provides its own lock screen with password and biometric
support, controlled by UEM policy. The UEM admin configures:
- Password complexity requirements
- Biometric unlock (fingerprint, face)
- Idle timeout before lock
- Maximum authentication attempts

The app has no control over this — the SDK handles it automatically. Any
app-level lock screen (biometric prompt, PIN entry, pattern lock) runs
on top of or alongside the Dynamics lock, creating a double-authentication
experience that confuses users and adds no security value.

### What to Look For

During Prompt 00 analysis, flag:
- `androidx.biometric.BiometricPrompt` usage
- `BiometricManager` / `FingerprintManager` usage
- Custom lock screen Activities (PIN entry, pattern lock)
- `KeyguardManager` usage for device credential confirmation
- SharedPreferences or DataStore keys like `biometric_enabled`,
  `app_lock`, `lock_timeout`, `security_level`
- Settings UI that lets users enable/disable biometric lock
- `KeyStore` usage for biometric-bound encryption keys

### How to Remove

1. **Remove biometric/lock dependencies** from `build.gradle`:
   ```groovy
   // REMOVE — Dynamics SDK handles lock/unlock
   // implementation "androidx.biometric:biometric:x.x.x"
   ```

2. **Remove lock screen Activities** — delete the Activity class and its
   layout, remove from AndroidManifest.xml

3. **Remove lock-related settings** — remove the UI toggle and the
   preference storage for app-level lock settings

4. **Remove biometric-bound KeyStore keys** — if the app used biometric
   authentication to unlock a local encryption key, this entire mechanism
   is replaced by the Dynamics container encryption

5. **Remove lock check logic** — any `if (isAppLocked)` guards in
   Activity `onResume()` or Application class that redirect to a lock
   screen

6. **Keep biometric if used for non-lock purposes** — if the app uses
   biometric authentication for a specific business action (e.g.,
   confirming a financial transaction), that is NOT redundant with
   Dynamics and should be kept

### Migration Comment

```kotlin
// [BB_DYNAMICS-MIGRATION] Removed app-level biometric lock — Dynamics SDK
// provides container lock/unlock with biometric support via UEM policy
```

---

## Category 2: App-Level Backup / Export for Data Protection

### Why It's Redundant

The Dynamics SDK manages its own secure container backup. The UEM admin
controls backup policy. Android Auto Backup is typically disabled
(`android:allowBackup="false"`) because:
- Standard Android backup cannot access the encrypted container
- Restoring a backup requires a UEM unlock key
- The Dynamics backup support library handles container-aware backup

App-level backup mechanisms that exist purely for data protection (not
user-facing export) become redundant.

When a backup or export feature moves protected bytes outside the Dynamics
container, treat it as an **egress-capability decision** per
`13-unsupported-feature-detection-matrix.md`, not as a routine storage
migration. The migration kit must not preserve unmanaged backup/export flows
just because they existed pre-migration.

### What to Look For

During Prompt 00 analysis, flag:
- Custom backup Services or BroadcastReceivers
- `BackupAgent` / `BackupAgentHelper` implementations
- Auto-backup XML rules (`res/xml/backup_rules.xml`)
- App-level "backup to file" features that encrypt and save the database
  for data protection purposes (not user-facing export)
- Scheduled backup WorkManager tasks

### What to Keep

- **Enterprise sync to an approved service** — if the app syncs to an
  enterprise-controlled endpoint through Dynamics-secure networking, that is
  a business integration, not a local backup feature. It may remain only
  after destination-specific review.
- **Inbound import into the container** — importing a file into secure
  storage is not a backup feature, but it still crosses the container
  boundary and should be surfaced as `MANUAL_INTERVENTION_REQUIRED`, not
  auto-preserved.

Do **not** keep any of the following as a default migration outcome:

- Exporting a backup/archive/database to Downloads, Documents, SD card, USB,
  or mounted storage
- Restoring from a backup that lives outside the container
- Generic chooser/email/share based backup distribution
- Consumer cloud backup/export

### How to Remove

1. **Set `android:allowBackup="false"`** in AndroidManifest.xml (also
   resolves manifest merger conflicts with the SDK)

2. **Remove BackupAgent** implementations if they exist solely for
   data protection

3. **Remove backup-related WorkManager tasks** if they exist solely for
   local data protection

4. **Remove backup/restore UI and helpers** — buttons, menu actions,
   settings toggles, temporary archive creation, export workers, and file
   chooser helpers that exist only to move protected app data outside the
   container

5. **Remove now-unused permissions, providers, and intent filters** —
   especially any backup/export `FileProvider`, URI-grant paths, storage
   permissions, or exported components retained solely for the removed flow

6. **Add Dynamics backup support library** when the product still needs the
   container-managed backup path:
   ```groovy
   implementation "com.blackberry.blackberrydynamics:android_handheld_backup_support:$dynamics_version"
   ```

### Migration Comment

```kotlin
// [BB_DYNAMICS-MIGRATION] Removed app-level backup — Dynamics container
// manages encrypted backup via UEM policy
```

---

## Category 3: App-Level Database Encryption (SQLCipher)

### Why It's Redundant

The Dynamics SDK provides encrypted SQLite via `com.good.gd.database.sqlite.*`.
All data inside the Dynamics container is encrypted at rest. If the app
previously used SQLCipher (or another encryption library) to encrypt its
database, this encryption layer is now redundant — the Dynamics container
already encrypts everything.

Running both SQLCipher and Dynamics encryption is:
- **Redundant**: Double encryption with no security benefit
- **Complex**: Two key management systems, two initialization paths
- **Fragile**: SQLCipher passphrase management conflicts with container
  lifecycle (the passphrase may not be available before `onAuthorized()`)

### What to Look For

During Prompt 00 analysis, flag:
- `net.zetetic:sqlcipher-android` dependency in `build.gradle`
- `net.sqlcipher.*` imports in source code
- `SQLiteDatabase.loadLibs(context)` calls
- `getWritableDatabase(passphrase)` calls (passphrase-based open)
- `SupportFactory` from SQLCipher used as Room's `openHelperFactory`
- Passphrase storage in SharedPreferences, KeyStore, or hardcoded
- Any `usingSQLCipher` or `encryptionEnabled` flags

### How to Remove

1. **Remove SQLCipher dependency** from `build.gradle`:
   ```groovy
   // REMOVE — Dynamics provides encrypted SQLite
   // implementation "net.zetetic:sqlcipher-android:x.x.x"
   ```

2. **Remove SQLCipher initialization** — delete `SQLiteDatabase.loadLibs()`
   calls and passphrase management code

3. **Remove passphrase-based database open** — replace
   `getWritableDatabase(passphrase)` with standard
   `getWritableDatabase()` (which Dynamics then encrypts)

4. **Remove SQLCipher SupportFactory** — replace with
   `GDSupportSQLiteOpenHelperFactory()` for Room databases

5. **Remove passphrase storage** — delete KeyStore entries,
   SharedPreferences keys, or any other passphrase management

6. **Remove encryption toggle UI** — if the app has a setting to
   enable/disable database encryption, remove it (Dynamics always
   encrypts)

7. **Do not copy leftover SQLCipher data** — a Dynamics conversion is
   always a fresh install (`18-fresh-dynamics-install.md`). Remove
   SQLCipher and open Dynamics SQLite. Do **not** invent an export/import
   helper for a previous installation's database.

### Migration Comment

```kotlin
// [BB_DYNAMICS-MIGRATION] Removed SQLCipher — Dynamics container provides
// encrypted SQLite via com.good.gd.database.sqlite
```

---

## Category 4: App-Level Screenshot / Screen-Recording Prevention (FLAG_SECURE)

### Why It's Redundant

The Dynamics SDK enforces screenshot and screen-recording prevention via
UEM DLP (Data Loss Prevention) policy. The UEM admin controls this
centrally — they can enable or disable screenshot prevention per app,
per user group, or per device policy.

If the app sets `WindowManager.LayoutParams.FLAG_SECURE` on its own
windows, this creates a conflict:
- **Admin loses control**: The UEM admin cannot selectively allow
  screenshots (e.g., for support/debugging) because the app hardcodes
  prevention regardless of policy
- **Double enforcement**: Both the app and the SDK try to prevent
  screenshots, which is redundant
- **Settings toggle anomaly**: If the app has a user-facing toggle to
  enable/disable screenshot prevention, this directly conflicts with
  UEM policy — the user should not be able to override enterprise
  security policy from within the app

### What to Look For

During Prompt 00 analysis, flag:
- `WindowManager.LayoutParams.FLAG_SECURE` usage in any Activity
- `getWindow().setFlags(FLAG_SECURE, FLAG_SECURE)` calls
- `getWindow().clearFlags(FLAG_SECURE)` calls
- Settings/preferences that toggle screenshot prevention
  (e.g., `prevent_screenshots`, `screen_capture_enabled`)
- SharedPreferences keys related to screenshot settings

### How to Remove

1. **Remove FLAG_SECURE calls** from all Activities:
   ```java
   // REMOVE — Dynamics DLP policy controls screenshot prevention
   // getWindow().setFlags(
   //         WindowManager.LayoutParams.FLAG_SECURE,
   //         WindowManager.LayoutParams.FLAG_SECURE);
   ```

2. **Remove or no-op the toggle method** — if the app has a
   `setScreenshotPrevention(boolean)` method called from Settings,
   make it a no-op and add a TODO to remove the Settings toggle:
   ```java
   // [BB_DYNAMICS-MIGRATION] Screenshot prevention now managed by UEM DLP policy
   public void setScreenshotPrevention(boolean enabled) {
       // No-op — Dynamics DLP policy controls this
   }
   ```

3. **Flag the Settings toggle for developer review** — the developer
   must decide whether to:
   - Remove the toggle entirely (recommended — avoids user confusion)
   - Keep the toggle but explain it has no effect under Dynamics
   - Repurpose the toggle to read/display the current DLP policy state

4. **Remove unused WindowManager import** if no other window flags are
   used in the file

### Developer Communication (IMPORTANT)

This is a case where the migration agent MUST explain the conflict to
the developer rather than silently removing code. The developer needs
to understand:
- The UEM admin now controls screenshot prevention, not the app
- Any user-facing toggle for this feature conflicts with enterprise
  policy and should be removed or repurposed
- If the app needs to know whether screenshots are allowed, it can
  read the DLP policy via `GDAndroid.getInstance().getApplicationPolicy()`

SDK 15.1 does **not** add a public Gemini / on-device-AI screenshot API.
Screenshot blocking remains UEM DLP via `FLAG_SECURE` /
`preventScreenCapture`. Do not invent a Dynamics Gemini wrapper.

### Migration Comment

```java
// [BB_DYNAMICS-MIGRATION] Removed app-level FLAG_SECURE — Dynamics SDK enforces
// screenshot/screen-recording prevention via UEM DLP policy
```

---

## Category 5: App-Level AES / Custom Encryption Engine

### Why It's Redundant

The Dynamics container encrypts all data at rest using FIPS-validated
algorithms controlled by UEM policy. If the app wraps file reads and
writes with its own AES encryption layer (e.g., an `EncryptionEngine` class
that encrypts before writing to storage and decrypts after reading), this
layer is now redundant — the container already handles it.

Running both layers:
- **Doubles memory pressure**: plaintext must be held in memory while being
  encrypted/decrypted an extra time
- **Adds unnecessary complexity**: key management (KeyStore, passphrases)
  for an encryption system that provides no additional security
- **Complicates the migration**: every read/write path that touches the
  encryption engine must be updated

### What to Look For

During Prompt 00 analysis, flag:
- Custom encryption classes (`EncryptionEngine`, `CryptoHelper`, `AESUtil`,
  `EncryptionManager`, etc.)
- `javax.crypto.Cipher` usage for file encryption/decryption
- `android.security.keystore.KeyGenParameterSpec` for data-at-rest keys
- Methods named `encrypt()`, `decrypt()`, `encryptToFile()`, `decryptFromFile()`
- Repository or storage classes that wrap data with an encryption engine
  before writing it to the filesystem

### Phased Removal Approach

App-level encryption is typically deeply entangled — removing it in one
pass causes a large blast radius that spans the repository layer, use cases,
background workers, and UI fragments. Use a phased approach:

**Phase 1: Add a deprecated shim constructor**

Add a constructor that accepts but ignores the encryption engine. This
allows compile-time callers to keep passing the engine without behavior
change while you migrate them one by one:

```java
public class LocalEncryptedMediaRepository implements MediaRepository {

    public LocalEncryptedMediaRepository(
            SecureFileStore fileStore,
            PhotoDao photoDao) {
        // Primary constructor — encryption handled by Dynamics container
        this.fileStore = fileStore;
        this.photoDao = photoDao;
    }

    /** @deprecated Encryption is now provided by the Dynamics secure container. */
    @Deprecated
    public LocalEncryptedMediaRepository(
            SecureFileStore fileStore,
            EncryptionEngine encryptionEngine,  // ignored
            PhotoDao photoDao) {
        this(fileStore, photoDao);  // delegate to primary, drop engine
    }
}
```

**Phase 2: Migrate callers one by one**

For each class that constructs or injects the encryption engine:

1. Update the constructor call to use the new non-encryption constructor
2. Remove the `EncryptionEngine` import from that file
3. Build and test before moving to the next caller

Callers are typically: repository factory sites, WorkManager workers,
use cases, and fragments that build the repository directly.

**Phase 3: Remove the shim and the encryption classes**

Once all callers have been migrated:

1. Remove the `@Deprecated` shim constructor
2. Delete the encryption engine class and its key manager
3. Remove `javax.crypto` imports and `AndroidKeyStore` key entries
4. Remove the dependency from `build.gradle` if it was a library

### Blast Radius Discovery

Before starting, map all transitive callers:

```bash
# Find all references to the encryption engine class
rg "EncryptionEngine|CryptoHelper|encryptionEngine|cryptoHelper" \
  -g "*.java" -g "*.kt" -n app/src/main/

# Find all encrypt/decrypt call sites
rg "\.encrypt\(|\.decrypt\(|encryptToFile|decryptFromFile" \
  -g "*.java" -g "*.kt" -n app/src/main/
```

Plan removal order from **leaf callers inward** (UI and workers first,
then use cases, then the repository, then the engine class itself).

### Acceptable Partial Migration

If the blast radius is too large for a single migration pass, it is
acceptable to leave deprecated shims in v1 as long as:

1. The encryption engine is no longer performing actual encryption (it
   passes data through to the secure container unchanged)
2. The shim is documented in `manualTodos` with `priority: "medium"` and
   a description explaining the remaining cleanup work
3. The migration report's `securityPosture.dataAtRest` reflects that the
   Dynamics container provides encryption, not the app layer

### Migration Comment

```java
// [BB_DYNAMICS-MIGRATION] Removed app-level AES encryption — Dynamics container
// provides encrypted storage. EncryptionEngine parameter retained as deprecated shim
// for callers not yet migrated; see manualTodos for cleanup.
```

---

## When to Remove

The ideal sequence is:

1. **Prompt 00 (analysis)** — flag all redundant features in the inventory and
   classify backup/export egress outcomes
2. **Prompt 01 (Gradle)** — remove redundant dependencies
3. **Prompt 03 (auth)** — remove app-level lock screen, add Dynamics auth
4. **Prompt 04 (SQL)** — remove SQLCipher, add Dynamics secure SQLite
5. **Prompt 05a/05b/05c/05z (filesystem split)** — remove app-level backup if file-based; strip unmanaged export/restore helpers; begin
   phased removal of custom encryption engine (Category 5)

Each prompt should check for these redundancies in its domain and remove
them as part of the migration.

---

## Checklist

- [ ] Identify all app-level lock/biometric features (Prompt 00)
- [ ] Identify all app-level backup mechanisms (Prompt 00)
- [ ] Classify backup/export flows that cross the container boundary as `REMOVE`, `BLOCKED_UNTIL_APPROVED`, or `MANUAL_INTERVENTION_REQUIRED`
- [ ] Identify SQLCipher or other encryption libraries (Prompt 00)
- [ ] Identify FLAG_SECURE / screenshot prevention code (Prompt 00)
- [ ] Identify custom AES/encryption engine classes (Prompt 00)
- [ ] Remove redundant dependencies (Prompt 01)
- [ ] Remove lock screen Activities and biometric prompts (Prompt 03)
- [ ] Remove SQLCipher and passphrase management (Prompt 04)
- [ ] Remove app-level backup mechanisms (Prompt 05a/05b/05c/05z)
- [ ] Remove backup/export UI, workers, providers, permissions, and temp-file helpers that only support unmanaged egress
- [ ] Remove FLAG_SECURE and screenshot prevention toggles (Prompt 03 or 09)
- [ ] Begin phased removal of custom encryption engine — add deprecated shim (Prompt 05a/05z)
- [ ] Migrate callers away from encryption engine one by one
- [ ] Remove shim and encryption classes once all callers migrated
- [ ] Verify no double-authentication UX remains
- [ ] Verify no double-encryption remains
- [ ] Verify no app-level screenshot prevention conflicts with DLP policy
- [ ] Document removed features in migration report
- [ ] Document any pending encryption removal in manualTodos if not completed in this pass

---

## Key Principle

**Dynamics replaces app-level security with container-level security.**
The app no longer needs to implement its own lock screen, its own
encryption, or its own backup. These are now managed by the Dynamics
SDK and controlled by UEM policy. The app's job is to defer all secure
API access until `onAuthorized()` and let the SDK handle the rest.

## Enterprise Hardening Addendum (Redundant Crypto and FLAG_SECURE)

- App-level crypto primitives are warn-level findings in this kit: keep migration moving, but require explicit report justification and cleanup plan.
- Before removing app-level `FLAG_SECURE`, confirm UEM DLP screenshot policy ownership in bootstrap attestations.
- Biometric flows may remain only for explicit business transaction confirmation, not container unlock behavior.

### C5 Review Contract (Standalone)

For any app-level crypto hit (`Cipher`, `EncryptedFile`, `EncryptedSharedPreferences`, `MasterKey`, Tink/Aead, custom crypto helpers):
- classify as one of: `remove-now`, `temporary-pass-through`, `business-required`
- add rationale to migration report `manualTodos`
- if `temporary-pass-through`, include a concrete cleanup follow-up task
- if `business-required`, explain why Dynamics container controls are not sufficient for that specific business control
