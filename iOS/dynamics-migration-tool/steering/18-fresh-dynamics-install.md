# Steering: Fresh Dynamics Install (Mandate)

A Dynamics conversion is **always a fresh install**. The kit does not
support overinstall, upgrade, or data transfer from a previously
installed non-Dynamics app.

The Dynamics package does not inherit `UserDefaults` plists, SQLCipher
databases, or sandbox files from a pre-Dynamics installation. There is
**no kit option** to copy that data. Do not ask the developer whether to
preserve it. Do not invent one-time transfer helpers.

This file is the canonical install-model rule. Storage-domain prompts
(`04`, `05`) and steering (`15`, `40`, `41`) follow it.

---

## Mandate

| Required | Forbidden |
|----------|-----------|
| Steady-state replacements: sensitive values via `GDFileManager` / `GDCWriteStream`, `GDFileManager` for files, `sqlite3enc` / `GDPersistentStoreCoordinator` | `migrateFromUserDefaults` or any copy from leftover `UserDefaults` |
| Removing redundant encryption (SQLCipher, app-level data-at-rest crypto) | SQLCipher rekey / export / import from a pre-Dynamics database |
| Post-authorization I/O (`GDAppEventAuthorized` / `GDState.isAuthorized`) | Copying sandbox files from a pre-Dynamics install into the Dynamics container |

---

## Bootstrap

Do **not** add an attestation or `bootstrap.json` field for this rule.
Do **not** prompt the developer to opt into leftover-data transfer.
Prompt `00pre` states the mandate; later prompts apply it.

---

## Agent checklist

- [ ] Treat every Dynamics conversion as a fresh install
- [ ] Replace runtime sensitive prefs / files / SQL with Dynamics APIs
- [ ] Do not create, keep, or offer leftover-data copy helpers
- [ ] Remove leftover `UserDefaults` sensitive paths instead of wrapping them
