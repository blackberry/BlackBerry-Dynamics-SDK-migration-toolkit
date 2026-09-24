# Steering: Fresh Dynamics Install (Mandate)

A Dynamics conversion is **always a fresh install**. The kit does not
support overinstall, upgrade, or data transfer from a previously
installed non-Dynamics app.

The Dynamics package does not inherit SharedPreferences XML, SQLCipher
databases, `filesDir` / `cacheDir` trees, or other Android-sandbox files
from a pre-Dynamics installation. There is **no kit option** to copy that
data. Do not ask the developer whether to preserve it. Do not invent
one-time transfer helpers.

This file is the canonical install-model rule. Storage-domain prompts
(`04`, `05a`, `05z`) and steering (`15`, `41`, `42`) follow it.

---

## Mandate

| Required | Forbidden |
|----------|-----------|
| Steady-state replacements: `SecurePreferencesHelper` (or equivalent GD-backed prefs), `com.good.gd.file.*`, Dynamics SQLite / Room bridge | `SecurePrefsMigration` or any copy from leftover `SharedPreferences` XML |
| Removing redundant encryption (`EncryptedSharedPreferences`, SQLCipher) | SQLCipher rekey / export / import from a pre-Dynamics database |
| Two-phase startup and post-`onAuthorized()` I/O | Copying `filesDir` / `cacheDir` / public-folder files from a pre-Dynamics sandbox |

Phase 4 success is **zero** `getSharedPreferences` / `PreferenceManager` /
`EncryptedSharedPreferences` call sites. A leftover "migration helper"
is not an allowed exception.

---

## Bootstrap

Do **not** add an attestation or `bootstrap.json` field for this rule.
Do **not** prompt the developer to opt into leftover-data transfer.
Prompt `00pre` states the mandate; later prompts apply it.

---

## Agent checklist

- [ ] Treat every Dynamics conversion as a fresh install
- [ ] Replace runtime prefs / files / SQL with Dynamics APIs
- [ ] Do not create, keep, or offer leftover-data copy helpers
- [ ] Remove leftover `SharedPreferences` call sites instead of wrapping them
