#!/usr/bin/env python3
"""Runtime loop-state recorder for bounded retry/escalation."""

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
    "00pre", "00", "00b", "01", "02", "03", "03b", "04", "05a", "05b",
    "05c", "05z", "06", "07", "08", "09", "11", "03c", "10", "12",
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


def save_json(path: str, payload: Dict[str, Any]) -> None:
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
    backup_path = f"{path}.bak"
    backup = load_json(backup_path)
    if isinstance(backup, dict):
        recovery_events.append(
            {
                "timestamp": now_iso(),
                "kind": "recovered-from-backup",
                "path": os.path.basename(backup_path),
            }
        )
        return backup, recovery_events
    if os.path.exists(path):
        recovery_events.append(
            {
                "timestamp": now_iso(),
                "kind": "corrupt-state-reset",
                "path": os.path.basename(path),
            }
        )
    return None, recovery_events


def normalize_message_prefix(message: Any) -> str:
    if not isinstance(message, str):
        return ""
    return message.strip().split(" — ", 1)[0][:160]


def signature_from_sidecar(sidecar: Dict[str, Any]) -> Tuple[Optional[Dict[str, Any]], Optional[str], Optional[str]]:
    violations = sidecar.get("violations")
    source_fp = None
    sf = sidecar.get("sourceFingerprints")
    if isinstance(sf, dict):
        source_fp = hashlib.sha256(
            json.dumps(sf, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()

    if isinstance(violations, list) and violations:
        parts: List[Dict[str, Any]] = []
        for v in violations:
            if not isinstance(v, dict):
                continue
            parts.append(
                {
                    "phase": v.get("phase") or "",
                    "domain": v.get("domain") or "",
                    "detector": v.get("detector") or "",
                    "category": v.get("category") or v.get("issue") or "",
                    "catalogRow": v.get("catalogRow") or "",
                    "file": v.get("file") or "",
                    "messagePrefix": normalize_message_prefix(v.get("message")),
                }
            )
        if parts:
            parts = sorted(parts, key=lambda p: json.dumps(p, sort_keys=True))
            signature: Dict[str, Any] = {"kind": "sidecar-violations", "parts": parts}
            digest = hashlib.sha256(
                json.dumps(signature, sort_keys=True, separators=(",", ":")).encode("utf-8")
            ).hexdigest()
            return signature, digest, source_fp

    fallback = {
        "kind": "sidecar-summary",
        "mode": sidecar.get("mode"),
        "promptId": sidecar.get("promptId"),
        "scope": sidecar.get("scope"),
        "status": sidecar.get("status"),
        "failCount": sidecar.get("failCount", 0),
    }
    digest = hashlib.sha256(
        json.dumps(fallback, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return fallback, digest, source_fp


def signature_from_gate(gate_id: str, message: str) -> Tuple[Dict[str, Any], str]:
    signature = {
        "kind": "recorder-gate",
        "gateId": gate_id or "recorder-gate",
        "messagePrefix": normalize_message_prefix(message),
    }
    digest = hashlib.sha256(
        json.dumps(signature, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return signature, digest


def resolve_policy(check_map: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    defaults: Dict[str, Any] = {
        "defaultMaxPromptFailures": 5,
        "defaultMaxIdenticalFailures": 3,
        "finalGateMaxIdenticalFailures": 2,
        "perPrompt": {},
    }
    if not isinstance(check_map, dict):
        return defaults
    rp = check_map.get("retryPolicy")
    if not isinstance(rp, dict):
        return defaults
    out = dict(defaults)
    for key in ("defaultMaxPromptFailures", "defaultMaxIdenticalFailures", "finalGateMaxIdenticalFailures"):
        val = rp.get(key)
        if isinstance(val, int) and val > 0:
            out[key] = val
    per_prompt = rp.get("perPrompt")
    if isinstance(per_prompt, dict):
        clean: Dict[str, Any] = {}
        for prompt_id, cfg in per_prompt.items():
            if not isinstance(prompt_id, str) or not isinstance(cfg, dict):
                continue
            m = cfg.get("maxIdenticalFailures")
            if isinstance(m, int) and m > 0:
                clean[prompt_id] = {"maxIdenticalFailures": m}
        out["perPrompt"] = clean
    return out


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
        "humanDecisions": {"backgroundAuthorizeDecisions": [], "deferredDomains": []},
        "deferrals": [],
        "promptReruns": {},
        "resumeInfo": {"completedPrompts": [], "nextPrompt": None},
        "terminalOutcome": None,
        "attempts": [],
        "escalations": [],
        "recoveryEvents": [],
    }


def next_prompt(completed: List[str]) -> Optional[str]:
    done = set(completed)
    for prompt in PROMPT_ORDER:
        if prompt not in done and prompt != "00b":
            return prompt
    return None


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
    state["resumeInfo"] = {
        "completedPrompts": completed,
        "nextPrompt": next_prompt(completed),
    }

    deferred = bootstrap.get("deferredDomains")
    clean_deferred = [d for d in deferred if isinstance(d, dict)] if isinstance(deferred, list) else []
    bg = bootstrap.get("backgroundAuthorize")
    bg_decisions = []
    if isinstance(bg, dict) and isinstance(bg.get("decisions"), list):
        bg_decisions = [d for d in bg["decisions"] if isinstance(d, dict)]
    state["deferrals"] = clean_deferred
    state["humanDecisions"] = {
        "deferredDomains": clean_deferred,
        "backgroundAuthorizeDecisions": bg_decisions,
    }


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
        new_state.setdefault("humanDecisions", {"backgroundAuthorizeDecisions": [], "deferredDomains": []})
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
            basis = {
                "phase": row.get("phase") or "",
                "domain": row.get("domain") or "",
                "severity": row.get("severity") or "",
                "messagePrefix": normalize_message_prefix(row.get("message")),
                "file": row.get("file") or row.get("files") or "",
            }
            digest = hashlib.sha256(
                json.dumps(basis, sort_keys=True, separators=(",", ":")).encode("utf-8")
            ).hexdigest()[:16]
            diagnostic_ids.append(f"diag-{digest}")
            for key in ("file", "files"):
                value = row.get(key)
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


def latest_attempt(attempts: List[Dict[str, Any]], prompt_id: str, stage: str) -> Optional[Dict[str, Any]]:
    for item in reversed(attempts):
        if item.get("promptId") == prompt_id and item.get("stage") == stage:
            return item
    return None


def identical_count(
    attempts: List[Dict[str, Any]],
    prompt_id: str,
    stage: str,
    failure_hash: str,
    source_changed: Optional[bool],
) -> int:
    if source_changed is False:
        # No-edit reruns are tracked but don't consume identical-failure budget.
        prior = [
            a
            for a in attempts
            if a.get("promptId") == prompt_id
            and a.get("stage") == stage
            and isinstance(a.get("failureHash"), str)
            and a.get("failureHash") == failure_hash
            and isinstance(a.get("retryBudget"), dict)
        ]
        if not prior:
            return 1
        return int(prior[-1]["retryBudget"].get("identicalFailureCount", 1))

    n = 0
    for a in attempts:
        if (
            a.get("promptId") == prompt_id
            and a.get("stage") == stage
            and isinstance(a.get("failureHash"), str)
            and a.get("failureHash") == failure_hash
        ):
            n += 1
    return n + 1


def prompt_failure_count(attempts: List[Dict[str, Any]], prompt_id: str) -> int:
    n = 0
    for a in attempts:
        if a.get("promptId") != prompt_id:
            continue
        if a.get("result") in ("failed", "configuration-error", "environment-error", "escalated"):
            n += 1
    return n + 1


def stage_limit(policy: Dict[str, Any], prompt_id: str, stage: str) -> Tuple[int, str]:
    per_prompt = policy.get("perPrompt", {})
    if isinstance(per_prompt, dict):
        p = per_prompt.get(prompt_id)
        if isinstance(p, dict):
            m = p.get("maxIdenticalFailures")
            if isinstance(m, int) and m > 0:
                return m, "per-prompt"
    if stage in ("source-gate", "report-gate"):
        m = policy.get("finalGateMaxIdenticalFailures")
        if isinstance(m, int) and m > 0:
            return m, "final-gate"
    m = policy.get("defaultMaxIdenticalFailures")
    return (m if isinstance(m, int) and m > 0 else 3), "default"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Record loop-state attempts.")
    parser.add_argument("--event", required=False, default="record", choices=["record", "terminal"])
    parser.add_argument("--platform", required=True, choices=["android", "ios"])
    parser.add_argument("--bootstrap", required=True)
    parser.add_argument("--check-map", required=False, default="")
    parser.add_argument("--loop-file", required=True)
    parser.add_argument("--toolkit-version", required=False, default="unknown")
    parser.add_argument("--prompt-id", required=True)
    parser.add_argument("--stage", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--sidecar", required=False, default="")
    parser.add_argument("--validation-run-id", required=False, default="")
    parser.add_argument("--gate-id", required=False, default="")
    parser.add_argument("--message", required=False, default="")
    parser.add_argument("--owner-prompt", required=False, default="")
    parser.add_argument("--failing-phase", required=False, default="")
    parser.add_argument("--failing-domain", required=False, default="")
    parser.add_argument("--suggested-command", required=False, default="")
    parser.add_argument("--safe-next-action", required=False, default="rerun-owner-prompt")
    parser.add_argument("--terminal-outcome", required=False, default="")
    parser.add_argument("--terminal-reason", required=False, default="")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    bootstrap = load_json(args.bootstrap) or {}
    check_map = load_json(args.check_map) if args.check_map else None
    policy = resolve_policy(check_map)
    run_id = bootstrap.get("runId") or (bootstrap.get("provenance") or {}).get("runId") or "unknown-run"

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
        save_json(args.loop_file, state)
        print(json.dumps({"deduped": False, "escalated": state["currentState"] == "escalated", "loopStatePath": args.loop_file}))
        return 0

    attempts = state.setdefault("attempts", [])
    escalations = state.setdefault("escalations", [])
    if not isinstance(attempts, list):
        attempts = []
        state["attempts"] = attempts
    if not isinstance(escalations, list):
        escalations = []
        state["escalations"] = escalations

    # Dedup validator-owned attempts.
    if args.validation_run_id:
        for a in attempts:
            if (
                a.get("validationRunId") == args.validation_run_id
                and a.get("promptId") == args.prompt_id
                and a.get("stage") == args.stage
            ):
                print(json.dumps({"deduped": True, "escalated": False}))
                return 0

    fail_count = 0
    warn_count = 0
    top_failures: List[str] = []
    failure_signature: Optional[Dict[str, Any]] = None
    failure_hash: Optional[str] = None
    source_fp: Optional[str] = None

    sidecar = load_json(args.sidecar) if args.sidecar else None
    diagnostic_ids, affected_files = diagnostics_from_sidecar(sidecar)
    if isinstance(sidecar, dict):
        fail_count = int(sidecar.get("failCount", 0) or 0)
        warn_count = int(sidecar.get("warnCount", 0) or 0)
        violations = sidecar.get("violations")
        if isinstance(violations, list):
            for v in violations[:5]:
                if isinstance(v, dict):
                    msg = v.get("message")
                    if isinstance(msg, str) and msg.strip():
                        top_failures.append(msg.strip()[:200])
        if args.result != "passed":
            failure_signature, failure_hash, source_fp = signature_from_sidecar(sidecar)
    elif args.result != "passed":
        failure_signature, failure_hash = signature_from_gate(args.gate_id, args.message)

    prev = latest_attempt(attempts, args.prompt_id, args.stage)
    prev_fp = prev.get("sourceFingerprint") if isinstance(prev, dict) else None
    source_changed: Optional[bool] = None
    if source_fp is not None:
        source_changed = prev_fp != source_fp
    source_changed_for_output = source_changed if isinstance(source_changed, bool) else True

    ident_count = 0
    threshold_type = "default"
    limit = 0
    remain = 0
    exhausted = False
    p_fail_count = 0

    if args.result == "passed":
        p_fail_count = 0
        limit, threshold_type = stage_limit(policy, args.prompt_id, args.stage)
        remain = limit
    else:
        p_fail_count = prompt_failure_count(attempts, args.prompt_id)
        if failure_hash:
            ident_count = identical_count(attempts, args.prompt_id, args.stage, failure_hash, source_changed)
        limit, threshold_type = stage_limit(policy, args.prompt_id, args.stage)
        remain = max(0, limit - ident_count)
        prompt_limit = int(policy.get("defaultMaxPromptFailures", 5) or 5)
        if source_changed is not False and failure_hash and ident_count >= limit:
            exhausted = True
        if p_fail_count >= prompt_limit:
            exhausted = True

    repair_feedback = {
        "ownerPrompt": args.owner_prompt or args.prompt_id,
        "failingPhase": args.failing_phase or None,
        "failingDomain": args.failing_domain or None,
        "affectedFiles": [],
        "suggestedCommand": args.suggested_command or None,
        "safeNextAction": args.safe_next_action,
    }

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
        "repairFeedback": repair_feedback,
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
            "identicalFailureCount": ident_count,
            "promptFailureCount": p_fail_count,
            "limit": limit if limit > 0 else 1,
            "remaining": remain,
            "thresholdType": threshold_type,
            "exhausted": exhausted,
        },
    }
    attempts.append(attempt)
    state["currentState"] = state_for_attempt(args.stage, args.result, exhausted)
    state["activePrompt"] = args.prompt_id

    escalation_payload: Optional[Dict[str, Any]] = None
    if exhausted:
        reason = "identical-failure-budget-exhausted"
        prompt_limit = int(policy.get("defaultMaxPromptFailures", 5) or 5)
        if p_fail_count >= prompt_limit and (not failure_hash or ident_count < limit):
            reason = "prompt-failure-budget-exhausted"
        if args.result in ("configuration-error", "environment-error"):
            reason = "environment-escalation"
        escalation_payload = {
            "escalationId": str(uuid.uuid4()),
            "timestamp": now_iso(),
            "promptId": args.prompt_id,
            "stage": args.stage,
            "failureHash": failure_hash,
            "reason": reason,
            "safeNextAction": args.safe_next_action,
            "message": args.message or None,
        }
        escalations.append(escalation_payload)

    save_json(args.loop_file, state)
    print(
        json.dumps(
            {
                "deduped": False,
                "escalated": exhausted,
                "escalation": escalation_payload,
                "loopStatePath": args.loop_file,
            }
        )
    )
    return 3 if exhausted else 0


if __name__ == "__main__":
    raise SystemExit(main())
