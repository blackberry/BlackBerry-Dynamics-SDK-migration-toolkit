## Task: Secure Filesystem Migration 05c (SharedPreferences + Final Closure)

Goal: Migrate SharedPreferences persistence and finalize secure file-storage
call-site closure for the domain.

**Prerequisite**: Run `05a` and `05b` first.

**Module map context**: Load
`dynamics-migration-tool/output/module-map.json` and resolve
`${in_scope_main_src}`. SharedPreferences adapters frequently live
in `core/preferences` or similar library modules; final closure
audits scan the full set. If `module-map.json` is missing, STOP
and re-run `00pre-bootstrap.md`.

---

## Steps

### 1. Migrate SharedPreferences Persistence — IMPLEMENT NOW

**Do not flag SharedPreferences as a blocker. Implement the migration.**

There is no `GDSharedPreferences` drop-in. The documented pattern is to
write preference key-value data as files inside the Dynamics secure
container using the `SecurePreferencesHelper` pattern from
`steering/42-secure-storage-sharedpreferences.md`. This is a
well-defined, mechanical migration:

1. **Create `SecurePreferencesHelper`** (or equivalent) using
   `com.good.gd.file.FileOutputStream` / `FileInputStream` to read and
   write key-value pairs under a `secure_prefs/` directory in the GD
   container. **Copy** `templates/file/SecurePreferencesHelper.kt` (or
   follow `steering/42-secure-storage-sharedpreferences.md`). The helper
   **must** fail-closed on `GDNotAuthorizedError` (reads return empty
   without caching; writes are no-ops). Do not gate helper I/O on
   `isContainerAuthorized` — idle lock is not the same as unauthorized.
2. **Do not create `SecurePrefsMigration`.** A Dynamics conversion is
   always a fresh install (`steering/18-fresh-dynamics-install.md`).
   There is no leftover-data transfer path. If such a helper already
   exists, delete it.
3. **Replace all steady-state reads and writes**
   from `getSharedPreferences(...)` / `PreferenceManager` /
   `EncryptedSharedPreferences` to `SecurePreferencesHelper`.
4. **Remove `EncryptedSharedPreferences`** and its dependency — it is
   redundant inside the Dynamics container.

**Do this for every SharedPreferences-backed runtime path you find. Do not
report "SharedPreferences runtime usage remains" as a blocker — that
is the finding you are here to fix.**

### 1b. Re-audit authorization deferral after the prefs swap — MANDATORY

Replacing `SharedPreferences` with a Dynamics-backed helper converts every
remaining launch-path prefs call site into secure file I/O. Before closing
05c, re-check:

- Launch / base `Activity.onCreate`, `onStart`, and `onResume`
- Shared base Activities that apply theme, FLAG_SECURE, or settings
- Repositories or helpers invoked from those lifecycle methods

Any read/write through `SecurePreferencesHelper` (or equivalent
`com.good.gd.file.*` prefs storage) on those paths must be deferred with
`runOnAuthorized(...)`, `authorized.observe(...)`, or
`isContainerAuthorized` — the same two-phase rule as Room/file access.
This includes Kotlin property getters (`preferences.theme.value`,
`isLockEnabled`) and `object` helper calls (`SecurePreferencesHelper.getString`)
with no constructor parentheses. Leaving prefs I/O in Phase 1 causes
`GDNotAuthorizedError` on cold start. Helper-level fail-closed is
defense in depth; it does not replace call-site deferral (otherwise
defaults get cached as stored values). Phase 11 enforces `[AUTH-PREF-001]`.

Requirements:

- provide both write and read secure implementations
- do **not** add a leftover SharedPreferences copy helper
  (`steering/18-fresh-dynamics-install.md`)
- remove `EncryptedSharedPreferences` for data-at-rest use cases (redundant)
- after migration, steady-state runtime code must read and write via
  secure storage; **zero** SharedPreferences call sites may remain

### 2. Final Domain Completeness Review

Before completion, verify all three secure-file sub-domains are closed:

- **05a Core I/O**: writer/readers migrated or removed (including any
  app-controlled native `.c`/`.cpp` storage call sites per 05a step 4a
  and `steering/40-secure-file-storage.md` §8)
- **05b UI Reader Closure**: no native-reader drift for migrated sensitive domains
- **05c SharedPreferences**: runtime preference persistence migrated with upgrade path

Native-source check for `secureFileStorage` closure:

- Every native `callSites[]` entry from prompt 00 step 2b (entries
  with `language: "C"` or `"C++"`) must have a matching disposition
  (`migrated` or `removed`) in `migration-plan-state.json`.
- Prebuilt `.so` libraries do **not** auto-close. They remain
  non-blocking manual interventions unless evidence shows a non-waivable
  storage/networking violation; the only way to close
  `secureFileStorage` while they exist is the developer-signed-off
  deferral path in `bootstrap.json deferredDomains[]`.

### 3. Finalize `migration-plan-state.json` for `secureFileStorage`

Ensure every applicable secure-file `callSites[].id` from prompt 00 has exactly
one disposition entry (`migrated|removed`) with correct domain.
Read the existing file first, merge/upsert this prompt's
`secureFileStorage` entries while preserving existing
`egressFeatureDecisions[]` and other domains' `dispositions[]`, then
full-file overwrite.

For `SharedPreferences`-backed call sites, `status: "migrated"` is allowed
**only** when the original steady-state runtime path no longer uses
`getSharedPreferences(...)`, `PreferenceManager.getDefaultSharedPreferences()`,
or `EncryptedSharedPreferences`. That means **zero** SharedPreferences
call sites. Do not add a leftover-data copy helper. Do not mark a call
site `migrated` just because it was reviewed or added to the ledger.

Required field names (matched by `record-prompt-execution.sh` and the
bundled schema
`dynamics-migration-tool/schemas/migration-plan-state.schema.v1.1.0.json`):

```json
{
  "schemaVersion": "1.1.0",
  "runId": "<copied unchanged from bootstrap.json / existing migration-plan-state.json>",
  "egressFeatureDecisions": [
    {
      "featureId": "<existing value or new prompt-owned feature id>",
      "domain": "secureFileStorage|secureNetworking|icc|secureClipboard|secureUiWidgets|policyManagement",
      "outcome": "REMOVE|REPLACE_WITH_DYNAMICS|MANUAL_INTERVENTION_REQUIRED|BLOCKED_UNTIL_APPROVED",
      "module": "<optional module path from module-map.json>",
      "note": "<optional detail>",
      "secureAlternative": "<optional string or null>",
      "uiDisposition": "removed|disabled|replaced|flagged",
      "codePathReachable": false
    }
  ],
  "dispositions": [
    {
      "callSiteId": "<id from migration-analysis.executionPlan[].callSites[].id>",
      "domain": "secureFileStorage",
      "status": "migrated",
      "module": "<module path from module-map.json, e.g. app>",
      "note": "required in practice for SharedPreferences; name the secure helper or removal"
    },
    {
      "callSiteId": "<id>",
      "domain": "secureFileStorage",
      "status": "removed",
      "module": "<module path from module-map.json, e.g. app>",
      "note": "call site removed during refactor"
    }
  ]
}
```

Do not invent alternative field names (`disposition`, `state`,
`verdict`, etc.) — the recorder hard-fails on schema mismatch.
Preserve the existing top-level `runId` exactly; never regenerate it.
Keep `egressFeatureDecisions[]` present even when unchanged.

This final closure is what must pass M2 gate for secure-file domain completion.

### 3b. Storage layout redesign decision (MANDATORY when applicable)

If any `secureFileStorage` call site has non-null `redesignPath` from prompt 00,
confirm the redesign is **implemented** (not merely planned) or the entire domain is
in `bootstrap.json deferredDomains[]` with developer sign-off. See
`steering/40-secure-file-storage.md` §7. Do not proceed to ICC while public-storage
roots remain for app data.

### 4. Exit Criteria Before Marking `05c` Completed (MANDATORY)

Do not record `--status completed` until the secure-file closure ledger
matches `migration-analysis.executionPlan[].callSites` (or the entire
`secureFileStorage` domain is deferred with developer sign-off in
`bootstrap.json deferredDomains[]`):

```bash
# Secure-file closure ledger must match executionPlan callSites
python3 - <<'PY'
import json
from pathlib import Path

analysis = json.loads(Path("dynamics-migration-tool/output/migration-analysis.json").read_text())
plan_state = json.loads(Path("dynamics-migration-tool/output/migration-plan-state.json").read_text())
required = {
    (row["domain"], cs["id"])
    for row in analysis.get("executionPlan", [])
    if row.get("domain") == "secureFileStorage" and row.get("applicable") is True
    for cs in row.get("callSites", [])
    if isinstance(cs, dict) and cs.get("id")
}
dispositions = {
    (d.get("domain"), d.get("callSiteId"))
    for d in plan_state.get("dispositions", [])
    if isinstance(d, dict)
}
missing = sorted(required - dispositions)
print("missing_dispositions", len(missing))
for m in missing:
    print("  ", m)
raise SystemExit(1 if missing else 0)
PY
```

Before recording completion, manually verify every
`SharedPreferences` call site is removed from the runtime path.
Do not isolate leftover reads in a copy helper
(`steering/18-fresh-dynamics-install.md`).

Before invoking the recorder below, run the scoped diagnostic for prompt 05c
(Phase 4 + Phase 10 API audit). If it reports remnants such as "External
storage/MediaStore API surface detected", "Android filesDir/cacheDir staging
remains", "Direct java.io.File construction", or "SharedPreferences runtime
usage still present", re-run `05a/05b/05c` as needed and update
`migration-plan-state.json`. The recorder records prompt progress here;
prompt `10` is the mandatory final source/report gate.

### 4a. Independent Evidence Preflight (MANDATORY before recording completion)

Run the scoped validator once before `record-prompt-execution.sh`:

```bash
bash dynamics-migration-tool/tooling/validate.sh --check-prompt 05c
```

If the output contains `Independent evidence closure` findings:

1. Fix **real data-path** failures first (storage paths, SAF/export, staging, runtime `SharedPreferences`).
2. For **inventory-only** findings (bridge files, DAO/entity artifacts, read-only UI rediscovery), backfill Prompt-00 inventory and matching `dispositions[]` entries instead of looping full prompt 10.
3. If `secureFileStorage` truly cannot close this release, STOP and hand the developer this exact `deferredDomains[]` template. The agent must not write it:

```json
{
  "deferredAt": "2026-06-25T12:00:00Z",
  "deferredBy": "developer",
  "developerSignedOff": true,
  "classification": "plannedInNextRelease",
  "domain": "secureFileStorage",
  "expiresAt": "2026-07-25T12:00:00Z",
  "reason": "Secure file-storage redesign is not complete; remaining call sites are tracked for the next release."
}
```

Do not proceed to ICC or prompt 10 while treating independent-evidence inventory gaps as if they were fixed by repeated full validator sweeps.

---

## Output

- SharedPreferences migration summary
- Confirmation that leftover-data copy helpers were not added (`18-fresh-dynamics-install.md`)
- **`dynamics-migration-tool/output/migration-plan-state.json` updated**
  with the canonical top-level shape (`schemaVersion`, `runId`,
  `egressFeatureDecisions[]`, `dispositions[]`) and merged
  `secureFileStorage` dispositions
- Final secure-file completeness checklist:
  - 05a closed
  - 05b closed
  - 05c closed
  - call-site dispositions complete
  - validator outcome captured

---

## Record execution

After 05c completes:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 05c \
    --status completed \
    --files-touched <comma-separated relative paths including migration-plan-state.json>
```

If secure file storage is `not-applicable` per execution plan:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 05c \
    --status skipped \
    --note "secureFileStorage not-applicable per executionPlan"
```
