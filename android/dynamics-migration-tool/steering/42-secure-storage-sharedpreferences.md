# Steering: Migrating SharedPreferences to Secure Storage

`android.content.SharedPreferences` stores key-value data in unencrypted XML
files on the device (`/data/data/<pkg>/shared_prefs/*.xml`). This data is
not protected by the Dynamics secure container and is therefore accessible
to anyone with physical access, a device backup, or root privileges.

Unlike SQLite (`android.database.sqlite` → `com.good.gd.database.sqlite`),
there is **no `GDSharedPreferences` drop-in replacement class**.
`SharedPreferences` persistence itself sits outside the Dynamics container,
so steady-state preference storage must be migrated to the Dynamics secure
filesystem instead.

> **Multi-module note**: `rg ... app/src/main/java/` examples below
> are canonical-shape. Scan `${in_scope_main_src}` from
> `dynamics-migration-tool/output/module-map.json` —
> SharedPreferences adapters routinely live in `core/preferences` or
> similar library modules. See `04-multi-module-projects.md`.

---

## Required Analysis

Locate all `SharedPreferences` usage:

```bash
rg "SharedPreferences|getSharedPreferences|PreferenceManager" \
  -g "*.java" -g "*.kt" -n app/src/main/java/
```

For each usage, identify:
- The preference file name (`PREFS_NAME`)
- The keys stored
- Whether the call site is **steady-state runtime persistence** or an
  explicit **one-time migration helper**

The validator no longer infers risk from preference-file names, key names,
or nearby identifier text. A `SharedPreferences` API call is in-scope
because it persists data outside the Dynamics container, not because its
names look sensitive.

---

## Classification: What Must Migrate

### Migrate to Dynamics Secure Storage

Every steady-state `SharedPreferences` / `EncryptedSharedPreferences` usage
must migrate, including:

| Data Type | Examples |
|-----------|---------|
| Authentication state | Bearer tokens, OAuth refresh tokens, API keys |
| Credentials | Usernames, passwords, PINs |
| PII | Email addresses, phone numbers, user IDs |
| Business configuration | Server URLs, upload endpoints, enterprise settings |
| UI / product state | Theme, font size, onboarding flags, camera settings, feature toggles |
| Encryption keys or passphrases | Any cryptographic material |

**The migration rule is storage-surface based, not sensitivity-name based:**
if the app persists it through `SharedPreferences`, move that steady-state
path into Dynamics secure storage.

### Allowed Legacy Exception: One-Time Migration Helper

Legacy `SharedPreferences` access may remain only inside an explicit
one-time migration helper that:

1. runs after `onAuthorized()`,
2. reads the old preference value,
3. writes the replacement value into secure storage, and
4. removes or clears the legacy preference entry.

Any remaining steady-state runtime reads/writes are a **high-priority
`manualTodo`** and must be addressed before production deployment.

---

## CRITICAL: Requires an Unlocked Container

Like all Dynamics secure file APIs, reading or writing to the secure
preferences storage requires an unlocked container. Do NOT access secure
preferences in `onCreate()` or any lifecycle method that runs before
`onAuthorized()`. See `21-authorization-deferral-patterns.md`.

---

## Migration Approach

There is no single `SharedPreferences` → `GDSharedPreferences` import swap.
The correct approach is to:

1. Write preference values as individual files inside the Dynamics
   secure filesystem, under a dedicated directory (e.g., `secure_prefs/`).
2. Provide a one-time migration helper that copies existing
   `SharedPreferences` values into secure storage on first authorized launch,
   then removes them from `SharedPreferences`.
3. Move steady-state reads and writes to the secure helper. After migration,
   legacy `SharedPreferences` access may remain only in the explicit one-time
   upgrade path, not in the runtime auth/session code path.

### Secure Preferences Helper Pattern

```java
/**
 * [BB_DYNAMICS-MIGRATION] Helper for storing preference key-value pairs inside
 * the Dynamics secure container. Replaces steady-state SharedPreferences storage.
 *
 * Storage layout: one UTF-8 text file per key under "secure_prefs/<key>"
 * inside the GD secure container.
 */
public final class SecurePreferencesHelper {

    private static final String PREFS_DIR = "secure_prefs";

    private final SecureFileStore fileStore;

    public SecurePreferencesHelper(SecureFileStore fileStore) {
        this.fileStore = fileStore;
    }

    /** Stores a string value. Overwrites any existing value for the key. */
    public void putString(String key, String value) throws StorageException {
        String path = PREFS_DIR + "/" + key;
        try (OutputStream out = fileStore.openForWrite(path)) {
            out.write(value.getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new StorageException("Failed to write secure pref: " + key, e);
        }
    }

    /**
     * Reads a string value. Returns null if the key does not exist.
     */
    @Nullable
    public String getString(String key) throws StorageException {
        String path = PREFS_DIR + "/" + key;
        try (InputStream in = fileStore.openForRead(path)) {
            if (in == null) return null;
            byte[] bytes = readAllBytes(in);
            return new String(bytes, StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new StorageException("Failed to read secure pref: " + key, e);
        }
    }

    /** Removes a value. No-op if the key does not exist. */
    public void remove(String key) {
        fileStore.delete(PREFS_DIR + "/" + key);
    }

    /** Returns true if the key exists in secure storage. */
    public boolean contains(String key) {
        return fileStore.exists(PREFS_DIR + "/" + key);
    }

    private static byte[] readAllBytes(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = in.read(buf)) != -1) {
            out.write(buf, 0, n);
        }
        return out.toByteArray();
    }
}
```

### One-Time Migration Helper

On the first authorized launch after migration, copy legacy values from
`SharedPreferences` into the secure container and then remove them:

```java
// [BB_DYNAMICS-MIGRATION] One-time migration of legacy SharedPreferences values
// into the Dynamics secure container. Run once after onAuthorized().
public class SecurePrefsMigration {

    private static final String MIGRATION_DONE_KEY = "secure_prefs_migration_v1_done";

    public static void runIfNeeded(
            Context context,
            SecurePreferencesHelper securePrefs) throws StorageException {

        // Guard: only run once
        if (securePrefs.contains(MIGRATION_DONE_KEY)) {
            return;
        }

        // Migrate auth token example
        SharedPreferences authPrefs = context.getSharedPreferences(
                "secure_camera_auth", Context.MODE_PRIVATE);
        String token = authPrefs.getString("bearer_token", null);
        if (token != null) {
            securePrefs.putString("bearer_token", token);
            authPrefs.edit().remove("bearer_token").apply();
        }

        // Add additional legacy preference keys here following the same pattern...

        // Mark migration complete
        securePrefs.putString(MIGRATION_DONE_KEY, "true");
    }
}
```

Call `SecurePrefsMigration.runIfNeeded()` from `onAuthorized()` before
any code that reads secure preferences:

```java
@Override
public void onAuthorized() {
    isContainerAuthorized = true;
    authorized.postValue(true);
    try {
        SecurePrefsMigration.runIfNeeded(this, securePrefs);
    } catch (StorageException e) {
        Log.e(TAG, "Secure prefs migration failed", e);
    }
}
```

---

## Updated Call Site Pattern

After migration, call sites that read a token change from:

```java
// [NOT OK] BEFORE — bearer token in unencrypted SharedPreferences
SharedPreferences prefs = context.getSharedPreferences("secure_camera_auth", MODE_PRIVATE);
String token = prefs.getString("bearer_token", null);
```

to:

```java
// [OK] AFTER — [BB_DYNAMICS-MIGRATION] bearer token in Dynamics secure container
String token = securePrefs.getString("bearer_token");
```

The original `SharedPreferences` read is allowed to survive only inside the
one-time migration helper. If the app still performs steady-state reads or
writes against `getSharedPreferences("auth" ...)`, `PreferenceManager`, or
`EncryptedSharedPreferences`, the call site is **not** closed and must not be
marked `migrated` in `migration-plan-state.json`.

---

## EncryptedSharedPreferences Is Also Redundant

If the app uses `androidx.security:security-crypto`'s `EncryptedSharedPreferences`,
this is a redundant encryption layer — the Dynamics container already encrypts
all data at rest. Remove it during migration:

1. Remove the `androidx.security:security-crypto` dependency from `build.gradle`
2. Replace steady-state call sites with `SecurePreferencesHelper`

See `15-redundant-feature-removal.md` for the general redundant-encryption-removal
pattern.

---

## Migration Checklist

- [ ] Audit all `SharedPreferences` files and keys (run the `rg` command above)
- [ ] For each `SharedPreferences` file, implement `SecurePreferencesHelper` storage (or equivalent GD-backed helper)
- [ ] Implement one-time migration helper and call it from `onAuthorized()`
- [ ] Verify steady-state reads and writes no longer use `SharedPreferences`
- [ ] Keep legacy `SharedPreferences` access only inside the one-time migration helper
- [ ] **Defer** every launch-path / base-Activity secure-prefs read/write until
      `runOnAuthorized` / `authorized` / `isContainerAuthorized` (Phase 11
      `[AUTH-PREF-001]` — theme, settings, unlock material, FLAG_SECURE, etc.)
- [ ] Verify all preference-backed call sites use secure storage post-migration
- [ ] Remove `EncryptedSharedPreferences` if present
- [ ] Document any unresolved runtime `SharedPreferences` usage in `manualTodos` with `severity: "P1"` and the appropriate `blocking` value
- [ ] Test the migration path: fresh install, then upgrade from pre-migration data
- [ ] Cold-start smoke: launch Activity must not throw `GDNotAuthorizedError` from prefs helpers before Dynamics authorize UI

---

## Output

- Inventory of all `SharedPreferences` files and keys
- List of keys migrated to secure storage
- Confirmation that steady-state runtime preference persistence no longer uses `SharedPreferences`
- Any `manualTodo` items for unresolved runtime preference usage
