#!/usr/bin/env python3
"""Bounded repair-loop state and task generator.

This helper does not edit application code. It consumes validator sidecars and
repository state, then writes a bounded repair task for the migration agent.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SCHEMA_VERSION = "1.0.0"
MATURITY_LEVEL = "maturing"
DEFAULT_MAX_PROMPT_ATTEMPTS = 3
DEFAULT_MAX_DIAGNOSTIC_ATTEMPTS = 2
DEFAULT_RUN_BUDGET = 10
HUMAN_OWNED_STRATEGIES = {
    "developer-decision-required",
    "redesign-required",
    "manual-review",
    "fix-environment",
}


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def load_json(path: Path) -> Optional[Dict[str, Any]]:
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def write_json_atomic(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        delete=False,
        dir=str(path.parent),
        prefix=f"{path.name}.tmp.",
    ) as tmp:
        json.dump(payload, tmp, indent=2, sort_keys=True)
        tmp.write("\n")
        tmp_path = Path(tmp.name)
    os.replace(tmp_path, path)


def repo_diff_fingerprint(project_root: Path) -> Tuple[str, List[str]]:
    try:
        proc = subprocess.run(
            ["git", "-C", str(project_root), "diff", "--name-only"],
            capture_output=True,
            text=True,
            check=False,
        )
        files = sorted([line.strip() for line in proc.stdout.splitlines() if line.strip()])
        proc_diff = subprocess.run(
            ["git", "-C", str(project_root), "diff", "--", *files],
            capture_output=True,
            text=True,
            check=False,
        )
        h = hashlib.sha256()
        h.update("\n".join(files).encode("utf-8"))
        h.update(proc_diff.stdout.encode("utf-8", errors="replace"))
        return h.hexdigest(), files
    except Exception:
        return "", []


def read_run_id(output_dir: Path) -> str:
    bootstrap = load_json(output_dir / "bootstrap.json") or {}
    return str(bootstrap.get("runId") or (bootstrap.get("provenance") or {}).get("runId") or "unknown-run")


def read_loop_resume(output_dir: Path, prompt_id: str) -> Dict[str, Any]:
    """Read durable migration-loop-state.json so resume is explicit and the
    durable state remains the single source of truth across interruptions."""
    loop = load_json(output_dir / "migration-loop-state.json") or {}
    attempts = loop.get("attempts") if isinstance(loop.get("attempts"), list) else []
    prompt_attempts = [
        a for a in attempts if isinstance(a, dict) and a.get("promptId") == prompt_id
    ]
    escalations = loop.get("escalations") if isinstance(loop.get("escalations"), list) else []
    last_escalation = None
    for entry in reversed(escalations):
        if isinstance(entry, dict) and entry.get("promptId") == prompt_id:
            last_escalation = entry
            break
    resume_info = loop.get("resumeInfo") if isinstance(loop.get("resumeInfo"), dict) else None
    return {
        "durableLoopStatePresent": bool(loop),
        "priorDurableAttempts": len(prompt_attempts),
        "lastDurableEscalation": last_escalation,
        "resumeInfo": resume_info,
    }


def reflect_loop_terminal(loop_state_sh: str, prompt_id: str, reason: str, message: str) -> Optional[Dict[str, Any]]:
    """Best-effort: reflect a repair-loop escalation into the durable
    migration-loop-state.json via the existing loop-state.sh terminal API.

    This keeps migration-loop-state.json authoritative for loop terminal and
    escalation status; the orchestrator's own ledger stays a working file."""
    if not loop_state_sh:
        return None
    sh = Path(loop_state_sh)
    if not sh.is_file():
        return {"reflected": False, "error": "loop-state.sh-not-found"}
    try:
        proc = subprocess.run(
            [
                "bash",
                str(sh),
                "terminal",
                "--prompt-id",
                prompt_id,
                "--stage",
                "validation",
                "--result",
                "escalated",
                "--terminal-outcome",
                "escalated",
                "--terminal-reason",
                f"repair-orchestrator:{reason}",
                "--message",
                (message or f"repair-orchestrator:{reason}")[:200],
                "--safe-next-action",
                "rerun-owner-prompt",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        return {"reflected": proc.returncode == 0, "returnCode": proc.returncode}
    except Exception as exc:  # best-effort: never block the orchestrator
        return {"reflected": False, "error": str(exc)[:200]}


def controlled_prompt_list(value: str) -> List[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def empty_state(platform: str, run_id: str, budgets: Dict[str, int], maturity_level: str, controlled_prompts: List[str]) -> Dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "maturityLevel": maturity_level,
        "platform": platform,
        "runId": run_id,
        "budgets": budgets,
        "controlledPrompts": controlled_prompts,
        "safety": {
            "editsSource": False,
            "validatorAuthority": "deterministic validators remain authoritative",
            "automaticTrustBoundaryDecisions": False,
        },
        "attempts": [],
        "diagnosticCounts": {},
        "promptCounts": {},
        "strategyChanges": [],
        "terminalOutcome": None,
    }


def load_state(path: Path, platform: str, run_id: str, budgets: Dict[str, int], maturity_level: str, controlled_prompts: List[str]) -> Dict[str, Any]:
    state = load_json(path)
    if not isinstance(state, dict) or state.get("runId") != run_id or state.get("platform") != platform:
        return empty_state(platform, run_id, budgets, maturity_level, controlled_prompts)
    state["schemaVersion"] = SCHEMA_VERSION
    state["maturityLevel"] = maturity_level
    state["budgets"] = budgets
    state["controlledPrompts"] = controlled_prompts
    state.setdefault(
        "safety",
        {
            "editsSource": False,
            "validatorAuthority": "deterministic validators remain authoritative",
            "automaticTrustBoundaryDecisions": False,
        },
    )
    state.setdefault("attempts", [])
    state.setdefault("diagnosticCounts", {})
    state.setdefault("promptCounts", {})
    state.setdefault("strategyChanges", [])
    state.setdefault("terminalOutcome", None)
    return state


def blocking_diagnostics(sidecar: Dict[str, Any]) -> List[Dict[str, Any]]:
    rows = sidecar.get("violations")
    if not isinstance(rows, list):
        return []
    return [
        row
        for row in rows
        if isinstance(row, dict) and str(row.get("severity") or "fail") in {"fail", "error", "critical"}
    ]


def first_diagnostic(rows: List[Dict[str, Any]]) -> Dict[str, Any]:
    if rows:
        return rows[0]
    return {
        "diagnosticCode": "NO-DIAGNOSTIC",
        "diagnosticFingerprint": "no-diagnostic",
        "owningPrompt": None,
        "safeRepairCategory": "manual-review",
        "humanJudgmentRequired": True,
        "automaticRepairProhibited": True,
        "message": "Validator failed without structured diagnostics",
    }


def count_prior(state: Dict[str, Any], prompt_id: str, fingerprint: str) -> Tuple[int, int, int]:
    attempts = state.get("attempts") if isinstance(state.get("attempts"), list) else []
    prompt_count = 0
    diagnostic_count = 0
    run_count = 0
    for attempt in attempts:
        if not isinstance(attempt, dict):
            continue
        run_count += 1
        if attempt.get("promptId") == prompt_id:
            prompt_count += 1
        if attempt.get("diagnosticFingerprint") == fingerprint:
            diagnostic_count += 1
    return prompt_count, diagnostic_count, run_count


def latest_attempt(state: Dict[str, Any], prompt_id: str) -> Optional[Dict[str, Any]]:
    attempts = state.get("attempts")
    if not isinstance(attempts, list):
        return None
    for attempt in reversed(attempts):
        if isinstance(attempt, dict) and attempt.get("promptId") == prompt_id:
            return attempt
    return None


def human_owned_reason(diagnostic: Dict[str, Any], strategy: str) -> Optional[str]:
    if diagnostic.get("humanJudgmentRequired") is True:
        return "human-decision-required"
    if diagnostic.get("automaticRepairProhibited") is True:
        return "automatic-repair-prohibited"
    if strategy == "developer-decision-required":
        return "human-decision-required"
    if strategy == "redesign-required":
        return "redesign-required"
    if strategy == "fix-environment":
        return "environment-fix-required"
    if strategy == "manual-review":
        return "manual-review-required"
    if strategy in HUMAN_OWNED_STRATEGIES:
        return "manual-review-required"
    return None


def task_markdown(task: Dict[str, Any]) -> str:
    diag = task["diagnostic"]
    lines = [
        "# Bounded Repair Task",
        "",
        f"- Prompt: `{task['promptId']}`",
        f"- Owning prompt: `{task.get('owningPrompt') or task['promptId']}`",
        f"- Strategy: `{task['strategy']}`",
        f"- Diagnostic: `{diag.get('diagnosticCode') or 'unknown'}`",
        f"- Fingerprint: `{diag.get('diagnosticFingerprint') or 'unknown'}`",
        f"- Maturity level: `{task.get('maturityLevel') or MATURITY_LEVEL}`",
        f"- Human judgment required: `{str(task['humanJudgmentRequired']).lower()}`",
        f"- Automatic repair prohibited: `{str(task['automaticRepairProhibited']).lower()}`",
        "",
        "## Evidence",
        "",
        str((diag.get("evidence") or {}).get("message") or diag.get("message") or "No message available."),
        "",
        "## Required Action",
        "",
    ]
    if task["automaticRepairProhibited"]:
        lines.append("Stop and request the owner decision described by the diagnostic. Do not approve, defer, redesign trust-boundary behavior, or fix environment-owned failures automatically.")
    else:
        lines.append("Apply the owning migration prompt to the affected code only. Preserve behavior, fix the listed diagnostic, and do not edit the report to hide unresolved failures.")
    lines.extend(
        [
            "",
            "## Verification",
            "",
            f"Run: `{task['suggestedVerificationCommand']}`",
            "",
        ]
    )
    return "\n".join(lines)


def record_failure(args: argparse.Namespace) -> int:
    output_dir = Path(args.output_dir)
    project_root = Path(args.project_root)
    state_path = output_dir / "repair-orchestrator-state.json"
    task_path = output_dir / "repair-task.json"
    task_md_path = output_dir / "repair-task.md"
    budgets = {
        "maxPromptAttempts": args.max_prompt_attempts,
        "maxDiagnosticAttempts": args.max_diagnostic_attempts,
        "runBudget": args.run_budget,
    }
    run_id = read_run_id(output_dir)
    controlled_prompts = controlled_prompt_list(args.controlled_prompts)
    state = load_state(state_path, args.platform, run_id, budgets, args.maturity_level, controlled_prompts)
    resume = read_loop_resume(output_dir, args.prompt_id)
    state["resume"] = resume
    sidecar = load_json(Path(args.sidecar)) or {}
    diagnostics = blocking_diagnostics(sidecar)
    diagnostic = first_diagnostic(diagnostics)
    fingerprint = str(diagnostic.get("diagnosticFingerprint") or diagnostic.get("failureHash") or "unknown")
    prompt_prior, diag_prior, run_prior = count_prior(state, args.prompt_id, fingerprint)
    diff_fp, changed_files = repo_diff_fingerprint(project_root)
    previous = latest_attempt(state, args.prompt_id)
    no_progress = (
        isinstance(previous, dict)
        and previous.get("diagnosticFingerprint") == fingerprint
        and previous.get("repoDiffFingerprint") == diff_fp
    )
    strategy = str(diagnostic.get("safeRepairCategory") or "manual-review")
    human_reason = human_owned_reason(diagnostic, strategy)
    previous_strategy = previous.get("strategy") if isinstance(previous, dict) else None
    if previous_strategy and previous_strategy != strategy:
        state["strategyChanges"].append(
            {
                "timestamp": now_iso(),
                "promptId": args.prompt_id,
                "from": previous_strategy,
                "to": strategy,
                "diagnosticFingerprint": fingerprint,
            }
        )

    human = bool(human_reason)
    automatic_prohibited = bool(diagnostic.get("automaticRepairProhibited") or human)
    prompt_count = prompt_prior + 1
    diag_count = diag_prior + 1
    run_count = run_prior + 1
    escalation_reason = None
    if human_reason:
        escalation_reason = human_reason
    elif prompt_count > args.max_prompt_attempts:
        escalation_reason = "prompt-attempt-budget-exhausted"
    elif diag_count > args.max_diagnostic_attempts:
        escalation_reason = "diagnostic-attempt-budget-exhausted"
    elif run_count > args.run_budget:
        escalation_reason = "run-repair-budget-exhausted"
    elif no_progress:
        escalation_reason = "no-progress"

    attempt = {
        "attemptNumber": run_count,
        "timestamp": now_iso(),
        "maturityLevel": args.maturity_level,
        "promptId": args.prompt_id,
        "owningPrompt": diagnostic.get("owningPrompt") or args.prompt_id,
        "diagnosticCode": diagnostic.get("diagnosticCode"),
        "diagnosticFingerprint": fingerprint,
        "strategy": strategy,
        "repoDiffFingerprint": diff_fp,
        "changedFiles": changed_files,
        "promptAttempt": prompt_count,
        "diagnosticAttempt": diag_count,
        "noProgress": no_progress,
        "humanJudgmentRequired": human,
        "automaticRepairProhibited": automatic_prohibited,
        "escalationReason": escalation_reason,
        "ownerDecisionReason": human_reason,
    }
    state["attempts"].append(attempt)
    state["promptCounts"][args.prompt_id] = prompt_count
    state["diagnosticCounts"][fingerprint] = diag_count

    task = {
        "schemaVersion": SCHEMA_VERSION,
        "maturityLevel": args.maturity_level,
        "platform": args.platform,
        "runId": run_id,
        "promptId": args.prompt_id,
        "owningPrompt": diagnostic.get("owningPrompt") or args.prompt_id,
        "strategy": strategy,
        "diagnostic": diagnostic,
        "suggestedVerificationCommand": diagnostic.get("suggestedVerificationCommand")
        or f"bash dynamics-migration-tool/tooling/validate.sh --check-prompt {args.prompt_id}",
        "humanJudgmentRequired": human,
        "automaticRepairProhibited": automatic_prohibited,
        "escalationReason": escalation_reason,
        "ownerDecisionReason": human_reason,
        "attempt": attempt,
        "controlledPrompts": controlled_prompts,
        "resume": resume,
    }
    write_json_atomic(task_path, task)
    task_md_path.write_text(task_markdown(task), encoding="utf-8")

    if escalation_reason:
        durable = reflect_loop_terminal(
            args.loop_state_sh,
            diagnostic.get("owningPrompt") or args.prompt_id,
            escalation_reason,
            str(diagnostic.get("message") or ""),
        )
        state["terminalOutcome"] = {
            "timestamp": now_iso(),
            "outcome": "escalated",
            "reason": escalation_reason,
            "promptId": args.prompt_id,
            "diagnosticFingerprint": fingerprint,
            "durableStateReflected": durable,
        }
        write_json_atomic(state_path, state)
        print(json.dumps({"status": "escalated", "reason": escalation_reason, "task": str(task_path), "durableStateReflected": durable}, sort_keys=True))
        return 3

    write_json_atomic(state_path, state)
    print(json.dumps({"status": "repair-task-created", "task": str(task_path), "taskMarkdown": str(task_md_path)}, sort_keys=True))
    return 1


def record_success(args: argparse.Namespace) -> int:
    output_dir = Path(args.output_dir)
    budgets = {
        "maxPromptAttempts": args.max_prompt_attempts,
        "maxDiagnosticAttempts": args.max_diagnostic_attempts,
        "runBudget": args.run_budget,
    }
    run_id = read_run_id(output_dir)
    state_path = output_dir / "repair-orchestrator-state.json"
    state = load_state(
        state_path,
        args.platform,
        run_id,
        budgets,
        args.maturity_level,
        controlled_prompt_list(args.controlled_prompts),
    )
    state["resume"] = read_loop_resume(output_dir, args.prompt_id)
    state["terminalOutcome"] = {
        "timestamp": now_iso(),
        "outcome": "passed",
        "promptId": args.prompt_id,
        "maturityLevel": args.maturity_level,
    }
    write_json_atomic(state_path, state)
    print(json.dumps({"status": "passed", "state": str(state_path)}, sort_keys=True))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Bounded repair-loop state helper.")
    parser.add_argument("--platform", required=True, choices=["android", "ios"])
    parser.add_argument("--event", required=True, choices=["failure", "success"])
    parser.add_argument("--prompt-id", required=True)
    parser.add_argument("--sidecar", default="")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--max-prompt-attempts", type=int, default=DEFAULT_MAX_PROMPT_ATTEMPTS)
    parser.add_argument("--max-diagnostic-attempts", type=int, default=DEFAULT_MAX_DIAGNOSTIC_ATTEMPTS)
    parser.add_argument("--run-budget", type=int, default=DEFAULT_RUN_BUDGET)
    parser.add_argument("--maturity-level", default=MATURITY_LEVEL)
    parser.add_argument("--controlled-prompts", default="")
    parser.add_argument("--loop-state-sh", default="")
    args = parser.parse_args()
    if args.event == "failure":
        if not args.sidecar:
            print("--sidecar is required for failure events", file=sys.stderr)
            return 2
        return record_failure(args)
    return record_success(args)


if __name__ == "__main__":
    raise SystemExit(main())
