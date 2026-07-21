#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$TOOL_DIR/output"
MIGRATION_REPORT="$OUT_DIR/migration-report.json"
ANALYSIS_REPORT="$OUT_DIR/tool-analysis-report.json"
VERSION_FILE="$TOOL_DIR/VERSION"

TOOL_VERSION="unknown"
if [[ -f "$VERSION_FILE" ]]; then
    TOOL_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
fi

mkdir -p "$OUT_DIR"

python3 - "$MIGRATION_REPORT" "$ANALYSIS_REPORT" "$TOOL_VERSION" <<'PY'
import datetime
import json
import os
import sys

migration_report_path = sys.argv[1]
analysis_report_path = sys.argv[2]
tool_version = sys.argv[3]

now = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"

report = {
    "schemaVersion": "1.0.0",
    "generatedAt": now,
    "toolkit": {
        "name": "dynamics-migration-tool",
        "platform": "iOS",
        "version": tool_version,
    },
    "inputArtifacts": {
        "migrationReportPresent": False,
        "migrationReportPath": "dynamics-migration-tool/output/migration-report.json",
    },
    "runSummary": {
        "overallStatus": "unknown",
        "validation": {"passed": False, "failures": 0, "warnings": 0},
        "counts": {
            "filesModified": 0,
            "apisReplaced": 0,
            "manualTodos": 0,
            "unsupportedFeatures": 0,
        },
    },
    "coverageSummary": {
        "migrated": 0,
        "partial": 0,
        "notApplicable": 0,
        "unknown": 0,
        "areas": [],
    },
    "frictionSignals": {
        "highPriorityManualTodos": 0,
        "highRiskApiReplacements": 0,
        "failedCoverageAreas": [],
    },
    "developerFeedback": {
        "overallExperience": "",
        "biggestPainPoint": "",
        "mostHelpfulStep": "",
        "suggestions": "",
    },
    "notes": [
        "Auto-generated from migration-report.json.",
        "Review and optionally fill developerFeedback fields before sharing internally.",
    ],
}

if os.path.exists(migration_report_path):
    report["inputArtifacts"]["migrationReportPresent"] = True
    with open(migration_report_path, "r", encoding="utf-8") as f:
        migration = json.load(f)

    summary = migration.get("summary", {})
    validation = migration.get("validation", {})
    files_modified = migration.get("filesModified", [])
    apis_replaced = migration.get("apisReplaced", [])
    manual_todos = migration.get("manualTodos", [])
    unsupported = migration.get("unsupportedFeatures", [])
    coverage = migration.get("coverage", {})

    report["runSummary"]["overallStatus"] = summary.get("overallStatus", "unknown")

    def coerce_count(value):
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, int):
            return value
        if isinstance(value, float):
            return int(value)
        if isinstance(value, list):
            return len(value)
        if isinstance(value, str) and value.strip().isdigit():
            return int(value.strip())
        return 0

    report["runSummary"]["validation"] = {
        "passed": bool(validation.get("passed", False)),
        "failures": coerce_count(validation.get("failures", 0)),
        "warnings": coerce_count(validation.get("warnings", 0)),
    }
    report["runSummary"]["counts"] = {
        "filesModified": len(files_modified),
        "apisReplaced": len(apis_replaced),
        "manualTodos": len(manual_todos),
        "unsupportedFeatures": len(unsupported),
    }

    migrated = partial = not_app = unknown = 0
    failed_areas = []
    area_rows = []
    coverage_rows = []
    if isinstance(coverage, dict):
        coverage_rows = list(coverage.items())
    elif isinstance(coverage, list):
        for row in coverage:
            if not isinstance(row, dict):
                continue
            area_name = str(row.get("area", row.get("domain", "unknown")))
            coverage_rows.append((area_name, row))

    for area_name, area_value in coverage_rows:
        status = "unknown"
        details = ""
        if isinstance(area_value, dict):
            status = str(area_value.get("status", "unknown"))
            details = str(area_value.get("details", ""))

        if status == "migrated":
            migrated += 1
        elif status == "partial":
            partial += 1
            failed_areas.append(area_name)
        elif status == "not-applicable":
            not_app += 1
        else:
            unknown += 1

        area_rows.append({"area": area_name, "status": status, "details": details})

    report["coverageSummary"] = {
        "migrated": migrated,
        "partial": partial,
        "notApplicable": not_app,
        "unknown": unknown,
        "areas": area_rows,
    }

    high_priority = sum(1 for t in manual_todos if str(t.get("priority", "")).lower() == "high")
    high_risk = sum(1 for a in apis_replaced if str(a.get("risk", "")).lower() == "high")
    report["frictionSignals"] = {
        "highPriorityManualTodos": high_priority,
        "highRiskApiReplacements": high_risk,
        "failedCoverageAreas": failed_areas,
    }

with open(analysis_report_path, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, ensure_ascii=True)
    f.write("\n")
PY

echo "Generated: dynamics-migration-tool/output/tool-analysis-report.json"
