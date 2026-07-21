#!/usr/bin/env python3
"""Runtime loop-state recorder for bounded retry/escalation (iOS)."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
import time
import uuid
from typing import Any, Dict, List, Optional, Tuple

SCHEMA_VERSION = "1.1.0"

PROMPT_ORDER = [
    "00", "00b", "01", "02", "03", "03b", "04", "04b", "05",
    "06", "07", "08", "09", "09b", "10",
]


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def load_json(path: str) -> Optional[Dict[str, Any]]:
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else None
    except Exception:
        return None


def write_json(path: str, payload: Dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    backup_path = f"{path}.bak"
    if os.path.isfile(path) and isinstance(load_json(path), dict):
        try:
            shutil.copy2(path, backup_path)
        except Exception:
            pass
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        delete=False,
        dir=os.path.dirname(path),
        prefix=f"{os.path.basename(path)}.tmp.",
    ) as f:
        json.dump(payload, f, indent=2, sort_keys=True)
        f.write("\n")
        tmp_path = f.name
    os.replace(tmp_path, path)
    try:
        shutil.copy2(path, backup_path)
    except Exception:
        pass


def load_state(path: str) -> Tuple[Optional[Dict[str, Any]], List[Dict[str, Any]]]:
    recovery_events: List[Dict[str, Any]] = []
    state = load_json(path)
    if isinstance(state, dict):
        return state, recovery_events
    backup = load_json(f"{path}.bak")
    if isinstance(backup, dict):
        recovery_events.append({"timestamp": now_iso(), "kind": "recovered-from-backup", "path": os.path.basename(f"{path}.bak")})
        return backup, recovery_events
    if os.path.exists(path):
        recovery_events.append({"timestamp": now_iso(), "kind": "corrupt-state-reset", "path": os.path.basename(path)})
    return None, recovery_events


def next_prompt(completed: List[str]) -> Optional[str]:
    done = set(completed)
    for prompt in PROMPT_ORDER:
        if prompt not in done:
            return prompt
    return None


def reset_state(run_id: str, platform: str, toolkit_version: str, policy: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "platform": platform,
        "activePlatform": platform,
        "activePrompt": None,
        "currentState": "discover",
        "runId": run_id,
        "toolkitVersion": toolkit_version,
        "policySource": "tooling/check-prompt-map.json#retryPolicy",
        "resolvedPolicy": policy,
        "humanDecisions": {"deferredDomains": [], "backgroundAuthorizeDecisions": []},
        "deferrals": [],
        "promptReruns": {},
        "resumeInfo": {"completedPrompts": [], "nextPrompt": None},
        "terminalOutcome": None,
        "attempts": [],
        "escalations": [],
        "recoveryEvents": [],
    }


def refresh_state_metadata(state: Dict[str, Any], bootstrap: Dict[str, Any], platform: str, prompt_id: str) -> None:
    state["activePlatform"] = platform
    state["activePrompt"] = prompt_id
    executed = bootstrap.get("executedPrompts")
    completed: List[str] = []
    reruns: Dict[str, int] = {}
    if isinstance(executed, list):
        for row in executed:
            if not isinstance(row, dict):
                continue
            pid = row.get("promptId")
            if not isinstance(pid, str) or not pid:
                continue
            reruns[pid] = reruns.get(pid, 0) + 1
            if row.get("status") in ("completed", "not-applicable") and pid not in completed:
                completed.append(pid)
    state["promptReruns"] = {k: v for k, v in sorted(reruns.items()) if v > 1}
    state["resumeInfo"] = {"completedPrompts": completed, "nextPrompt": next_prompt(completed)}
    state["humanDecisions"] = {"deferredDomains": [], "backgroundAuthorizeDecisions": []}
    state["deferrals"] = []


def migrate_state(
    state: Optional[Dict[str, Any]],
    run_id: str,
    platform: str,
    toolkit_version: str,
    policy: Dict[str, Any],
    recovery_events: List[Dict[str, Any]],
) -> Dict[str, Any]:
    if not isinstance(state, dict) or state.get("runId") != run_id:
        new_state = reset_state(run_id, platform, toolkit_version, policy)
    else:
        new_state = state
        new_state["schemaVersion"] = SCHEMA_VERSION
        new_state.setdefault("platform", platform)
        new_state.setdefault("activePlatform", platform)
        new_state.setdefault("activePrompt", None)
        new_state.setdefault("currentState", "discover")
        new_state.setdefault("humanDecisions", {"deferredDomains": [], "backgroundAuthorizeDecisions": []})
        new_state.setdefault("deferrals", [])
        new_state.setdefault("promptReruns", {})
        new_state.setdefault("resumeInfo", {"completedPrompts": [], "nextPrompt": None})
        new_state.setdefault("terminalOutcome", None)
        new_state.setdefault("attempts", [])
        new_state.setdefault("escalations", [])
        new_state.setdefault("recoveryEvents", [])
    new_state["resolvedPolicy"] = policy
    new_state["toolkitVersion"] = toolkit_version
    if recovery_events:
        existing = new_state.get("recoveryEvents")
        if not isinstance(existing, list):
            existing = []
        existing.extend(recovery_events)
        new_state["recoveryEvents"] = existing
    return new_state


def diagnostics_from_sidecar(sidecar: Optional[Dict[str, Any]]) -> Tuple[List[str], List[str]]:
    if not isinstance(sidecar, dict):
        return [], []
    diagnostic_ids: List[str] = []
    files: List[str] = []
    violations = sidecar.get("violations")
    if isinstance(violations, list):
        for row in violations:
            if not isinstance(row, dict):
                continue
            msg = str(row.get("message") or "").strip().split(" — ", 1)[0][:160]
            basis = {
                "severity": row.get("severity") or "",
                "phase": row.get("phase") or "",
                "domain": row.get("domain") or "",
                "messagePrefix": msg,
            }
            digest = hashlib.sha256(json.dumps(basis, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()[:16]
            diagnostic_ids.append(f"diag-{digest}")
            value = row.get("file") or row.get("files")
            if isinstance(value, str) and value and value not in files:
                files.append(value)
            elif isinstance(value, list):
                for item in value:
                    if isinstance(item, str) and item and item not in files:
                        files.append(item)
    return diagnostic_ids, files


def state_for_attempt(stage: str, result: str, exhausted: bool) -> str:
    if exhausted or result != "passed":
        return "repair-or-escalate"
    if stage == "report-gate":
        return "report"
    if stage in ("source-gate", "validation"):
        return "verify"
    return "execute"


def signature_from_sidecar(sidecar: Dict[str, Any]) -> Tuple[Dict[str, Any], str, Optional[str], List[str], int, int]:
    fails = int(sidecar.get("failCount", 0) or 0)
    warns = int(sidecar.get("warnCount", 0) or 0)
    top: List[str] = []

    violations = sidecar.get("violations")
    if isinstance(violations, list):
        normalized = []
        for row in violations:
            if not isinstance(row, dict):
                continue
            msg = str(row.get("message") or "").strip()
            if msg and len(top) < 5:
                top.append(msg[:200])
            normalized.append(
                {
                    "severity": row.get("severity") or "",
                    "phase": row.get("phase") or "",
                    "domain": row.get("domain") or "",
                    "messagePrefix": msg.split(" — ", 1)[0][:160],
                }
            )
        if normalized:
            normalized = sorted(normalized, key=lambda x: json.dumps(x, sort_keys=True))
            sig = {"kind": "sidecar-violations", "parts": normalized}
            digest = hashlib.sha256(json.dumps(sig, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
            src_fp = None
            sf = sidecar.get("sourceFingerprints")
            if isinstance(sf, dict):
                src_fp = hashlib.sha256(
                    json.dumps(sf, sort_keys=True, separators=(",", ":")).encode("utf-8")
                ).hexdigest()
            return sig, digest, src_fp, top, fails, warns

    errors = sidecar.get("errors") if isinstance(sidecar.get("errors"), list) else []
    blockers = sidecar.get("blockers") if isinstance(sidecar.get("blockers"), list) else []
    sig = {
        "kind": "sidecar-summary",
        "validationMode": sidecar.get("validationMode"),
        "promptScope": sidecar.get("promptScope"),
        "phasesExecuted": sidecar.get("phasesExecuted") or [],
        "errors": sorted(str(e) for e in errors if isinstance(e, str)),
        "blockers": sorted(str(b) for b in blockers if isinstance(b, str)),
    }
    digest = hashlib.sha256(json.dumps(sig, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
    src_fp = None
    sf = sidecar.get("sourceFingerprints")
    if isinstance(sf, dict):
        src_fp = hashlib.sha256(
            json.dumps(sf, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
    if not top:
        top = [str(e)[:200] for e in errors[:5] if isinstance(e, str)]
    return sig, digest, src_fp, top, fails, warns


def signature_from_gate(gate_id: str, message: str) -> Tuple[Dict[str, Any], str]:
    sig = {
        "kind": "recorder-gate",
        "gateId": gate_id or "recorder-gate",
        "messagePrefix": (message or "").strip().split(" — ", 1)[0][:160],
    }
    digest = hashlib.sha256(json.dumps(sig, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
    return sig, digest


def parse_policy(check_map: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    base = {
        "defaultMaxPromptFailures": 5,
        "defaultMaxIdenticalFailures": 3,
        "finalGateMaxIdenticalFailures": 2,
        "perPrompt": {},
    }
    if not isinstance(check_map, dict):
        return base
    rp = check_map.get("retryPolicy")
    if not isinstance(rp, dict):
        return base
    out = dict(base)
    for key in ("defaultMaxPromptFailures", "defaultMaxIdenticalFailures", "finalGateMaxIdenticalFailures"):
        v = rp.get(key)
        if isinstance(v, int) and v > 0:
            out[key] = v
    if isinstance(rp.get("perPrompt"), dict):
        clean = {}
        for pid, cfg in rp["perPrompt"].items():
            if isinstance(pid, str) and isinstance(cfg, dict):
                m = cfg.get("maxIdenticalFailures")
                if isinstance(m, int) and m > 0:
                    clean[pid] = {"maxIdenticalFailures": m}
        out["perPrompt"] = clean
    return out


def stage_limit(policy: Dict[str, Any], prompt_id: str, stage: str) -> Tuple[int, str]:
    per = policy.get("perPrompt")
    if isinstance(per, dict):
        cfg = per.get(prompt_id)
        if isinstance(cfg, dict):
            m = cfg.get("maxIdenticalFailures")
            if isinstance(m, int) and m > 0:
                return m, "per-prompt"
    if stage in ("source-gate", "report-gate"):
        m = policy.get("finalGateMaxIdenticalFailures")
        if isinstance(m, int) and m > 0:
            return m, "final-gate"
    m = policy.get("defaultMaxIdenticalFailures")
    return (m if isinstance(m, int) and m > 0 else 3), "default"


def dedup_exists(attempts: List[Dict[str, Any]], run_id: str, prompt_id: str, stage: str) -> bool:
    for a in attempts:
        if a.get("validationRunId") == run_id and a.get("promptId") == prompt_id and a.get("stage") == stage:
            return True
    return False


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    p.add_argument("--event", default="record", choices=["record", "terminal"])
    p.add_argument("--platform", required=True, choices=["ios"])
    p.add_argument("--bootstrap", required=True)
    p.add_argument("--check-map", default="")
    p.add_argument("--loop-file", required=True)
    p.add_argument("--toolkit-version", default="unknown")
    p.add_argument("--prompt-id", required=True)
    p.add_argument("--stage", required=True)
    p.add_argument("--result", required=True)
    p.add_argument("--sidecar", default="")
    p.add_argument("--validation-run-id", default="")
    p.add_argument("--gate-id", default="")
    p.add_argument("--message", default="")
    p.add_argument("--owner-prompt", default="")
    p.add_argument("--failing-phase", default="")
    p.add_argument("--failing-domain", default="")
    p.add_argument("--suggested-command", default="")
    p.add_argument("--safe-next-action", default="rerun-owner-prompt")
    p.add_argument("--terminal-outcome", default="")
    p.add_argument("--terminal-reason", default="")
    return p


def main() -> int:
    args = parser().parse_args()
    bootstrap = load_json(args.bootstrap) or {}
    check_map = load_json(args.check_map) if args.check_map else None
    policy = parse_policy(check_map)
    run_id = bootstrap.get("runId") or "unknown-run"

    loaded_state, recovery_events = load_state(args.loop_file)
    state = migrate_state(loaded_state, run_id, args.platform, args.toolkit_version, policy, recovery_events)
    refresh_state_metadata(state, bootstrap, args.platform, args.prompt_id)

    if args.event == "terminal":
        outcome = args.terminal_outcome or args.result
        state["currentState"] = outcome if outcome in ("success", "blocked", "escalated", "cancelled", "aborted") else "aborted"
        state["activePrompt"] = args.prompt_id
        state["terminalOutcome"] = {
            "timestamp": now_iso(),
            "outcome": state["currentState"],
            "promptId": args.prompt_id,
            "reason": args.terminal_reason or args.message or None,
        }
        write_json(args.loop_file, state)
        print(json.dumps({"deduped": False, "escalated": state["currentState"] == "escalated", "loopStatePath": args.loop_file}))
        return 0

    attempts = state.get("attempts")
    if not isinstance(attempts, list):
        attempts = []
        state["attempts"] = attempts
    escalations = state.get("escalations")
    if not isinstance(escalations, list):
        escalations = []
        state["escalations"] = escalations

    if args.validation_run_id and dedup_exists(attempts, args.validation_run_id, args.prompt_id, args.stage):
        print(json.dumps({"deduped": True, "escalated": False}))
        return 0

    fail_count = 0
    warn_count = 0
    top_failures: List[str] = []
    failure_signature = None
    failure_hash = None
    source_fp = None

    sidecar = load_json(args.sidecar) if args.sidecar else None
    diagnostic_ids, affected_files = diagnostics_from_sidecar(sidecar)
    if args.result != "passed":
        if isinstance(sidecar, dict):
            failure_signature, failure_hash, source_fp, top_failures, fail_count, warn_count = signature_from_sidecar(sidecar)
        else:
            failure_signature, failure_hash = signature_from_gate(args.gate_id, args.message)

    prior = None
    for a in reversed(attempts):
        if a.get("promptId") == args.prompt_id and a.get("stage") == args.stage:
            prior = a
            break
    source_changed = None
    if source_fp is not None and isinstance(prior, dict):
        source_changed = prior.get("sourceFingerprint") != source_fp
    source_changed_for_output = source_changed if isinstance(source_changed, bool) else True

    limit, threshold_type = stage_limit(policy, args.prompt_id, args.stage)
    prompt_limit = int(policy.get("defaultMaxPromptFailures", 5) or 5)

    prompt_failures = 0
    for a in attempts:
        if a.get("promptId") == args.prompt_id and a.get("result") in ("failed", "configuration-error", "environment-error", "escalated"):
            prompt_failures += 1
    if args.result != "passed":
        prompt_failures += 1

    identical = 0
    if failure_hash:
        if source_changed is False:
            for a in reversed(attempts):
                if (
                    a.get("promptId") == args.prompt_id
                    and a.get("stage") == args.stage
                    and a.get("failureHash") == failure_hash
                    and isinstance(a.get("retryBudget"), dict)
                ):
                    identical = int(a["retryBudget"].get("identicalFailureCount", 1))
                    break
            if identical == 0:
                identical = 1
        else:
            for a in attempts:
                if a.get("promptId") == args.prompt_id and a.get("stage") == args.stage and a.get("failureHash") == failure_hash:
                    identical += 1
            identical += 1

    exhausted = False
    if args.result != "passed" and failure_hash and source_changed is not False and identical >= limit:
        exhausted = True
    if args.result != "passed" and prompt_failures >= prompt_limit:
        exhausted = True

    attempt = {
        "attemptId": str(uuid.uuid4()),
        "attemptNumber": len(attempts) + 1,
        "timestamp": now_iso(),
        "promptId": args.prompt_id,
        "domainIds": [args.failing_domain] if args.failing_domain else [],
        "phaseIds": [args.failing_phase] if args.failing_phase else [],
        "stage": args.stage,
        "result": "escalated" if exhausted else args.result,
        "validationRunId": args.validation_run_id or None,
        "gateId": args.gate_id or None,
        "sidecarPath": args.sidecar or None,
        "failureHash": failure_hash,
        "failureSignature": failure_signature,
        "diagnosticIds": diagnostic_ids,
        "sourceFingerprint": source_fp,
        "sourceChangedSincePrev": source_changed_for_output,
        "failCount": fail_count,
        "warnCount": warn_count,
        "topFailures": top_failures,
        "filesAffected": affected_files,
        "repairFeedback": {
            "ownerPrompt": args.owner_prompt or args.prompt_id,
            "failingPhase": args.failing_phase or None,
            "failingDomain": args.failing_domain or None,
            "affectedFiles": [],
            "suggestedCommand": args.suggested_command or None,
            "safeNextAction": args.safe_next_action,
        },
        "repairStrategy": {
            "selected": args.safe_next_action,
            "automaticRepair": False,
            "result": None,
        },
        "validationResult": {
            "validationRunId": args.validation_run_id or None,
            "result": args.result,
            "failCount": fail_count,
            "warnCount": warn_count,
            "sidecarPath": args.sidecar or None,
        },
        "retryBudget": {
            "identicalFailureCount": identical,
            "promptFailureCount": prompt_failures,
            "limit": limit,
            "remaining": max(0, limit - identical),
            "thresholdType": threshold_type,
            "exhausted": exhausted,
        },
    }
    attempts.append(attempt)
    state["currentState"] = state_for_attempt(args.stage, args.result, exhausted)
    state["activePrompt"] = args.prompt_id

    escalation = None
    if exhausted:
        reason = "identical-failure-budget-exhausted"
        if prompt_failures >= prompt_limit and (not failure_hash or identical < limit):
            reason = "prompt-failure-budget-exhausted"
        if args.result in ("configuration-error", "environment-error"):
            reason = "environment-escalation"
        escalation = {
            "escalationId": str(uuid.uuid4()),
            "timestamp": now_iso(),
            "promptId": args.prompt_id,
            "stage": args.stage,
            "failureHash": failure_hash,
            "reason": reason,
            "safeNextAction": args.safe_next_action,
            "message": args.message or None,
        }
        escalations.append(escalation)

    write_json(args.loop_file, state)
    print(json.dumps({"deduped": False, "escalated": exhausted, "escalation": escalation}))
    return 3 if exhausted else 0


if __name__ == "__main__":
    raise SystemExit(main())
