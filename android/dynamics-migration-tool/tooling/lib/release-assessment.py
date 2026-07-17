#!/usr/bin/env python3
"""Generate Stage 11 benchmark and readiness assessment artifacts.

This helper evaluates evidence only. It does not run migrations, weaken
validators, or change toolkit behavior.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

SCHEMA_VERSION = "1.0.0"
STAGE7_STATUS = "maturing"


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


def read_run_id(output_dir: Path) -> str:
    bootstrap = load_json(output_dir / "bootstrap.json") or {}
    report = load_json(output_dir / "migration-report.json") or {}
    return str(
        bootstrap.get("runId")
        or (bootstrap.get("provenance") or {}).get("runId")
        or report.get("runId")
        or "unknown-run"
    )


def read_cases(benchmark_dir: Path, platform: str) -> List[Dict[str, Any]]:
    if not benchmark_dir.is_dir():
        return []
    cases: List[Dict[str, Any]] = []
    for path in sorted(benchmark_dir.glob("*.json")):
        payload = load_json(path)
        if not isinstance(payload, dict):
            continue
        case_platform = str(payload.get("platform") or platform)
        if case_platform != platform:
            continue
        payload = dict(payload)
        payload.setdefault("sourceFile", str(path))
        cases.append(payload)
    return cases


def boolish(value: Any) -> bool:
    return value is True or str(value).lower() in {"pass", "passed", "success", "succeeded", "true"}


def metric(case: Dict[str, Any], name: str, default: int = 0) -> int:
    metrics = case.get("metrics")
    if not isinstance(metrics, dict):
        return default
    value = metrics.get(name)
    return value if isinstance(value, int) else default


def status_from_runtime(case: Dict[str, Any]) -> str:
    runtime = case.get("runtimeEvidence")
    if isinstance(runtime, dict):
        status = runtime.get("overallStatus") or runtime.get("status")
        if isinstance(status, str):
            return status
    report = case.get("migrationReport")
    if isinstance(report, dict):
        evidence = report.get("evidenceCompleteness")
        if isinstance(evidence, dict):
            runtime_report = evidence.get("runtimeEvidence")
            if isinstance(runtime_report, dict) and isinstance(runtime_report.get("status"), str):
                return runtime_report["status"]
    return "missing"


def summarize_tier(cases: Iterable[Dict[str, Any]], tier: str) -> Dict[str, Any]:
    scoped = [case for case in cases if str(case.get("tier") or "").upper() == tier]
    total = len(scoped)
    passed = sum(1 for case in scoped if boolish(case.get("success") or case.get("status")))
    return {
        "tier": tier,
        "total": total,
        "passed": passed,
        "successRate": (passed / total) if total else None,
    }


def aggregate_metrics(cases: List[Dict[str, Any]]) -> Dict[str, int]:
    fields = [
        "totalDurationMs",
        "agentAndToolOperations",
        "fullFileReads",
        "partialFileReads",
        "redundantUnchangedFileReads",
        "bytesProcessed",
        "repositorySearchCount",
        "buildDurationMs",
        "validationDurationMs",
        "lateStageFailures",
        "repairAttempts",
        "noProgressEscalations",
        "humanInterventions",
        "falseSuccesses",
    ]
    return {field: sum(metric(case, field) for case in cases) for field in fields}


def runtime_completion(cases: List[Dict[str, Any]]) -> Dict[str, Any]:
    if not cases:
        return {"total": 0, "passed": 0, "completionRate": None}
    passed = sum(1 for case in cases if status_from_runtime(case) in {"passed", "pass"})
    return {"total": len(cases), "passed": passed, "completionRate": passed / len(cases)}


def current_run_case(platform: str, output_dir: Path) -> Optional[Dict[str, Any]]:
    report = load_json(output_dir / "migration-report.json")
    observability = load_json(output_dir / "observability/migration-observability-summary.json") or {}
    repair_state = load_json(output_dir / "repair-orchestrator-state.json") or {}
    runtime = load_json(output_dir / "runtime-evidence.json")
    if not any(isinstance(value, dict) for value in (report, observability, repair_state, runtime)):
        return None
    attempts = repair_state.get("attempts") if isinstance(repair_state, dict) else []
    terminal = repair_state.get("terminalOutcome") if isinstance(repair_state, dict) else {}
    return {
        "appId": "current-run",
        "platform": platform,
        "tier": "current",
        "category": "local-artifacts",
        "success": bool((report or {}).get("validation", {}).get("passed")) if isinstance(report, dict) else False,
        "runtimeEvidence": runtime or {},
        "metrics": {
            "totalDurationMs": int(observability.get("totalDurationMs") or 0) if isinstance(observability, dict) else 0,
            "agentAndToolOperations": int(observability.get("eventCount") or 0) if isinstance(observability, dict) else 0,
            "bytesProcessed": int(observability.get("bytesProcessed") or 0) if isinstance(observability, dict) else 0,
            "repositorySearchCount": int(observability.get("repositorySearchCount") or 0) if isinstance(observability, dict) else 0,
            "buildDurationMs": int(observability.get("buildDurationMs") or 0) if isinstance(observability, dict) else 0,
            "validationDurationMs": int(observability.get("validationDurationMs") or 0) if isinstance(observability, dict) else 0,
            "repairAttempts": len(attempts) if isinstance(attempts, list) else 0,
            "noProgressEscalations": 1 if isinstance(terminal, dict) and terminal.get("reason") == "no-progress" else 0,
            "humanInterventions": 1 if isinstance(terminal, dict) and terminal.get("reason") == "human-decision-required" else 0,
        },
    }


def gate(name: str, status: str, evidence: str, owner: str = "migration-kit maintainer") -> Dict[str, str]:
    return {"name": name, "status": status, "evidence": evidence, "owner": owner}


def release_decision(cases: List[Dict[str, Any]], stage7_not_production_default: bool) -> str:
    tier_a = summarize_tier(cases, "A")
    tier_b = summarize_tier(cases, "B")
    runtime = runtime_completion(cases)
    if tier_a["total"] == 0 or tier_b["total"] == 0:
        return "further-hardening"
    if (tier_a["successRate"] or 0) < 0.90 or (tier_b["successRate"] or 0) < 0.75:
        return "further-hardening"
    if (runtime["completionRate"] or 0) < 1.0:
        return "controlled-preview"
    if stage7_not_production_default:
        return "controlled-preview"
    return "production"


def build_assessment(platform: str, output_dir: Path, benchmark_dir: Path) -> Dict[str, Any]:
    benchmark_cases = read_cases(benchmark_dir, platform)
    current = current_run_case(platform, output_dir)
    all_cases = benchmark_cases + ([current] if current else [])
    corpus_cases = [case for case in benchmark_cases if str(case.get("tier") or "").upper() in {"A", "B", "PILOT"}]
    metrics = aggregate_metrics(all_cases)
    tier_a = summarize_tier(corpus_cases, "A")
    tier_b = summarize_tier(corpus_cases, "B")
    runtime = runtime_completion(corpus_cases)
    decision = release_decision(corpus_cases, stage7_not_production_default=True)
    p0: List[Dict[str, str]] = []
    p1: List[Dict[str, str]] = []
    if tier_a["total"] == 0 or tier_b["total"] == 0:
        p0.append(
            {
                "id": "REL-P0-CORPUS-MISSING",
                "title": "Representative Tier A/Tier B benchmark evidence is missing",
                "owner": "migration-kit maintainer",
                "requiredAction": "Run representative Android/iOS corpus migrations and provide benchmark case JSON artifacts.",
            }
        )
    if runtime["total"] == 0 or (runtime["completionRate"] or 0) < 1.0:
        p1.append(
            {
                "id": "REL-P1-RUNTIME-EVIDENCE",
                "title": "Runtime evidence is incomplete for benchmark corpus",
                "owner": "QA/UEM owner",
                "requiredAction": "Complete real device/UEM runtime evidence for every applicable benchmark case.",
            }
        )
    p1.append(
        {
            "id": "REL-P1-STAGE7-MATURITY",
            "title": "Stage 7 repair orchestrator is maturing but not production-default",
            "owner": "migration-kit maintainer",
            "requiredAction": "Keep repair orchestration optional/controlled until benchmark evidence proves expanded coverage, no-progress handling, and human-decision escalation.",
        }
    )
    gates = [
        gate("Contract consistency", "go", "Latest platform preflight and contract checks passed if recorded externally."),
        gate("KPI targets met", "go" if not p0 and tier_a["successRate"] and tier_b["successRate"] else "blocked", "Tier A/Tier B benchmark corpus scorecard."),
        gate("Agent parity", "at-risk", "Requires explicit Kiro/Cursor/Codex/generic parity evidence."),
        gate("Runtime/UEM validation", "go" if runtime["completionRate"] == 1.0 else "at-risk", "Runtime evidence completion rate."),
        gate("Security evidence", "at-risk", "Requires completed security evidence package."),
        gate("Packaging hygiene", "go", "Platform release preflight should remain green."),
    ]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "platform": platform,
        "runId": read_run_id(output_dir),
        "generatedAt": now_iso(),
        "benchmark": {
            "benchmarkDirectory": str(benchmark_dir),
            "caseCount": len(benchmark_cases),
            "currentRunIncluded": current is not None,
            "tierA": tier_a,
            "tierB": tier_b,
            "runtimeEvidenceCompletion": runtime,
            "aggregateMetrics": metrics,
            "cases": all_cases,
        },
        "stage7RepairOrchestrator": {
            "maturity": STAGE7_STATUS,
            "defaultRecommendation": "optional-controlled-lane",
            "productionDefaultReady": False,
            "reason": "Stage 7 has moved beyond the initial MVP with broader controlled prompt coverage and stronger escalation metadata, but it is still not production-default autonomous repair.",
        },
        "qualityGuardrail": {
            "statement": "Efficiency or success-rate improvements are valid only when validation coverage, runtime evidence, and security evidence are not weakened.",
            "weakerValidationAllowed": False,
            "reducedCoverageAllowed": False,
        },
        "remainingP0": p0,
        "remainingP1": p1,
        "recommendedDefaults": [
            "prompt-scoped deterministic validation",
            "durable loop state",
            "standardized validator diagnostics",
            "runtime evidence contract",
            "reviewer lane as advisory evidence",
            "improvement backlog as advisory maintainer input",
        ],
        "recommendedOptionalFeatures": [
            "observability event logging",
            "repository manifest/context summary",
            "Stage 7 repair orchestrator maturing lane for controlled prompts only",
            "retrospective and benchmark artifact generation",
        ],
        "rolloutPlan": [
            "Keep deterministic validators authoritative.",
            "Ship reviewer/runtime/improvement evidence as advisory/default-safe artifacts.",
            "Enable Stage 7 repair orchestration only in controlled preview for selected prompts.",
            "Require benchmark corpus evidence before production release.",
        ],
        "rollbackPlan": [
            "Disable optional wrappers without changing migrated app code.",
            "Fall back to direct recorder and validate.sh gates.",
            "Treat generated output artifacts as disposable evidence, not source of truth.",
        ],
        "compatibilityPlan": [
            "Preserve current report and sidecar schema versions.",
            "Add new Stage 11 artifacts as optional outputs.",
            "Do not require benchmark artifacts during normal app migrations.",
        ],
        "releaseGates": gates,
        "decision": decision,
    }


def benchmark_markdown(payload: Dict[str, Any]) -> str:
    bench = payload["benchmark"]
    metrics = bench["aggregateMetrics"]
    lines = [
        "# Loop Evolution Benchmark",
        "",
        f"- Platform: `{payload['platform']}`",
        f"- Benchmark cases: `{bench['caseCount']}`",
        f"- Current run included: `{str(bench['currentRunIncluded']).lower()}`",
        f"- Tier A success rate: `{bench['tierA']['successRate']}`",
        f"- Tier B success rate: `{bench['tierB']['successRate']}`",
        f"- Runtime evidence completion: `{bench['runtimeEvidenceCompletion']['completionRate']}`",
        "",
        "## Aggregate Metrics",
        "",
    ]
    for key, value in metrics.items():
        lines.append(f"- `{key}`: `{value}`")
    lines.extend(
        [
            "",
            "Improvements must be interpreted only alongside validation coverage, runtime evidence, and security evidence. Lower duration or fewer reads is not a release-quality gain if coverage is weaker.",
            "",
        ]
    )
    return "\n".join(lines)


def readiness_markdown(payload: Dict[str, Any]) -> str:
    lines = [
        "# Loop Readiness Assessment",
        "",
        f"- Platform: `{payload['platform']}`",
        f"- Decision: `{payload['decision']}`",
        f"- Stage 7 repair orchestrator maturity: `{payload['stage7RepairOrchestrator']['maturity']}`",
        f"- Stage 7 production default ready: `{str(payload['stage7RepairOrchestrator']['productionDefaultReady']).lower()}`",
        "",
        "## Remaining P0 Issues",
        "",
    ]
    if not payload["remainingP0"]:
        lines.append("No P0 issues recorded by this assessment.")
    for item in payload["remainingP0"]:
        lines.append(f"- `{item['id']}` {item['title']} — owner: {item['owner']}")
    lines.extend(["", "## Remaining P1 Issues", ""])
    if not payload["remainingP1"]:
        lines.append("No P1 issues recorded by this assessment.")
    for item in payload["remainingP1"]:
        lines.append(f"- `{item['id']}` {item['title']} — owner: {item['owner']}")
    lines.extend(["", "## Recommended Defaults", ""])
    for item in payload["recommendedDefaults"]:
        lines.append(f"- {item}")
    lines.extend(["", "## Recommended Optional Features", ""])
    for item in payload["recommendedOptionalFeatures"]:
        lines.append(f"- {item}")
    lines.extend(["", "## Release Gates", ""])
    for gate_row in payload["releaseGates"]:
        lines.append(f"- `{gate_row['status']}` {gate_row['name']}: {gate_row['evidence']}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate Stage 11 release assessment.")
    parser.add_argument("--platform", required=True, choices=["android", "ios"])
    parser.add_argument("--tool-dir", required=True)
    parser.add_argument("--benchmark-dir", default="")
    args = parser.parse_args()
    tool_dir = Path(args.tool_dir)
    output = tool_dir / "output"
    benchmark_dir = Path(args.benchmark_dir) if args.benchmark_dir else output / "benchmarks"
    payload = build_assessment(args.platform, output, benchmark_dir)
    write_json(output / "loop-readiness-assessment.json", payload)
    (output / "loop-evolution-benchmark.md").write_text(benchmark_markdown(payload), encoding="utf-8")
    (output / "loop-readiness-assessment.md").write_text(readiness_markdown(payload), encoding="utf-8")
    print(json.dumps({"decision": payload["decision"], "output": str(output / "loop-readiness-assessment.json")}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
