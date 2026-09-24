# Steering: Call-site worklist and closure (`migration-plan-state.json`)

This document defines **M2** artifacts that bind prompt 00’s inventory to
final acceptance: every inventoried call site listed for a domain must
receive an explicit disposition before prompt `10` can record
`status: completed`.

Background Authorize (`03c`) is intentionally outside this ledger:
prompt `03c` closes candidates through
`bootstrap.backgroundAuthorize.decisions[]`, and the prompt 10 recorder
gate special-cases that domain. Do not add `backgroundAuthorize`
entries to `migration-plan-state.json`.

---

> **Cross-domain gating:** `tooling/check-prompt-map.json` `requires[]`
> documents domain-closure prerequisites for selected prompts and enforces
> the prompt `10` full-sweep gates. The current shipped recorder records
> prompts `01`–`09` as progress bookkeeping and does not auto-run or hard-gate
> their scoped checks. See
> `steering/40-secure-file-storage.md` §7 and the schema at
> `documentation/report-contract/check-prompt-map-schema-v1.2.0.md`.
>
> Prompt `10` also enforces `auxProcessGdReachClosed` for `[PROC-AUX-001]`
> findings. This closure lives in `migration-report.json`
> `unverifiedSurfaces[]` (pattern `PROC-AUX-001`), not in
> `migration-plan-state.json` `dispositions[]`.

## Files

| File | Writer | Purpose |
|------|--------|---------|
| `dynamics-migration-tool/output/migration-analysis.json` | Prompt 00 | `executionPlan[]` rows include `callSites[]` for applicable domains; `egressFeatures[]` records feature-level container-boundary decisions |
| `dynamics-migration-tool/output/migration-plan-state.json` | Prompts 04/05z/06/08/09 (and 00 seeds empty) | `dispositions[]` — one row per closed call site; `egressFeatureDecisions[]` — one row per analyzed egress-capability feature |

Both are **full-file overwrite** JSON (no patch tools). Same hygiene as
`bootstrap.json` and `migration-report.json`.

---

## `migration-analysis.json` — `executionPlan[].callSites`

For each `executionPlan` row whose `promptId` is `04`, `05z`, `06`, `08`, or `09`:

- Include a **`callSites` array** (may be empty only when the inventory
  truly found **zero** call sites for that domain; document
  that in `rationale`).
- If `applicable: true` and the inventory found one or more call sites,
  `callSites` MUST be non-empty. Empty with applicable true is a contract
  violation.

Each call site object:

```json
{
  "id": "string — unique across entire migration-analysis.json",
  "file": "string — path relative to project root",
  "line": 0,
  "language": "Java|Kotlin",
  "kind": "string — short detector label, e.g. FileOutputStream, Room.Database, HttpURLConnection",
  "context": "string — one-line human summary of what this call does"
}
```

Rules:

- **`id`**: stable for the run (e.g. `secureSql-app-src-main-java-com-acme-Db-42`).
  Used as the join key to `migration-plan-state.json`.
- **`line`**: 1-based line number from `rg`/IDE at analysis time; `0` only
  if the tool cannot determine a line (discouraged).
- **`language`**: `Java` or `Kotlin` (match source file extension).

### Independent-Evidence Inventory Rule

Prompt 10's independent-evidence closure is file-based. Do not inventory only
the "obvious" top-level writes/reads and assume bridge or support files will be
implicitly covered later.

When Prompt 00 encounters files that the validator will rediscover as part of a
domain audit, include them in `callSites[]` with stable IDs and explicit
`context`, even when the file is a bridge/helper or an import-only inventory
surface. Typical examples:

- `secureSql`: Room DAO/entity/converter files and GDRoom bridge helpers
- `secureUiWidgets`: adapters, view holders, and bridge UI files that retain
  covered widget imports
- `icc` / `secureFileStorage`: support files that still own share/export or SAF
  boundaries

If these files are omitted from Prompt 00 inventory, prompt 10 will rediscover
them independently and force mechanical cleanup in `migration-plan-state.json`
after the main migration is already done.

---

## `migration-plan-state.json` — `dispositions`

`dispositions[]` is the **canonical disposition array for all
closure-gated domains**. This includes `secureSql`, `secureFileStorage`,
`secureNetworking`, **`icc`**, `secureUiWidgets`, and **`secureClipboard`**
— not just the three data-plane domains. Prompts 08 and 09 write to the
same `dispositions[]` as prompts 04, 05z, and 06.

`migration-plan-state.json` is a **closure ledger**, not proof by itself.
Prompt `10` uses it to confirm that every inventoried call site received a
disposition; the validator still decides whether the underlying code is
actually migrated. Agents must not treat "ledger entry exists" as evidence
that a call site is closed.

`egressFeatureDecisions[]` serves the same purpose for feature-level
container-boundary capabilities discovered during Prompt 00. It records the
final migration outcome for features such as backup/export/share/open-with/
print/clipboard egress, separate from low-level API call-site closure.

> **Schema rule — no custom top-level keys.** Any key other than
> `schemaVersion`, `runId`, `dispositions`, and `egressFeatureDecisions` at the root of
> `migration-plan-state.json` will be rejected by the schema validator
> (`additionalProperties: false`). Do **not** create keys such as:
>
> - `iccDispositions` (wrong)
> - `clipboardDispositions` (wrong)
> - `callSiteDispositions` (wrong)
> - `secureUiWidgetsDispositions` (wrong)
> - `blockedFeatures` (wrong)
> - `removedFeatures` (wrong)
>
> All domains write to the **same** `dispositions[]` array. The `domain`
> field on each entry is how the recorder joins entries back to their
> owning domain. All feature-level egress outcomes write to the **same**
> `egressFeatureDecisions[]` array.

Top-level shape:

```json
{
  "schemaVersion": "1.1.0",
  "runId": "string — copied from bootstrap.json runId",
  "egressFeatureDecisions": [
    {
      "featureId": "string — must match migration-analysis.json egressFeatures[].id",
      "domain": "secureFileStorage|secureNetworking|icc|secureClipboard|secureUiWidgets|policyManagement",
      "outcome": "REMOVE|REPLACE_WITH_DYNAMICS|MANUAL_INTERVENTION_REQUIRED|BLOCKED_UNTIL_APPROVED",
      "module": "string — optional; module path from module-map.json",
      "note": "string — optional; what changed or why the feature remains blocked/manual",
      "secureAlternative": "string — optional; ICC, secure clipboard, in-container viewer, approved Dynamics service, etc.",
      "uiDisposition": "removed|disabled|replaced|flagged",
      "codePathReachable": "boolean — false when the unmanaged path has been stripped or blocked"
    }
  ],
  "dispositions": [
    {
      "callSiteId": "string — must match migration-analysis callSites[].id",
      "domain": "secureSql|secureFileStorage|secureNetworking|icc|secureUiWidgets|secureClipboard",
      "module": "string — optional; module path from module-map.json",
      "status": "migrated|removed",
      "note": "string — optional; what changed or why removed",
      "safDecision": "object — optional; required for SAF trust-boundary dispositions"
    }
  ]
}
```

When prompts 08 or 09 add ICC or clipboard dispositions, the entries sit
alongside (not instead of) the entries from earlier data-plane prompts:

```json
{
  "schemaVersion": "1.1.0",
  "runId": "...",
  "dispositions": [
    { "callSiteId": "sql-app-DbHelper-42",       "domain": "secureSql",        "status": "migrated" },
    { "callSiteId": "sfs-store-1",               "domain": "secureFileStorage","status": "migrated" },
    { "callSiteId": "icc-sharesheet-MainActivity-88", "domain": "icc",          "status": "migrated" },
    { "callSiteId": "clip-util-CopyHelper-14",   "domain": "secureClipboard",  "status": "migrated" }
  ]
}
```

`runId` is optional in the historical v1.0.0 schema for backward
compatibility, but required for new runs. Prompts 00/04/05a/05b/05c/05z/06
must preserve it unchanged so prompt 10 can cross-check report
provenance against bootstrap + plan-state artifacts.

### `module` field

`module` is the repo-relative path of the Gradle module that owns the
call site, taken from `module-map.json` (`primaryAppModule.path` or
one of `libraryModulesInScope[].path`). For canonical single-module
projects this is `"app"`. The field is optional in v1.0.0 to keep
data produced before the multi-module rollout valid; new runs
populate it. Prompt 10 surfaces a per-module rollup in the migration
report's `summary.migrationCommentCountByModule` and uses it as part
of the per-module execution-plan gate.

### Disposition semantics

| `status` | Meaning |
|----------|---------|
| `migrated` | Call site was converted to the Dynamics-backed pattern |
| `removed` | Call site eliminated (dead code removal, feature removed) |

A call site is either migrated to Dynamics or removed from the
codebase. If a domain cannot be migrated this release, the developer
records it in `bootstrap.json deferredDomains[]`; the domain is then
excluded from call-site closure entirely.

**Caller-liveness invariant for `removed`:** A `removed` disposition is
only valid when the containing method/class is actually dead code — either
deleted from the source or unreachable from any active caller. Final closure
enforces this: when a disposition has `status: "removed"`, prompt `10`
checks that the code path is truly gone or blocked. If callers exist
(especially from UI-bound code paths like click listeners, list adapters,
or menu handlers), the final gate rejects the disposition and requires
either:
- reclassifying as `migrated` and replacing with the Dynamics-backed
  pattern, or
- removing/disabling the calling UI elements so the method is truly dead.

This prevents the **silent functional regression** anti-pattern where an
agent replaces an `ACTION_VIEW` / `ACTION_SEND` method body with a no-op
Toast while leaving active UI callers intact. The result compiles, passes
validation, and produces no crash, but the user-facing feature silently
does nothing.

For `secureFileStorage` call sites backed by `SharedPreferences`,
`status: "migrated"` means the steady-state runtime path no longer uses
`getSharedPreferences(...)`, `PreferenceManager`, or
`EncryptedSharedPreferences`. Do not add a leftover-data copy helper
(`18-fresh-dynamics-install.md`). A runtime path still touching
SharedPreferences is **not** migrated and must not receive a `migrated`
disposition.

These semantics apply identically to every closure-gated domain. ICC
sharing paths that are replaced with `GDServiceClient.sendTo()` are
`migrated`; sharing paths whose feature is removed outright are
`removed`. Clipboard call sites replaced with `GDClipboardAdapter` or
`com.good.gd.content.ClipboardManager` are `migrated`; eliminated
clipboard utilities are `removed`.

## `migration-analysis.json` — `egressFeatures`

Prompt 00 also inventories **feature-level egress capabilities** that are not
well represented as a single API call-site migration. Examples:

- Android Auto Backup / app-level backup and restore
- public Downloads / Gallery / MediaStore export
- generic Android share sheet / open-with / external viewer
- FileProvider-based external sharing
- unmanaged printing
- unmanaged clipboard / drag-and-drop export
- unmanaged email / messaging / consumer-cloud export

Each entry belongs to one owning prompt (`05a`, `08`, `09`, or `10`) and must
have a stable `id` so later prompts and the final report can refer to the
same capability without re-inventing labels.

Minimum shape:

```json
{
  "id": "egress-share-main-001",
  "domain": "icc",
  "ownerPrompt": "08",
  "category": "generic-sharing",
  "featureName": "External file sharing",
  "recommendedOutcome": "BLOCKED_UNTIL_APPROVED",
  "userEntryPoint": "Share menu item",
  "targetMechanism": "ACTION_SEND + FileProvider",
  "sourceFiles": ["app/src/main/java/com/example/ShareHelper.kt"]
}
```

`recommendedOutcome` is the Prompt 00 recommendation. The **final**
implemented state lives in `migration-plan-state.json`
`egressFeatureDecisions[]`.

## `migration-plan-state.json` — `egressFeatureDecisions`

`egressFeatureDecisions[]` is the canonical feature-level outcome array for
container-boundary capabilities identified by Prompt 00. Prompts `05a`, `08`,
and `09` update this array as they strip, replace, block, or flag those
features.

Minimum shape:

```json
{
  "featureId": "egress-share-main-001",
  "domain": "icc",
  "outcome": "BLOCKED_UNTIL_APPROVED",
  "module": "app",
  "note": "Share sheet removed; FileProvider URI grants deleted; feature remains blocked until ICC runtime provider discovery flow is wired.",
  "secureAlternative": "AppKinetics ICC with runtime provider discovery/chooser",
  "uiDisposition": "disabled",
  "codePathReachable": false
}
```

### Egress outcome semantics

| `outcome` | Meaning |
|----------|---------|
| `REMOVE` | The unmanaged feature was stripped. Remove the UI action, implementation, helper code, permissions/providers/intent filters, and temp-file staging. |
| `REPLACE_WITH_DYNAMICS` | The original Android path was removed and replaced with an approved Dynamics-controlled boundary such as ICC or secure clipboard. |
| `MANUAL_INTERVENTION_REQUIRED` | The kit intentionally did not auto-preserve the original path. The report must explain the required product/policy decision and safe next options. |
| `BLOCKED_UNTIL_APPROVED` | The original path is disabled and unreachable. The capability may only return after explicit developer approval and a documented Dynamics-safe redesign. |

`uiDisposition` and `codePathReachable` are the anti-noop guardrails:

- `uiDisposition: "removed"` means the user-facing entry point is gone.
- `uiDisposition: "disabled"` means the entry point may remain visible but
  must be non-functional and clearly blocked.
- `uiDisposition: "replaced"` means the user now reaches a Dynamics-safe flow.
- `uiDisposition: "flagged"` is reserved for purely report-owned manual items
  that have no single in-app affordance to remove.

For `REMOVE` and `BLOCKED_UNTIL_APPROVED`, `codePathReachable` should be
`false`. Leaving the Android export/share/open-with implementation reachable
while calling the feature "removed" is a contract violation.

#### SAF decisions

When a disposition closes a SAF trust-boundary call site from prompt
`05a` or prompt `08`, include a structured `safDecision` object. Prompt
10 reads this object to generate report-only `safFindings[]` and
blocker `manualTodos[]`; it must not parse free-text `note` as the
machine contract.

Minimum shape:

```json
{
  "callSiteId": "saf-export-ReportViewModel-42",
  "domain": "secureFileStorage",
  "status": "removed",
  "module": "app",
  "note": "SAF_OUTBOUND_EXPORT | ACTION_CREATE_DOCUMENT | BLOCKED_PENDING_DEVELOPER_APPROVAL",
  "safDecision": {
    "classification": "SAF_OUTBOUND_EXPORT",
    "direction": "outbound",
    "migrationDecision": "BLOCKED_PENDING_DEVELOPER_APPROVAL",
    "developerApprovalRequested": true,
    "developerDecision": null,
    "decisionTimestamp": null,
    "uiEntryPoint": "Export button",
    "targetMechanism": "ACTION_CREATE_DOCUMENT",
    "runtimeDlpEnforced": false,
    "outboundCodeReachable": false,
    "uiDisposition": "disabled",
    "plaintextStagingRemoved": true
  }
}
```

Use `domain: "secureFileStorage"` for storage-owned SAF import/export,
external-primary-storage, and plaintext-staging call sites. Use
`domain: "icc"` for URI-sharing call sites (`ACTION_SEND`,
`ACTION_VIEW`, `EXTRA_STREAM`, URI grants, `FileProvider`) owned by
prompt `08`. `externalStorage` is a validator/security-blocker category,
not a `migration-plan-state.json` disposition domain.

#### `secureFileStorage`: type-and-stream closure (stream-layer rule)

A `secureFileStorage` call site may only be marked `migrated` when
**both** of the following are GD-backed:

1. The **`File` type** in scope at the call site is `com.good.gd.file.File`
   (not `java.io.File`), AND
2. The **stream layer** actually used to perform the read or write goes
   through `com.good.gd.file.FileInputStream` /
   `com.good.gd.file.FileOutputStream`, `GDFileSystem.openFileInput` /
   `openFileOutput`, or a wrapper helper (`SecureFileIO`) that delegates
   exclusively to those.

A call site whose `File` is GD-typed but whose write/read goes through
`kotlin.io` extensions (`writeText`, `readText`, `forEachLine`,
`writeBytes`, `copyRecursively`, `deleteRecursively`,
`bufferedReader()`, `inputStream()`, …), `java.nio.file.Files.*`,
`new FileReader/FileWriter/Scanner/PrintWriter/RandomAccessFile(...)`,
`BitmapFactory.decodeFile(...)`, or `Bitmap.compress(..., new
java.io.FileOutputStream(...))` is **not** migrated. The Kotlin
extensions are defined on `java.io.File`; `com.good.gd.file.File`
resolves through `java.io` interop, so these calls compile but silently
write to / read from an Android sandbox path. See
`steering/40-secure-file-storage.md` §5 for the canonical replacement
table.

`validate.sh` Phase 4 enforces this rule via the stream-layer
closure block, scoped to files importing `com.good.gd.file.*`. Both
prompts `05a` and `05b` include Phase 4 in their scoped check via
`tooling/check-prompt-map.json`, so agents can diagnose the issue early with
`validate.sh --check-prompt 05a` / `05b`. The shipped recorder enforces it
through prompt `10` final source validation.

---

## Prompt 10 closure gate

When **`record-prompt-execution.sh --status completed --prompt-id 10`** runs:

1. Load `migration-analysis.json`.
2. Select `executionPlan` rows where `promptId` matches and
   `applicable` is `true`.
3. Collect all `callSites[].id` from those rows (`callSites` missing
   treated as **error** — re-run prompt 00 with schema ≥ 1.2.0).
4. If there are **zero** call sites across those rows, closure passes
   (nothing to close).
5. Otherwise load `migration-plan-state.json`. Missing file → **exit 1**.
6. For every required `callSiteId`, require exactly one disposition with
   matching `callSiteId` and `domain`, and `status` in
   `migrated|removed`. Unknown status values and unknown fields are
   rejected by `record-prompt-execution.sh` and the validator.

On failure, the script **does not** write `bootstrap.json` and prints
**all** missing or invalid callSiteIds in a single message, grouped by
domain, with the expected JSON skeleton for each missing entry. This
applies equally to prompts 08 (icc) and 09 (secureUiWidgets,
secureClipboard): there is no separate ICC or clipboard error path.

Prompt `10` also validates feature-level egress closure:

1. Load `migration-analysis.json` `egressFeatures[]`.
2. Select rows owned by prompts that ran this migration (`05a`, `08`, `09`,
   plus any report-only items assigned to `10`).
3. Require exactly one matching `egressFeatureDecisions[]` entry per
   `featureId`, with a valid `outcome` and `uiDisposition`.
4. Reject `REMOVE` or `BLOCKED_UNTIL_APPROVED` entries when
   `codePathReachable` is `true`.
5. Reject `REPLACE_WITH_DYNAMICS` entries that omit `secureAlternative`.

Remediation hint printed during final closure:

```
❌ M2 closure failed:
   - missing disposition for callSiteId='icc-share-1' domain='icc'
   - missing disposition for callSiteId='icc-share-2' domain='icc'
   - missing disposition for callSiteId='clip-util-14' domain='secureClipboard'

   Expected dispositions[] entries (add to migration-plan-state.json):
   domain='icc':
     {"callSiteId": "icc-share-1", "domain": "icc", "status": "migrated", ...}
     {"callSiteId": "icc-share-2", "domain": "icc", "status": "migrated", ...}
   domain='secureClipboard':
     {"callSiteId": "clip-util-14", "domain": "secureClipboard", "status": "migrated", ...}

   Do NOT create custom top-level keys (e.g. iccDispositions, clipboardDispositions).
   Use dispositions[] — it is the canonical array for all closure-gated domains.
```

When an owning prompt is recorded with **`--status skipped`**, closure still
depends on the prompt-00 execution plan: a domain that is not applicable has
nothing to close, while an applicable domain must be closed or validly
deferred before prompt `10`.

---

## Recorder-owned validation

The recorder OWNS deterministic validation gates. Prompts with configured
`scopedChecks` run `validate.sh --check-prompt <id>` before their
`executedPrompts[]` entry is written; no-op prompts record without validation.
Prompt `10` then runs the final source/report acceptance gates, evaluates
`requires[]`, independent evidence, and closure completeness, and refuses to
record completion until those final checks pass. There is no
`--validate-result` flag on the recorder.

---

## Schema version

Bump `migration-analysis.json` **`schemaVersion` to `1.2.0`** when
`callSites` is present on execution plan rows. Older `1.1.0` files without
`callSites` will fail prompt `10` closure until prompt 00 is re-run.

Canonical schema file:

- `schemas/migration-plan-state.schema.v1.1.0.json`
