# Steering: Application config read and refresh

**Ownership:** platform migration kit (`templates/auth/DynamicsApplicationBase.*`,
Phase `7` policy validator, `contracts/api-catalog.v1.0.0.json` row
`appconfig-java-001`).

UEM pushes **application configuration** into the Dynamics container. Apps
read the current snapshot with `GDAndroid.getApplicationConfig()` and
receive updates through `GDStateListener.onUpdateConfig(Map<String, Object>)`.

This is distinct from **application policy** (`getApplicationPolicy()` /
`onUpdatePolicy`) — both use the same cache-and-refresh discipline.

> **Verified public API (WI-00):**
> `Map<String, Object> GDAndroid.getInstance().getApplicationConfig()
> throws GDNotAuthorizedError` and
> `void GDStateListener.onUpdateConfig(Map<String, Object>)`.
> Maintainer transcript: `_maintainer/notes/sdk-verification-2026Q2.md`.

---

## When to use application config

| Use application config for | Use application policy for |
|----------------------------|----------------------------|
| UEM-managed app settings (servers, feature flags, DLP keys) | Custom XML policy definitions uploaded to UEM |
| Keys such as `GDAppConfigKeyServers`, `GDAppConfigKeyUserId` | Keys from your `AppPolicyDefinition` XML |
| Values pushed with the Dynamics container profile | Values read via `getApplicationPolicy()` |

Do **not** call `getApplicationConfig()` from every `Activity.onCreate()`.
Policy and config values change at runtime; the SDK delivers updates only
through the listener callbacks.

---

## Canonical cache-and-refresh pattern

Keep a single in-memory cache on the `Application` class (the same class
that implements `GDStateListener`):

1. **Initial load** — in `onAuthorized()`, populate the cache once (or call
   your private `refreshApplicationConfig(null)` helper).
2. **Refresh** — in `onUpdateConfig(Map<String, Object> settings)`, pass
   the map from the callback when non-null; otherwise re-fetch from
   `getApplicationConfig()`.
3. **Readers** — Activities, ViewModels, and services read from
   `Application.getCachedApplicationConfig()` (or policy equivalent), never
   call `GDAndroid` directly.

### Java (excerpt — see `DynamicsApplicationBase.java` template)

```java
private volatile Map<String, Object> cachedApplicationConfig;

public static Map<String, Object> getCachedApplicationConfig() {
    return getInstance().cachedApplicationConfig;
}

private void refreshApplicationConfig(Map<String, Object> fromCallback) {
    try {
        if (fromCallback != null) {
            cachedApplicationConfig = fromCallback;
        } else {
            cachedApplicationConfig = GDAndroid.getInstance().getApplicationConfig();
        }
    } catch (com.good.gd.error.GDNotAuthorizedError e) {
        cachedApplicationConfig = null;
    }
}

@Override
public void onAuthorized() {
    // ... existing auth wiring ...
    refreshApplicationConfig(null);
}

@Override
public void onUpdateConfig(Map<String, Object> settings) {
    refreshApplicationConfig(settings);
}
```

### Kotlin

Same structure in `DynamicsApplicationBase.kt` — use
`MutableMap<String, Any>?` for the callback parameter (Java platform type).

### Policy twin

Apply the same pattern for `getApplicationPolicy()` / `onUpdatePolicy` with
`cachedApplicationPolicy` and `refreshApplicationPolicy(...)`.

---

## Detection and migration steps

1. **Find direct reads** — search for `getApplicationConfig(` and
   `getApplicationPolicy(` outside the Application class.
2. **Move to Application cache** — add cache fields + refresh helpers to the
   `GDStateListener` Application class (start from the template).
3. **Replace call sites** — UI and background code use static getters on the
   Application class.
4. **Remove `RestrictionsManager`** — enterprise restrictions belong to
   Dynamics policy/config APIs (Phase `7` already fails `RestrictionsManager`
   hits).

```bash
rg -n 'getApplicationConfig\s*\(|getApplicationPolicy\s*\(' --glob '*.{java,kt}'
```

---

## Anti-patterns

| Anti-pattern | Why it fails | Fix |
|--------------|--------------|-----|
| `getApplicationConfig()` in `Activity.onCreate()` | Stale values; may throw `GDNotAuthorizedError` pre-auth | Read cache; gate UI on `isContainerAuthorized` |
| Ignoring `onUpdateConfig` (empty stub) | Misses UEM updates while app is running | Implement `refreshApplicationConfig(settings)` |
| Calling `getApplicationConfig()` on every button click | Policy thrash; unnecessary container round-trips | Cache + invalidate only in `onUpdateConfig` |
| Confusing config with policy | Wrong keys / wrong callback | Use config APIs for container config only |

---

## Validator (Phase 7, warn-only)

Phase `7` warns when `getApplicationConfig()` or `getApplicationPolicy()` appears
in a method other than:

- `onUpdateConfig` / `onUpdatePolicy`
- `onAuthorized` (one-time cache seed)
- Private `refresh*Config*` / `refresh*Policy*` helpers in the same file

Warnings also fire for calls inside `Activity`, `Fragment`, or `ViewModel`
types. This is **warn-scoped** in the first release — fix before production.

---

## Cross-references

- `steering/20-auth-initialization.md` — `GDStateListener` callbacks
- `steering/72-local-compliance-and-custom-policies.md` — custom policy XML
- `steering/14-api-provenance-and-replacement-catalog.md` — `appconfig-java-001`
- `templates/auth/DynamicsApplicationBase.java` / `.kt`

---

## Verification

- `bash dynamics-migration-tool/tooling/validate.sh` — Phase `7` app-config cache warn
- Maintainer: `internal/fixtures/04-sharedprefs-sensitive/` pass/fail pair
- `bash dynamics-migration-tool/_maintainer/tooling/hardening-smoke.sh`
