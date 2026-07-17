#!/usr/bin/env python3
"""Runtime evidence contract helper.

Creates, validates, and summarizes output/runtime-evidence.json. The helper
does not claim runtime success; unavailable device/UEM/human steps must be
recorded as blocked or pending.
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

SCHEMA_VERSION = "1.0.0"
BEHAVIORS = {
    "uem-activation",
    "authorization",
    "lock-unlock",
    "wipe",
    "policy-change",
    "secure-storage",
    "secure-networking",
    "authentication-deferral",
    "background-authorization",
    "icc-appkinetics",
    "dlp-restrictions",
    "clipboard",
    "file-sharing",
    "application-restart",
    "process-death-recovery",
    "offline-reconnect",
}
STATUSES = {"pass", "fail", "blocked", "pending", "not-applicable"}
OVERALL = {"passed", "failed", "blocked", "pending", "not-applicable"}


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def load_json(path: Path) -> Optional[Dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def read_run_id(output_dir: Path) -> str:
    bootstrap = load_json(output_dir / "bootstrap.json") or {}
    return str(bootstrap.get("runId") or (bootstrap.get("provenance") or {}).get("runId") or "unknown-run")


def template(platform: str, run_id: str) -> Dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "platform": platform,
        "runId": run_id,
        "generatedAt": now_iso(),
        "applicationBuild": {
            "identifier": "",
            "version": "",
            "buildNumber": "",
            "buildType": "",
        },
        "environment": {
            "device": "",
            "osVersion": "",
            "uemEnvironment": "",
            "network": "",
        },
        "policyConfiguration": {
            "name": "",
            "settings": {},
        },
        "overallStatus": "pending",
        "summary": "Runtime evidence pending. Do not mark passed until tests execute on a device/UEM environment.",
        "tests": [
            {
                "testId": "runtime-authorization-001",
                "behavior": "authorization",
                "status": "pending",
                "preconditions": ["Device and UEM test environment available"],
                "steps": ["Launch app", "Complete Dynamics authorization"],
                "expectedResult": "App reaches authorized state without pre-auth secure API access.",
                "observedResult": "",
                "evidenceReferences": [],
                "timestamp": now_iso(),
                "tester": {"type": "human", "name": ""},
                "automationSource": None,
                "blockerReason": "Not yet executed",
            }
        ],
    }


def validate(payload: Dict[str, Any], expected_platform: str, expected_run_id: str = "") -> List[str]:
    errors: List[str] = []
    if payload.get("schemaVersion") != SCHEMA_VERSION:
        errors.append("schemaVersion must be 1.0.0")
    if payload.get("platform") != expected_platform:
        errors.append(f"platform must be {expected_platform}")
    if expected_run_id and payload.get("runId") not in {expected_run_id, "unknown-run"}:
        errors.append(f"runId mismatch: expected {expected_run_id}, got {payload.get('runId')!r}")
    if payload.get("overallStatus") not in OVERALL:
        errors.append("overallStatus must be passed|failed|blocked|pending|not-applicable")
    if not isinstance(payload.get("summary"), str) or not payload.get("summary", "").strip():
        errors.append("summary must be a non-empty string")
    for key in ("applicationBuild", "environment", "policyConfiguration"):
        if not isinstance(payload.get(key), dict):
            errors.append(f"{key} must be an object")

    tests = payload.get("tests")
    if not isinstance(tests, list) or not tests:
        errors.append("tests must be a non-empty array")
        return errors
    seen = set()
    has_fail = False
    has_blocked = False
    has_pending = False
    has_pass = False
    for idx, test in enumerate(tests):
        prefix = f"tests[{idx}]"
        if not isinstance(test, dict):
            errors.append(f"{prefix} must be an object")
            continue
        test_id = test.get("testId")
        if not isinstance(test_id, str) or not test_id.strip():
            errors.append(f"{prefix}.testId must be non-empty")
        elif test_id in seen:
            errors.append(f"{prefix}.testId is duplicated: {test_id}")
        else:
            seen.add(test_id)
        behavior = test.get("behavior")
        if behavior not in BEHAVIORS:
            errors.append(f"{prefix}.behavior must be a known runtime behavior")
        status = test.get("status")
        if status not in STATUSES:
            errors.append(f"{prefix}.status must be pass|fail|blocked|pending|not-applicable")
        has_fail = has_fail or status == "fail"
        has_blocked = has_blocked or status == "blocked"
        has_pending = has_pending or status == "pending"
        has_pass = has_pass or status == "pass"
        for key in ("preconditions", "steps", "evidenceReferences"):
            if not isinstance(test.get(key), list):
                errors.append(f"{prefix}.{key} must be an array")
        for key in ("expectedResult", "observedResult", "timestamp"):
            if not isinstance(test.get(key), str):
                errors.append(f"{prefix}.{key} must be a string")
        tester = test.get("tester")
        if not isinstance(tester, dict) or tester.get("type") not in {"human", "automation"}:
            errors.append(f"{prefix}.tester.type must be human|automation")
        if status == "pass":
            if not str(test.get("observedResult") or "").strip():
                errors.append(f"{prefix}.observedResult is required for pass")
            if not test.get("evidenceReferences"):
                errors.append(f"{prefix}.evidenceReferences is required for pass")
        if status in {"blocked", "pending"} and not str(test.get("blockerReason") or "").strip():
            errors.append(f"{prefix}.blockerReason is required for blocked/pending")
    overall = payload.get("overallStatus")
    if overall == "passed" and (has_fail or has_blocked or has_pending or not has_pass):
        errors.append("overallStatus passed requires at least one pass and no fail/blocked/pending tests")
    if overall == "failed" and not has_fail:
        errors.append("overallStatus failed requires at least one failed test")
    if overall == "blocked" and not has_blocked:
        errors.append("overallStatus blocked requires at least one blocked test")
    if overall == "pending" and not has_pending:
        errors.append("overallStatus pending requires at least one pending test")
    return errors


def report_status(payload: Dict[str, Any]) -> str:
    status = payload.get("overallStatus")
    if status == "passed":
        return "passed"
    if status == "failed":
        return "failed"
    return "not-run"


def summary(payload: Dict[str, Any], path: Path) -> Dict[str, Any]:
    tests = payload.get("tests") if isinstance(payload.get("tests"), list) else []
    counts: Dict[str, int] = {status: 0 for status in STATUSES}
    for test in tests:
        if isinstance(test, dict) and test.get("status") in counts:
            counts[test["status"]] += 1
    return {
        "schemaVersion": SCHEMA_VERSION,
        "path": str(path),
        "runId": payload.get("runId"),
        "platform": payload.get("platform"),
        "overallStatus": payload.get("overallStatus"),
        "reportStatus": report_status(payload),
        "summary": payload.get("summary"),
        "testCount": len(tests),
        "statusCounts": counts,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Runtime evidence contract helper.")
    parser.add_argument("--platform", required=True, choices=["android", "ios"])
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--init-template", action="store_true")
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--summary", action="store_true")
    args = parser.parse_args()
    output_dir = Path(args.output_dir)
    path = output_dir / "runtime-evidence.json"
    if args.init_template:
        if path.exists():
            print(f"runtime evidence already exists: {path}")
            return 0
        output_dir.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(template(args.platform, read_run_id(output_dir)), indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(str(path))
        return 0
    payload = load_json(path)
    if not isinstance(payload, dict):
        print(f"runtime evidence missing or invalid JSON: {path}")
        return 1
    errors = validate(payload, args.platform, read_run_id(output_dir))
    if errors:
        print("\n".join(errors))
        return 1
    if args.summary:
        print(json.dumps(summary(payload, path), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
