#!/usr/bin/env python3
"""Sync migration-report.json provenance from bootstrap.json (recorder-owned).

The recorder is the single source of truth for prompt execution audit:
bootstrap.json executedPrompts[] is canonical; migration-report.json
provenance must mirror it after every successful record when a report exists.
"""

from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path
from typing import Any


def _load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: root must be a JSON object")
    return data


def _write_json(path: Path, data: dict[str, Any]) -> None:
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")


def _exec_pairs(executed: Any) -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []
    if not isinstance(executed, list):
        return pairs
    for ep in executed:
        if not isinstance(ep, dict):
            continue
        pid = ep.get("promptId")
        status = ep.get("status")
        if isinstance(pid, str) and isinstance(status, str):
            pairs.append((pid, status))
    return pairs


def _normalize_source_mode(raw_mode: Any) -> str:
    if raw_mode in ("source", "final-source"):
        return str(raw_mode)
    if raw_mode in ("full", "final", "fullSweep"):
        # Manual diagnostics may still run full/final sweeps, but the report's
        # validation block must represent source-validation semantics.
        return "source"
    raise ValueError(
        "source-check mode must be source|final-source (or full/final/fullSweep "
        f"for manual diagnostics), got {raw_mode!r}"
    )


def _apply_validation_from_source_check(
    report: dict[str, Any],
    source_check: dict[str, Any],
    report_check: dict[str, Any] | None = None,
) -> None:
    def _to_int(value: Any, default: int) -> int:
        try:
            if value is None:
                return default
            return int(value)
        except Exception:
            return default

    mode = _normalize_source_mode(source_check.get("mode"))
    status = source_check.get("status")
    exit_code = _to_int(source_check.get("exitCode"), 1)
    fail_count = int(source_check.get("failCount", 0) or 0)
    warn_count = int(source_check.get("warnCount", 0) or 0)
    passed = status == "passed" and exit_code == 0 and fail_count == 0

    generated_at = None
    if isinstance(report_check, dict):
        rpt_generated_at = report_check.get("generatedAt")
        if isinstance(rpt_generated_at, str) and rpt_generated_at.strip():
            generated_at = rpt_generated_at
    if generated_at is None:
        src_generated_at = source_check.get("generatedAt")
        if isinstance(src_generated_at, str) and src_generated_at.strip():
            generated_at = src_generated_at
    if generated_at is not None:
        report["generatedAt"] = generated_at

    report["validation"] = {
        "failures": fail_count,
        "mode": mode,
        "passed": passed,
        "warnings": warn_count,
    }
    if passed:
        report["blockingFailuresFromValidate"] = []
    else:
        failures: list[str] = []
        violations = source_check.get("violations")
        if isinstance(violations, list):
            for item in violations:
                if not isinstance(item, dict):
                    continue
                if item.get("severity") != "fail":
                    continue
                message = item.get("message")
                if isinstance(message, str) and message.strip():
                    failures.append(message.strip())
        if not failures:
            failures.append("Source validation reported failures; review output/.last-source-check.json")
        report["blockingFailuresFromValidate"] = failures

    todos = report.get("manualTodos")
    if isinstance(todos, list):
        report["manualTodos"] = [
            t
            for t in todos
            if not (
                isinstance(t, dict)
                and "Prompt 10 recorder has not yet refreshed final validation values."
                in str(t.get("description", ""))
            )
        ]


def sync_report_from_bootstrap(
    report: dict[str, Any],
    bootstrap: dict[str, Any],
    *,
    source_check: dict[str, Any] | None = None,
    report_check: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Refresh report provenance and optional validation fields from bootstrap/sidecars."""
    boot_prov = bootstrap.get("provenance")
    if not isinstance(boot_prov, dict):
        boot_prov = {}
    boot_toolkit = bootstrap.get("toolkit")
    if not isinstance(boot_toolkit, dict):
        boot_toolkit = {}

    run_id = bootstrap.get("runId")
    if isinstance(run_id, str) and run_id.strip():
        report["runId"] = run_id

    prov = report.get("provenance")
    if not isinstance(prov, dict):
        prov = {}
        report["provenance"] = prov

    boot_generated_at = bootstrap.get("generatedAt")
    if isinstance(boot_generated_at, str) and boot_generated_at.strip():
        prov["bootstrapGeneratedAt"] = boot_generated_at

    catalog_contract = boot_prov.get("catalogContract")
    prov["catalogContract"] = (
        catalog_contract
        if isinstance(catalog_contract, str) and catalog_contract.strip()
        else "contracts/api-catalog.v1.0.0.json"
    )

    catalog_version = bootstrap.get("catalogVersion")
    if not isinstance(catalog_version, str) or not catalog_version.strip():
        catalog_version = boot_prov.get("catalogVersion")
    if isinstance(catalog_version, str) and catalog_version.strip():
        prov["catalogVersion"] = catalog_version

    if isinstance(run_id, str) and run_id.strip():
        prov["runId"] = run_id

    toolkit_version = boot_toolkit.get("version")
    if not isinstance(toolkit_version, str) or not toolkit_version.strip():
        toolkit_version = boot_prov.get("toolkitVersion")
    if isinstance(toolkit_version, str) and toolkit_version.strip():
        prov["toolkitVersion"] = toolkit_version

    executed = bootstrap.get("executedPrompts")
    prov["executedPrompts"] = copy.deepcopy(executed if isinstance(executed, list) else [])

    for key in ("gitCommit", "sdkArtifact", "sdkResolvedVersion", "sdkSha256"):
        if key in boot_prov:
            prov[key] = boot_prov.get(key)

    toolkit = report.get("toolkit")
    if isinstance(toolkit, dict):
        if isinstance(boot_toolkit.get("name"), str) and boot_toolkit.get("name"):
            toolkit["name"] = boot_toolkit["name"]
        if isinstance(boot_toolkit.get("platform"), str) and boot_toolkit.get("platform"):
            toolkit["platform"] = boot_toolkit["platform"]
        if isinstance(toolkit_version, str) and toolkit_version.strip():
            toolkit["version"] = toolkit_version

    if source_check is not None:
        _apply_validation_from_source_check(report, source_check, report_check)

    return report


def validation_consistency_errors(
    report: dict[str, Any],
    source_check: dict[str, Any],
) -> list[str]:
    """Return errors if the report validation block contradicts source check.

    Catches the placeholder-values bug where the agent writes
    validation.passed=false/failures>0 before the final sweep runs,
    and the recorder fails to refresh the block from source-sidecar truth.
    """
    errors: list[str] = []
    val = report.get("validation")
    if not isinstance(val, dict):
        return errors

    lc_status = source_check.get("status")
    lc_fail_count = source_check.get("failCount")
    lc_warn_count = source_check.get("warnCount")
    lc_mode = source_check.get("mode")
    report_passed = val.get("passed")
    report_failures = val.get("failures")
    report_warnings = val.get("warnings")
    report_mode = val.get("mode")

    if lc_status == "passed" and report_passed is False:
        errors.append(
            "validation.passed is false but .last-source-check.json status is 'passed' "
            "— stale placeholder was not refreshed by the recorder"
        )
    if lc_status == "passed" and isinstance(report_failures, int) and report_failures > 0:
        errors.append(
            f"validation.failures is {report_failures} but .last-source-check.json "
            "status is 'passed' — stale placeholder was not refreshed"
        )
    if report_passed is True and isinstance(report_failures, int) and report_failures > 0:
        errors.append(
            f"validation.passed is true but validation.failures is "
            f"{report_failures} — mutually inconsistent"
        )
    if report_passed is False and isinstance(report_failures, int) and report_failures == 0:
        errors.append(
            "validation.passed is false but validation.failures is 0 "
            "— mutually inconsistent"
        )
    if isinstance(lc_fail_count, int) and isinstance(report_failures, int) and report_failures != lc_fail_count:
        errors.append(
            f"validation.failures is {report_failures} but .last-source-check.json "
            f"failCount is {lc_fail_count} — values must match source validation"
        )
    if isinstance(lc_warn_count, int) and isinstance(report_warnings, int) and report_warnings != lc_warn_count:
        errors.append(
            f"validation.warnings is {report_warnings} but .last-source-check.json "
            f"warnCount is {lc_warn_count} — values must match source validation"
        )
    if lc_mode not in ("source", "final-source", "full", "final", "fullSweep"):
        errors.append(
            f".last-source-check.json mode is {lc_mode!r}; expected source|final-source "
            "(full/final/fullSweep accepted for manual diagnostics)"
        )
    if report_mode not in ("source", "final-source"):
        errors.append(
            f"validation.mode is {report_mode!r}; expected source|final-source"
        )

    return errors


def provenance_consistency_errors(
    report: dict[str, Any],
    bootstrap: dict[str, Any],
) -> list[str]:
    """Return human-readable drift messages between report and bootstrap."""
    errors: list[str] = []
    boot_prov = bootstrap.get("provenance")
    if not isinstance(boot_prov, dict):
        boot_prov = {}
    boot_toolkit = bootstrap.get("toolkit")
    if not isinstance(boot_toolkit, dict):
        boot_toolkit = {}

    report_run_id = report.get("runId")
    boot_run_id = bootstrap.get("runId")
    if isinstance(report_run_id, str) and isinstance(boot_run_id, str) and report_run_id != boot_run_id:
        errors.append(
            f"runId: report={report_run_id!r} bootstrap={boot_run_id!r}"
        )

    prov = report.get("provenance")
    if not isinstance(prov, dict):
        errors.append("provenance: missing or not an object on migration-report.json")
        return errors

    boot_generated_at = bootstrap.get("generatedAt")
    p_boot_ts = prov.get("bootstrapGeneratedAt")
    if (
        isinstance(boot_generated_at, str)
        and isinstance(p_boot_ts, str)
        and p_boot_ts != boot_generated_at
    ):
        errors.append(
            f"provenance.bootstrapGeneratedAt: report={p_boot_ts!r} bootstrap.generatedAt={boot_generated_at!r}"
        )

    boot_catalog_version = bootstrap.get("catalogVersion")
    p_cat_ver = prov.get("catalogVersion")
    if (
        isinstance(boot_catalog_version, str)
        and isinstance(p_cat_ver, str)
        and p_cat_ver != boot_catalog_version
    ):
        errors.append(
            f"provenance.catalogVersion: report={p_cat_ver!r} bootstrap.catalogVersion={boot_catalog_version!r}"
        )

    boot_toolkit_version = boot_toolkit.get("version")
    p_tk_ver = prov.get("toolkitVersion")
    if (
        isinstance(boot_toolkit_version, str)
        and isinstance(p_tk_ver, str)
        and p_tk_ver != boot_toolkit_version
    ):
        errors.append(
            f"provenance.toolkitVersion: report={p_tk_ver!r} bootstrap.toolkit.version={boot_toolkit_version!r}"
        )

    p_run_id = prov.get("runId")
    if isinstance(boot_run_id, str) and isinstance(p_run_id, str) and p_run_id != boot_run_id:
        errors.append(
            f"provenance.runId: report={p_run_id!r} bootstrap.runId={boot_run_id!r}"
        )

    boot_pairs = _exec_pairs(bootstrap.get("executedPrompts"))
    report_pairs = _exec_pairs(prov.get("executedPrompts"))
    if boot_pairs and sorted(report_pairs) != sorted(boot_pairs):
        errors.append(
            "provenance.executedPrompts: promptId/status pairs differ from bootstrap.json "
            f"(report={report_pairs!r} bootstrap={boot_pairs!r})"
        )

    for key in ("gitCommit", "sdkArtifact", "sdkResolvedVersion", "sdkSha256"):
        if key in boot_prov and prov.get(key) != boot_prov.get(key):
            errors.append(
                f"provenance.{key}: report={prov.get(key)!r} bootstrap.provenance.{key}={boot_prov.get(key)!r}"
            )

    return errors


def cmd_sync(args: argparse.Namespace) -> int:
    bootstrap_path = Path(args.bootstrap)
    report_path = Path(args.report)
    bootstrap = _load_json(bootstrap_path)
    report = _load_json(report_path)

    source_check = None
    if args.source_check:
        source_path = Path(args.source_check)
        if source_path.is_file():
            source_check = _load_json(source_path)

    report_check = None
    if args.report_check:
        report_path_check = Path(args.report_check)
        if report_path_check.is_file():
            report_check = _load_json(report_path_check)

    sync_report_from_bootstrap(
        report,
        bootstrap,
        source_check=source_check,
        report_check=report_check,
    )
    _write_json(report_path, report)

    if args.check:
        drift = provenance_consistency_errors(report, bootstrap)
        if drift:
            print("❌ Provenance consistency check failed after sync:", file=sys.stderr)
            for line in drift:
                print(f"   - {line}", file=sys.stderr)
            return 1
        if source_check is not None:
            val_errors = validation_consistency_errors(report, source_check)
            if val_errors:
                print(
                    "❌ Validation consistency check failed after sync "
                    "(report validation block vs .last-source-check.json):",
                    file=sys.stderr,
                )
                for line in val_errors:
                    print(f"   - {line}", file=sys.stderr)
                return 1

    if not args.quiet:
        print(
            "✅ migration-report.json provenance synced from bootstrap.json "
            f"({len(bootstrap.get('executedPrompts') or [])} executedPrompts entr"
            f"{'y' if len(bootstrap.get('executedPrompts') or []) == 1 else 'ies'})"
        )
        if source_check is not None:
            print("✅ migration-report.json validation summary refreshed from .last-source-check.json")
        if report_check is not None:
            print("✅ report-contract sidecar observed at sync time (.last-report-check.json)")
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    bootstrap = _load_json(Path(args.bootstrap))
    report = _load_json(Path(args.report))
    drift = provenance_consistency_errors(report, bootstrap)
    if drift:
        print("❌ Provenance consistency check failed:", file=sys.stderr)
        for line in drift:
            print(f"   - {line}", file=sys.stderr)
        return 1
    if not args.quiet:
        print("✅ Provenance consistent with bootstrap.json")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sync_p = sub.add_parser("sync", help="Write report provenance from bootstrap")
    sync_p.add_argument("--bootstrap", required=True)
    sync_p.add_argument("--report", required=True)
    sync_p.add_argument(
        "--source-check",
        default="",
        help="Optional .last-source-check.json path (authoritative source validation)",
    )
    sync_p.add_argument(
        "--report-check",
        default="",
        help="Optional .last-report-check.json path (report-contract validation)",
    )
    sync_p.add_argument(
        "--check",
        action="store_true",
        help="Run provenance consistency check after writing",
    )
    sync_p.add_argument("--quiet", action="store_true")
    sync_p.set_defaults(func=cmd_sync)

    check_p = sub.add_parser("check", help="Compare report provenance to bootstrap (no write)")
    check_p.add_argument("--bootstrap", required=True)
    check_p.add_argument("--report", required=True)
    check_p.add_argument("--quiet", action="store_true")
    check_p.set_defaults(func=cmd_check)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
