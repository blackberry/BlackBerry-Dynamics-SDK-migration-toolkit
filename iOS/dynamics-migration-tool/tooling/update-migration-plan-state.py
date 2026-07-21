#!/usr/bin/env python3
"""
Atomic updater for output/migration-plan-state.json.

This is the only supported mutation path for call-site dispositions.
Prompts must not edit migration-plan-state.json directly.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Tuple


ALLOWED_STATUSES = {"migrated", "removed", "blocked", "deferred", "notApplicable"}

# Conservative transition policy for deterministic behavior.
ALLOWED_TRANSITIONS = {
    "migrated": {"migrated"},
    "removed": {"removed"},
    "blocked": {"blocked", "removed", "migrated", "notApplicable"},
    "notApplicable": {"notApplicable"},
    "deferred": {"deferred", "migrated", "removed", "notApplicable", "blocked"},
}

AUTH_OWNERS = {"03", "03b"}


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(1)


def read_json(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"{label} not found: {path}")
    except json.JSONDecodeError as exc:
        fail(f"{label} is invalid JSON: {exc}")


def write_json_atomic(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", delete=False, dir=str(path.parent), prefix=f"{path.name}.tmp."
    ) as tmp:
        json.dump(payload, tmp, ensure_ascii=False, indent=2, sort_keys=False)
        tmp.write("\n")
        tmp_path = Path(tmp.name)
    os.replace(tmp_path, path)


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def callsite_index(analysis: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    index: Dict[str, Dict[str, Any]] = {}
    for domain in analysis.get("executionPlan", []):
        domain_id = domain.get("domainId", "")
        prompt_id = str(domain.get("promptId", ""))
        for cs in domain.get("callSites", []):
            cs_id = cs.get("id")
            if not cs_id:
                continue
            if cs_id in index:
                fail(f"duplicate call-site ID in analysis: {cs_id}")
            index[cs_id] = {
                "domainId": domain_id,
                "promptId": prompt_id,
            }
    return index


def owner_matches(prompt_id: str, expected_prompt: str, domain_id: str) -> bool:
    if prompt_id == expected_prompt:
        return True
    if domain_id == "authorization" and prompt_id in AUTH_OWNERS and expected_prompt in AUTH_OWNERS:
        return True
    return False


def validate_updates_shape(updates: List[Dict[str, Any]]) -> None:
    seen_ids: set[str] = set()
    for idx, item in enumerate(updates):
        if not isinstance(item, dict):
            fail(f"updates[{idx}] must be an object")
        cs_id = str(item.get("callSiteId", "")).strip()
        status = item.get("status")
        evidence = item.get("evidence")
        if not cs_id:
            fail(f"updates[{idx}].callSiteId is required")
        if cs_id in seen_ids:
            fail(f"duplicate callSiteId in updates: {cs_id}")
        seen_ids.add(cs_id)
        if status not in ALLOWED_STATUSES:
            fail(f"updates[{idx}].status is invalid: {status}")
        if not isinstance(evidence, dict):
            fail(f"updates[{idx}].evidence must be an object")
        if status in {"blocked", "deferred", "notApplicable"}:
            rationale = item.get("rationale")
            if not isinstance(rationale, str) or not rationale.strip():
                fail(f"updates[{idx}] with status '{status}' requires non-empty rationale")


def validate_transition(existing: Dict[str, Any], new_status: str, cs_id: str) -> None:
    old_status = existing.get("status")
    if old_status is None:
        return
    allowed = ALLOWED_TRANSITIONS.get(str(old_status), {str(old_status)})
    if new_status not in allowed:
        fail(f"invalid status transition for {cs_id}: {old_status} -> {new_status}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Update migration-plan-state.json atomically")
    parser.add_argument("--analysis", required=True, help="Path to migration-analysis.json")
    parser.add_argument("--plan", required=True, help="Path to migration-plan-state.json")
    parser.add_argument("--run-id", required=True, help="Current run ID")
    parser.add_argument("--prompt-id", required=True, help="Owning prompt ID")
    parser.add_argument("--domain-id", required=True, help="Owning domain ID")
    parser.add_argument("--updates-file", required=True, help="JSON file containing updates[]")
    args = parser.parse_args()

    analysis_path = Path(args.analysis)
    plan_path = Path(args.plan)
    updates_path = Path(args.updates_file)

    analysis = read_json(analysis_path, "migration-analysis.json")
    updates_obj = read_json(updates_path, "updates file")
    if not isinstance(updates_obj, list):
        fail("updates file must be a JSON array")
    updates = updates_obj
    validate_updates_shape(updates)

    analysis_run = str(analysis.get("runId", ""))
    if analysis_run and analysis_run != args.run_id:
        fail(f"runId mismatch: analysis has {analysis_run}, expected {args.run_id}")

    cs_index = callsite_index(analysis)

    if plan_path.exists():
        plan = read_json(plan_path, "migration-plan-state.json")
    else:
        plan = {
            "schemaVersion": "1.0.0",
            "platform": "ios",
            "runId": args.run_id,
            "updatedAt": now_iso(),
            "dispositions": [],
        }

    if str(plan.get("runId", "")) != args.run_id:
        fail(f"runId mismatch: plan has {plan.get('runId')}, expected {args.run_id}")

    dispositions = plan.get("dispositions", [])
    if not isinstance(dispositions, list):
        fail("migration-plan-state.json dispositions must be an array")

    # Validate current plan uniqueness for this run.
    existing_by_cs: Dict[str, Dict[str, Any]] = {}
    for row in dispositions:
        if not isinstance(row, dict):
            fail("migration-plan-state.json contains non-object disposition")
        if row.get("runId") != args.run_id:
            continue
        cs_id = str(row.get("callSiteId", "")).strip()
        if not cs_id:
            fail("migration-plan-state.json disposition missing callSiteId")
        if cs_id in existing_by_cs:
            fail(f"duplicate active disposition for callSiteId: {cs_id}")
        existing_by_cs[cs_id] = row

    for item in updates:
        cs_id = str(item["callSiteId"]).strip()
        if cs_id not in cs_index:
            fail(f"unknown call-site ID: {cs_id}")
        expected_domain = cs_index[cs_id]["domainId"]
        expected_prompt = cs_index[cs_id]["promptId"]
        if expected_domain != args.domain_id:
            fail(
                f"wrong domain for {cs_id}: analysis says '{expected_domain}', "
                f"updater called with '{args.domain_id}'"
            )
        if not owner_matches(args.prompt_id, expected_prompt, expected_domain):
            fail(
                f"wrong owning prompt for {cs_id}: analysis says '{expected_prompt}', "
                f"updater called with '{args.prompt_id}'"
            )
        if cs_id in existing_by_cs:
            validate_transition(existing_by_cs[cs_id], str(item["status"]), cs_id)

    # Preserve unrelated entries, replace same-run entries for updated call sites.
    replace_ids = {str(u["callSiteId"]).strip() for u in updates}
    kept: List[Dict[str, Any]] = []
    for row in dispositions:
        if (
            isinstance(row, dict)
            and row.get("runId") == args.run_id
            and str(row.get("callSiteId", "")).strip() in replace_ids
        ):
            continue
        kept.append(row)

    ts = now_iso()
    for item in updates:
        status = str(item["status"])
        entry = {
            "callSiteId": str(item["callSiteId"]).strip(),
            "domainId": args.domain_id,
            "promptId": args.prompt_id,
            "status": status,
            "evidence": item["evidence"],
            "rationale": item.get("rationale"),
            "timestamp": ts,
            "runId": args.run_id,
        }
        if status in {"migrated", "removed"}:
            entry["rationale"] = None
        kept.append(entry)

    kept.sort(key=lambda d: (str(d.get("callSiteId", "")), str(d.get("timestamp", ""))))
    plan["updatedAt"] = ts
    plan["dispositions"] = kept

    write_json_atomic(plan_path, plan)
    print(f"OK: updated {len(updates)} call-site disposition(s) in {plan_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
