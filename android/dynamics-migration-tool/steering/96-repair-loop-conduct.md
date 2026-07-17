# Steering: Bounded Repair-Loop Conduct

This steering file defines **how the migration agent drives the optional
bounded repair loop** (`tooling/repair-orchestrator.sh`). The orchestrator is a
deterministic, non-editing control plane. It runs the recorder and the
prompt-scoped validator, parses structured diagnostics, enforces budgets, and
writes a bounded repair task. **The agent is the actuator** that applies the
repair. Neither the orchestrator nor the agent may override a deterministic
validator or conceal an unresolved failure.

The loop is optional and risk-based. Use it for the controlled implementation
and configuration prompts where a scoped validator owns a clear failure. Do not
wrap analysis, diagram, retrospective, or final-acceptance prompts in it.

**Boundary invariant:** final acceptance authority remains
`tooling/record-prompt-execution.sh` (especially prompt `10` split
`final-source` + `report` gates). The orchestrator cannot and does not
replace that acceptance path.

---

## The Exit-Code Contract (authoritative)

`repair-orchestrator.sh --prompt-id <id>` returns:

- **`0` — passed.** The recorder recorded the prompt and the scoped validator
  passed. Move to the next prompt. Do nothing else.
- **`1` — repair task created.** A blocking diagnostic exists and a bounded
  repair is permitted. Read `output/repair-task.md` (and `repair-task.json`),
  apply **only** the owning prompt's guidance to the affected files, then
  **re-invoke the orchestrator for the same prompt**. This is one loop turn.
- **`3` — escalated. STOP.** The orchestrator hit a budget, detected
  no-progress, or routed an owner-owned decision. Do not retry. Surface the
  escalation reason to the developer and route to the human-decision state.

The orchestrator persists state across invocations in
`output/repair-orchestrator-state.json` (working ledger) and reflects terminal
escalations into `output/migration-loop-state.json` (durable single source).
Because budgets and no-progress detection are evaluated across invocations,
**you must re-invoke rather than re-implement from memory** — that is how the
loop stays bounded.

---

## The Loop (exactly this, nothing more)

For each controlled prompt:

1. Run `bash ./dynamics-migration-tool/tooling/repair-orchestrator.sh --prompt-id <id>`.
2. On `0`: continue to the next prompt.
3. On `1`:
   - Open `output/repair-task.md`.
   - If `automaticRepairProhibited` is `true` or `humanJudgmentRequired` is
     `true`: **stop and escalate** (treat as `3`). Do not approve, defer,
     redesign a trust boundary, or fix an environment-owned failure on the
     developer's behalf.
   - Otherwise apply the `owningPrompt` migration guidance to the listed files
     only. Preserve end-to-end behavior. Do not edit the report or the
     validator to make the check pass.
   - Re-invoke step 1 for the same prompt.
4. On `3`: stop, report the `escalationReason`, and hand the decision to the
   developer.

If the target prompt is outside the controlled subset (for example prompt `10`),
do not force it through Stage 7. Run the owning recorder flow directly and
respect its deterministic gate outcome.

The orchestrator already enforces: max attempts per prompt, max attempts per
diagnostic fingerprint, a run-wide repair budget, repeated-diagnostic
detection, and no-progress detection (unchanged diagnostic fingerprint **and**
unchanged repository diff). You do not re-implement these; you obey the exit
code.

---

## Escalation Reasons

The orchestrator emits one of:

- `human-decision-required` / `automatic-repair-prohibited` — a developer or
  security owner must decide.
- `redesign-required` — no safe 1:1 replacement; a principled redesign is
  needed.
- `environment-fix-required` — a build/dependency/environment failure the
  toolkit must not paper over.
- `manual-review-required` — the failure is not a safe deterministic repair.
- `prompt-attempt-budget-exhausted`, `diagnostic-attempt-budget-exhausted`,
  `run-repair-budget-exhausted`, `no-progress` — bounded retry gave up.

All of these mean **stop and involve a human**. None of them authorize the
agent to weaken a check.

---

## Hard Prohibitions

The repair loop must never:

- Retry indefinitely or ignore a `3`.
- Re-run unrelated prompts to "shake loose" a failure.
- Override or edit a deterministic validator.
- Approve, defer, or synthesize a Dynamics trust-boundary decision.
- Modify `migration-report.json` to hide an unresolved failure.
- Change application behavior merely to satisfy a check.

---

## Maturity Status

The repair loop is **maturing**, not production-default. It is an optional,
controlled lane that requires the agent to apply repairs and a human to resolve
escalations. It is not autonomous, hands-off repair. Keep it scoped to the
controlled prompt set until benchmark evidence justifies broader use.
