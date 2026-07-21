#!/usr/bin/env python3
"""Generate a migration improvement backlog from completed loop artifacts.

The helper is read-only with respect to source, prompts, steering, validators,
and schemas. It only writes output/migration-improvement-backlog.{json,md}.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

SCHEMA_VERSION = "1.0.0"


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


def fingerprint(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def read_run_id(output_dir: Path) -> str:
    bootstrap = load_json(output_dir / "bootstrap.json") or {}
    report = load_json(output_dir / "migration-report.json") or {}
    return str(
        bootstrap.get("runId")
        or (bootstrap.get("provenance") or {}).get("runId")
        or report.get("runId")
        or "unknown-run"
    )


def affected_app(report: Optional[Dict[str, Any]], project_root: Path) -> str:
    if isinstance(report, dict):
        project = report.get("project")
        if isinstance(project, dict):
            for key in ("applicationId", "bundleIdentifier", "name"):
                value = project.get(key)
                if isinstance(value, str) and value.strip():
                    return value.strip()
    return project_root.name or "unknown-application"


def short_text(value: Any, fallback: str = "") -> str:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return fallback


def infer_target(defect_kind: str, safe_category: str, source_type: str) -> str:
    if source_type in {"manual-todo", "unsupported-feature"}:
        return "steering"
    if source_type == "runtime-failure":
        return "validator"
    if source_type == "observability":
        return "implementation"
    if defect_kind == "tool-defect":
        return "implementation"
    if defect_kind == "runtime-evidence-gap":
        return "validator"
    if safe_category in {"developer-decision-required", "redesign-required"}:
        return "steering"
    return "prompt"


def confidence(frequency: int, source_count: int, human_required: bool) -> str:
    if frequency >= 3 or source_count >= 3:
        return "high"
    if frequency >= 2 or human_required:
        return "medium"
    return "low"


def base_candidate(
    *,
    source_type: str,
    pattern: str,
    frequency: int,
    app: str,
    evidence: List[str],
    source_artifacts: List[str],
    root_cause: str,
    workaround: str,
    proposed_target: str,
    proposed_description: str,
    regression_reason: str,
    security: str,
    human_required: bool = False,
    prompt_id: Optional[str] = None,
    domain: Optional[str] = None,
    diagnostic_fingerprint: Optional[str] = None,
    diagnostic_code: Optional[str] = None,
    defect_kind: Optional[str] = None,
) -> Dict[str, Any]:
    basis = diagnostic_fingerprint or fingerprint([source_type, pattern, prompt_id or "", domain or ""])[:16]
    return {
        "candidateId": f"IMP-{fingerprint([source_type, basis])[:12].upper()}",
        "failurePattern": {
            "type": source_type,
            "summary": pattern,
            "diagnosticFingerprint": diagnostic_fingerprint,
            "diagnosticCode": diagnostic_code,
            "promptId": prompt_id,
            "domain": domain,
            "defectKind": defect_kind,
        },
        "frequency": frequency,
        "affectedApplications": [app],
        "rootCauseHypothesis": root_cause,
        "currentWorkaround": workaround,
        "proposedChange": {
            "target": proposed_target,
            "description": proposed_description,
        },
        "regressionFixtureRequired": {
            "required": True,
            "reason": regression_reason,
        },
        "securityImplications": security,
        "confidenceLevel": confidence(frequency, len(source_artifacts), human_required),
        "humanApprovalStatus": "pending-review",
        "autoPromotionProhibited": True,
        "deterministicAcceptanceEvidenceRequired": True,
        "evidence": evidence,
        "sourceArtifacts": sorted(set(source_artifacts)),
    }


def merge_candidate(existing: Dict[str, Any], incoming: Dict[str, Any]) -> None:
    existing["frequency"] = int(existing.get("frequency") or 0) + int(incoming.get("frequency") or 0)
    apps = list(existing.get("affectedApplications") or [])
    for app in incoming.get("affectedApplications") or []:
        if app not in apps:
            apps.append(app)
    existing["affectedApplications"] = apps
    for key in ("evidence", "sourceArtifacts"):
        values = list(existing.get(key) or [])
        for item in incoming.get(key) or []:
            if item not in values:
                values.append(item)
        existing[key] = values
    existing["confidenceLevel"] = confidence(existing["frequency"], len(existing.get("sourceArtifacts") or []), False)


def add_candidate(candidates: Dict[str, Dict[str, Any]], candidate: Dict[str, Any]) -> None:
    fp = candidate["failurePattern"].get("diagnosticFingerprint")
    key = fp or fingerprint(
        [
            candidate["failurePattern"].get("type"),
            candidate["failurePattern"].get("summary"),
            candidate["failurePattern"].get("promptId"),
            candidate["failurePattern"].get("domain"),
        ]
    )
    if key in candidates:
        merge_candidate(candidates[key], candidate)
    else:
        candidates[key] = candidate


def iter_sidecar_rows(sidecars: Iterable[Tuple[str, Optional[Dict[str, Any]]]]) -> Iterable[Tuple[str, Dict[str, Any]]]:
    for label, sidecar in sidecars:
        if not isinstance(sidecar, dict):
            continue
        rows = sidecar.get("violations")
        if not isinstance(rows, list):
            continue
        for row in rows:
            if isinstance(row, dict):
                yield label, row


def candidates_from_sidecars(
    candidates: Dict[str, Dict[str, Any]],
    app: str,
    sidecars: Iterable[Tuple[str, Optional[Dict[str, Any]]]],
) -> None:
    for label, row in iter_sidecar_rows(sidecars):
        severity = str(row.get("severity") or "fail")
        if severity not in {"fail", "error", "critical", "warn"}:
            continue
        defect_kind = str(row.get("defectKind") or "migrated-application-defect")
        safe_category = str(row.get("safeRepairCategory") or "")
        pattern = short_text((row.get("evidence") or {}).get("message"), short_text(row.get("message"), "Validator diagnostic"))
        target = infer_target(defect_kind, safe_category, "validator-diagnostic")
        prompt_id = row.get("owningPrompt") if isinstance(row.get("owningPrompt"), str) else None
        domain = row.get("domain") if isinstance(row.get("domain"), str) else None
        add_candidate(
            candidates,
            base_candidate(
                source_type="validator-diagnostic",
                pattern=pattern,
                frequency=1,
                app=app,
                evidence=[f"{label}: {row.get('diagnosticCode') or pattern}"],
                source_artifacts=[f"output/{label}.json"],
                root_cause=f"Validator repeatedly observed {defect_kind} in {domain or 'unknown domain'}.",
                workaround=f"Rerun owning prompt {prompt_id or 'unknown'} or follow safe repair category {safe_category or 'manual-review'}.",
                proposed_target=target,
                proposed_description=f"Review whether {prompt_id or 'the owning prompt'} or {target} logic should make this condition deterministic.",
                regression_reason="Every promoted diagnostic pattern needs a fixture proving the new rule catches the failure and accepts the intended repair.",
                security="Review trust-boundary impact before changing migration guidance or validator behavior.",
                human_required=bool(row.get("humanJudgmentRequired") or row.get("automaticRepairProhibited")),
                prompt_id=prompt_id,
                domain=domain,
                diagnostic_fingerprint=row.get("diagnosticFingerprint") if isinstance(row.get("diagnosticFingerprint"), str) else None,
                diagnostic_code=row.get("diagnosticCode") if isinstance(row.get("diagnosticCode"), str) else None,
                defect_kind=defect_kind,
            ),
        )


def candidates_from_repair_state(candidates: Dict[str, Dict[str, Any]], app: str, repair_state: Optional[Dict[str, Any]]) -> None:
    if not isinstance(repair_state, dict):
        return
    attempts = repair_state.get("attempts")
    if not isinstance(attempts, list):
        return
    grouped: Dict[str, List[Dict[str, Any]]] = {}
    for attempt in attempts:
        if not isinstance(attempt, dict):
            continue
        fp = str(attempt.get("diagnosticFingerprint") or fingerprint(attempt))
        grouped.setdefault(fp, []).append(attempt)
    for fp, rows in grouped.items():
        latest = rows[-1]
        prompt_id = latest.get("owningPrompt") or latest.get("promptId")
        strategy = str(latest.get("strategy") or "manual-review")
        add_candidate(
            candidates,
            base_candidate(
                source_type="repair-history",
                pattern=f"Repair loop repeated {len(rows)} time(s) for {latest.get('diagnosticCode') or fp[:12]}",
                frequency=len(rows),
                app=app,
                evidence=[f"output/repair-orchestrator-state.json:{fp}"],
                source_artifacts=["output/repair-orchestrator-state.json"],
                root_cause="Repeated repair attempts suggest prompt guidance, validator diagnostics, or deterministic migration support may be incomplete.",
                workaround=f"Current repair strategy is {strategy}.",
                proposed_target=infer_target("", strategy, "repair-history"),
                proposed_description=f"Review prompt {prompt_id or 'unknown'} repair history and decide whether to strengthen prompt, steering, validator, or implementation behavior.",
                regression_reason="Repeated repairs must be represented by a regression fixture before becoming deterministic guidance.",
                security="Repair-loop promotion can change migration behavior; require security review for storage, network, ICC, DLP, authorization, or policy domains.",
                human_required=bool(latest.get("humanJudgmentRequired") or latest.get("automaticRepairProhibited")),
                prompt_id=str(prompt_id) if prompt_id else None,
                diagnostic_fingerprint=fp,
                diagnostic_code=latest.get("diagnosticCode") if isinstance(latest.get("diagnosticCode"), str) else None,
            ),
        )


def candidates_from_report(candidates: Dict[str, Dict[str, Any]], app: str, report: Optional[Dict[str, Any]]) -> None:
    if not isinstance(report, dict):
        return
    for item in report.get("runtimeFailures") or []:
        if not isinstance(item, dict):
            continue
        pattern = short_text(item.get("symptom"), "Runtime-only migration failure")
        add_candidate(
            candidates,
            base_candidate(
                source_type="runtime-failure",
                pattern=pattern,
                frequency=1,
                app=app,
                evidence=[f"runtimeFailures:{item.get('id') or pattern}"],
                source_artifacts=["output/migration-report.json"],
                root_cause=short_text(item.get("rootCause"), "Runtime behavior exposed a static-analysis or prompt gap."),
                workaround=short_text(item.get("fix"), "Manual runtime repair recorded in report."),
                proposed_target="validator" if item.get("validatorGap") else "prompt",
                proposed_description=short_text(item.get("promptGap"), "Review runtime failure and add deterministic prompt/validator coverage if safe."),
                regression_reason="Runtime-only defects require a fixture or deterministic runtime evidence before toolkit behavior changes.",
                security="Runtime failures may indicate authorization, storage, networking, ICC, DLP, or process-model regressions.",
                human_required=True,
                defect_kind="runtime-evidence-gap",
            ),
        )
    for item in report.get("manualTodos") or []:
        if not isinstance(item, dict):
            continue
        domain = item.get("domain") if isinstance(item.get("domain"), str) else None
        pattern = short_text(item.get("title"), "Manual intervention")
        add_candidate(
            candidates,
            base_candidate(
                source_type="manual-intervention",
                pattern=pattern,
                frequency=1,
                app=app,
                evidence=[f"manualTodos:{item.get('id') or pattern}"],
                source_artifacts=["output/migration-report.json"],
                root_cause=short_text(item.get("reason"), "Migration required developer-owned follow-up."),
                workaround="Manual TODO remains the current workaround until reviewed.",
                proposed_target="steering",
                proposed_description="Decide whether this manual intervention should remain a developer decision or become deterministic guidance.",
                regression_reason="Manual interventions cannot be automated without a fixture proving safe closure and accepted-risk behavior.",
                security="Manual TODOs often carry security or policy implications; require approval before promotion.",
                human_required=True,
                domain=domain,
                defect_kind="missing-developer-decision",
            ),
        )
    for item in report.get("unsupportedFeatures") or []:
        if not isinstance(item, dict):
            continue
        feature = short_text(item.get("feature"), "Unsupported feature")
        add_candidate(
            candidates,
            base_candidate(
                source_type="unsupported-feature",
                pattern=feature,
                frequency=1,
                app=app,
                evidence=[f"unsupportedFeatures:{feature}"],
                source_artifacts=["output/migration-report.json"],
                root_cause=short_text(item.get("reason"), "Feature has no safe drop-in Dynamics replacement."),
                workaround=short_text(item.get("workaround"), "Documented redesign or feature removal."),
                proposed_target="steering",
                proposed_description="Clarify unsupported-feature guidance only after confirming the correct redesign or developer-decision path.",
                regression_reason="Unsupported patterns need a fixture proving detection and report disposition.",
                security="Unsupported feature handling must preserve Dynamics trust boundaries and avoid unmanaged fallbacks.",
                human_required=True,
                defect_kind="unsupported-application-behaviour",
            ),
        )


def candidates_from_reviewer(candidates: Dict[str, Dict[str, Any]], app: str, reviewer: Optional[Dict[str, Any]]) -> None:
    if not isinstance(reviewer, dict):
        return
    for finding in reviewer.get("findings") or []:
        if not isinstance(finding, dict):
            continue
        summary = short_text(finding.get("summary"), "Reviewer finding")
        add_candidate(
            candidates,
            base_candidate(
                source_type="reviewer-finding",
                pattern=summary,
                frequency=1,
                app=app,
                evidence=list(finding.get("evidence") or [])[:10],
                source_artifacts=["output/reviewer-lane.json"],
                root_cause="Risk-based reviewer lane identified a pattern needing maintainer review.",
                workaround=short_text(finding.get("recommendation"), "Manual review required."),
                proposed_target="steering",
                proposed_description="Evaluate whether this reviewer finding represents a recurring prompt, steering, validator, or developer-decision improvement.",
                regression_reason="Reviewer findings are advisory; deterministic promotion requires a regression fixture and validator or prompt proof.",
                security="Reviewer findings must not override validators and need independent security assessment.",
                human_required=True,
            ),
        )


def candidates_from_observability(candidates: Dict[str, Dict[str, Any]], app: str, observability: Optional[Dict[str, Any]]) -> None:
    if not isinstance(observability, dict):
        return
    search_count = int(observability.get("repositorySearchCount") or 0)
    total_duration = int(observability.get("totalDurationMs") or 0)
    event_count = int(observability.get("eventCount") or 0)
    if search_count < 25 and total_duration < 600000:
        return
    add_candidate(
        candidates,
        base_candidate(
            source_type="context-efficiency",
            pattern=f"Expensive context loading observed ({search_count} repository searches, {total_duration} ms total)",
            frequency=max(1, search_count),
            app=app,
            evidence=[f"repositorySearchCount={search_count}", f"eventCount={event_count}", f"totalDurationMs={total_duration}"],
            source_artifacts=["output/observability/migration-observability-summary.json"],
            root_cause="Observability indicates repeated context/search activity that may be reducible by manifest reuse or prompt context narrowing.",
            workaround="Use repository manifest and context summary during migration runs.",
            proposed_target="implementation",
            proposed_description="Review context-loading flow for durable manifest reuse, narrower searches, or prompt-map context scoping.",
            regression_reason="Efficiency improvements need before/after telemetry and a fixture or benchmark proving no loss of migration coverage.",
            security="Efficiency changes must not skip security-critical rediscovery or validator checks.",
        ),
    )


def generate(platform: str, project_root: Path, tool_dir: Path) -> Dict[str, Any]:
    output = tool_dir / "output"
    report = load_json(output / "migration-report.json")
    app = affected_app(report, project_root)
    candidates: Dict[str, Dict[str, Any]] = {}
    candidates_from_sidecars(
        candidates,
        app,
        [
            (".last-check", load_json(output / ".last-check.json")),
            (".last-source-check", load_json(output / ".last-source-check.json")),
            (".last-report-check", load_json(output / ".last-report-check.json")),
        ],
    )
    candidates_from_repair_state(candidates, app, load_json(output / "repair-orchestrator-state.json"))
    candidates_from_report(candidates, app, report)
    candidates_from_reviewer(candidates, app, load_json(output / "reviewer-lane.json"))
    candidates_from_observability(candidates, app, load_json(output / "observability/migration-observability-summary.json"))
    sorted_candidates = sorted(
        candidates.values(),
        key=lambda item: (-int(item.get("frequency") or 0), item.get("candidateId") or ""),
    )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "platform": platform,
        "runId": read_run_id(output),
        "generatedAt": now_iso(),
        "safety": {
            "autoPromotionProhibited": True,
            "requiresHumanReview": True,
            "requiresRegressionFixture": True,
            "requiresDeterministicAcceptanceEvidence": True,
            "statement": "Candidates are advisory backlog items. This tool must not modify prompts, steering, validators, schemas, or app source.",
        },
        "candidateCount": len(sorted_candidates),
        "candidates": sorted_candidates,
        "evidenceSources": [
            {"path": "output/migration-loop-state.json", "exists": (output / "migration-loop-state.json").is_file()},
            {"path": "output/repair-orchestrator-state.json", "exists": (output / "repair-orchestrator-state.json").is_file()},
            {"path": "output/reviewer-lane.json", "exists": (output / "reviewer-lane.json").is_file()},
            {"path": "output/migration-report.json", "exists": (output / "migration-report.json").is_file()},
            {"path": "output/observability/migration-observability-summary.json", "exists": (output / "observability/migration-observability-summary.json").is_file()},
            {"path": "output/.last-check.json", "exists": (output / ".last-check.json").is_file()},
            {"path": "output/.last-source-check.json", "exists": (output / ".last-source-check.json").is_file()},
            {"path": "output/.last-report-check.json", "exists": (output / ".last-report-check.json").is_file()},
        ],
    }


def markdown(payload: Dict[str, Any]) -> str:
    lines = [
        "# Migration Improvement Backlog",
        "",
        f"- Platform: `{payload['platform']}`",
        f"- Run ID: `{payload['runId']}`",
        f"- Candidate count: `{payload['candidateCount']}`",
        "",
        "Candidates are advisory. Do not automatically promote repairs into production steering, prompts, validators, or implementation.",
        "",
        "## Candidates",
        "",
    ]
    if not payload["candidates"]:
        lines.append("No improvement candidates were generated from available artifacts.")
    for candidate in payload["candidates"]:
        pattern = candidate["failurePattern"]
        change = candidate["proposedChange"]
        lines.extend(
            [
                f"### {candidate['candidateId']}",
                "",
                f"- Pattern: {pattern['summary']}",
                f"- Frequency: `{candidate['frequency']}`",
                f"- Proposed target: `{change['target']}`",
                f"- Confidence: `{candidate['confidenceLevel']}`",
                f"- Human approval: `{candidate['humanApprovalStatus']}`",
                f"- Regression fixture required: `{str(candidate['regressionFixtureRequired']['required']).lower()}`",
                "",
            ]
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate migration improvement backlog.")
    parser.add_argument("--platform", required=True, choices=["android", "ios"])
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--tool-dir", required=True)
    args = parser.parse_args()
    tool_dir = Path(args.tool_dir)
    payload = generate(args.platform, Path(args.project_root), tool_dir)
    output = tool_dir / "output"
    write_json(output / "migration-improvement-backlog.json", payload)
    (output / "migration-improvement-backlog.md").write_text(markdown(payload), encoding="utf-8")
    print(json.dumps({"candidateCount": payload["candidateCount"], "output": str(output / "migration-improvement-backlog.json")}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
