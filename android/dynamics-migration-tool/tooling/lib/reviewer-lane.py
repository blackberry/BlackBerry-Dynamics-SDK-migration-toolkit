#!/usr/bin/env python3
"""Generate the optional Stage 8 risk-based reviewer lane.

The helper is read-only with respect to application source. It reads migration
artifacts and writes reviewer-lane output under dynamics-migration-tool/output.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

SCHEMA_VERSION = "1.0.0"
SECURITY_DOMAINS = {
    "authorization",
    "backgroundAuthorize",
    "secureFileStorage",
    "secureSql",
    "secureNetworking",
    "secureClipboard",
    "secureUiWidgets",
    "icc",
    "dlpPasteboard",
    "policyManagement",
    "transportHardening",
    "externalStorage",
    "webview",
}
SENSITIVE_PATH_MARKERS = (
    "AndroidManifest.xml",
    "Info.plist",
    ".entitlements",
    "network_security_config",
    "file_paths",
    "Provider",
    "Service",
    "Receiver",
)


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


def write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def git_changed_files(project_root: Path) -> List[str]:
    try:
        proc = subprocess.run(
            ["git", "-C", str(project_root), "diff", "--name-only"],
            capture_output=True,
            text=True,
            check=False,
        )
        return sorted(line.strip() for line in proc.stdout.splitlines() if line.strip())
    except Exception:
        return []


def fingerprint_obj(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def artifact(path: Path, label: str) -> Dict[str, Any]:
    return {"label": label, "path": str(path), "exists": path.is_file()}


def add_trigger(triggers: List[Dict[str, Any]], trigger_type: str, severity: str, reason: str, evidence: List[str]) -> None:
    triggers.append(
        {
            "triggerId": f"TRG-{fingerprint_obj([trigger_type, reason, evidence])[:12].upper()}",
            "type": trigger_type,
            "severity": severity,
            "reason": reason,
            "evidence": evidence,
        }
    )


def add_finding(
    findings: List[Dict[str, Any]],
    *,
    severity: str,
    category: str,
    owner: str,
    summary: str,
    evidence: List[str],
    recommendation: str,
) -> None:
    findings.append(
        {
            "findingId": f"RVW-{fingerprint_obj([severity, category, owner, summary, evidence])[:12].upper()}",
            "severity": severity,
            "category": category,
            "owner": owner,
            "summary": summary,
            "evidence": evidence,
            "recommendation": recommendation,
            "validatorOverride": False,
        }
    )


def iter_sidecar_diagnostics(sidecars: Iterable[Tuple[str, Optional[Dict[str, Any]]]]) -> Iterable[Tuple[str, Dict[str, Any]]]:
    for label, sidecar in sidecars:
        if not isinstance(sidecar, dict):
            continue
        rows = sidecar.get("violations")
        if not isinstance(rows, list):
            continue
        for row in rows:
            if isinstance(row, dict):
                yield label, row


def runtime_artifact_status(runtime_artifact: Optional[Dict[str, Any]]) -> Optional[str]:
    if not isinstance(runtime_artifact, dict):
        return None
    status = runtime_artifact.get("overallStatus")
    if status == "passed":
        return "passed"
    if status == "failed":
        return "failed"
    if status in {"blocked", "pending"}:
        return str(status)
    if status == "not-applicable":
        return "not-applicable"
    return None


def report_runtime_status(report: Optional[Dict[str, Any]]) -> Optional[str]:
    if not isinstance(report, dict):
        return None
    evidence = report.get("evidenceCompleteness")
    if not isinstance(evidence, dict):
        return None
    runtime = evidence.get("runtimeEvidence")
    if not isinstance(runtime, dict):
        return None
    status = runtime.get("status")
    return str(status) if status is not None else None


def generate(platform: str, project_root: Path, tool_dir: Path) -> Dict[str, Any]:
    started = time.time()
    output = tool_dir / "output"
    bootstrap = load_json(output / "bootstrap.json")
    report = load_json(output / "migration-report.json")
    loop_state = load_json(output / "migration-loop-state.json")
    repair_state = load_json(output / "repair-orchestrator-state.json")
    repair_task = load_json(output / "repair-task.json")
    runtime_artifact = load_json(output / "runtime-evidence.json")
    last_check = load_json(output / ".last-check.json")
    last_source = load_json(output / ".last-source-check.json")
    last_report = load_json(output / ".last-report-check.json")
    changed = git_changed_files(project_root)

    triggers: List[Dict[str, Any]] = []
    findings: List[Dict[str, Any]] = []
    run_id = "unknown-run"
    if isinstance(bootstrap, dict):
        run_id = str(bootstrap.get("runId") or (bootstrap.get("provenance") or {}).get("runId") or run_id)

    for label, row in iter_sidecar_diagnostics(
        [("last-check", last_check), ("last-source-check", last_source), ("last-report-check", last_report)]
    ):
        domain = str(row.get("domain") or "")
        defect_kind = str(row.get("defectKind") or "")
        human = bool(row.get("humanJudgmentRequired") or row.get("automaticRepairProhibited"))
        if domain in SECURITY_DOMAINS:
            evidence = [f"{label}: {row.get('diagnosticCode') or row.get('message') or domain}"]
            add_trigger(triggers, "security-sensitive-migration", "high", f"Security-sensitive domain {domain}", evidence)
            add_finding(
                findings,
                severity="high",
                category="dynamics-security-posture",
                owner=str(row.get("owningPrompt") or "validator"),
                summary=f"Review security-sensitive migration domain {domain}.",
                evidence=evidence,
                recommendation="Reviewer should inspect migrated code, validator sidecar, and report evidence for behavioural and Dynamics policy preservation.",
            )
        if human or defect_kind in {"missing-developer-decision", "unsupported-application-behaviour"}:
            evidence = [f"{label}: {row.get('diagnosticCode') or row.get('message') or defect_kind}"]
            add_trigger(triggers, "developer-decision-or-unsupported-behaviour", "high", "Human decision or unsupported behavior is present", evidence)
            add_finding(
                findings,
                severity="high",
                category="developer-decision",
                owner=str(row.get("owningPrompt") or "developer"),
                summary="Developer decision requires independent review.",
                evidence=evidence,
                recommendation="Reviewer must verify the decision is explicit and must not treat validator output as waived.",
            )

    if isinstance(repair_state, dict):
        attempts = repair_state.get("attempts")
        if isinstance(attempts, list) and len(attempts) >= 2:
            add_trigger(
                triggers,
                "repeated-repair-attempts",
                "medium",
                f"{len(attempts)} repair attempt(s) recorded",
                ["output/repair-orchestrator-state.json"],
            )
            add_finding(
                findings,
                severity="medium",
                category="repair-loop-risk",
                owner="repair-orchestrator",
                summary="Repeated repair attempts may indicate churn or validator-satisfying workarounds.",
                evidence=["output/repair-orchestrator-state.json"],
                recommendation="Reviewer should compare repair task history with final code and validator proof.",
            )
        terminal = repair_state.get("terminalOutcome")
        if isinstance(terminal, dict) and terminal.get("outcome") == "escalated":
            add_trigger(
                triggers,
                "escalated-repair-loop",
                "high",
                f"Repair loop escalated: {terminal.get('reason')}",
                ["output/repair-orchestrator-state.json"],
            )

    if isinstance(repair_task, dict) and repair_task.get("automaticRepairProhibited") is True:
        add_trigger(
            triggers,
            "human-decision-required",
            "high",
            "Latest repair task prohibits automatic repair",
            ["output/repair-task.json"],
        )

    if isinstance(bootstrap, dict):
        deferred = bootstrap.get("deferredDomains")
        if isinstance(deferred, list) and deferred:
            add_trigger(
                triggers,
                "deferrals-or-developer-decisions",
                "high",
                f"{len(deferred)} deferred domain decision(s)",
                ["output/bootstrap.json:deferredDomains"],
            )
            add_finding(
                findings,
                severity="high",
                category="deferral-review",
                owner="developer",
                summary="Deferred domains require independent sign-off review.",
                evidence=["output/bootstrap.json:deferredDomains"],
                recommendation="Reviewer should confirm sign-off, expiry, classification, and report visibility.",
            )
        working_tree = bootstrap.get("workingTree")
        if isinstance(working_tree, dict) and (working_tree.get("override") or {}).get("acknowledged") is True:
            add_trigger(
                triggers,
                "unintended-scope-risk",
                "medium",
                "Bootstrap acknowledged dirty working tree override",
                ["output/bootstrap.json:workingTree.override"],
            )

    if isinstance(report, dict):
        rr = report.get("releaseReadiness")
        if isinstance(rr, dict):
            recommendation = rr.get("recommendation")
            blockers = rr.get("blockingItems")
            if recommendation in {"go-with-risks", "no-go"} or (isinstance(blockers, list) and blockers):
                add_trigger(
                    triggers,
                    "report-risk-or-blockers",
                    "high",
                    f"Report recommendation is {recommendation!r} with blocker evidence",
                    ["output/migration-report.json:releaseReadiness"],
                )
        security_blockers = report.get("securityBlockers")
        if isinstance(security_blockers, list) and security_blockers:
            add_trigger(
                triggers,
                "security-blockers",
                "critical",
                f"{len(security_blockers)} security blocker(s) in report",
                ["output/migration-report.json:securityBlockers"],
            )

    runtime_status = runtime_artifact_status(runtime_artifact) or report_runtime_status(report)
    if runtime_status in {None, "", "missing", "not-run", "failed", "insufficient"}:
        add_trigger(
            triggers,
            "insufficient-runtime-evidence",
            "medium",
            f"Runtime evidence status is {runtime_status or 'missing'}",
            ["output/migration-report.json:evidenceCompleteness.runtimeEvidence"],
        )
    elif runtime_status in {"blocked", "pending"}:
        add_trigger(
            triggers,
            "runtime-evidence-blocked-or-pending",
            "medium",
            f"Runtime evidence status is {runtime_status}",
            ["output/runtime-evidence.json"],
        )

    sensitive_changed = [p for p in changed if any(marker in p for marker in SENSITIVE_PATH_MARKERS)]
    if sensitive_changed:
        add_trigger(
            triggers,
            "sensitive-file-diff",
            "medium",
            "Sensitive platform files changed",
            sensitive_changed[:10],
        )

    result = {
        "schemaVersion": SCHEMA_VERSION,
        "platform": platform,
        "runId": run_id,
        "generatedAt": now_iso(),
        "reviewRequired": bool(triggers),
        "validatorAuthority": {
            "overridesValidators": False,
            "statement": "Reviewer findings are advisory and must never mark deterministic validator failures as passed.",
        },
        "triggers": triggers,
        "findings": findings,
        "evidenceSources": [
            artifact(output / "bootstrap.json", "bootstrap"),
            artifact(output / "migration-report.json", "migration-report"),
            artifact(output / ".last-check.json", "last-check"),
            artifact(output / ".last-source-check.json", "last-source-check"),
            artifact(output / ".last-report-check.json", "last-report-check"),
            artifact(output / "repair-orchestrator-state.json", "repair-orchestrator-state"),
            artifact(output / "repair-task.json", "repair-task"),
            artifact(output / "runtime-evidence.json", "runtime-evidence"),
        ],
        "metrics": {
            "analysisDurationMs": int((time.time() - started) * 1000),
            "triggerCount": len(triggers),
            "findingCount": len(findings),
            "changedFileCount": len(changed),
        },
    }
    return result


def markdown(payload: Dict[str, Any]) -> str:
    lines = [
        "# Risk-Based Reviewer Lane",
        "",
        f"- Platform: `{payload['platform']}`",
        f"- Run ID: `{payload['runId']}`",
        f"- Review required: `{str(payload['reviewRequired']).lower()}`",
        f"- Trigger count: `{payload['metrics']['triggerCount']}`",
        "",
        "Reviewer findings are advisory and do not override deterministic validators.",
        "",
        "## Triggers",
        "",
    ]
    if not payload["triggers"]:
        lines.append("No risk-based reviewer triggers were detected.")
    for trigger in payload["triggers"]:
        lines.append(f"- `{trigger['severity']}` `{trigger['type']}`: {trigger['reason']}")
    lines.extend(["", "## Findings", ""])
    if not payload["findings"]:
        lines.append("No structured reviewer findings were generated.")
    for finding in payload["findings"]:
        lines.append(f"- `{finding['severity']}` `{finding['category']}` ({finding['owner']}): {finding['summary']}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate read-only reviewer lane artifacts.")
    parser.add_argument("--platform", required=True, choices=["android", "ios"])
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--tool-dir", required=True)
    args = parser.parse_args()

    tool_dir = Path(args.tool_dir)
    payload = generate(args.platform, Path(args.project_root), tool_dir)
    output = tool_dir / "output"
    write_json(output / "reviewer-lane.json", payload)
    (output / "reviewer-lane.md").write_text(markdown(payload), encoding="utf-8")
    print(json.dumps({"reviewRequired": payload["reviewRequired"], "triggerCount": len(payload["triggers"])}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
