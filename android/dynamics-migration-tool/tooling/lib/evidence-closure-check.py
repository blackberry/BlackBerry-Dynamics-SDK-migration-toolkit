#!/usr/bin/env python3
"""Cross-check agent-authored inventory against independent validator evidence.

Used by validate.sh (validator mode), record-prompt-execution.sh (recorder mode),
and phase-report.sh (report mode).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

EVIDENCE_DOMAINS = frozenset(
    {
        "secureNetworking",
        "secureFileStorage",
        "secureSql",
        "icc",
        "secureUiWidgets",
        "secureClipboard",
        "webview",
    }
)
LOW_PRIORITY_CLASSES = frozenset({"bridge", "read-only-ui", "inventory-artifact"})


def _load(path: str | None) -> dict[str, Any]:
    if not path or not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    return data if isinstance(data, dict) else {}


def _norm_path(value: str) -> str:
    return value.replace("\\", "/").lstrip("./")


def _surface_class(surface: dict[str, Any]) -> str:
    surface_class = surface.get("surfaceClass")
    if isinstance(surface_class, str) and surface_class:
        return surface_class
    if surface.get("securityCritical") is True:
        return "data-path"
    return "inventory-artifact"


def _domain_rows(analysis: dict, domain: str) -> list[dict]:
    return [
        row
        for row in analysis.get("executionPlan") or []
        if isinstance(row, dict) and row.get("domain") == domain
    ]


def _domain_applicable(analysis: dict, domain: str) -> bool:
    rows = _domain_rows(analysis, domain)
    return any(r.get("applicable") is True for r in rows)


def _domain_not_applicable(analysis: dict, domain: str) -> bool:
    rows = _domain_rows(analysis, domain)
    return bool(rows) and all(r.get("applicable") is not True for r in rows)


def _call_sites_for_domain(analysis: dict, domain: str) -> list[dict]:
    sites: list[dict] = []
    for row in _domain_rows(analysis, domain):
        if row.get("applicable") is not True:
            continue
        cs = row.get("callSites")
        if isinstance(cs, list):
            for item in cs:
                if isinstance(item, dict):
                    sites.append(item)
    return sites


def _covered_files(analysis: dict, plan_state: dict, domain: str) -> set[str]:
    covered: set[str] = set()
    by_key = {}
    for disp in plan_state.get("dispositions") or []:
        if isinstance(disp, dict):
            by_key[(disp.get("domain"), disp.get("callSiteId"))] = disp
    for cs in _call_sites_for_domain(analysis, domain):
        cid = cs.get("id")
        disp = by_key.get((domain, cid))
        if not isinstance(disp, dict):
            continue
        if disp.get("status") not in ("migrated", "removed"):
            continue
        for key in ("file", "sourceFile", "path"):
            val = cs.get(key)
            if isinstance(val, str) and val.strip():
                covered.add(_norm_path(val))
    return covered


def _manual_todo_files(report: dict, domain: str) -> set[str]:
    files: set[str] = set()
    for todo in report.get("manualTodos") or []:
        if not isinstance(todo, dict):
            continue
        if todo.get("domain") != domain:
            blob = " ".join(
                str(todo.get(key, ""))
                for key in ("title", "reason", "domain")
            )
            if domain not in blob:
                continue
        for item in todo.get("evidence") or []:
            if isinstance(item, str) and item.strip():
                files.add(_norm_path(item))
    return files


def _surface_covered(surface_file: str, covered: set[str], manual: set[str]) -> bool:
    sf = _norm_path(surface_file)
    for cf in covered:
        if sf == cf or sf.endswith("/" + cf) or cf in sf:
            return True
    for mf in manual:
        if mf in sf or sf.endswith("/" + mf):
            return True
    return False


def _surface_counts(surfaces: list[dict]) -> str:
    counts: dict[str, int] = {}
    for surface in surfaces:
        surface_class = _surface_class(surface)
        counts[surface_class] = counts.get(surface_class, 0) + 1
    return ", ".join(f"{kind}={counts[kind]}" for kind in sorted(counts))


def _first_surface_ids(surfaces: list[dict], limit: int = 6) -> str:
    ids = [
        repr(surface.get("id"))
        for surface in surfaces
        if isinstance(surface.get("id"), str)
    ]
    if len(ids) > limit:
        return ", ".join(ids[:limit]) + " ..."
    return ", ".join(ids)


def evaluate_independent_closure(
    evidence: dict,
    analysis: dict,
    plan_state: dict,
    report: dict | None = None,
    *,
    require_report_fields: bool = False,
    domains: set[str] | None = None,
) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    surfaces = [s for s in (evidence.get("surfaces") or []) if isinstance(s, dict)]
    by_domain: dict[str, list[dict]] = {}
    for surf in surfaces:
        domain = surf.get("domain")
        if isinstance(domain, str):
            by_domain.setdefault(domain, []).append(surf)

    for domain, domain_surfaces in sorted(by_domain.items()):
        if domains is not None and domain not in domains:
            continue
        critical_surfaces = [s for s in domain_surfaces if _surface_class(s) == "data-path"]
        if _domain_not_applicable(analysis, domain):
            target = errors if critical_surfaces else warnings
            target.append(
                f"independent evidence: domain {domain!r} is marked not-applicable in "
                f"migration-analysis.json but validator rediscovered "
                f"{len(domain_surfaces)} surface(s) ({_surface_counts(domain_surfaces)}) — re-run prompt 00"
            )
            continue

        if not _domain_applicable(analysis, domain):
            if domain not in EVIDENCE_DOMAINS:
                continue
            target = errors if critical_surfaces else warnings
            target.append(
                f"independent evidence: domain {domain!r} missing from applicable "
                f"executionPlan[] but validator rediscovered "
                f"{len(domain_surfaces)} surface(s) ({_surface_counts(domain_surfaces)}) — re-run prompt 00"
            )
            continue

        call_sites = _call_sites_for_domain(analysis, domain)
        if len(call_sites) == 0 and domain_surfaces:
            target = errors if critical_surfaces else warnings
            target.append(
                f"independent evidence: domain {domain!r} is applicable with empty "
                f"callSites[] but validator rediscovered surface(s) "
                f"({_surface_counts(domain_surfaces)}) — prompt execution cannot close this domain without inventory evidence"
            )

        covered = _covered_files(analysis, plan_state, domain)
        manual = _manual_todo_files(report or {}, domain)
        uncovered_critical: list[dict] = []
        uncovered_low_priority: list[dict] = []
        for surf in domain_surfaces:
            sf = surf.get("sourceFile")
            if not isinstance(sf, str):
                continue
            if _surface_covered(sf, covered, manual):
                continue
            if _surface_class(surf) == "data-path":
                uncovered_critical.append(surf)
            else:
                uncovered_low_priority.append(surf)

        if uncovered_critical:
            errors.append(
                f"independent evidence: uncovered data-path surface(s) in domain {domain!r} "
                f"({len(uncovered_critical)}; first ids: {_first_surface_ids(uncovered_critical)}) — "
                "add prompt 00 inventory + disposition or record a manualTodos[] entry with evidence"
            )
        if uncovered_low_priority:
            warnings.append(
                f"independent evidence: uncovered inventory-only surface(s) in domain {domain!r} "
                f"({len(uncovered_low_priority)}; {_surface_counts(uncovered_low_priority)}) — "
                "backfill prompt 00 inventory/dispositions to improve audit completeness"
            )

    if require_report_fields and report:
        ec = report.get("evidenceCompleteness")
        if not isinstance(ec, dict):
            errors.append("migration-report.json missing required evidenceCompleteness object")
        else:
            overall = ec.get("overallStatus")
            if overall not in ("complete", "incomplete", "partial"):
                errors.append("evidenceCompleteness.overallStatus must be complete|incomplete|partial")
            runtime = ec.get("runtimeEvidence")
            if not isinstance(runtime, dict):
                errors.append("evidenceCompleteness.runtimeEvidence is required")
            else:
                status = runtime.get("status")
                summary = runtime.get("summary")
                if status not in ("passed", "failed", "not-run"):
                    errors.append(
                        "evidenceCompleteness.runtimeEvidence.status must be passed|failed|not-run"
                    )
                if not isinstance(summary, str) or not summary.strip():
                    errors.append(
                        "evidenceCompleteness.runtimeEvidence.summary must be a non-empty string"
                    )

        report_unverified = report.get("unverifiedSurfaces")
        if not isinstance(report_unverified, list):
            errors.append("migration-report.json missing required unverifiedSurfaces array")
        else:
            report_ids = {
                item.get("id")
                for item in report_unverified
                if isinstance(item, dict) and isinstance(item.get("id"), str)
            }
            critical_surfaces = [s for s in surfaces if _surface_class(s) == "data-path"]
            for surf in critical_surfaces:
                sf = surf.get("sourceFile")
                domain = surf.get("domain", "")
                if not isinstance(sf, str) or not isinstance(domain, str):
                    continue
                covered = _covered_files(analysis, plan_state, domain)
                manual = _manual_todo_files(report, domain)
                if _surface_covered(sf, covered, manual):
                    continue
                if surf.get("id") not in report_ids:
                    errors.append(
                        f"unverifiedSurfaces[] missing independent surface {surf.get('id')!r}"
                    )

        rr = report.get("releaseReadiness") or {}
        rec = rr.get("recommendation") if isinstance(rr, dict) else None
        if rec == "go":
            if isinstance(ec, dict) and ec.get("overallStatus") != "complete":
                errors.append(
                    "releaseReadiness.recommendation is 'go' but "
                    "evidenceCompleteness.overallStatus is not 'complete'"
                )
            blocking_open = [
                t
                for t in (report.get("manualTodos") or [])
                if isinstance(t, dict)
                and t.get("blocking") is True
                and t.get("status") in (None, "open")
            ]
            if blocking_open:
                errors.append(
                    "releaseReadiness.recommendation is 'go' but blocking manualTodos remain open"
                )
            critical_unverified = [
                item
                for item in (report_unverified or [])
                if isinstance(item, dict)
                and item.get("securityCritical") is True
                and item.get("status") not in ("resolved", "acceptedRisk", "notApplicable")
            ]
            if critical_unverified:
                errors.append(
                    "releaseReadiness.recommendation is 'go' but security-critical "
                    "unverifiedSurfaces remain"
                )
            runtime_status = (ec or {}).get("runtimeEvidence", {}).get("status")
            if runtime_status == "failed":
                errors.append(
                    "releaseReadiness.recommendation is 'go' but runtimeEvidence.status is failed"
                )

    return errors, warnings


def main() -> int:
    parser = argparse.ArgumentParser(description="Independent evidence closure check")
    parser.add_argument("--mode", choices=("validator", "recorder", "report"), default="validator")
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--analysis")
    parser.add_argument("--plan-state")
    parser.add_argument("--report")
    parser.add_argument(
        "--domain",
        action="append",
        default=[],
        help="Limit checks to one or more evidence domains (repeatable)",
    )
    args = parser.parse_args()

    evidence = _load(args.evidence)
    analysis = _load(args.analysis)
    plan_state = _load(args.plan_state)
    report = _load(args.report)

    require_report = args.mode == "report"
    domains = {d for d in (args.domain or []) if isinstance(d, str) and d.strip()}
    errors, warnings = evaluate_independent_closure(
        evidence,
        analysis,
        plan_state,
        report,
        require_report_fields=require_report,
        domains=domains if domains else None,
    )

    prefix = {
        "validator": "Independent evidence closure",
        "recorder": "requires[] independent-evidence gate",
        "report": "Report evidence contract",
    }[args.mode]
    for warning in warnings:
        print(f"WARN: {prefix}: {warning}", file=sys.stderr)
    for err in errors:
        print(f"ERROR: {prefix}: {err}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
