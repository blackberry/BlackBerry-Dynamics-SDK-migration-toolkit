# BlackBerry Dynamics Migration — validator phase catalog
#
# Sourced by tooling/validate.sh once should_run_phase "catalog" passes.
# Inherits PASS/FAIL/WARN counters, helpers (check_pass/check_fail/
# check_warn, fail_or_defer, strip_audit_noise, NATIVE_SCAN_PY, …)
# and the module-map scope vars from the parent shell.
#
# Do not edit the inner body without preserving validation semantics
# (see docs/android-dynamics-migration-tool-production-readiness-review.md
# and the per-domain steering files for what each check enforces).
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2086,SC2046,SC2016

    # ========================================
    # Phase: API Catalog Cross-Check
    # ========================================
    echo "Phase catalog: API Catalog Cross-Check"
    echo "-----------------------------------------"

    # WI-10 kit self-check: steering/prompts/templates must not ship a
    # non-compiling no-arg canAuthorizeAutonomously() example (only
    # canAuthorizeAutonomously(Context) exists on the public API).
    KIT_DOC_ROOTS=("$TOOL_DIR/steering" "$TOOL_DIR/prompts" "$TOOL_DIR/templates")
    if command -v rg >/dev/null 2>&1; then
        NOARG_CAN_AUTH="$(rg -n 'canAuthorizeAutonomously\s*\(\s*\)' "${KIT_DOC_ROOTS[@]}" 2>/dev/null || true)"
    else
        NOARG_CAN_AUTH="$(grep -rnE 'canAuthorizeAutonomously[[:space:]]*\([[:space:]]*\)' "${KIT_DOC_ROOTS[@]}" 2>/dev/null || true)"
    fi
    if [ -n "$NOARG_CAN_AUTH" ]; then
        check_fail "Kit docs ship non-compiling canAuthorizeAutonomously() no-arg example — use canAuthorizeAutonomously(Context) only (WI-10). Hits:${NOARG_CAN_AUTH}"
    else
        check_pass "Kit docs: no canAuthorizeAutonomously() no-arg examples (WI-10)"
    fi

CATALOG_FILE="$TOOL_DIR/contracts/api-catalog.v1.0.0.json"
REPORT_FILE="dynamics-migration-tool/output/migration-report.json"

if [ ! -f "$CATALOG_FILE" ]; then
    check_fail "contracts/api-catalog.v1.0.0.json not found — cannot validate API replacements against catalog"
elif [ ! -f "$REPORT_FILE" ]; then
    check_warn "migration-report.json not yet generated — catalog cross-check skipped (will run at prompt 10)"
else
    set +e
    CATALOG_CHECK_OUTPUT="$(CATALOG_PATH="$CATALOG_FILE" REPORT_PATH="$REPORT_FILE" SRC_DIR_FOR_CATALOG="$SRC_DIR" python3 - <<'PY'
import json
import os
import sys

catalog_path = os.environ["CATALOG_PATH"]
report_path = os.environ["REPORT_PATH"]
src_dir = os.environ.get("SRC_DIR_FOR_CATALOG", "")

errors = []
warnings = []

try:
    with open(catalog_path, "r", encoding="utf-8") as f:
        catalog = json.load(f)
except Exception as exc:
    print(f"ERROR:cannot parse api-catalog.v1.0.0.json: {exc}")
    sys.exit(0)

try:
    with open(report_path, "r", encoding="utf-8") as f:
        report = json.load(f)
except Exception as exc:
    print(f"ERROR:cannot parse migration-report.json: {exc}")
    sys.exit(0)

rows = catalog.get("rows", [])
valid_ids = {r["id"] for r in rows if isinstance(r, dict) and "id" in r}
supported_ids = {
    r["id"] for r in rows
    if isinstance(r, dict) and r.get("supportStatus") == "supported"
}
unsupported_ids = valid_ids - supported_ids

apis_replaced = report.get("apisReplaced", [])
if not isinstance(apis_replaced, list):
    print("ERROR:apisReplaced is not an array in migration-report.json")
    sys.exit(0)

violations = []

for idx, entry in enumerate(apis_replaced):
    if not isinstance(entry, dict):
        continue
    catalog_row = entry.get("catalogRow")
    original_api = entry.get("originalApi", entry.get("original", "unknown"))
    replacement_api = entry.get("replacementApi", entry.get("replacement", "unknown"))
    files = entry.get("files", entry.get("filesModified", []))
    file_str = ", ".join(files[:3]) if isinstance(files, list) and files else "unknown"

    if not catalog_row:
        violations.append({
            "index": idx,
            "issue": "missing-catalogRow",
            "originalApi": original_api,
            "replacementApi": replacement_api,
            "files": file_str,
            "remediation": (
                f"apisReplaced[{idx}] has no catalogRow. Every API replacement "
                "must reference a valid rows[].id from "
                "contracts/api-catalog.v1.0.0.json. If no catalog entry exists, "
                "move this replacement to manualTodos with status needs-review."
            ),
        })
    elif catalog_row not in valid_ids:
        violations.append({
            "index": idx,
            "issue": "unknown-catalogRow",
            "catalogRow": catalog_row,
            "originalApi": original_api,
            "replacementApi": replacement_api,
            "files": file_str,
            "remediation": (
                f"apisReplaced[{idx}].catalogRow = {catalog_row!r} does not "
                "match any rows[].id in contracts/api-catalog.v1.0.0.json. "
                "Do not invent catalog rows. Either add the row to the catalog "
                "(maintainer action) or move this replacement to manualTodos."
            ),
        })
    elif catalog_row in unsupported_ids:
        row_obj = next((r for r in rows if r.get("id") == catalog_row), {})
        status = row_obj.get("supportStatus", "unknown")
        violations.append({
            "index": idx,
            "issue": "unsupported-catalogRow",
            "catalogRow": catalog_row,
            "supportStatus": status,
            "originalApi": original_api,
            "replacementApi": replacement_api,
            "files": file_str,
            "remediation": (
                f"apisReplaced[{idx}].catalogRow = {catalog_row!r} has "
                f"supportStatus={status!r}. Only rows with "
                "supportStatus='supported' may appear in apisReplaced[]. "
                "Move this to manualTodos or unsupportedFeatures."
            ),
        })

if violations:
    for v in violations:
        print(f"FAIL:{v['remediation']}")
    violation_json = json.dumps(violations, indent=2)
    print(f"VIOLATIONS_JSON:{violation_json}")
else:
    print(f"PASS:All {len(apis_replaced)} apisReplaced[] entries reference valid supported catalog rows")
PY
    )"
    CATALOG_CHECK_RC=$?
    set -e

    CATALOG_VIOLATIONS_JSON=""
    while IFS= read -r line; do
        case "$line" in
            PASS:*)
                check_pass "${line#PASS:}"
                ;;
            FAIL:*)
                check_fail "${line#FAIL:}"
                ;;
            ERROR:*)
                check_fail "${line#ERROR:}"
                ;;
            VIOLATIONS_JSON:*)
                CATALOG_VIOLATIONS_JSON="${line#VIOLATIONS_JSON:}"
                ;;
            *)
                if [ -n "$CATALOG_VIOLATIONS_JSON" ]; then
                    CATALOG_VIOLATIONS_JSON="$CATALOG_VIOLATIONS_JSON
$line"
                fi
                ;;
        esac
    done <<< "$CATALOG_CHECK_OUTPUT"
fi
echo ""
