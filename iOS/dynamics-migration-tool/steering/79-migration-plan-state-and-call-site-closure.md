# Steering: Migration Plan State and Call-Site Closure

The iOS migration system requires a per-call-site closure ledger
(`migration-plan-state.json`) that joins prompt-00 inventory evidence to
per-domain prompt completion. Prompt 10 cannot generate a successful
migration report until the ledger is complete.

---

## Closure Principle

An applicable migration domain is closed only when:

1. Prompt 00 found the domain applicable and emitted call-site IDs in
   `migration-analysis.json` `executionPlan[].callSites[]`.
2. The owning prompt processed every call site and wrote a disposition.
3. Every disposition is one of: `migrated`, `removed`, `blocked`,
   `deferred`, or `notApplicable` (with evidence).
4. The validator's prompt-scoped check passes for that prompt.
5. The final full validation passes.
6. Prompt 10 confirms the same state with run-ID-matched provenance.

---

## Ledger Location

`dynamics-migration-tool/output/migration-plan-state.json`

Schema: `schemas/migration-plan-state.schema.v1.0.0.json`

---

## Call-Site ID Stability

Call-site IDs assigned by prompt 00 must be:

- Deterministic for unchanged source (`{domain}:{relative-path}:{line}` or similar)
- Stable across prompt re-runs where the underlying code has not changed
- Unique within a single run

If source changes cause an ID to become invalid, prompt 00 must be re-run
to produce a fresh inventory. The recorder rejects unknown call-site IDs.

---

## Disposition Rules

| Status | When to use | Blocks final report? |
|--------|-------------|----------------------|
| `migrated` | Source now uses the Dynamics-backed pattern | No |
| `removed` | Feature or call path is deleted/unreachable | No |
| `blocked` | Migration cannot safely proceed without a product/security decision | Yes |
| `deferred` | Developer-approved deferral with rationale (non-security only) | Yes in this tranche |
| `notApplicable` | Proven irrelevant for sensitive Dynamics data (must include evidence) | No |

### Allowed disposition transitions

| From | To |
|------|-----|
| `deferred` | `migrated`, `removed`, `notApplicable`, `blocked`, `deferred` |
| `blocked` | `removed`, `migrated`, `notApplicable`, `blocked` (when product deletion or redesign is evidenced) |
| `migrated` / `removed` / `notApplicable` | same status only (idempotent refresh) |

Do **not** invent a new call-site ID solely to escape a frozen `blocked` row —
prefer `blocked → removed` / `blocked → migrated` via the atomic updater with
rationale + evidence.

### `blocked`
A `blocked` disposition means a hard security or architectural blocker
prevents migration **until** the product path is removed or redesigned.
While active it must appear as a `blockingItem` and usually forces
`releaseReadiness.recommendation` to `no-go`. It may later transition to
`removed` or `migrated` with evidence (see transitions above).

### `deferred`
`deferred` in this tranche blocks the final report unless the deferral
mechanism is explicitly approved as non-security. Agents must NOT use
`deferred` to escape sensitive call sites that should be migrated.

### `notApplicable`
Requires:
- Evidence that the call site never handles sensitive data, OR
- Evidence that the call path is unreachable from any sensitive data flow
  
Must never be used as a generic escape hatch.

---

## How Domain Prompts Update the Ledger

Each domain prompt is responsible for updating the ledger for its owned
domain. The update contract is:

```json
{
  "callSiteId": "<stable-id-from-analysis>",
  "domainId": "<domain>",
  "promptId": "<prompt-id>",
  "status": "migrated | removed | blocked | deferred | notApplicable",
  "evidence": {
    "changedFiles": ["relative/path/File.swift"],
    "proofOfRemoval": null,
    "validationResult": "prompt-scoped pass from .last-check.json",
    "notes": "optional notes"
  },
  "rationale": null,
  "timestamp": "<ISO-8601>",
  "runId": "<must-match-bootstrap-runId>"
}
```

**Write method:** Use
`tooling/update-migration-plan-state.py` as the only supported mutation path.
Do not patch, append, or hand-edit `migration-plan-state.json`.

---

## Validation Enforcement

The validator (validate.sh) checks:

- Every call site in applicable domains has exactly one active disposition
- No unknown call-site IDs (IDs not in the current analysis inventory)
- No duplicate active dispositions for the same call-site ID
- `blocked` dispositions produce validation blockers
- `runId` in each disposition matches the current run
- Storage contract closure for `secureSql`, `secureCoreData`, and
  `secureFileStorage` (writer + reader/follow-on coverage, SwiftData block
  handling, Keychain/local-crypto decision evidence, sensitive path closure)
- Tranche-5 closure for `dlpPasteboard`, `icc`, and `policyManagement`
  (direction taxonomy, inbound secure copy, outbound egress closure, AppKinetics
  source/plist closure, residual URL/share closure, policy timing/cache/update closure)

The recorder (record-prompt-execution.sh) checks:

- All applicable call sites owned by the prompt have valid dispositions
  before marking the prompt `completed`
- Stale run IDs in dispositions fail the gate
- Prompt-level non-waivable blocker policies from `check-prompt-map.json`
  (for Tranche 3 storage prompts, `blocked` and `deferred` block completion)
- Prompt 08/09/09b scoped validation proof includes the exact required tranche-5 phases

---

## Prompt 10 Final Gate

Prompt 10 reads the ledger and enforces:

- No call site in any applicable domain lacks a disposition
- No `blocked` disposition exists
- `deferred` dispositions are recorded as `blockingItems` in this tranche
- `runId` in ledger matches `bootstrap.json.runId`

If any gate fails, prompt 10 must NOT write a `migration-report.json`.

---

## Example: Minimal Ledger

```json
{
  "schemaVersion": "1.0.0",
  "platform": "ios",
  "runId": "3f7a1b9c-...",
  "updatedAt": "2026-06-23T12:00:00Z",
  "dispositions": [
    {
      "callSiteId": "secureFileStorage:Sources/DataManager.swift:42",
      "domainId": "secureFileStorage",
      "promptId": "05",
      "status": "migrated",
      "evidence": {
        "changedFiles": ["Sources/DataManager.swift"],
        "proofOfRemoval": null,
        "validationResult": "prompt-scoped:05:pass",
        "notes": "FileManager.default replaced with GDFileManager.default"
      },
      "rationale": null,
      "timestamp": "2026-06-23T13:15:00Z",
      "runId": "3f7a1b9c-..."
    }
  ]
}
```
