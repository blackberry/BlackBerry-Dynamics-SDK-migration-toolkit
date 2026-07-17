# BlackBerry Dynamics Migration — validator phase report
#
# Sourced by tooling/validate.sh once should_run_phase "report" passes.
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
    # Migration Report
    # ========================================
    echo "Migration Report"
    echo "-----------------------------------------"

if [ -f "dynamics-migration-tool/output/migration-report.json" ]; then
    check_pass "migration-report.json exists"
    set +e
    EXPECTED_TOOLKIT_VERSION="$(tr -d '[:space:]' < "dynamics-migration-tool/VERSION" 2>/dev/null)"
    MODULE_MAP_FILE_FOR_REPORT="dynamics-migration-tool/output/module-map.json"
    [ -f "$MODULE_MAP_FILE_FOR_REPORT" ] || MODULE_MAP_FILE_FOR_REPORT=""
    ANALYSIS_FILE_FOR_REPORT="dynamics-migration-tool/output/migration-analysis.json"
    [ -f "$ANALYSIS_FILE_FOR_REPORT" ] || ANALYSIS_FILE_FOR_REPORT=""
    PLAN_STATE_FILE_FOR_REPORT="dynamics-migration-tool/output/migration-plan-state.json"
    [ -f "$PLAN_STATE_FILE_FOR_REPORT" ] || PLAN_STATE_FILE_FOR_REPORT=""
    SOURCE_CHECK_FILE_FOR_REPORT="dynamics-migration-tool/output/.last-source-check.json"
    [ -f "$SOURCE_CHECK_FILE_FOR_REPORT" ] || SOURCE_CHECK_FILE_FOR_REPORT=""
    README_FILE_FOR_REPORT="Dynamics_Migration_Readme.md"
    COMPOSE_CLIP_REPORT_SCAN="OK"
    COMPOSE_CLIP_SCAN_PY="$SCRIPT_DIR/lib/compose-clipboard-scan.py"
    if [ -f "$COMPOSE_CLIP_SCAN_PY" ]; then
        CLIP_REPORT_ROOTS=()
        if [ -n "$MM_IN_SCOPE_SOURCE_ROOTS" ]; then
            while IFS= read -r _rroot; do
                [ -n "$_rroot" ] && CLIP_REPORT_ROOTS+=("$_rroot")
            done <<EOF
$MM_IN_SCOPE_SOURCE_ROOTS
EOF
        fi
        if [ "${#CLIP_REPORT_ROOTS[@]}" -eq 0 ] && [ -n "$SRC_DIR" ]; then
            CLIP_REPORT_ROOTS=("$SRC_DIR")
        fi
        if [ "${#CLIP_REPORT_ROOTS[@]}" -gt 0 ]; then
            COMPOSE_CLIP_REPORT_SCAN="$(python3 "$COMPOSE_CLIP_SCAN_PY" "${CLIP_REPORT_ROOTS[@]}" 2>/dev/null || echo OK)"
        fi
    fi
    COMPOSE_ICC_REPORT_SCAN="OK"
    COMPOSE_ICC_SCAN_PY="$SCRIPT_DIR/lib/compose-icc-chooser-scan.py"
    if [ -f "$COMPOSE_ICC_SCAN_PY" ]; then
        ICC_REPORT_ROOTS=()
        if [ -n "$MM_IN_SCOPE_SOURCE_ROOTS" ]; then
            while IFS= read -r _iroot; do
                [ -n "$_iroot" ] && ICC_REPORT_ROOTS+=("$_iroot")
            done <<EOF
$MM_IN_SCOPE_SOURCE_ROOTS
EOF
        fi
        if [ "${#ICC_REPORT_ROOTS[@]}" -eq 0 ] && [ -n "$SRC_DIR" ]; then
            ICC_REPORT_ROOTS=("$SRC_DIR")
        fi
        if [ "${#ICC_REPORT_ROOTS[@]}" -gt 0 ]; then
            COMPOSE_ICC_REPORT_SCAN="$(python3 "$COMPOSE_ICC_SCAN_PY" "${ICC_REPORT_ROOTS[@]}" 2>/dev/null || echo OK)"
        fi
    fi
    REPORT_FP_CALLS=$(grep -rn "FileProvider\.getUriForFile" "$SRC_DIR/" 2>/dev/null \
        | strip_audit_noise \
        | grep -v "test/" \
        | wc -l | tr -d ' ')
    REPORT_FP_DECL=0
    for _mf in $MM_IN_SCOPE_MANIFESTS; do
        [ -f "$_mf" ] || continue
        REPORT_FP_DECL=$((REPORT_FP_DECL + $(grep -rn "androidx.core.content.FileProvider\|android.support.v4.content.FileProvider" "$_mf" 2>/dev/null | wc -l | tr -d ' ')))
    done
    REPORT_FP_PATH_RES=0
    for _res in $MM_IN_SCOPE_RES_DIRS; do
        [ -d "$_res/xml" ] || continue
        REPORT_FP_PATH_RES=$((REPORT_FP_PATH_RES + $(grep -rnE "<files-path|<cache-path|<external-path|<external-files-path|<external-cache-path|<root-path" "$_res/xml" 2>/dev/null | wc -l | tr -d ' ')))
    done
    REPORT_STALE_FILEPROVIDER=0
    if [ "$REPORT_FP_CALLS" -eq 0 ] && { [ "$REPORT_FP_DECL" -gt 0 ] || [ "$REPORT_FP_PATH_RES" -gt 0 ]; }; then
        REPORT_STALE_FILEPROVIDER=1
    fi

    # HR-0-2/HR-0-4: opaque native + broad DLP/export surfaces must be
    # represented as manual interventions in migration-report.json.
    MANUAL_INTERVENTION_CHECK_PY="$SCRIPT_DIR/lib/manual-intervention-check.py"
    if [ -f "$MANUAL_INTERVENTION_CHECK_PY" ]; then
        set +e
        MANUAL_INTERVENTION_OUTPUT="$(python3 "$MANUAL_INTERVENTION_CHECK_PY" \
            --report "dynamics-migration-tool/output/migration-report.json" \
            --native-so-hits "${NATIVE_SO_HITS:-0}" \
            --jni-load-hits "${NATIVE_JNI_LOAD_HITS:-0}" \
            --opaque-binary-dep-hits "${OPAQUE_BINARY_DEP_HITS:-0}" \
            --dlp-notification-hits "${DLP_NOTIFICATION_SURFACE_HITS:-0}" \
            --dlp-print-hits "${DLP_PRINT_SURFACE_HITS:-0}" \
            --dlp-screenshot-hits "${DLP_SCREENSHOT_SURFACE_HITS:-0}" \
            --dlp-autofill-hits "${DLP_AUTOFILL_SURFACE_HITS:-0}" \
            --dlp-accessibility-hits "${DLP_ACCESSIBILITY_SURFACE_HITS:-0}" \
            --dlp-ime-hits "${DLP_IME_SURFACE_HITS:-0}" \
            --dlp-external-browser-hits "${DLP_EXTERNAL_BROWSER_SURFACE_HITS:-0}" \
            --dlp-rich-clipboard-uri-hits "${DLP_RICH_CLIPBOARD_URI_SURFACE_HITS:-0}" \
            --dlp-dragdrop-hits "${DLP_DRAGDROP_SURFACE_HITS:-0}" 2>&1)"
        MANUAL_INTERVENTION_EXIT=$?
        set -e
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            case "$line" in
                OK:*)
                    check_pass "${line#OK:}"
                    ;;
                WARN:*)
                    check_warn "${line#WARN:}"
                    ;;
                ERROR:*)
                    check_fail "${line#ERROR:}"
                    ;;
                *)
                    check_warn "$line"
                    ;;
            esac
        done <<< "$MANUAL_INTERVENTION_OUTPUT"
        if [ "$MANUAL_INTERVENTION_EXIT" -ne 0 ]; then
            check_fail "migration-report.json missing required manualTodos for opaque native/closed-source or DLP/export surfaces"
        fi
    fi

    set +e
    REPORT_CHECK_OUTPUT="$(python3 - "dynamics-migration-tool/output/migration-report.json" "$EXPECTED_TOOLKIT_VERSION" "$BOOTSTRAP_FILE" "$MODULE_MAP_FILE_FOR_REPORT" "$MM_SETTINGS_JSON_TARGETS" "$ANALYSIS_FILE_FOR_REPORT" "$PLAN_STATE_FILE_FOR_REPORT" "$CATALOG_CONTRACT_FILE" "$COMPOSE_CLIP_REPORT_SCAN" "$COMPOSE_ICC_REPORT_SCAN" "$REPORT_STALE_FILEPROVIDER" "$SOURCE_CHECK_FILE_FOR_REPORT" "$README_FILE_FOR_REPORT" <<'PY'
import json
import os
import re
import sys
from datetime import datetime, timezone

path = sys.argv[1]
expected_toolkit_version = sys.argv[2]
bootstrap_path = sys.argv[3]
module_map_path = sys.argv[4] if len(sys.argv) > 4 else ""
settings_json_targets_raw = sys.argv[5] if len(sys.argv) > 5 else ""
analysis_path = sys.argv[6] if len(sys.argv) > 6 else ""
plan_state_path = sys.argv[7] if len(sys.argv) > 7 else ""
catalog_contract_path = sys.argv[8] if len(sys.argv) > 8 else ""
compose_clip_scan = sys.argv[9] if len(sys.argv) > 9 else "OK"
compose_icc_scan = sys.argv[10] if len(sys.argv) > 10 else "OK"
stale_fileprovider = (sys.argv[11] if len(sys.argv) > 11 else "0") == "1"
source_check_path = sys.argv[12] if len(sys.argv) > 12 else ""
readme_path = sys.argv[13] if len(sys.argv) > 13 else "Dynamics_Migration_Readme.md"
settings_json_targets = [t for t in settings_json_targets_raw.split(" ") if t]
errors = []
warnings = []

def check(cond, msg):
    if not cond:
        errors.append(msg)

def validate_follow_up(parent, prefix, required=False):
    follow_up = None
    if isinstance(parent, dict):
        follow_up = parent.get("followUp")
    if follow_up is None:
        if required:
            errors.append(
                f"{prefix}.followUp is required for unresolved migration guidance"
            )
        return
    if not isinstance(follow_up, dict):
        errors.append(f"{prefix}.followUp must be an object")
        return
    why_blocked = follow_up.get("whyBlocked")
    if not isinstance(why_blocked, str) or not why_blocked.strip():
        errors.append(f"{prefix}.followUp.whyBlocked must be a non-empty string")
    safe_next = follow_up.get("safeNextOptions")
    if not isinstance(safe_next, list) or len(safe_next) == 0:
        errors.append(f"{prefix}.followUp.safeNextOptions must be a non-empty array")
    else:
        for idx, option in enumerate(safe_next):
            if not isinstance(option, str) or not option.strip():
                errors.append(
                    f"{prefix}.followUp.safeNextOptions[{idx}] must be a non-empty string"
                )
    suggested_prompt = follow_up.get("suggestedAgentPrompt")
    if not isinstance(suggested_prompt, str) or not suggested_prompt.strip():
        errors.append(
            f"{prefix}.followUp.suggestedAgentPrompt must be a non-empty string"
        )
    evidence_files = follow_up.get("evidenceFiles")
    if evidence_files is not None:
        if not isinstance(evidence_files, list):
            errors.append(f"{prefix}.followUp.evidenceFiles must be an array when present")
        else:
            for idx, evidence in enumerate(evidence_files):
                if not isinstance(evidence, str) or not evidence.strip():
                    errors.append(
                        f"{prefix}.followUp.evidenceFiles[{idx}] must be a non-empty string"
                    )

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    print(f"ERROR:invalid JSON: {exc}")
    sys.exit(1)

required_keys = [
    "schemaVersion", "toolkit", "project", "summary", "filesModified", "apisReplaced",
    "coverage", "manualTodos", "blockingFailuresFromValidate", "runtimeFailures",
    "egressFeatures",
    "unsupportedFeatures", "runtimeTestPlan", "evidenceCompleteness", "unverifiedSurfaces",
    "uemAdminHandoff", "validation", "securityPosture", "migrationConfidence",
    "releaseReadiness", "runId", "provenance",
    "targetModule", "excludedTestOnlyModules", "conventionPlugins",
]

forbidden_keys = ["waiverReview"]
for k in forbidden_keys:
    if k in data:
        errors.append(
            f"unsupported top-level key '{k}' — this toolkit does not "
            f"support line-level exceptions; do not emit this field"
        )
for key in required_keys:
    check(key in data, f"missing top-level key '{key}'")

check(data.get("schemaVersion") == "2.1.0", "schemaVersion must be 2.1.0")

tk = data.get("toolkit", {})
check(isinstance(tk, dict), "toolkit must be an object")
if isinstance(tk, dict):
    check(tk.get("name") == "dynamics-migration-tool", "toolkit.name must be dynamics-migration-tool")
    check(tk.get("platform") == "Android", "toolkit.platform must be Android")
    check(isinstance(tk.get("version"), str) and tk.get("version"), "toolkit.version must be non-empty string")
    check(tk.get("reportSchemaVersion") == "2.1.0", "toolkit.reportSchemaVersion must be 2.1.0")
    if expected_toolkit_version:
        check(tk.get("version") == expected_toolkit_version, "toolkit.version must match dynamics-migration-tool/VERSION")

report_run_id = data.get("runId")
if not isinstance(report_run_id, str) or not re.fullmatch(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}",
    report_run_id,
):
    errors.append("runId must be a UUID string")

prov = data.get("provenance")
check(isinstance(prov, dict), "provenance must be an object")
if isinstance(prov, dict):
    for key in (
        "bootstrapGeneratedAt",
        "catalogVersion",
        "catalogContract",
        "runId",
        "toolkitVersion",
    ):
        val = prov.get(key)
        if not isinstance(val, str) or not val.strip():
            errors.append(f"provenance.{key} must be a non-empty string")
    if isinstance(report_run_id, str):
        check(prov.get("runId") == report_run_id, "provenance.runId must match top-level runId")
    if isinstance(tk, dict):
        check(prov.get("toolkitVersion") == tk.get("version"), "provenance.toolkitVersion must match toolkit.version")
    check(
        prov.get("catalogContract") == "contracts/api-catalog.v1.0.0.json",
        "provenance.catalogContract must be contracts/api-catalog.v1.0.0.json",
    )
    if prov.get("gitCommit") is not None and not isinstance(prov.get("gitCommit"), str):
        errors.append("provenance.gitCommit must be a string or null")
    for key in ("sdkArtifact", "sdkResolvedVersion", "sdkSha256"):
        val = prov.get(key)
        if val is not None and not isinstance(val, str):
            errors.append(f"provenance.{key} must be a string or null")
    exec_prompts = prov.get("executedPrompts")
    if not isinstance(exec_prompts, list):
        errors.append("provenance.executedPrompts must be an array")
    else:
        for idx, ep in enumerate(exec_prompts):
            prefix = f"provenance.executedPrompts[{idx}]"
            if not isinstance(ep, dict):
                errors.append(f"{prefix} must be an object")
                continue
            if not isinstance(ep.get("promptId"), str) or not ep["promptId"].strip():
                errors.append(f"{prefix}.promptId must be a non-empty string")
            if ep.get("status") not in ("completed", "failed", "aborted", "skipped"):
                errors.append(f"{prefix}.status must be completed|failed|aborted|skipped")

v = data.get("validation", {})
check(isinstance(v, dict), "validation must be an object")
if isinstance(v, dict):
    check(isinstance(v.get("passed"), bool), "validation.passed must be boolean")
    check(isinstance(v.get("failures"), int), "validation.failures must be number")
    check(isinstance(v.get("warnings"), int), "validation.warnings must be number")
    # validation.mode is required (schema v2.1.0); must represent source
    # validation, not report-contract validation.
    check(
        v.get("mode") in ("source", "final-source"),
        "validation.mode must be source or final-source (report reflects source validation truth)",
    )
    # Cross-field invariant: passed and failures must be mutually consistent.
    _vp = v.get("passed")
    _vf = v.get("failures")
    if _vp is True and isinstance(_vf, int) and _vf > 0:
        errors.append(
            "validation.passed is true but validation.failures is %d "
            "— mutually inconsistent (stale placeholder?)" % _vf
        )
    if _vp is False and isinstance(_vf, int) and _vf == 0:
        errors.append(
            "validation.passed is false but validation.failures is 0 "
            "— mutually inconsistent (stale placeholder?)"
        )
    # Cross-check against .last-source-check.json when present.
    _lc_path = source_check_path or os.path.join(os.path.dirname(path), ".last-source-check.json")
    if os.path.isfile(_lc_path):
        try:
            with open(_lc_path, "r", encoding="utf-8") as _lcf:
                _lc = json.load(_lcf)
            _lc_mode = _lc.get("mode")
            _lc_scope = _lc.get("scope")
            _lc_status = _lc.get("status")
            _lc_fc = _lc.get("failCount")
            _lc_wc = _lc.get("warnCount")
            if _lc_scope == "source" and _lc_mode in ("source", "final-source"):
                if _lc_status == "passed" and _vp is False:
                    errors.append(
                        "validation.passed is false but .last-source-check.json status is "
                        "'passed' — recorder did not refresh validation block"
                    )
                if _lc_status == "passed" and isinstance(_vf, int) and _vf > 0:
                    errors.append(
                        "validation.failures is %d but .last-source-check.json status is "
                        "'passed' — recorder did not refresh validation block" % _vf
                    )
                if isinstance(_lc_fc, int) and isinstance(_vf, int) and _vf != _lc_fc:
                    errors.append(
                        "validation.failures is %d but .last-source-check.json failCount "
                        "is %d — values diverged after source validation" % (_vf, _lc_fc)
                    )
                if isinstance(_lc_wc, int) and isinstance(v.get("warnings"), int) and v.get("warnings") != _lc_wc:
                    errors.append(
                        "validation.warnings is %d but .last-source-check.json warnCount "
                        "is %d — values diverged after source validation" % (v.get("warnings"), _lc_wc)
                    )
            else:
                errors.append(
                    ".last-source-check.json is missing scope=source/mode=source|final-source"
                )
        except Exception:
            pass

sp = data.get("securityPosture", {})
check(isinstance(sp, dict), "securityPosture must be an object")
if isinstance(sp, dict):
    dar = sp.get("dataAtRest", {})
    dit = sp.get("dataInTransit", {})
    check(isinstance(dar, dict), "securityPosture.dataAtRest must be an object")
    check(isinstance(dit, dict), "securityPosture.dataInTransit must be an object")
    if isinstance(dar, dict):
        check(dar.get("status") in ("secured", "partial", "unverified"),
              "securityPosture.dataAtRest.status must be secured|partial|unverified")
        check(isinstance(dar.get("summary"), str), "securityPosture.dataAtRest.summary must be string")
    if isinstance(dit, dict):
        check(dit.get("status") in ("secured", "partial", "unverified"),
              "securityPosture.dataInTransit.status must be secured|partial|unverified")
        check(isinstance(dit.get("summary"), str), "securityPosture.dataInTransit.summary must be string")

mc = data.get("migrationConfidence", {})
check(isinstance(mc, dict), "migrationConfidence must be an object")
if isinstance(mc, dict):
    score = mc.get("score")
    check(isinstance(score, (int, float)), "migrationConfidence.score must be number")
    if isinstance(score, (int, float)):
        check(0 <= score <= 100, "migrationConfidence.score must be in range 0..100")
    check(mc.get("level") in ("high", "medium", "low"), "migrationConfidence.level must be high|medium|low")
    check(isinstance(mc.get("rationale"), str), "migrationConfidence.rationale must be string")

rr = data.get("releaseReadiness", {})
check(isinstance(rr, dict), "releaseReadiness must be an object")
rec = rr.get("recommendation") if isinstance(rr, dict) else None
if isinstance(rr, dict):
    check(rec in ("go", "go-with-risks", "no-go"),
          "releaseReadiness.recommendation must be go|go-with-risks|no-go")
    check(isinstance(rr.get("blockingItems"), list), "releaseReadiness.blockingItems must be array")
    if rec in ("go-with-risks", "no-go") and not rr.get("blockingItems"):
        warnings.append("releaseReadiness has risk/no-go but blockingItems is empty")

bf = data.get("blockingFailuresFromValidate", [])
check(isinstance(bf, list), "blockingFailuresFromValidate must be an array")
if isinstance(bf, list):
    for idx, item in enumerate(bf):
        if not isinstance(item, str) or not item.strip():
            errors.append(f"blockingFailuresFromValidate[{idx}] must be non-empty string")

rf = data.get("runtimeFailures", [])
check(isinstance(rf, list), "runtimeFailures must be an array")
ALLOWED_RUNTIME_CATEGORIES = (
    "startupAuthSequencing",
    "deferredInitNullability",
    "duplicateActivityInit",
    "other",
)
if isinstance(rf, list):
    for idx, entry in enumerate(rf):
        prefix = f"runtimeFailures[{idx}]"
        if not isinstance(entry, dict):
            errors.append(f"{prefix} must be an object")
            continue
        for key in ("id", "symptom", "rootCause", "promptGap", "validatorGap", "fix"):
            val = entry.get(key)
            if not isinstance(val, str) or not val.strip():
                errors.append(f"{prefix}.{key} must be non-empty string")
        status = entry.get("status")
        if status not in ("open", "fixed"):
            errors.append(f"{prefix}.status must be open|fixed")
        category = entry.get("category")
        if category not in ALLOWED_RUNTIME_CATEGORIES:
            errors.append(
                f"{prefix}.category must be one of "
                + "|".join(ALLOWED_RUNTIME_CATEGORIES)
                + f"; got {category!r}"
            )

# coverage shape — every area must be a {status, details} object, NOT a bare string.
# A bare string here causes the toolkit-analysis-report coverage roll-up to
# classify every area as "unknown" and silently masks partial migrations.
# (Apostrophes are deliberately avoided in this comment block: bash 3.2 on
# macOS misparses unbalanced single quotes inside <<\PY heredocs nested in
# command substitutions, which would break syntax-check on developer machines.)
ALLOWED_COVERAGE_STATUS = ("migrated", "partial", "not-applicable")
ALLOWED_STATUS_LIST = "|".join(ALLOWED_COVERAGE_STATUS)
REQUIRED_COVERAGE_AREAS = (
    "secureNetworking",
    "securePush",
    "backgroundAuthorize",
    "secureFileStorage",
    "secureSql",
    "secureUiWidgets",
    "secureClipboard",
    "authorization",
    "policyManagement",
    "webview",
    "icc",
)
cov = data.get("coverage", {})
check(isinstance(cov, dict), "coverage must be an object")
if isinstance(cov, dict):
    for area_name in REQUIRED_COVERAGE_AREAS:
        if area_name not in cov:
            errors.append(
                "coverage is missing required area '" + area_name + "'"
            )
    for area_name, area_value in cov.items():
        if not isinstance(area_value, dict):
            type_name = type(area_value).__name__
            errors.append(
                "coverage." + str(area_name)
                + " must be an object with keys status and details; got "
                + type_name
                + " (bare strings/values are not accepted by the report contract)"
            )
            continue
        status_val = area_value.get("status")
        if status_val not in ALLOWED_COVERAGE_STATUS:
            errors.append(
                "coverage." + str(area_name) + ".status must be one of "
                + ALLOWED_STATUS_LIST + "; got " + repr(status_val)
            )
        if not isinstance(area_value.get("details"), str):
            errors.append(
                "coverage." + str(area_name) + ".details must be a string"
            )

media_containment = data.get("mediaContainment")
if media_containment is not None:
    if not isinstance(media_containment, dict):
        errors.append("mediaContainment must be an object when present")
    else:
        if not isinstance(media_containment.get("summary"), str) or not media_containment.get("summary").strip():
            errors.append("mediaContainment.summary must be a non-empty string")
        media_write_paths = media_containment.get("mediaWritePaths")
        export_paths = media_containment.get("exportPaths")
        if not isinstance(media_write_paths, list):
            errors.append("mediaContainment.mediaWritePaths must be an array")
        else:
            for idx, entry in enumerate(media_write_paths):
                prefix = f"mediaContainment.mediaWritePaths[{idx}]"
                if not isinstance(entry, dict):
                    errors.append(f"{prefix} must be an object")
                    continue
                for key in ("sourceFile", "api", "originalBehavior", "migratedBehavior"):
                    val = entry.get(key)
                    if not isinstance(val, str) or not val.strip():
                        errors.append(f"{prefix}.{key} must be a non-empty string")
                for key in (
                    "staysInContainer",
                    "usesDirectSecureStream",
                    "usesFilesystemStaging",
                    "publicExportRemains",
                    "manualInterventionRequired",
                ):
                    if not isinstance(entry.get(key), bool):
                        errors.append(f"{prefix}.{key} must be boolean")
                validate_follow_up(
                    entry,
                    prefix,
                    required=(
                        entry.get("usesFilesystemStaging") is True
                        or entry.get("publicExportRemains") is True
                        or entry.get("manualInterventionRequired") is True
                    ),
                )
        if not isinstance(export_paths, list):
            errors.append("mediaContainment.exportPaths must be an array")
        else:
            for idx, entry in enumerate(export_paths):
                prefix = f"mediaContainment.exportPaths[{idx}]"
                if not isinstance(entry, dict):
                    errors.append(f"{prefix} must be an object")
                    continue
                for key in ("sourceFile", "pattern", "dlpImpact", "behaviorChange"):
                    val = entry.get(key)
                    if not isinstance(val, str) or not val.strip():
                        errors.append(f"{prefix}.{key} must be a non-empty string")
                if entry.get("status") not in ("disabled", "migrated", "controlled", "unresolved"):
                    errors.append(f"{prefix}.status must be disabled|migrated|controlled|unresolved")
                if entry.get("safeOutcome") not in ("safe", "partial", "no-go"):
                    errors.append(f"{prefix}.safeOutcome must be safe|partial|no-go")
                validate_follow_up(
                    entry,
                    prefix,
                    required=(
                        entry.get("status") == "unresolved"
                        or entry.get("safeOutcome") in ("partial", "no-go")
                    ),
                )

report_egress = data.get("egressFeatures")
todos = data.get("manualTodos")
has_blocking_manual_todo = False
if not isinstance(todos, list):
    errors.append("manualTodos must be an array")
else:
    for idx, todo in enumerate(todos):
        prefix = f"manualTodos[{idx}]"
        if not isinstance(todo, dict):
            errors.append(f"{prefix} must be an object")
            continue
        if todo.get("blocking") is True:
            has_blocking_manual_todo = True
        elif todo.get("blocking") is not False:
            errors.append(f"{prefix}.blocking must be boolean")
        if todo.get("owner") != "applicationDeveloper":
            errors.append(f"{prefix}.owner must be applicationDeveloper")
        if todo.get("severity") not in ("P0", "P1", "P2", "P3"):
            priority = todo.get("priority")
            if isinstance(priority, str) and priority in ("P0", "P1", "P2", "P3"):
                errors.append(
                    f"{prefix}.severity must be P0|P1|P2|P3 "
                    f"(found priority={priority!r} — use severity, or re-run "
                    f"prepare-report-artifacts.py to alias P0-P3 priority values)"
                )
            elif isinstance(priority, str) and priority.strip():
                errors.append(
                    f"{prefix}.severity must be P0|P1|P2|P3 "
                    f"(found priority={priority!r}; do not use analysis vocab "
                    f"blocker|high|medium|low — map explicitly to P0-P3 severity)"
                )
            else:
                errors.append(f"{prefix}.severity must be P0|P1|P2|P3")
        elif "priority" in todo:
            errors.append(
                f"{prefix} has both severity and priority — use severity only "
                f"(additionalProperties:false); drop priority after aliasing"
            )
        if todo.get("status") not in ("open", "completed", "acceptedRisk", "notApplicable"):
            errors.append(f"{prefix}.status must be open|completed|acceptedRisk|notApplicable")
        for key in ("id", "title", "domain", "reason"):
            val = todo.get(key)
            if not isinstance(val, str) or not val.strip():
                errors.append(f"{prefix}.{key} must be a non-empty string")
        for key in ("affectedModules", "evidence", "requiredActions", "acceptanceCriteria"):
            val = todo.get(key)
            if not isinstance(val, list):
                errors.append(f"{prefix}.{key} must be an array")
                continue
            if key == "requiredActions" and not val:
                errors.append(f"{prefix}.requiredActions must not be empty")
            for item_idx, item in enumerate(val):
                if not isinstance(item, str) or not item.strip():
                    errors.append(f"{prefix}.{key}[{item_idx}] must be a non-empty string")
        validate_follow_up(todo, prefix, required=False)

if has_blocking_manual_todo and rec != "no-go":
    errors.append(
        f"manualTodos[] contains blocking=true but releaseReadiness.recommendation is {rec!r} — blocking manual interventions force no-go"
    )

if isinstance(report_egress, list) and isinstance(todos, list):
    for entry in report_egress:
        if not isinstance(entry, dict):
            continue
        outcome = entry.get("outcome")
        if outcome not in ("BLOCKED_UNTIL_APPROVED", "MANUAL_INTERVENTION_REQUIRED"):
            continue
        feature_id = str(entry.get("id", ""))
        feature_name = str(entry.get("featureName", ""))
        matching = []
        for todo in todos:
            if not isinstance(todo, dict):
                continue
            blob_parts = [str(todo.get("id", "")), str(todo.get("title", "")), str(todo.get("reason", ""))]
            for key in ("evidence", "requiredActions", "acceptanceCriteria"):
                val = todo.get(key)
                if isinstance(val, list):
                    blob_parts.extend(str(v) for v in val if isinstance(v, str))
            blob = " ".join(blob_parts).lower()
            if feature_id.lower() in blob or feature_name.lower() in blob:
                matching.append(todo)
        if not matching:
            errors.append(
                f"egressFeatures entry {feature_id!r} ({feature_name}) requires a matching manualTodos[] entry"
            )
            continue
        if outcome == "BLOCKED_UNTIL_APPROVED":
            if not any(todo.get("blocking") is True for todo in matching):
                errors.append(
                    f"egressFeatures entry {feature_id!r} is blocked but matching manualTodos[] entries are not blocking=true"
                )

unsupported_features = data.get("unsupportedFeatures")
if not isinstance(unsupported_features, list):
    errors.append("unsupportedFeatures must be an array")
else:
    for idx, feature in enumerate(unsupported_features):
        prefix = f"unsupportedFeatures[{idx}]"
        if not isinstance(feature, dict):
            errors.append(f"{prefix} must be an object")
            continue
        for key in ("feature", "reason"):
            val = feature.get(key)
            if not isinstance(val, str) or not val.strip():
                errors.append(f"{prefix}.{key} must be a non-empty string")
        workaround = feature.get("workaround")
        if workaround is not None and (not isinstance(workaround, str) or not workaround.strip()):
            errors.append(f"{prefix}.workaround must be a non-empty string or null")
        validate_follow_up(feature, prefix, required=True)

summary_obj = data.get("summary") or {}
overall_status = summary_obj.get("overallStatus") if isinstance(summary_obj, dict) else None
secure_file_cov = cov.get("secureFileStorage") if isinstance(cov, dict) else None
secure_file_status = secure_file_cov.get("status") if isinstance(secure_file_cov, dict) else None
secure_file_details = secure_file_cov.get("details") if isinstance(secure_file_cov, dict) else ""

# README/report consistency checks (prompt-10 companion artifact).
if not os.path.isfile(readme_path):
    errors.append("Dynamics_Migration_Readme.md missing at project root")
else:
    try:
        with open(readme_path, "r", encoding="utf-8") as rf:
            readme_text = rf.read()
    except Exception as exc:
        errors.append(f"could not read Dynamics_Migration_Readme.md: {exc}")
        readme_text = ""

    if isinstance(readme_text, str) and readme_text.strip():
        required_sections = (
            "# Dynamics Migration Summary",
            "## Overview",
            "## What Changed",
            "## Unsupported Features",
            "## Manual TODOs",
            "## UEM Admin Setup",
            "## Testing",
            "## Finding Migration Changes",
        )
        for section in required_sections:
            if section not in readme_text:
                errors.append(
                    f"Dynamics_Migration_Readme.md missing required section heading: {section}"
                )
        if "[BB_DYNAMICS-MIGRATION]" not in readme_text:
            errors.append(
                "Dynamics_Migration_Readme.md must describe how to locate [BB_DYNAMICS-MIGRATION] markers"
            )

        status_match = re.search(r"(?mi)^-\s*Status:\s*([A-Za-z-]+)\s*$", readme_text)
        if status_match and isinstance(overall_status, str):
            reported_status = status_match.group(1).strip().lower()
            expected_status = {"complete": "complete", "partial": "partial", "failed": "failed"}.get(
                overall_status.lower()
            )
            if expected_status and reported_status != expected_status:
                errors.append(
                    "Dynamics_Migration_Readme.md status line does not match "
                    f"migration-report summary.overallStatus (readme={reported_status!r}, report={expected_status!r})"
                )
        elif isinstance(overall_status, str):
            errors.append(
                "Dynamics_Migration_Readme.md must include a Status line in Overview: - Status: <complete|partial|failed>"
            )
validation_failed = False
if isinstance(v, dict):
    _vp = v.get("passed")
    _vf = v.get("failures")
    validation_failed = (_vp is False) or (isinstance(_vf, int) and _vf > 0)
if validation_failed:
    if rec != "no-go":
        errors.append(
            f"validation.passed is false or validation.failures > 0, but "
            f"releaseReadiness.recommendation is {rec!r} — failed validation must force no-go"
        )
    if overall_status != "failed":
        errors.append(
            f"validation.passed is false or validation.failures > 0, but "
            f"summary.overallStatus is {overall_status!r} — failed validation must force failed status"
        )

# Compose clipboard vs coverage.secureClipboard cross-check
if isinstance(compose_clip_scan, str) and compose_clip_scan.startswith("UNMANAGED|"):
    sc_area = cov.get("secureClipboard") if isinstance(cov, dict) else None
    sc_status = sc_area.get("status") if isinstance(sc_area, dict) else None
    if sc_status == "not-applicable":
        errors.append(
            "coverage.secureClipboard.status is not-applicable but unmanaged "
            "Jetpack Compose clipboard APIs remain in source — re-run prompt 09 "
            "or set status to partial with a manualTodos remediation entry"
        )
    elif sc_status == "migrated":
        errors.append(
            "coverage.secureClipboard.status is migrated but unmanaged "
            "Jetpack Compose clipboard APIs remain — re-run prompt 09"
        )
    todos = data.get("manualTodos")
    if isinstance(todos, list) and sc_status == "partial":
        has_compose_todo = False
        for todo in todos:
            if not isinstance(todo, dict):
                continue
            blob = (
                str(todo.get("title", ""))
                + str(todo.get("reason", ""))
                + " ".join(str(item) for item in todo.get("requiredActions", []) if isinstance(item, str))
            ).lower()
            if "compose" in blob and "clipboard" in blob:
                if todo.get("status") in ("open", "acceptedRisk"):
                    has_compose_todo = True
                    break
        if not has_compose_todo:
            errors.append(
                "unmanaged Compose clipboard APIs remain but manualTodos has no "
                "Compose clipboard remediation entry"
            )

# Compose ICC chooser vs coverage.icc cross-check
if isinstance(compose_icc_scan, str) and compose_icc_scan.startswith("UNMANAGED|"):
    icc_area = cov.get("icc") if isinstance(cov, dict) else None
    icc_status = icc_area.get("status") if isinstance(icc_area, dict) else None
    if icc_status == "not-applicable":
        errors.append(
            "coverage.icc.status is not-applicable but unmanaged Compose ICC "
            "View-system chooser patterns remain — re-run prompt 08 or set "
            "status to partial with a manualTodos remediation entry"
        )
    elif icc_status == "migrated":
        errors.append(
            "coverage.icc.status is migrated but unmanaged Compose ICC "
            "View-system chooser patterns remain — re-run prompt 08"
        )
    todos = data.get("manualTodos")
    if isinstance(todos, list) and icc_status == "partial":
        has_compose_icc_todo = False
        for todo in todos:
            if not isinstance(todo, dict):
                continue
            blob = (
                str(todo.get("title", ""))
                + str(todo.get("reason", ""))
                + " ".join(str(item) for item in todo.get("requiredActions", []) if isinstance(item, str))
            ).lower()
            if ("compose" in blob or "jetpack" in blob) and (
                "icc" in blob or "chooser" in blob or "share" in blob
            ):
                if todo.get("status") in ("open", "acceptedRisk"):
                    has_compose_icc_todo = True
                    break
        if not has_compose_icc_todo:
            errors.append(
                "unmanaged Compose ICC chooser patterns remain but manualTodos "
                "has no Compose ICC remediation entry"
            )

# --- Module map surfacing (schema v2.1.0) ----------------------------
#
# Every multi-module field in the report must be present, well-typed,
# and consistent with output/module-map.json. On canonical single-module
# projects the module map is synthesized to a single-module shape so
# these checks still apply uniformly. Apostrophes are deliberately
# avoided in this section because the surrounding heredoc is nested in
# a $(...) command substitution and bash 3.2 on macOS treats unbalanced
# single quotes inside it as live tokens. Use angle brackets <...>
# instead of quotes around dynamic values in error messages.
module_map = None
if module_map_path:
    try:
        with open(module_map_path, "r", encoding="utf-8") as mmf:
            module_map = json.load(mmf)
    except Exception as exc:
        warnings.append(f"could not parse module-map.json for cross-check: {exc}")

mm_primary = (module_map or {}).get("primaryAppModule") if isinstance(module_map, dict) else None
mm_primary_name = mm_primary.get("name") if isinstance(mm_primary, dict) else None
mm_primary_path = mm_primary.get("path") if isinstance(mm_primary, dict) else None
mm_lib_names = set()
mm_lib_paths = set()
mm_libs = (module_map or {}).get("libraryModulesInScope") if isinstance(module_map, dict) else None
if isinstance(mm_libs, list):
    for lib in mm_libs:
        if isinstance(lib, dict):
            if isinstance(lib.get("name"), str):
                mm_lib_names.add(lib["name"])
            if isinstance(lib.get("path"), str):
                mm_lib_paths.add(lib["path"])
mm_known_module_names = ({mm_primary_name} | mm_lib_names) - {None}
mm_known_module_paths = ({mm_primary_path} | mm_lib_paths) - {None}

# targetModule: required object mirroring primaryAppModule
tm = data.get("targetModule")
if not isinstance(tm, dict):
    errors.append("targetModule must be an object mirroring module-map.json primaryAppModule")
else:
    tm_name = tm.get("name") if isinstance(tm.get("name"), str) else ""
    tm_path = tm.get("path") if isinstance(tm.get("path"), str) else ""
    if not tm_name.strip():
        errors.append("targetModule.name must be a non-empty string")
    if not tm_path.strip():
        errors.append("targetModule.path must be a non-empty string")
    if tm.get("appliesAndroidApplicationPlugin") is not True:
        errors.append("targetModule.appliesAndroidApplicationPlugin must be true")
    if mm_primary_name and tm_name and tm_name != mm_primary_name:
        errors.append(
            f"targetModule.name <{tm_name}> does not match module-map.json "
            f"primaryAppModule.name <{mm_primary_name}>"
        )
    if mm_primary_path and tm_path and tm_path != mm_primary_path:
        errors.append(
            f"targetModule.path <{tm_path}> does not match module-map.json "
            f"primaryAppModule.path <{mm_primary_path}>"
        )

# excludedTestOnlyModules: required array; entries are objects
etom = data.get("excludedTestOnlyModules")
if not isinstance(etom, list):
    errors.append("excludedTestOnlyModules must be an array (use [] when none)")
else:
    for idx, entry in enumerate(etom):
        prefix = f"excludedTestOnlyModules[{idx}]"
        if not isinstance(entry, dict):
            errors.append(f"{prefix} must be an object")
            continue
        if not isinstance(entry.get("name"), str) or not entry["name"].strip():
            errors.append(f"{prefix}.name must be a non-empty string")
        if not isinstance(entry.get("path"), str) or not entry["path"].strip():
            errors.append(f"{prefix}.path must be a non-empty string")
        valid_reached_via = {
            "testImplementation",
            "androidTestImplementation",
            "testApi",
            "androidTestApi",
            "testCompileOnly",
            "androidTestCompileOnly",
            "testRuntimeOnly",
            "androidTestRuntimeOnly",
        }
        if entry.get("reachedVia") not in valid_reached_via:
            errors.append(
                f"{prefix}.reachedVia must be one of the test configuration names "
                "(testImplementation, androidTestImplementation, ...)"
            )

# conventionPlugins: required array
cp = data.get("conventionPlugins")
if not isinstance(cp, list):
    errors.append("conventionPlugins must be an array (use [] when none)")
else:
    for idx, entry in enumerate(cp):
        prefix = f"conventionPlugins[{idx}]"
        if not isinstance(entry, dict):
            errors.append(f"{prefix} must be an object")
            continue
        if not isinstance(entry.get("pluginId"), str) or not entry["pluginId"].strip():
            errors.append(f"{prefix}.pluginId must be a non-empty string")
        if not isinstance(entry.get("sourceFile"), str) or not entry["sourceFile"].strip():
            errors.append(f"{prefix}.sourceFile must be a non-empty string")
        if not isinstance(entry.get("edited"), bool):
            errors.append(f"{prefix}.edited must be a boolean")

# summary.migrationCommentCountByModule: required map; sums to migrationCommentCount
summary = data.get("summary", {})
if isinstance(summary, dict):
    by_mod = summary.get("migrationCommentCountByModule")
    total = summary.get("migrationCommentCount")
    if not isinstance(by_mod, dict):
        errors.append(
            "summary.migrationCommentCountByModule must be an object map "
            "from module-path to count (use empty object when migrationCommentCount is 0)"
        )
    else:
        bad_count = False
        running = 0
        for k, v in by_mod.items():
            if not isinstance(k, str) or not k.strip():
                errors.append("summary.migrationCommentCountByModule keys must be non-empty strings")
                bad_count = True
                continue
            if not isinstance(v, int) or v < 0:
                errors.append(
                    f"summary.migrationCommentCountByModule[<{k}>] must be a non-negative integer"
                )
                bad_count = True
                continue
            running += v
            if mm_known_module_paths and k not in mm_known_module_paths:
                errors.append(
                    f"summary.migrationCommentCountByModule key <{k}> is not a path in module-map.json "
                    "(primaryAppModule.path or libraryModulesInScope[*].path)"
                )
        if not bad_count and isinstance(total, int):
            if running != total:
                errors.append(
                    f"summary.migrationCommentCountByModule values sum to {running} "
                    f"but summary.migrationCommentCount is {total}"
                )

# apisReplaced[*].catalogRow: required, must match api-catalog.json
catalog_ids = set()
catalog_supported_ids = set()
catalog_contract_version = None
catalog_path = catalog_contract_path or os.path.join(
    os.path.dirname(path), "..", "contracts", "api-catalog.v1.0.0.json"
)
if os.path.isfile(catalog_path):
    try:
        with open(catalog_path, "r", encoding="utf-8") as cf:
            catalog_data = json.load(cf)
        catalog_ids = {r["id"] for r in catalog_data.get("rows", []) if isinstance(r, dict) and "id" in r}
        catalog_supported_ids = {
            r["id"]
            for r in catalog_data.get("rows", [])
            if isinstance(r, dict) and r.get("supportStatus") == "supported" and "id" in r
        }
        if isinstance(catalog_data, dict):
            cv = catalog_data.get("catalogVersion")
            if isinstance(cv, str) and cv.strip():
                catalog_contract_version = cv
    except Exception as exc:
        warnings.append(f"Could not load api-catalog.v1.0.0.json for catalogRow cross-check: {exc}")
else:
    warnings.append("contracts/api-catalog.v1.0.0.json not found — catalogRow cross-check skipped")

# apisReplaced[*].modules and catalogRow: required, non-empty when files[] non-empty
ar = data.get("apisReplaced", [])
if isinstance(ar, list):
    for idx, entry in enumerate(ar):
        if not isinstance(entry, dict):
            continue
        prefix = f"apisReplaced[{idx}]"
        catalog_row = entry.get("catalogRow")
        if not isinstance(catalog_row, str) or not catalog_row.strip():
            errors.append(f"{prefix}.catalogRow must be a non-empty string referencing contracts/api-catalog.v1.0.0.json")
        elif catalog_ids and catalog_row not in catalog_ids:
            errors.append(
                f"{prefix}.catalogRow = <{catalog_row}> does not match any row ID "
                "in contracts/api-catalog.v1.0.0.json"
            )
        elif catalog_supported_ids and catalog_row not in catalog_supported_ids:
            errors.append(
                f"{prefix}.catalogRow = <{catalog_row}> is not marked supportStatus=supported "
                "in contracts/api-catalog.v1.0.0.json"
            )
        modules_val = entry.get("modules")
        files_val = entry.get("files")
        if not isinstance(modules_val, list):
            errors.append(f"{prefix}.modules must be an array of module names")
            continue
        for j, m in enumerate(modules_val):
            if not isinstance(m, str) or not m.strip():
                errors.append(f"{prefix}.modules[{j}] must be a non-empty string")
                continue
            if mm_known_module_names and m not in mm_known_module_names and m != "<convention-plugin>":
                errors.append(
                    f"{prefix}.modules[{j}] = <{m}> is not a name in module-map.json "
                    "(primaryAppModule.name, libraryModulesInScope[*].name, or <convention-plugin>)"
                )
        if isinstance(files_val, list) and files_val and not modules_val:
            errors.append(f"{prefix}.modules must be non-empty when files is non-empty")

# filesModified[*].module: required string
fm = data.get("filesModified", [])
if isinstance(fm, list):
    for idx, entry in enumerate(fm):
        if not isinstance(entry, dict):
            continue
        prefix = f"filesModified[{idx}]"
        module_val = entry.get("module")
        if not isinstance(module_val, str) or not module_val.strip():
            errors.append(f"{prefix}.module must be a non-empty string")
            continue
        if mm_known_module_names and module_val not in mm_known_module_names and module_val != "<convention-plugin>":
            errors.append(
                f"{prefix}.module = <{module_val}> is not a name in module-map.json "
                "(primaryAppModule.name, libraryModulesInScope[*].name, or <convention-plugin>)"
            )

# uemAdminHandoff cross-validation across every settings.json target.
# Bootstrap is the source of truth; each settings.json target must agree
# with bootstrap byte-for-byte; the report uemAdminHandoff must agree
# with both. Any divergence is a hard fail per steering 81 quality gate 11.
uah = data.get("uemAdminHandoff", {})
report_gid = uah.get("gdApplicationId") if isinstance(uah, dict) else None
report_gver = uah.get("gdApplicationVersion") if isinstance(uah, dict) else None
boot_gid = None
boot_gver = None
boot_run_id = None
boot_catalog_version = None
boot_toolkit_version = None
boot_generated_at = None
boot_exec_pairs = []
_boot = {}
try:
    with open(bootstrap_path, "r", encoding="utf-8") as bf:
        _boot = json.load(bf)
    _uem = _boot.get("uem") or {}
    boot_gid = _uem.get("gdApplicationId")
    boot_gver = _uem.get("gdApplicationVersion")
    boot_run_id = _boot.get("runId")
    boot_catalog_version = _boot.get("catalogVersion")
    _boot_toolkit = _boot.get("toolkit") or {}
    boot_toolkit_version = _boot_toolkit.get("version") if isinstance(_boot_toolkit, dict) else None
    boot_generated_at = _boot.get("generatedAt")
    if isinstance(_boot.get("executedPrompts"), list):
        for _ep in _boot.get("executedPrompts"):
            if isinstance(_ep, dict):
                _pid = _ep.get("promptId")
                _status = _ep.get("status")
                if isinstance(_pid, str) and isinstance(_status, str):
                    boot_exec_pairs.append((_pid, _status))
except Exception:
    pass

pm = _boot.get("processModel") if isinstance(_boot, dict) else {}
bg_candidates = []
if isinstance(pm, dict):
    bg_candidates = [c for c in (pm.get("backgroundEntryPoints") or []) if isinstance(c, dict)]
ba = _boot.get("backgroundAuthorize") if isinstance(_boot, dict) else {}
ba_decisions = ba.get("decisions") if isinstance(ba, dict) else None
bg_cov = cov.get("backgroundAuthorize") if isinstance(cov, dict) else None
bg_status = bg_cov.get("status") if isinstance(bg_cov, dict) else None
bg_details = bg_cov.get("details") if isinstance(bg_cov, dict) else ""
if bg_candidates:
    if not isinstance(ba_decisions, list):
        errors.append(
            "coverage.backgroundAuthorize is required because backgroundEntryPoints[] exist, "
            "but bootstrap.backgroundAuthorize.decisions[] is missing"
        )
    else:
        allowed_bg_intents = {"migrate", "deferred", "not-applicable"}
        by_name = {}
        for decision in ba_decisions:
            if not isinstance(decision, dict):
                continue
            name = decision.get("name")
            intent = decision.get("intent")
            if isinstance(name, str) and name.strip():
                by_name[name] = intent
                if intent not in allowed_bg_intents:
                    errors.append(
                        f"bootstrap.backgroundAuthorize.decisions[] has invalid intent {intent!r} for {name!r}"
                    )
        missing_bg = []
        for candidate in bg_candidates:
            name = candidate.get("name")
            if isinstance(name, str) and name.strip() and name not in by_name:
                missing_bg.append(name)
        if missing_bg:
            errors.append(
                "backgroundAuthorize decisions missing for candidate(s): "
                + ", ".join(repr(m) for m in missing_bg[:5])
            )
        has_deferred_bg = any(intent == "deferred" for intent in by_name.values())
        if has_deferred_bg and bg_status != "partial":
            errors.append(
                "coverage.backgroundAuthorize.status must be partial while any candidate intent is deferred"
            )
        if not has_deferred_bg and bg_status == "not-applicable":
            errors.append(
                "coverage.backgroundAuthorize.status must not be not-applicable when backgroundEntryPoints[] exist"
            )
        if isinstance(bg_details, str):
            for candidate in bg_candidates:
                name = candidate.get("name")
                if isinstance(name, str) and name and name not in bg_details:
                    errors.append(
                        f"coverage.backgroundAuthorize.details must mention candidate {name!r}"
                    )
                    break
else:
    if bg_status not in (None, "not-applicable"):
        errors.append(
            "coverage.backgroundAuthorize.status must be not-applicable when no background entry points exist"
        )

if isinstance(report_run_id, str) and isinstance(boot_run_id, str) and report_run_id != boot_run_id:
    errors.append(
        f"runId drift: migration-report.json runId <{report_run_id}> does not match "
        f"bootstrap.json runId <{boot_run_id}>"
    )

if isinstance(prov, dict):
    p_boot_ts = prov.get("bootstrapGeneratedAt")
    if isinstance(boot_generated_at, str) and isinstance(p_boot_ts, str) and p_boot_ts != boot_generated_at:
        errors.append(
            f"provenance.bootstrapGeneratedAt <{p_boot_ts}> does not match "
            f"bootstrap.json generatedAt <{boot_generated_at}>"
        )
    p_cat_ver = prov.get("catalogVersion")
    if isinstance(boot_catalog_version, str) and isinstance(p_cat_ver, str) and p_cat_ver != boot_catalog_version:
        errors.append(
            f"catalogVersion drift: report provenance catalogVersion <{p_cat_ver}> does not match "
            f"bootstrap.json catalogVersion <{boot_catalog_version}>"
        )
    if isinstance(catalog_contract_version, str) and isinstance(p_cat_ver, str) and p_cat_ver != catalog_contract_version:
        errors.append(
            f"catalogVersion drift: report provenance catalogVersion <{p_cat_ver}> does not match "
            f"contracts/api-catalog.v1.0.0.json catalogVersion <{catalog_contract_version}>"
        )
    p_tk_ver = prov.get("toolkitVersion")
    if isinstance(boot_toolkit_version, str) and isinstance(p_tk_ver, str) and p_tk_ver != boot_toolkit_version:
        errors.append(
            f"provenance.toolkitVersion <{p_tk_ver}> does not match "
            f"bootstrap.json toolkit.version <{boot_toolkit_version}>"
        )
    if isinstance(prov.get("executedPrompts"), list) and boot_exec_pairs:
        report_exec_pairs = []
        for _ep in prov.get("executedPrompts"):
            if isinstance(_ep, dict):
                _pid = _ep.get("promptId")
                _status = _ep.get("status")
                if isinstance(_pid, str) and isinstance(_status, str):
                    report_exec_pairs.append((_pid, _status))
        if sorted(report_exec_pairs) != sorted(boot_exec_pairs):
            errors.append(
                "provenance.executedPrompts does not match bootstrap.json executedPrompts "
                "(promptId/status pairs must match exactly)"
            )

if analysis_path and os.path.isfile(analysis_path):
    try:
        with open(analysis_path, "r", encoding="utf-8") as af:
            analysis = json.load(af)
        analysis_run_id = analysis.get("runId")
        if isinstance(boot_run_id, str):
            if not isinstance(analysis_run_id, str) or not analysis_run_id.strip():
                errors.append("migration-analysis.json must contain runId copied from bootstrap.json")
            elif analysis_run_id != boot_run_id:
                errors.append(
                    f"migration-analysis.json runId <{analysis_run_id}> does not match "
                    f"bootstrap.json runId <{boot_run_id}>"
                )
    except Exception as exc:
        warnings.append(f"could not parse migration-analysis.json for runId cross-check: {exc}")

if plan_state_path and os.path.isfile(plan_state_path):
    try:
        with open(plan_state_path, "r", encoding="utf-8") as pf:
            plan_state = json.load(pf)
        ps_run_id = plan_state.get("runId")
        if isinstance(boot_run_id, str):
            if not isinstance(ps_run_id, str) or not ps_run_id.strip():
                errors.append("migration-plan-state.json must contain runId copied from bootstrap.json")
            elif ps_run_id != boot_run_id:
                errors.append(
                    f"migration-plan-state.json runId <{ps_run_id}> does not match "
                    f"bootstrap.json runId <{boot_run_id}>"
                )
    except Exception as exc:
        warnings.append(f"could not parse migration-plan-state.json for runId cross-check: {exc}")

report_egress = data.get("egressFeatures")
ALLOWED_EGRESS_OUTCOMES = (
    "REMOVE",
    "REPLACE_WITH_DYNAMICS",
    "MANUAL_INTERVENTION_REQUIRED",
    "BLOCKED_UNTIL_APPROVED",
)
ALLOWED_EGRESS_STATUS = ("implemented", "manual-follow-up", "blocked")
if not isinstance(report_egress, list):
    errors.append("egressFeatures must be an array")
else:
    report_egress_by_id = {}
    for idx, item in enumerate(report_egress):
        prefix = f"egressFeatures[{idx}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix} must be an object")
            continue
        fid = item.get("id")
        if not isinstance(fid, str) or not fid.strip():
            errors.append(f"{prefix}.id must be a non-empty string")
            continue
        report_egress_by_id[fid] = item
        for key in ("featureName", "domain", "outcome", "status", "reason", "migrationAction", "userVisibleChange"):
            val = item.get(key)
            if not isinstance(val, str) or not val.strip():
                errors.append(f"{prefix}.{key} must be a non-empty string")
        if item.get("outcome") not in ALLOWED_EGRESS_OUTCOMES:
            errors.append(f"{prefix}.outcome must be one of {'|'.join(ALLOWED_EGRESS_OUTCOMES)}")
        if item.get("status") not in ALLOWED_EGRESS_STATUS:
            errors.append(f"{prefix}.status must be one of {'|'.join(ALLOWED_EGRESS_STATUS)}")
        source_files = item.get("sourceFiles")
        if not isinstance(source_files, list) or not source_files:
            errors.append(f"{prefix}.sourceFiles must be a non-empty array")
        secure_alt = item.get("secureAlternative")
        if secure_alt is not None and not isinstance(secure_alt, str):
            errors.append(f"{prefix}.secureAlternative must be a string or null")
        if item.get("outcome") == "REPLACE_WITH_DYNAMICS":
            if not isinstance(secure_alt, str) or not secure_alt.strip():
                errors.append(f"{prefix}.secureAlternative must be non-empty for REPLACE_WITH_DYNAMICS")
            if item.get("status") != "implemented":
                errors.append(f"{prefix}.status must be 'implemented' for REPLACE_WITH_DYNAMICS")
        if item.get("outcome") == "BLOCKED_UNTIL_APPROVED" and item.get("status") != "blocked":
            errors.append(f"{prefix}.status must be 'blocked' for BLOCKED_UNTIL_APPROVED")
        if item.get("outcome") == "MANUAL_INTERVENTION_REQUIRED" and item.get("status") != "manual-follow-up":
            errors.append(f"{prefix}.status must be 'manual-follow-up' for MANUAL_INTERVENTION_REQUIRED")
        if item.get("outcome") == "REMOVE" and item.get("status") != "implemented":
            errors.append(f"{prefix}.status must be 'implemented' for REMOVE")
        if item.get("outcome") in ("BLOCKED_UNTIL_APPROVED", "MANUAL_INTERVENTION_REQUIRED"):
            if not isinstance(item.get("followUp"), dict):
                errors.append(f"{prefix}.followUp must be present for blocked/manual egress outcomes")
            else:
                validate_follow_up(item, prefix, required=True)

    analysis_egress = analysis.get("egressFeatures") if isinstance(analysis, dict) else None
    plan_state_egress = plan_state.get("egressFeatureDecisions") if isinstance(plan_state, dict) else None
    analysis_ids = set()
    if isinstance(analysis_egress, list):
        for feat in analysis_egress:
            if isinstance(feat, dict):
                fid = feat.get("id")
                if isinstance(fid, str) and fid.strip() and feat.get("applicable") is not False:
                    analysis_ids.add(fid)
    plan_ids = set()
    if isinstance(plan_state_egress, list):
        for feat in plan_state_egress:
            if isinstance(feat, dict):
                fid = feat.get("featureId")
                if isinstance(fid, str) and fid.strip():
                    plan_ids.add(fid)
    expected_ids = analysis_ids | plan_ids
    if expected_ids:
        missing_from_report = sorted(expected_ids - set(report_egress_by_id.keys()))
        if missing_from_report:
            errors.append(
                "egressFeatures report section is missing entries for feature id(s): "
                + ", ".join(missing_from_report[:10])
                + (" ..." if len(missing_from_report) > 10 else "")
            )
        for fid in sorted(set(report_egress_by_id.keys()) & plan_ids):
            plan_item = next(
                (x for x in (plan_state_egress or []) if isinstance(x, dict) and x.get("featureId") == fid),
                None,
            )
            report_item = report_egress_by_id.get(fid) or {}
            if isinstance(plan_item, dict):
                if report_item.get("outcome") != plan_item.get("outcome"):
                    errors.append(
                        f"egressFeatures[{fid!r}] outcome {report_item.get('outcome')!r} "
                        f"does not match migration-plan-state.json egressFeatureDecisions outcome {plan_item.get('outcome')!r}"
                    )

if isinstance(report_gid, str) and isinstance(boot_gid, str) and report_gid != boot_gid:
    errors.append(
        f"uemAdminHandoff.gdApplicationId <{report_gid}> does not match "
        f"bootstrap.json uem.gdApplicationId <{boot_gid}>"
    )
if isinstance(report_gver, str) and isinstance(boot_gver, str) and report_gver != boot_gver:
    errors.append(
        f"uemAdminHandoff.gdApplicationVersion <{report_gver}> does not match "
        f"bootstrap.json uem.gdApplicationVersion <{boot_gver}>"
    )

# Cross-check every existing settings.json target against bootstrap.
# Missing targets are warnings (handled earlier in validate.sh); divergent
# values inside a present target are hard fails.
for tgt in settings_json_targets:
    try:
        with open(tgt, "r", encoding="utf-8") as sf:
            _st = json.load(sf)
    except FileNotFoundError:
        continue
    except Exception as exc:
        errors.append(f"settings.json at <{tgt}> is not valid JSON: {exc}")
        continue
    s_gid = _st.get("GDApplicationID")
    s_gver = _st.get("GDApplicationVersion")
    if isinstance(boot_gid, str) and isinstance(s_gid, str) and s_gid != boot_gid:
        errors.append(
            f"settings.json at <{tgt}> GDApplicationID <{s_gid}> does not match "
            f"bootstrap.json uem.gdApplicationId <{boot_gid}>"
        )
    if isinstance(boot_gver, str) and isinstance(s_gver, str) and s_gver != boot_gver:
        errors.append(
            f"settings.json at <{tgt}> GDApplicationVersion <{s_gver}> does not match "
            f"bootstrap.json uem.gdApplicationVersion <{boot_gver}>"
        )

# Cross-check validator security-blocker log vs report readiness semantics.
blockers_log_path = os.path.join(os.path.dirname(path), ".security-blockers.log")
blocker_log_rows = []
if os.path.isfile(blockers_log_path):
    with open(blockers_log_path, encoding="utf-8") as bl:
        blocker_log_rows = [ln.strip() for ln in bl if ln.strip()]

sec_blockers = data.get("securityBlockers")
if sec_blockers is None:
    sec_blockers = []
if not isinstance(sec_blockers, list):
    errors.append("securityBlockers must be an array when present")

rec = rr.get("recommendation") if isinstance(rr, dict) else None
blocker_domains = set()
for raw in blocker_log_rows:
    parts = raw.split("\t", 3)
    if parts and isinstance(parts[0], str) and parts[0].strip():
        blocker_domains.add(parts[0].strip())
if isinstance(sec_blockers, list):
    for item in sec_blockers:
        if not isinstance(item, dict):
            continue
        domain = item.get("domain")
        if isinstance(domain, str) and domain.strip():
            blocker_domains.add(domain.strip())

if blocker_domains:
    if mc.get("level") != "low":
        errors.append(
            f"migrationConfidence.level is {mc.get('level')!r} but "
            f"securityBlockers exist for domain(s) {sorted(blocker_domains)} — non-waivable blockers force low confidence"
        )
    if rec != "no-go":
        errors.append(
            f"releaseReadiness.recommendation is {rec!r} but "
            f"securityBlockers exist for domain(s) {sorted(blocker_domains)} — must be no-go"
        )
    if overall_status != "failed":
        errors.append(
            f"summary.overallStatus is {overall_status!r} but "
            f"securityBlockers exist for domain(s) {sorted(blocker_domains)} — must be failed"
        )

external_storage_blocked = "externalStorage" in blocker_domains
if external_storage_blocked:
    if secure_file_status != "partial":
        errors.append(
            f"coverage.secureFileStorage.status is {secure_file_status!r} but "
            "externalStorage security blockers exist — secureFileStorage must be partial until the blocker is removed"
        )
    if isinstance(secure_file_details, str):
        detail_blob = secure_file_details.lower()
        if not any(token in detail_blob for token in (
            "externalstorage", "external storage", "mediastore",
            "shared-storage", "shared storage", "saf", "fileprovider",
            "raw path", "container"
        )):
            errors.append(
                "coverage.secureFileStorage.details does not mention the active "
                "externalStorage security blocker — explain that container-boundary "
                "escape remains and the domain is only partially migrated"
            )

media_related_failure = False
if isinstance(bf, list):
    for item in bf:
        if not isinstance(item, str):
            continue
        lowered = item.lower()
        if any(token in lowered for token in (
            "mediastore", "mediarecorder", "capture", "extra_output",
            "output uri", "gallery", "mediascanner", "filesdir", "cachedir"
        )):
            media_related_failure = True
            break

media_report_required = external_storage_blocked or media_related_failure
if media_report_required:
    if not isinstance(media_containment, dict):
        errors.append(
            "mediaContainment section is required when media/export/capture blockers "
            "or validation failures are present"
        )
    else:
        mw = media_containment.get("mediaWritePaths")
        ep = media_containment.get("exportPaths")
        if not isinstance(mw, list) or len(mw) == 0:
            errors.append(
                "mediaContainment.mediaWritePaths must contain at least one entry "
                "when media/export/capture blockers or failures are present"
            )
        if not isinstance(ep, list) or len(ep) == 0:
            errors.append(
                "mediaContainment.exportPaths must contain at least one entry "
                "when media/export/capture blockers or failures are present"
            )
        if isinstance(mw, list):
            for idx, entry in enumerate(mw):
                if not isinstance(entry, dict):
                    continue
                if (
                    entry.get("usesFilesystemStaging") is True
                    or entry.get("publicExportRemains") is True
                    or entry.get("manualInterventionRequired") is True
                ) and secure_file_status == "migrated":
                    errors.append(
                        "mediaContainment.mediaWritePaths[%d] records filesystem staging, "
                        "public export, or manual intervention, but coverage.secureFileStorage.status "
                        "is 'migrated' — media containment risk keeps secureFileStorage partial" % idx
                    )
        if isinstance(ep, list):
            for idx, entry in enumerate(ep):
                if not isinstance(entry, dict):
                    continue
                pattern = str(entry.get("pattern", ""))
                if (
                    entry.get("status") == "unresolved"
                    or entry.get("safeOutcome") == "no-go"
                ) and rec != "no-go":
                    errors.append(
                        "mediaContainment.exportPaths[%d] is unresolved/no-go but "
                        "releaseReadiness.recommendation is not 'no-go'" % idx
                    )
                lowered_pattern = pattern.lower()
                if (
                    any(token in lowered_pattern for token in (
                        "action_view",
                        "action view",
                        "action_review",
                        "action review",
                        "category_app_gallery",
                        "category app gallery",
                    ))
                    and entry.get("status") == "controlled"
                ):
                    errors.append(
                        "mediaContainment.exportPaths[%d] classifies native gallery/viewer "
                        "invocation as 'controlled' — secure media must treat ACTION_VIEW / "
                        "ACTION_REVIEW / CATEGORY_APP_GALLERY as unresolved unless replaced "
                        "with an in-app secure viewer or Dynamics ICC" % idx
                    )

if blocker_log_rows:
    if not sec_blockers:
        errors.append(
            "securityBlockers[] is empty but dynamics-migration-tool/output/.security-blockers.log "
            f"has {len(blocker_log_rows)} row(s) — transcribe each validator security blocker into the report"
        )
    if rec != "no-go":
        errors.append(
            f"releaseReadiness.recommendation is {rec!r} but .security-blockers.log is non-empty — must be no-go"
        )
    if overall_status != "failed":
        errors.append(
            f"summary.overallStatus is {overall_status!r} but security blockers exist — must be failed"
        )
    if isinstance(v, dict) and v.get("passed") is True:
        errors.append(
            "validation.passed is true but .security-blockers.log is non-empty — security blockers require validation failure"
        )
elif isinstance(sec_blockers, list) and sec_blockers:
    warnings.append(
        "securityBlockers[] is populated but .security-blockers.log is empty — re-run full validate before prompt 10"
    )

if stale_fileprovider:
    blocking_items = rr.get("blockingItems") if isinstance(rr, dict) else None
    has_fileprovider_blocking = False
    if isinstance(blocking_items, list):
        for item in blocking_items:
            if isinstance(item, str) and "fileprovider" in item.lower():
                has_fileprovider_blocking = True
                break
    has_fileprovider_sec_blocker = False
    if isinstance(sec_blockers, list):
        for item in sec_blockers:
            if isinstance(item, dict):
                blob = (str(item.get("surface", "")) + " " + str(item.get("message", ""))).lower()
                if "fileprovider" in blob:
                    has_fileprovider_sec_blocker = True
                    break
    if not (has_fileprovider_blocking or has_fileprovider_sec_blocker):
        errors.append(
            "stale FileProvider manifest/resource surface detected in source, "
            "but releaseReadiness.blockingItems/securityBlockers does not call it out"
        )

# --- HR-0-5 evidence completeness + unverifiedSurfaces contract ------------
evidence_completeness = data.get("evidenceCompleteness")
unverified_surfaces = data.get("unverifiedSurfaces")
ALLOWED_EVIDENCE_OVERALL = ("complete", "incomplete", "partial")
ALLOWED_DOMAIN_EVIDENCE_STATUS = ("verified", "partial", "unverified", "not-applicable")
ALLOWED_RUNTIME_EVIDENCE_STATUS = ("passed", "failed", "not-run")
ALLOWED_UNVERIFIED_STATUS = ("open", "resolved", "acceptedRisk", "notApplicable")

runtime_evidence = None
if not isinstance(evidence_completeness, dict):
    errors.append("evidenceCompleteness must be an object")
else:
    overall_evidence = evidence_completeness.get("overallStatus")
    if overall_evidence not in ALLOWED_EVIDENCE_OVERALL:
        errors.append(
            "evidenceCompleteness.overallStatus must be one of "
            + "|".join(ALLOWED_EVIDENCE_OVERALL)
        )
    domains_evidence = evidence_completeness.get("domains")
    if not isinstance(domains_evidence, dict):
        errors.append("evidenceCompleteness.domains must be an object map")
    else:
        for domain_name, domain_evidence in domains_evidence.items():
            prefix = f"evidenceCompleteness.domains.{domain_name}"
            if not isinstance(domain_evidence, dict):
                errors.append(f"{prefix} must be an object")
                continue
            if domain_evidence.get("status") not in ALLOWED_DOMAIN_EVIDENCE_STATUS:
                errors.append(
                    f"{prefix}.status must be one of "
                    + "|".join(ALLOWED_DOMAIN_EVIDENCE_STATUS)
                )
            for key in ("validatorVerified",):
                if not isinstance(domain_evidence.get(key), bool):
                    errors.append(f"{prefix}.{key} must be boolean")
            for key in ("inventoriedCallSites", "rediscoveredSurfaces"):
                val = domain_evidence.get(key)
                if not isinstance(val, int) or val < 0:
                    errors.append(f"{prefix}.{key} must be a non-negative integer")
    runtime_evidence = evidence_completeness.get("runtimeEvidence")
    if not isinstance(runtime_evidence, dict):
        errors.append("evidenceCompleteness.runtimeEvidence must be an object")
    else:
        rt_status = runtime_evidence.get("status")
        if rt_status not in ALLOWED_RUNTIME_EVIDENCE_STATUS:
            errors.append(
                "evidenceCompleteness.runtimeEvidence.status must be one of "
                + "|".join(ALLOWED_RUNTIME_EVIDENCE_STATUS)
            )
        if not isinstance(runtime_evidence.get("summary"), str) or not runtime_evidence.get("summary").strip():
            errors.append("evidenceCompleteness.runtimeEvidence.summary must be a non-empty string")

if not isinstance(unverified_surfaces, list):
    errors.append("unverifiedSurfaces must be an array")
else:
    for idx, entry in enumerate(unverified_surfaces):
        prefix = f"unverifiedSurfaces[{idx}]"
        if not isinstance(entry, dict):
            errors.append(f"{prefix} must be an object")
            continue
        for key in ("id", "domain", "sourceFile", "pattern"):
            val = entry.get(key)
            if not isinstance(val, str) or not val.strip():
                errors.append(f"{prefix}.{key} must be a non-empty string")
        if not isinstance(entry.get("securityCritical"), bool):
            errors.append(f"{prefix}.securityCritical must be boolean")
        if entry.get("status") not in ALLOWED_UNVERIFIED_STATUS:
            errors.append(
                f"{prefix}.status must be one of " + "|".join(ALLOWED_UNVERIFIED_STATUS)
            )

independent_evidence_path = os.path.join(os.path.dirname(path), ".independent-evidence.json")
independent_evidence = None
if os.path.isfile(independent_evidence_path):
    try:
        with open(independent_evidence_path, "r", encoding="utf-8") as ief:
            independent_evidence = json.load(ief)
    except Exception as exc:
        warnings.append(f"could not parse .independent-evidence.json for cross-check: {exc}")

if isinstance(independent_evidence, dict) and analysis_path and os.path.isfile(analysis_path):
    try:
        with open(analysis_path, "r", encoding="utf-8") as af:
            analysis_for_evidence = json.load(af)
    except Exception:
        analysis_for_evidence = {}
    plan_state_for_evidence = {}
    if plan_state_path and os.path.isfile(plan_state_path):
        try:
            with open(plan_state_path, "r", encoding="utf-8") as pf:
                plan_state_for_evidence = json.load(pf)
        except Exception:
            plan_state_for_evidence = {}

    # Inline the closure semantics used by tooling/lib/evidence-closure-check.py
    def _norm_evidence_path(value):
        return str(value).replace("\\", "/").lstrip("./")

    def _domain_rows_local(analysis_obj, domain):
        return [
            row
            for row in (analysis_obj.get("executionPlan") or [])
            if isinstance(row, dict) and row.get("domain") == domain
        ]

    def _call_sites_local(analysis_obj, domain):
        sites = []
        for row in _domain_rows_local(analysis_obj, domain):
            if row.get("applicable") is not True:
                continue
            cs = row.get("callSites")
            if isinstance(cs, list):
                for item in cs:
                    if isinstance(item, dict):
                        sites.append(item)
        return sites

    def _covered_files_local(analysis_obj, plan_obj, domain):
        covered = set()
        by_key = {}
        for disp in (plan_obj or {}).get("dispositions") or []:
            if isinstance(disp, dict):
                by_key[(disp.get("domain"), disp.get("callSiteId"))] = disp
        for cs in _call_sites_local(analysis_obj, domain):
            cid = cs.get("id")
            disp = by_key.get((domain, cid))
            if not isinstance(disp, dict) or disp.get("status") not in ("migrated", "removed"):
                continue
            for key in ("file", "sourceFile", "path"):
                val = cs.get(key)
                if isinstance(val, str) and val.strip():
                    covered.add(_norm_evidence_path(val))
        return covered

    def _manual_files_local(report_obj, domain):
        files = set()
        for todo in (report_obj or {}).get("manualTodos") or []:
            if not isinstance(todo, dict):
                continue
            if todo.get("domain") != domain:
                blob = " ".join(str(todo.get(k, "")) for k in ("title", "reason", "domain"))
                if domain not in blob:
                    continue
            for item in todo.get("evidence") or []:
                if isinstance(item, str) and item.strip():
                    files.add(_norm_evidence_path(item))
        return files

    def _surface_covered_local(surface_file, covered, manual):
        sf = _norm_evidence_path(surface_file)
        for cf in covered:
            if sf == cf or sf.endswith("/" + cf) or cf in sf:
                return True
        for mf in manual:
            if mf in sf or sf.endswith("/" + mf):
                return True
        return False

    def _surface_class_local(surface):
        surface_class = surface.get("surfaceClass")
        if isinstance(surface_class, str) and surface_class:
            return surface_class
        if surface.get("securityCritical") is True:
            return "data-path"
        return "inventory-artifact"

    critical_surfaces = [
        s
        for s in (independent_evidence.get("surfaces") or [])
        if isinstance(s, dict) and _surface_class_local(s) == "data-path"
    ]
    report_unverified_ids = {
        item.get("id")
        for item in (unverified_surfaces or [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    for surf in critical_surfaces:
        domain = surf.get("domain")
        sf = surf.get("sourceFile")
        if not isinstance(domain, str) or not isinstance(sf, str):
            continue
        rows = _domain_rows_local(analysis_for_evidence, domain)
        applicable = any(r.get("applicable") is True for r in rows)
        not_applicable = bool(rows) and all(r.get("applicable") is not True for r in rows)
        if not_applicable:
            errors.append(
                f"independent evidence rediscovered domain {domain!r} surfaces but "
                "migration-analysis marks the domain not-applicable"
            )
            continue
        if applicable and len(_call_sites_local(analysis_for_evidence, domain)) == 0:
            errors.append(
                f"independent evidence rediscovered domain {domain!r} surfaces but "
                "executionPlan callSites[] is empty for an applicable domain"
            )
        covered = _covered_files_local(analysis_for_evidence, plan_state_for_evidence, domain)
        manual = _manual_files_local(data, domain)
        if not _surface_covered_local(sf, covered, manual):
            sid = surf.get("id")
            if isinstance(sid, str) and sid not in report_unverified_ids:
                errors.append(
                    f"unverifiedSurfaces[] missing independent security-critical surface {sid!r}"
                )

if rec == "go":
    if isinstance(evidence_completeness, dict) and evidence_completeness.get("overallStatus") != "complete":
        errors.append(
            "releaseReadiness.recommendation is go but evidenceCompleteness.overallStatus is not complete"
        )
    if isinstance(unverified_surfaces, list):
        open_critical = [
            item
            for item in unverified_surfaces
            if isinstance(item, dict)
            and item.get("securityCritical") is True
            and item.get("status") in (None, "open")
        ]
        if open_critical:
            errors.append(
                "releaseReadiness.recommendation is go but security-critical unverifiedSurfaces remain open"
            )
    if isinstance(runtime_evidence, dict) and runtime_evidence.get("status") == "failed":
        errors.append(
            "releaseReadiness.recommendation is go but runtimeEvidence.status is failed"
        )

if errors:
    for e in errors:
        print(f"ERROR:{e}")
    for w in warnings:
        print(f"WARN:{w}")
    sys.exit(1)

print("OK:migration-report contract validated")
for w in warnings:
    print(f"WARN:{w}")
PY
)"
    REPORT_CHECK_EXIT=$?
    set -e

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            OK:*)
                check_pass "${line#OK:}"
                ;;
            WARN:*)
                check_warn "${line#WARN:}"
                ;;
            ERROR:*)
                check_fail "${line#ERROR:}"
                ;;
            *)
                check_warn "$line"
                ;;
        esac
    done <<< "$REPORT_CHECK_OUTPUT"

    if [ "$REPORT_CHECK_EXIT" -ne 0 ]; then
        check_fail "migration-report.json does not satisfy schema/report contract"
    fi
else
    check_warn "dynamics-migration-tool/output/migration-report.json not found — run prompt 10 to generate it"
fi
echo ""
