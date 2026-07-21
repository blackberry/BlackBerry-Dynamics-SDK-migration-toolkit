#!/usr/bin/env bash
# BlackBerry Dynamics iOS Migration Tool — Prompt Execution Recorder
#
# This script is the ONLY writer of bootstrap.json.executedPrompts[].
# Agents and prompts must never edit executedPrompts[] directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$TOOL_DIR/output"
CPM_FILE="$SCRIPT_DIR/check-prompt-map.json"
BOOTSTRAP_FILE="$OUTPUT_DIR/bootstrap.json"
ANALYSIS_FILE="$OUTPUT_DIR/migration-analysis.json"
TARGET_MAP_FILE="$OUTPUT_DIR/target-map.json"
PLAN_STATE_FILE="$OUTPUT_DIR/migration-plan-state.json"
LAST_CHECK_FILE="$OUTPUT_DIR/.last-check.json"
LOOP_STATE_SH="$TOOL_DIR/tooling/loop-state.sh"
OBSERVABILITY_PY="$TOOL_DIR/tooling/lib/observability.py"
VALIDATE_SH="$TOOL_DIR/tooling/validate.sh"
DIAGNOSTICS_CONTRACT_PY="$TOOL_DIR/tooling/lib/diagnostics-contract.py"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

PROMPT_ID=""
PROMPT_STATUS=""
PROMPT_NOTES=""
OVERRIDE_RUN_ID=""

usage() {
    cat <<'EOF'
Usage:
  record-prompt-execution.sh --prompt-id <id> --status completed|not-applicable|blocked|failed [--notes TEXT] [--run-id <id>]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prompt-id) PROMPT_ID="${2:-}"; shift 2 ;;
        --status) PROMPT_STATUS="${2:-}"; shift 2 ;;
        --notes) PROMPT_NOTES="${2:-}"; shift 2 ;;
        --run-id) OVERRIDE_RUN_ID="${2:-}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo -e "${RED}ERROR: unknown argument '$1'${NC}" >&2; usage; exit 3 ;;
    esac
done

if [[ -z "$PROMPT_ID" || -z "$PROMPT_STATUS" ]]; then
    echo -e "${RED}ERROR: --prompt-id and --status are required${NC}" >&2
    exit 3
fi

case "$PROMPT_STATUS" in
    completed|not-applicable|blocked|failed) ;;
    *) echo -e "${RED}ERROR: invalid --status '$PROMPT_STATUS'${NC}" >&2; exit 3 ;;
esac

if [[ ! -f "$BOOTSTRAP_FILE" ]]; then
    echo -e "${RED}ERROR: bootstrap.json not found at $BOOTSTRAP_FILE${NC}" >&2
    echo -e "Run prompt 00pre first." >&2
    exit 2
fi

BOOTSTRAP_RUN_ID=$(python3 - <<PYEOF
import json
try:
    print(json.load(open("$BOOTSTRAP_FILE", encoding="utf-8")).get("runId",""))
except Exception:
    print("")
PYEOF
)
if [[ -z "$BOOTSTRAP_RUN_ID" ]]; then
    echo -e "${RED}ERROR: bootstrap.json is invalid or missing runId${NC}" >&2
    exit 2
fi
CURRENT_RUN_ID="${OVERRIDE_RUN_ID:-$BOOTSTRAP_RUN_ID}"
RECORDED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  iOS Prompt Recorder — $PROMPT_ID ($PROMPT_STATUS)${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "  Run ID: $CURRENT_RUN_ID"
echo ""

GATE_FAILURES=0
gate_pass() { echo -e "  ${GREEN}GATE PASS${NC} $1"; }
gate_warn() { echo -e "  ${YELLOW}GATE WARN${NC} $1"; }
gate_fail() { echo -e "  ${RED}GATE FAIL${NC} $1"; GATE_FAILURES=$((GATE_FAILURES + 1)); }
observability_event() {
    [[ -f "$OBSERVABILITY_PY" ]] || return 0
    python3 "$OBSERVABILITY_PY" event \
        --tool-dir "$TOOL_DIR" \
        --project-root "$TOOL_DIR/.." \
        --platform ios \
        --run-id "${CURRENT_RUN_ID:-}" \
        "$@" >/dev/null 2>&1 || true
}

record_loop_gate_failure() {
    local stage_label="$1"
    local result_label="$2"
    local gate_id="$3"
    local message="$4"
    local action="${5:-rerun-owner-prompt}"
    [[ -f "$LOOP_STATE_SH" ]] || return 0

    local _loop_out=""
    local _loop_rc=0
    set +e
    _loop_out="$(
        bash "$LOOP_STATE_SH" record \
            --prompt-id "$PROMPT_ID" \
            --stage "$stage_label" \
            --result "$result_label" \
            --gate-id "$gate_id" \
            --message "$message" \
            --owner-prompt "$PROMPT_ID" \
            --safe-next-action "$action" 2>/dev/null
    )"
    _loop_rc=$?
    set -e
    if [[ $_loop_rc -eq 3 ]]; then
        echo "ESCALATION REQUIRED: retry budget exhausted for prompt=$PROMPT_ID stage=$stage_label." >&2
        [[ -n "$_loop_out" ]] && echo "$_loop_out" >&2
        return 3
    fi
    return 0
}

VALIDATION_PROOF_SUMMARY=""
if [[ "$PROMPT_STATUS" == "completed" ]]; then
    if [[ ! -f "$VALIDATE_SH" ]]; then
        echo -e "${RED}ERROR: validate.sh not found at $VALIDATE_SH${NC}" >&2
        exit 2
    fi
    if [[ ! -f "$DIAGNOSTICS_CONTRACT_PY" ]]; then
        echo -e "${RED}ERROR: diagnostics proof helper missing at $DIAGNOSTICS_CONTRACT_PY${NC}" >&2
        exit 2
    fi

    VALIDATOR_MODE=$(python3 - "$CPM_FILE" "$PROMPT_ID" <<'PYEOF'
import json
import sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("unknown")
    sys.exit(0)
for prompt in data.get("prompts", []):
    if isinstance(prompt, dict) and prompt.get("id") == sys.argv[2]:
        print((prompt.get("validator") or {}).get("mode") or "none")
        sys.exit(0)
print("unknown")
PYEOF
)

    case "$VALIDATOR_MODE" in
        none)
            gate_pass "Prompt '$PROMPT_ID' has no prompt-scoped validator"
            ;;
        preflight)
            echo "Running validate.sh --preflight for prompt '$PROMPT_ID'"
            set +e
            bash "$VALIDATE_SH" --preflight
            VALIDATE_EXIT=$?
            set -e
            ;;
        prompt-scoped)
            echo "Running validate.sh --check-prompt $PROMPT_ID"
            set +e
            bash "$VALIDATE_SH" --check-prompt "$PROMPT_ID"
            VALIDATE_EXIT=$?
            set -e
            ;;
        full)
            echo "Running validate.sh full validation for prompt '$PROMPT_ID'"
            set +e
            bash "$VALIDATE_SH"
            VALIDATE_EXIT=$?
            set -e
            ;;
        *)
            echo -e "${RED}ERROR: unknown validator mode '$VALIDATOR_MODE' for prompt '$PROMPT_ID'${NC}" >&2
            exit 2
            ;;
    esac

    if [[ "$VALIDATOR_MODE" != "none" ]]; then
        case "$VALIDATE_EXIT" in
            0)
                : # proof is checked below
                ;;
            1)
                echo -e "${RED}Recording blocked: prompt '$PROMPT_ID' validation failed${NC}" >&2
                if ! record_loop_gate_failure "validation" "failed" "prompt-scoped-validation" "validate.sh proof gate failed for prompt $PROMPT_ID" "rerun-owner-prompt"; then
                    exit 3
                fi
                exit 1
                ;;
            3)
                echo -e "${RED}ESCALATION REQUIRED: retry budget exhausted for prompt '$PROMPT_ID'${NC}" >&2
                exit 3
                ;;
            *)
                echo -e "${RED}Recording blocked: validate.sh exited $VALIDATE_EXIT for prompt '$PROMPT_ID'${NC}" >&2
                if ! record_loop_gate_failure "validation" "environment-error" "validator-unexpected-exit" "validate.sh exited $VALIDATE_EXIT for prompt $PROMPT_ID" "fix-environment"; then
                    exit 3
                fi
                exit 1
                ;;
        esac
        if ! VALIDATION_PROOF_SUMMARY="$(python3 "$DIAGNOSTICS_CONTRACT_PY" --validate-prompt-proof "$LAST_CHECK_FILE" --platform ios --prompt-id "$PROMPT_ID" --check-map "$CPM_FILE" 2>/tmp/dynamics-ios-proof.$$.err)"; then
            echo -e "${RED}Recording blocked: validation proof guard failed for prompt '$PROMPT_ID'${NC}" >&2
            if [[ -s "/tmp/dynamics-ios-proof.$$.err" ]]; then
                sed 's/^/  /' "/tmp/dynamics-ios-proof.$$.err" >&2
            fi
            rm -f "/tmp/dynamics-ios-proof.$$.err"
            exit 1
        fi
        rm -f "/tmp/dynamics-ios-proof.$$.err"
        export VALIDATION_PROOF_SUMMARY
    fi
fi

set +e
GATE_OUTPUT=$(python3 - "$CPM_FILE" "$BOOTSTRAP_FILE" "$ANALYSIS_FILE" "$TARGET_MAP_FILE" "$PLAN_STATE_FILE" "$LAST_CHECK_FILE" "$TOOL_DIR" "$PROMPT_ID" "$PROMPT_STATUS" "$CURRENT_RUN_ID" <<'PYEOF'
import hashlib
import json
import sys
from pathlib import Path

(
    cpm_path,
    bootstrap_path,
    analysis_path,
    target_map_path,
    plan_path,
    last_check_path,
    tool_dir,
    prompt_id,
    status,
    run_id,
) = sys.argv[1:]

ALLOWED_DISPOSITIONS = {"migrated", "removed", "blocked", "deferred", "notApplicable"}
PASS, WARN, FAIL = [], [], []

def add(kind, msg):
    if kind == "PASS":
        PASS.append(msg)
    elif kind == "WARN":
        WARN.append(msg)
    else:
        FAIL.append(msg)

def read_json(path, label, required=True):
    p = Path(path)
    if not p.exists():
        if required:
            add("FAIL", f"{label} missing: {path}")
        else:
            add("WARN", f"{label} missing: {path}")
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception as exc:
        add("FAIL", f"{label} invalid JSON: {exc}")
        return None

def artifact_run_id(obj):
    if not isinstance(obj, dict):
        return ""
    return str(obj.get("runId") or (obj.get("runProvenance") or {}).get("runId") or "")

def file_hash(path_obj):
    if not path_obj.exists() or not path_obj.is_file():
        return ""
    try:
        return hashlib.sha256(path_obj.read_bytes()).hexdigest()
    except Exception:
        return ""

def compute_source_tree_fingerprint(project_root: Path) -> str:
    exclude = {"dynamics-migration-tool", ".cursor", ".kiro", "Pods", ".build", "DerivedData"}
    patterns = ("*.swift", "*.m", "*.mm", "*.h", "*.plist", "*.entitlements", "*.pbxproj", "Podfile", "Package.swift")
    files = []
    for pat in patterns:
        files.extend(project_root.rglob(pat))
    usable = []
    for p in files:
        if not p.is_file():
            continue
        if set(p.parts) & exclude:
            continue
        usable.append(p)
    usable = sorted(set(usable))
    h = hashlib.sha256()
    for p in usable:
        try:
            rel = str(p.relative_to(project_root))
            h.update(rel.encode("utf-8"))
            h.update(p.read_bytes())
        except Exception:
            continue
    return h.hexdigest()

cpm = read_json(cpm_path, "check-prompt-map.json")
bootstrap = read_json(bootstrap_path, "bootstrap.json")
analysis = read_json(analysis_path, "migration-analysis.json", required=False)
target_map = read_json(target_map_path, "target-map.json", required=False)
plan = read_json(plan_path, "migration-plan-state.json", required=False)
last_check = read_json(last_check_path, ".last-check.json", required=False)

if not cpm or not bootstrap:
    for m in PASS: print(f"PASS:{m}")
    for m in WARN: print(f"WARN:{m}")
    for m in FAIL: print(f"FAIL:{m}")
    sys.exit(1 if FAIL else 0)

prompt = None
for p in cpm.get("prompts", []):
    if p.get("id") == prompt_id:
        prompt = p
        break
if prompt is None:
    add("FAIL", f"unknown prompt id '{prompt_id}' in check-prompt-map.json")
    for m in FAIL:
        print(f"FAIL:{m}")
    sys.exit(1)
add("PASS", f"Prompt '{prompt_id}' found in registry")

requires = prompt.get("requires", [])
required_artifacts = prompt.get("requiredArtifacts", [])
can_be_not_applicable = bool(prompt.get("canBeNotApplicable", False))
owned_domains = prompt.get("ownedDomains", [])
validator = prompt.get("validator", {}) if isinstance(prompt.get("validator"), dict) else {}
validator_mode = validator.get("mode") or "none"
required_phases = validator.get("requiredPhases", [])
must_be_full = bool(validator.get("mustBeFull", False))
non_waivable = set(prompt.get("nonWaivableBlockers", []))

if status == "not-applicable" and not can_be_not_applicable:
    add("FAIL", f"Prompt '{prompt_id}' cannot be marked not-applicable")

executed = bootstrap.get("executedPrompts", [])
completed_or_na = {
    e.get("promptId")
    for e in executed
    if e.get("runId") == run_id and e.get("status") in {"completed", "not-applicable"}
}
for req in requires:
    if req in completed_or_na:
        add("PASS", f"Prerequisite '{req}' already completed/not-applicable")
    else:
        add("FAIL", f"Prerequisite '{req}' has not been recorded for run '{run_id}'")

for rel in required_artifacts:
    artifact = Path(tool_dir) / rel
    if not artifact.exists():
        add("FAIL", f"Required artifact missing: {rel}")
        continue
    if artifact.suffix == ".json":
        try:
            json.loads(artifact.read_text(encoding="utf-8"))
            add("PASS", f"Required artifact valid: {rel}")
        except Exception as exc:
            add("FAIL", f"Required artifact invalid JSON: {rel} ({exc})")
    else:
        add("PASS", f"Required artifact present: {rel}")

bootstrap_run = artifact_run_id(bootstrap)
if bootstrap_run and bootstrap_run != run_id:
    add("FAIL", f"bootstrap runId mismatch: expected {run_id}, got {bootstrap_run}")

for label, obj in (
    ("migration-analysis.json", analysis),
    ("target-map.json", target_map),
    ("migration-plan-state.json", plan),
    (".last-check.json", last_check),
):
    if obj is None:
        continue
    rid = artifact_run_id(obj)
    if rid and rid != run_id:
        add("FAIL", f"{label} runId mismatch: expected {run_id}, got {rid}")
    elif rid:
        add("PASS", f"{label} runId matches")

if status == "completed" and validator_mode != "none":
    if not isinstance(last_check, dict):
        add("FAIL", "Validation proof missing (.last-check.json)")
    else:
        proof_result = last_check.get("result")
        proof_mode = last_check.get("validationMode")
        proof_scope = last_check.get("promptScope")
        proof_stale = bool(last_check.get("isStale", False))
        proof_phases = set(last_check.get("phasesExecuted") or [])
        allowed_results = {"pass"}
        if validator_mode in {"preflight", "prompt-scoped"}:
            allowed_results.add("warn")
        # Full-mode Prompt 10 (and other full proofs): allow warn when there are
        # zero failures — informational notices must not block recorder completion.
        if validator_mode == "full" and int(last_check.get("failCount") or 0) == 0:
            allowed_results.add("warn")
        if proof_result not in allowed_results:
            expected = "', '".join(sorted(allowed_results))
            add("FAIL", f"Validation proof result must be '{expected}' (got {proof_result!r})")
        if proof_stale:
            add("FAIL", "Validation proof is stale")
        if must_be_full and proof_mode != "full":
            add("FAIL", f"Prompt '{prompt_id}' requires full validation proof")
        elif validator_mode == "prompt-scoped":
            if proof_mode != "prompt-scoped":
                add("FAIL", f"Expected prompt-scoped validation proof, got '{proof_mode}'")
            if proof_scope != prompt_id:
                add("FAIL", f"Validation proof promptScope mismatch (expected {prompt_id}, got {proof_scope!r})")
        elif validator_mode == "full" and proof_mode != "full":
            add("FAIL", f"Expected full validation proof, got '{proof_mode}'")
        missing_phases = [ph for ph in required_phases if ph not in proof_phases]
        if missing_phases:
            add("FAIL", f"Validation proof missing required phase(s): {', '.join(missing_phases)}")
        else:
            add("PASS", "Validation proof phases satisfy registry requirements")

        proof_fps = last_check.get("sourceFingerprints")
        if not isinstance(proof_fps, dict):
            add("FAIL", "Validation proof missing sourceFingerprints")
        else:
            if "source-tree" not in proof_fps:
                add("FAIL", "Validation proof missing source-tree fingerprint")
            else:
                tool_path = Path(tool_dir)
                project_root = tool_path.parent
                current_fps = {
                    "bootstrap.json": file_hash(Path(bootstrap_path)),
                    "target-map.json": file_hash(Path(target_map_path)),
                    "migration-analysis.json": file_hash(Path(analysis_path)),
                    "migration-plan-state.json": file_hash(Path(plan_path)),
                    "check-prompt-map.json": file_hash(Path(cpm_path)),
                    "auth-reachability.json": file_hash(project_root / "output" / "auth-reachability.json"),
                    "migration-report.json": file_hash(project_root / "output" / "migration-report.json"),
                    "source-tree": compute_source_tree_fingerprint(project_root),
                }
                stale_keys = []
                for key, expected_fp in proof_fps.items():
                    if not isinstance(expected_fp, str) or not expected_fp:
                        continue
                    current_fp = current_fps.get(key)
                    if not current_fp:
                        continue
                    if current_fp != expected_fp:
                        stale_keys.append(key)
                if stale_keys:
                    add("FAIL", f"Validation proof fingerprint mismatch (stale): {', '.join(sorted(set(stale_keys)))}")
                else:
                    add("PASS", "Validation proof fingerprints match current source/artifacts")

analysis_execution = (analysis or {}).get("executionPlan", []) if isinstance(analysis, dict) else []
plan_rows = (plan or {}).get("dispositions", []) if isinstance(plan, dict) else []
run_dispositions = {}
seen_dispositions = set()
for row in plan_rows:
    if not isinstance(row, dict):
        continue
    if row.get("runId") != run_id:
        continue
    cs_id = row.get("callSiteId")
    if isinstance(cs_id, str) and cs_id:
        if cs_id in seen_dispositions:
            add("FAIL", f"duplicate disposition entry for callSiteId '{cs_id}'")
            continue
        seen_dispositions.add(cs_id)
        run_dispositions[cs_id] = row

def domain_entry(domain_id):
    for d in analysis_execution:
        if d.get("domainId") == domain_id:
            return d
    return None

def validate_owned_domains(domains, require_non_waivable_clear=False):
    ok = True
    for domain_id in domains:
        entry = domain_entry(domain_id)
        if entry is None:
            add("FAIL", f"Owned domain '{domain_id}' missing from executionPlan")
            ok = False
            continue
        applicability = entry.get("applicability", "applicable")
        callsites = [cs.get("id") for cs in entry.get("callSites", []) if isinstance(cs, dict) and cs.get("id")]
        if applicability == "not-applicable":
            add("PASS", f"Domain '{domain_id}' marked not-applicable in analysis")
            continue
        missing = [cs for cs in callsites if cs not in run_dispositions]
        invalid = []
        blockers = []
        for cs in callsites:
            if cs not in run_dispositions:
                continue
            status_value = run_dispositions[cs].get("status")
            if status_value not in ALLOWED_DISPOSITIONS:
                invalid.append(f"{cs}={status_value!r}")
                continue
            if require_non_waivable_clear and status_value in non_waivable:
                blockers.append(f"{cs}={status_value}")
        if missing:
            add("FAIL", f"Domain '{domain_id}' missing dispositions for call sites: {', '.join(missing)}")
            ok = False
        if invalid:
            add("FAIL", f"Domain '{domain_id}' has invalid disposition status(es): {', '.join(invalid)}")
            ok = False
        if blockers:
            add("FAIL", f"Domain '{domain_id}' still has non-waivable blockers: {', '.join(blockers)}")
            ok = False
        if not missing and not invalid and not blockers:
            add("PASS", f"Domain '{domain_id}' has complete call-site dispositions")
    return ok

if status == "not-applicable" and owned_domains:
    for domain_id in owned_domains:
        entry = domain_entry(domain_id)
        if entry is None:
            add("FAIL", f"Cannot mark prompt not-applicable: owned domain '{domain_id}' missing from executionPlan")
            continue
        if entry.get("applicability") != "not-applicable":
            add("FAIL", f"Cannot mark prompt not-applicable: domain '{domain_id}' is still applicable")
        else:
            add("PASS", f"Owned domain '{domain_id}' is not-applicable")

if status == "completed" and owned_domains:
    validate_owned_domains(owned_domains, require_non_waivable_clear=bool(non_waivable))

if status == "completed" and prompt_id == "10":
    applicable_domains = [
        d.get("domainId")
        for d in analysis_execution
        if isinstance(d, dict) and d.get("domainId") and d.get("applicability", "applicable") != "not-applicable"
    ]
    if not applicable_domains:
        add("WARN", "No applicable domains in analysis executionPlan")
    else:
        validate_owned_domains(applicable_domains, require_non_waivable_clear=True)

for m in PASS:
    print(f"PASS:{m}")
for m in WARN:
    print(f"WARN:{m}")
for m in FAIL:
    print(f"FAIL:{m}")
sys.exit(1 if FAIL else 0)
PYEOF
)
GATE_EXIT=$?
set -e

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
        PASS:*) gate_pass "${line#PASS:}" ;;
        WARN:*) gate_warn "${line#WARN:}" ;;
        FAIL:*) gate_fail "${line#FAIL:}" ;;
        *) gate_warn "$line" ;;
    esac
done <<< "$GATE_OUTPUT"

if [[ $GATE_EXIT -ne 0 || $GATE_FAILURES -gt 0 ]]; then
    echo ""
    echo -e "${RED}${BOLD}Recording FAILED — $GATE_FAILURES gate failure(s)${NC}"
    echo -e "Prompt '$PROMPT_ID' was NOT recorded."
    if ! record_loop_gate_failure "closure-gate" "failed" "prompt-recorder-gates" "iOS recorder gate failure for prompt $PROMPT_ID" "rerun-owner-prompt"; then
        exit 3
    fi
    exit 1
fi

python3 - "$BOOTSTRAP_FILE" "$PROMPT_ID" "$PROMPT_STATUS" "$CURRENT_RUN_ID" "$RECORDED_AT" "$PROMPT_NOTES" "$LAST_CHECK_FILE" <<'PYEOF'
import json
import os
import sys
import tempfile
from pathlib import Path

bootstrap_path, prompt_id, status, run_id, recorded_at, notes_text, last_check_path = sys.argv[1:]
boot = json.loads(Path(bootstrap_path).read_text(encoding="utf-8"))

validation_file = ".last-check.json" if Path(last_check_path).exists() else None
proof_summary = None
proof_summary_raw = os.environ.get("VALIDATION_PROOF_SUMMARY", "")
if proof_summary_raw:
    try:
        parsed = json.loads(proof_summary_raw)
        if isinstance(parsed, dict):
            proof_summary = parsed
    except Exception:
        proof_summary = None
entry = {
    "promptId": prompt_id,
    "status": status,
    "runId": run_id,
    "recordedAt": recorded_at,
    "validationProofFile": validation_file,
    "notes": notes_text if notes_text else None,
}
if proof_summary:
    entry["validationProof"] = proof_summary

existing = []
for row in boot.get("executedPrompts", []):
    if not isinstance(row, dict):
        continue
    if row.get("promptId") == prompt_id and row.get("runId") == run_id:
        continue
    existing.append(row)
existing.append(entry)
boot["executedPrompts"] = existing

path = Path(bootstrap_path)
with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", delete=False, dir=str(path.parent), prefix=f"{path.name}.tmp.") as tmp:
    json.dump(boot, tmp, ensure_ascii=False, indent=2)
    tmp.write("\n")
    tmp_path = Path(tmp.name)
os.replace(tmp_path, path)
print(f"OK: recorded {prompt_id} as {status}")
PYEOF
if [[ -n "$PROMPT_NOTES" ]]; then
    _OBS_NOTES_PRESENT=true
else
    _OBS_NOTES_PRESENT=false
fi
observability_event \
    --operation-type prompt-record \
    --prompt-id "$PROMPT_ID" \
    --status "$PROMPT_STATUS" \
    --metadata-json "{\"notesPresent\":$_OBS_NOTES_PRESENT}"
unset _OBS_NOTES_PRESENT

echo ""
echo -e "${GREEN}${BOLD}✓ Prompt '$PROMPT_ID' recorded as '$PROMPT_STATUS'${NC}"
