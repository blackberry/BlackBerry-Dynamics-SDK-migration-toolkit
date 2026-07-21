## Task: Managed Policy Migration Chain

Goal: Close managed policy migration for iOS by ensuring policy reads are
post-authorization, update events are handled, unmanaged caches are removed,
and policy-dependent features (DLP/export/ICC) re-evaluate on change.

**Prerequisites**:
- Prompts 00-03b and 09 are complete
- Prompt 00 identified policy/config call sites

**Skip this prompt only if** the `policyManagement` domain is genuinely
not-applicable with evidence in `migration-analysis.json`.

---

## SDK Header Verification (Mandatory Before Changes)

Before editing code, verify policy APIs and update symbols in installed SDK
headers:

```bash
rg "getApplicationConfig|getApplicationPolicy|getApplicationPolicyString|GDAppEventPolicyUpdate|getServiceProvidersFor" \
  Pods/BlackBerryDynamics --include="*.h" -n
rg "GDPolicyUpdateNotification|GDKeyIsAuthorized|GDStateChangeNotification" \
  Pods/BlackBerryDynamics --include="*.h" -n
```

Confirm exact symbols against:
- `GDiOS.h`
- `GDState.h`

Do not invent alternate policy APIs.

---

## Steps

### 1. Inventory policy sources and consumers

From Prompt 00 call sites, identify:
- app-defined config in `UserDefaults`, local plist/json files, or hard-coded defaults
- `getApplicationConfig()`, `getApplicationPolicy()`, `getApplicationPolicyString()`
- policy-driven feature toggles for DLP/export/AppKinetics behavior
- policy update handling (`GDAppEventPolicyUpdate`, `GDPolicyUpdateNotification`)

### 2. Enforce post-authorization policy reads

Policy reads that affect protected behavior must happen only after Dynamics
authorization is complete.

Required outcomes:
- move pre-auth reads behind authorized callbacks/state gates
- mark unresolved pre-auth reads as `blocked` with explicit rationale

### 3. Add/update policy update handling

Implement at least one verified update path:
- `handleEvent` branch for `GDAppEventPolicyUpdate`, and/or
- `NotificationCenter` observer for `GDPolicyUpdateNotification`

On update, re-evaluate:
- outbound export decisions
- ICC availability/registration assumptions
- feature flags based on policy values

### 4. Remove unmanaged policy caches

For sensitive policy state:
- remove stale `UserDefaults`/unmanaged-file caches, or
- redesign to avoid persistent unmanaged cache

If temporary cache cannot be removed safely in this tranche, mark the call
site as `blocked` and capture design evidence.

### 5. Define defaults and missing-key behavior

For each policy-controlled feature:
- document default when key is absent
- use secure default-safe behavior (deny/disable export-sensitive behavior)
- record fallback semantics in evidence notes

### 6. Build and verify

Run `xcodebuild` and classify failures as pre-existing, migration-introduced,
or unrelated.

---

## Closure Ledger Update (Required)

Before recording Prompt 09b as `completed`, write call-site dispositions for
the `policyManagement` domain using the atomic updater:

```bash
python3 dynamics-migration-tool/tooling/update-migration-plan-state.py \
  --analysis dynamics-migration-tool/output/migration-analysis.json \
  --plan dynamics-migration-tool/output/migration-plan-state.json \
  --run-id "<run-id-from-output/bootstrap.json>" \
  --prompt-id "09b" \
  --domain-id "policyManagement" \
  --updates-file /tmp/policy-management-updates.json
```

Do not edit `migration-plan-state.json` directly.

---

## Scoped Validation (Required)

Run scoped validation for this prompt before recorder completion:

```bash
bash ./dynamics-migration-tool/tooling/validate.sh --check-prompt 09b
```

Prompt completion must fail if scoped proof is missing, stale, or failing.

---

## Output

- Policy reads moved to post-auth boundaries (or blocked with rationale)
- Policy update handling implemented and connected to feature re-evaluation
- Unmanaged sensitive policy caches removed or blocked with evidence
- Defaults/fallback semantics documented
- `policyManagement` call sites dispositioned in ledger
- Scoped validation result captured
