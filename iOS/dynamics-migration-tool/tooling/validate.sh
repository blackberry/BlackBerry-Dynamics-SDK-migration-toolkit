#!/usr/bin/env bash
# BlackBerry Dynamics iOS Migration Tool — Validation Script
# Verifies migration-tool changes and report contract correctness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/toolkit-version.sh
. "$SCRIPT_DIR/lib/toolkit-version.sh"
toolkit_version_load "$TOOL_DIR"
CHECK_PROMPT_MAP="$TOOL_DIR/tooling/check-prompt-map.json"

OUTPUT_DIR="$TOOL_DIR/output"
BOOTSTRAP_FILE="$OUTPUT_DIR/bootstrap.json"
TARGET_MAP_FILE="$OUTPUT_DIR/target-map.json"
ANALYSIS_FILE="$OUTPUT_DIR/migration-analysis.json"
PLAN_STATE_FILE="$OUTPUT_DIR/migration-plan-state.json"
LAST_CHECK_FILE="$OUTPUT_DIR/.last-check.json"
REPORT_FILE="$OUTPUT_DIR/migration-report.json"
API_CATALOG_FILE="$TOOL_DIR/contracts/api-catalog.ios.v1.0.0.json"
AUTH_REACHABILITY_FILE="$OUTPUT_DIR/auth-reachability.json"
LOOP_STATE_SH="$TOOL_DIR/tooling/loop-state.sh"
VALIDATE_START_EPOCH_MS="$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)"
VALIDATION_RUN_ID="$(python3 -c 'import uuid; print(str(uuid.uuid4()))' 2>/dev/null || echo "run-$(date +%s)")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

PASS=0
FAIL=0
WARN=0

PREFLIGHT=false
CHECK_PROMPT_ID=""
PROMPT_CONFIG_JSON=""
VALIDATION_MODE="full"
EXPECTED_VALIDATION_MODE=""
REQUIRED_PHASES=()
REQUIRED_ARTIFACTS=()
PHASES_EXECUTED=()
CURRENT_RUN_ID=""

ERRORS_LIST=()
BLOCKERS_LIST=()
WARNINGS_LIST=()

FINGERPRINT_ROWS=()

usage() {
    cat <<'EOF'
Usage:
  validate.sh [--preflight] [--check-prompt <id>] [--version]

Modes:
  --preflight            Run environment checks only.
  --check-prompt <id>    Run prompt-scoped validation for prompt id.
  (default)              Run full validation.
EOF
}

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS + 1)); }
warn() { echo -e "  ${YELLOW}WARN${NC} $1"; WARN=$((WARN + 1)); WARNINGS_LIST+=("$1"); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL + 1)); ERRORS_LIST+=("$1"); }
blocker() { echo -e "  ${RED}FAIL${NC} [BLOCKER] $1"; FAIL=$((FAIL + 1)); BLOCKERS_LIST+=("$1"); ERRORS_LIST+=("[BLOCKER] $1"); }
skip() { echo -e "  ${CYAN}SKIP${NC} $1"; }

OBSERVABILITY_PY="$TOOL_DIR/tooling/lib/observability.py"
observability_event() {
    [[ -f "$OBSERVABILITY_PY" ]] || return 0
    python3 "$OBSERVABILITY_PY" event \
        --tool-dir "$TOOL_DIR" \
        --project-root "$PROJECT_ROOT" \
        --platform ios \
        --run-id "${CURRENT_RUN_ID:-$VALIDATION_RUN_ID}" \
        "$@" >/dev/null 2>&1 || true
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --preflight) PREFLIGHT=true; VALIDATION_MODE="preflight"; shift ;;
        --check-prompt)
            CHECK_PROMPT_ID="${2:-}"
            [[ -z "$CHECK_PROMPT_ID" ]] && { echo -e "${RED}ERROR: --check-prompt requires an id${NC}"; exit 2; }
            VALIDATION_MODE="prompt-scoped"
            shift 2
            ;;
        --version) toolkit_version_print; exit 0 ;;
        --help|-h) usage; exit 0 ;;
        *) echo -e "${RED}ERROR: Unknown argument '$1'${NC}"; usage; exit 2 ;;
    esac
done

load_prompt_registry() {
    if [[ "$VALIDATION_MODE" != "prompt-scoped" ]]; then
        return
    fi
    local registry_rc
    set +e
    PROMPT_CONFIG_JSON=$(python3 - <<PYEOF
import json, sys
path = "$CHECK_PROMPT_MAP"
prompt_id = "$CHECK_PROMPT_ID"
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception as exc:
    print(f"ERROR: cannot parse check-prompt-map.json: {exc}")
    sys.exit(2)
for p in data.get("prompts", []):
    if p.get("id") == prompt_id:
        print(json.dumps(p))
        sys.exit(0)
print(f"ERROR: unknown prompt id '{prompt_id}'")
sys.exit(3)
PYEOF
)
    registry_rc=$?
    set -e
    if [[ $registry_rc -ne 0 && "$PROMPT_CONFIG_JSON" != ERROR:* ]]; then
        fail "unknown prompt id '$CHECK_PROMPT_ID'"
        return
    fi
    if [[ "$PROMPT_CONFIG_JSON" == ERROR:* ]]; then
        fail "${PROMPT_CONFIG_JSON#ERROR: }"
        return
    fi

    EXPECTED_VALIDATION_MODE=$(python3 - <<PYEOF
import json
p = json.loads("""$PROMPT_CONFIG_JSON""")
print((p.get("validator") or {}).get("mode") or "")
PYEOF
)
    if [[ "$EXPECTED_VALIDATION_MODE" != "prompt-scoped" ]]; then
        fail "Prompt '$CHECK_PROMPT_ID' is not configured for prompt-scoped validation"
        return
    fi

    REQUIRED_PHASES=()
    while IFS= read -r phase; do
        [[ -n "$phase" ]] && REQUIRED_PHASES+=("$phase")
    done < <(python3 - <<PYEOF
import json
p = json.loads("""$PROMPT_CONFIG_JSON""")
for phase in (p.get("validator") or {}).get("requiredPhases", []):
    print(phase)
PYEOF
)
    REQUIRED_ARTIFACTS=()
    while IFS= read -r artifact; do
        [[ -n "$artifact" ]] && REQUIRED_ARTIFACTS+=("$artifact")
    done < <(python3 - <<PYEOF
import json
p = json.loads("""$PROMPT_CONFIG_JSON""")
for artifact in p.get("requiredArtifacts", []):
    print(artifact)
PYEOF
)
    if [[ "${#REQUIRED_PHASES[@]}" -le 1 ]]; then
        fail "Prompt '$CHECK_PROMPT_ID' has invalid scoped phase set (Phase 0-only or empty)"
    fi
}

should_run_phase() {
    local phase="$1"
    if [[ "$VALIDATION_MODE" == "full" ]]; then
        return 0
    fi
    if [[ "$VALIDATION_MODE" == "preflight" ]]; then
        [[ "$phase" == "0-artifact-provenance" ]] && return 0
        return 1
    fi
    # prompt-scoped
    if [[ "$phase" == "0-artifact-provenance" ]]; then
        return 0
    fi
    for p in "${REQUIRED_PHASES[@]-}"; do
        [[ -z "$p" ]] && continue
        [[ "$p" == "$phase" ]] && return 0
    done
    return 1
}

record_phase() {
    PHASES_EXECUTED+=("$1")
}

set_fingerprint() {
    local key="$1"
    local value="$2"
    local i
    for i in "${!FINGERPRINT_ROWS[@]}"; do
        if [[ "${FINGERPRINT_ROWS[$i]}" == "$key="* ]]; then
            FINGERPRINT_ROWS[$i]="$key=$value"
            return
        fi
    done
    FINGERPRINT_ROWS+=("$key=$value")
}

get_fingerprint() {
    local key="$1"
    local row
    for row in "${FINGERPRINT_ROWS[@]}"; do
        if [[ "$row" == "$key="* ]]; then
            echo "${row#*=}"
            return 0
        fi
    done
    echo ""
}

fingerprint_file() {
    local file="$1"
    local key="$2"
    if [[ -f "$file" ]]; then
        local fp
        fp=$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$fp" ]]; then
            set_fingerprint "$key" "$fp"
        fi
    fi
}

compute_source_fingerprint() {
    local fp
    local fp_start_ms
    fp_start_ms="$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0)"
    fp=$(PROJECT_ROOT_ENV="$PROJECT_ROOT" python3 - <<'PYEOF'
import hashlib
import os
import pathlib

root = pathlib.Path(os.environ["PROJECT_ROOT_ENV"])
exclude = {
    "dynamics-migration-tool",
    ".cursor",
    ".kiro",
    "Pods",
    ".build",
    "DerivedData",
}
patterns = ("*.swift", "*.m", "*.mm", "*.h", "*.plist", "*.entitlements", "*.pbxproj", "Podfile", "Package.swift")
files = []
for pat in patterns:
    files.extend(root.rglob(pat))
usable = []
for p in files:
    parts = set(p.parts)
    if parts & exclude:
        continue
    if p.is_file():
        usable.append(p)
usable = sorted(set(usable))
h = hashlib.sha256()
for p in usable:
    rel = str(p.relative_to(root))
    h.update(rel.encode("utf-8"))
    try:
        h.update(p.read_bytes())
    except Exception:
        continue
print(h.hexdigest())
PYEOF
)
    if [[ -n "$fp" ]]; then
        set_fingerprint "source-tree" "$fp"
        observability_event \
            --operation-type script-hash-read \
            --phase source-tree-fingerprint \
            --content-hash "$fp" \
            --start-ms "$fp_start_ms" \
            --metadata-json "{\"fingerprintKey\":\"source-tree\"}"
    fi
}

phase_0_artifact_provenance() {
    if ! should_run_phase "0-artifact-provenance"; then
        return
    fi
    record_phase "0-artifact-provenance"
    echo -e "${BOLD}Phase 0: Artifact Provenance${NC}"

    if [[ "$VALIDATION_MODE" == "prompt-scoped" ]]; then
        local artifact
        for artifact in "${REQUIRED_ARTIFACTS[@]-}"; do
            [[ -z "$artifact" ]] && continue
            local abs="$TOOL_DIR/$artifact"
            if [[ ! -f "$abs" ]]; then
                if [[ "$CHECK_PROMPT_ID" == "03b" && "$artifact" == "output/auth-reachability.json" ]]; then
                    warn "Required artifact deferred until phase 4c: $artifact"
                    continue
                fi
                fail "Required artifact missing for prompt '$CHECK_PROMPT_ID': $artifact"
            else
                if [[ "$abs" == *.json ]]; then
                    if python3 -m json.tool "$abs" >/dev/null 2>&1; then
                        pass "Required artifact valid: $artifact"
                    else
                        fail "Required artifact invalid JSON: $artifact"
                    fi
                else
                    pass "Required artifact present: $artifact"
                fi
            fi
        done
    fi

    if [[ -f "$BOOTSTRAP_FILE" ]]; then
        if python3 -m json.tool "$BOOTSTRAP_FILE" >/dev/null 2>&1; then
            pass "bootstrap.json is valid JSON"
        else
            fail "bootstrap.json is invalid JSON"
        fi
        CURRENT_RUN_ID=$(python3 - <<PYEOF
import json
try:
    print(json.load(open("$BOOTSTRAP_FILE", encoding="utf-8")).get("runId",""))
except Exception:
    print("")
PYEOF
)
        [[ -n "$CURRENT_RUN_ID" ]] && pass "bootstrap.json runId present: $CURRENT_RUN_ID" || fail "bootstrap.json missing runId"
    else
        fail "bootstrap.json missing — run prompt 00pre first"
    fi

    if [[ -f "$TARGET_MAP_FILE" ]]; then
        if python3 -m json.tool "$TARGET_MAP_FILE" >/dev/null 2>&1; then
            pass "target-map.json is valid JSON"
        else
            fail "target-map.json is invalid JSON"
        fi
    else
        fail "target-map.json missing — run prompt 00pre first"
    fi

    if [[ -f "$ANALYSIS_FILE" ]]; then
        python3 -m json.tool "$ANALYSIS_FILE" >/dev/null 2>&1 && pass "migration-analysis.json is valid JSON" || fail "migration-analysis.json is invalid JSON"
    else
        if [[ "$VALIDATION_MODE" == "preflight" ]]; then
            warn "migration-analysis.json missing — expected before prompt 00"
        else
            fail "migration-analysis.json missing — run prompt 00 first"
        fi
    fi

    if [[ -f "$PLAN_STATE_FILE" ]]; then
        python3 -m json.tool "$PLAN_STATE_FILE" >/dev/null 2>&1 && pass "migration-plan-state.json is valid JSON" || fail "migration-plan-state.json is invalid JSON"
    fi

    if [[ -f "$REPORT_FILE" ]]; then
        local schema_ver
        schema_ver=$(python3 - <<PYEOF
import json
try:
    print(json.load(open("$REPORT_FILE", encoding="utf-8")).get("schemaVersion",""))
except Exception:
    print("")
PYEOF
)
        if [[ "$schema_ver" == "2.0.0" ]]; then
            fail "stale migration-report.json schemaVersion 2.0.0 detected"
        fi
    fi

    if [[ -n "$CURRENT_RUN_ID" ]]; then
        local file file_run
        for file in "$TARGET_MAP_FILE" "$ANALYSIS_FILE" "$PLAN_STATE_FILE" "$LAST_CHECK_FILE" "$REPORT_FILE"; do
            [[ ! -f "$file" ]] && continue
            file_run=$(python3 - <<PYEOF
import json
try:
    d = json.load(open("$file", encoding="utf-8"))
    print(d.get("runId") or (d.get("runProvenance") or {}).get("runId") or "")
except Exception:
    print("")
PYEOF
)
            if [[ -n "$file_run" && "$file_run" != "$CURRENT_RUN_ID" ]]; then
                fail "$(basename "$file") runId mismatch (expected $CURRENT_RUN_ID, got $file_run)"
            fi
        done
    fi

    fingerprint_file "$BOOTSTRAP_FILE" "bootstrap.json"
    fingerprint_file "$TARGET_MAP_FILE" "target-map.json"
    fingerprint_file "$ANALYSIS_FILE" "migration-analysis.json"
    fingerprint_file "$PLAN_STATE_FILE" "migration-plan-state.json"
    fingerprint_file "$REPORT_FILE" "migration-report.json"
    fingerprint_file "$AUTH_REACHABILITY_FILE" "auth-reachability.json"
    fingerprint_file "$CHECK_PROMPT_MAP" "check-prompt-map.json"
    compute_source_fingerprint
    echo ""
}

detect_project_files() {
    XCWORKSPACE=""
    XCODEPROJ=""
    INFO_PLIST=""
    PODFILE=""
    ENTITLEMENTS=""
    shopt -s nullglob
    for ws in "$PROJECT_ROOT"/*.xcworkspace "$PROJECT_ROOT"/*/*.xcworkspace; do
        if [[ -d "$ws" ]]; then
            XCWORKSPACE="$ws"
            break
        fi
    done
    for proj in "$PROJECT_ROOT"/*.xcodeproj "$PROJECT_ROOT"/*/*.xcodeproj; do
        if [[ -d "$proj" ]]; then
            XCODEPROJ="$proj"
            break
        fi
    done
    if [[ -f "$PROJECT_ROOT/Podfile" ]]; then
        PODFILE="$PROJECT_ROOT/Podfile"
    else
        for pf in "$PROJECT_ROOT"/*/Podfile; do
            if [[ -f "$pf" ]]; then
                PODFILE="$pf"
                break
            fi
        done
    fi
    # Prefer application-target Info.plist / entitlements from target-map
    # so Widget/Share extension plists are not chosen first.
    if [[ -f "$TARGET_MAP_FILE" ]]; then
        local mapped
        mapped=$(python3 - "$TARGET_MAP_FILE" "$PROJECT_ROOT" <<'PY' 2>/dev/null
import json, sys
from pathlib import Path
tm = Path(sys.argv[1])
root = Path(sys.argv[2])
try:
    data = json.loads(tm.read_text(encoding="utf-8"))
except Exception:
    sys.exit(0)
plist = ""
ent = ""
for t in data.get("targets") or []:
    if not isinstance(t, dict) or t.get("type") != "application":
        continue
    ip = t.get("infoPlistPath")
    if isinstance(ip, str) and ip.strip() and not plist:
        cand = root / ip.strip()
        if cand.is_file():
            plist = str(cand)
    ep = t.get("entitlementsPath")
    if isinstance(ep, str) and ep.strip() and not ent:
        cand = root / ep.strip()
        if cand.is_file():
            ent = str(cand)
    if plist and ent:
        break
if plist:
    print(f"PLIST={plist}")
if ent:
    print(f"ENT={ent}")
PY
        )
        while IFS= read -r line; do
            case "$line" in
                PLIST=*) INFO_PLIST="${line#PLIST=}" ;;
                ENT=*) ENTITLEMENTS="${line#ENT=}" ;;
            esac
        done <<< "$mapped"
    fi
    if [[ -z "$INFO_PLIST" ]]; then
        for plist in \
            "$PROJECT_ROOT"/*/Info.plist \
            "$PROJECT_ROOT"/Info.plist \
            "$PROJECT_ROOT"/*/*/Info.plist \
            "$PROJECT_ROOT"/*/*/*/Info.plist \
            "$PROJECT_ROOT"/*/Supporting\ Files/Info.plist \
            "$PROJECT_ROOT"/*/*/Supporting\ Files/Info.plist
        do
            if [[ -f "$plist" ]]; then
                # Skip obvious extension/widget plists when falling back
                case "$plist" in
                    *Widget*|*Share*|*Extension*|*Intents*|*Safari*) continue ;;
                esac
                INFO_PLIST="$plist"
                break
            fi
        done
    fi
    if [[ -z "$INFO_PLIST" ]]; then
        for plist in \
            "$PROJECT_ROOT"/*/Info.plist \
            "$PROJECT_ROOT"/Info.plist \
            "$PROJECT_ROOT"/*/*/Info.plist \
            "$PROJECT_ROOT"/*/*/*/Info.plist
        do
            if [[ -f "$plist" ]]; then
                INFO_PLIST="$plist"
                break
            fi
        done
    fi
    if [[ -z "$ENTITLEMENTS" ]]; then
        for ent in \
            "$PROJECT_ROOT"/*/*.entitlements \
            "$PROJECT_ROOT"/*.entitlements \
            "$PROJECT_ROOT"/*/*/*.entitlements \
            "$PROJECT_ROOT"/*/Supporting\ Files/*.entitlements
        do
            if [[ -f "$ent" ]]; then
                ENTITLEMENTS="$ent"
                break
            fi
        done
    fi
    shopt -u nullglob
}

validate_info_plist_configuration() {
    local output rc
    set +e
    output=$(python3 - "$INFO_PLIST" "$XCODEPROJ" "$BOOTSTRAP_FILE" <<'PYEOF'
import json
import plistlib
import re
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
xcodeproj_path = Path(sys.argv[2]) if sys.argv[2] else None
bootstrap_path = Path(sys.argv[3])

messages = []

def add(kind, message):
    messages.append((kind, message))

def text(value):
    return value.strip() if isinstance(value, str) else ""

def load_plist(path):
    try:
        with path.open("rb") as fh:
            return plistlib.load(fh)
    except Exception as exc:
        add("FAIL", f"Info.plist cannot be parsed: {exc}")
        return None

def product_bundle_identifiers(project_path):
    values = []
    if not project_path:
        return values
    pbxproj = project_path / "project.pbxproj"
    if not pbxproj.is_file():
        return values
    try:
        data = pbxproj.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return values
    for raw in re.findall(r"PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);", data):
        value = raw.strip().strip('"')
        if value and value not in values:
            values.append(value)
    return values

def bootstrap_setup_type(path):
    if not path.is_file():
        return ""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return ""
    uem = data.get("uemValues") if isinstance(data, dict) else {}
    if not isinstance(uem, dict):
        return ""
    value = uem.get("applicationSetupType") or uem.get("appSetupType") or ""
    return str(value).strip().lower()

def normalize_setup(value):
    value = value.replace("_", "-").replace(" ", "-")
    aliases = {
        "enterprise": "in-house",
        "inhouse": "in-house",
        "in-house": "in-house",
        "uem": "in-house",
        "uem-managed": "in-house",
        "partner": "partner-third-party",
        "third-party": "partner-third-party",
        "thirdparty": "partner-third-party",
        "partner-third-party": "partner-third-party",
        "blackberry": "blackberry-developed",
        "blackberry-developed": "blackberry-developed",
        "blackberry-internal": "blackberry-developed",
    }
    return aliases.get(value, "")

def scheme_set(plist):
    schemes = []
    names = []
    url_types = plist.get("CFBundleURLTypes")
    if not isinstance(url_types, list) or not url_types:
        add("FAIL", "Prompt 02: CFBundleURLTypes missing from Info.plist; required Dynamics URL schemes are absent")
        return set(), [], False
    for entry in url_types:
        if not isinstance(entry, dict):
            continue
        name = text(entry.get("CFBundleURLName"))
        if name:
            names.append(name)
        raw_schemes = entry.get("CFBundleURLSchemes")
        if isinstance(raw_schemes, list):
            for scheme in raw_schemes:
                scheme_text = text(scheme)
                if scheme_text:
                    schemes.append(scheme_text)
    if not schemes:
        add("FAIL", "Prompt 02: CFBundleURLTypes present but CFBundleURLSchemes is empty; required Dynamics URL schemes are absent")
    return set(schemes), names, True

plist = load_plist(plist_path)
if plist is None:
    for kind, message in messages:
        print(f"{kind}:{message}")
    sys.exit(1)

gd_app_id = text(plist.get("GDApplicationID"))
gd_version = text(plist.get("GDApplicationVersion"))
bundle_identifier = text(plist.get("CFBundleIdentifier"))

if gd_app_id:
    add("PASS", "GDApplicationID present in Info.plist")
else:
    add("FAIL", "Prompt 02: GDApplicationID missing from Info.plist")

if gd_version:
    add("PASS", "GDApplicationVersion present in Info.plist")
else:
    add("FAIL", "Prompt 02: GDApplicationVersion missing from Info.plist")

face_id_purpose = text(plist.get("NSFaceIDUsageDescription"))
if face_id_purpose:
    add("PASS", "NSFaceIDUsageDescription present with purpose string")
else:
    add("FAIL", "Prompt 02: NSFaceIDUsageDescription missing or empty in Info.plist; Dynamics requires a Face ID purpose string for biometric container unlock")

camera_purpose = text(plist.get("NSCameraUsageDescription"))
if camera_purpose:
    add("PASS", "NSCameraUsageDescription present with purpose string")
else:
    add("FAIL", "Prompt 02: NSCameraUsageDescription missing or empty in Info.plist; required for QR-code activation support")

for key in (
    "CFBundleExecutable",
    "CFBundleIdentifier",
    "CFBundleName",
    "CFBundlePackageType",
    "CFBundleShortVersionString",
    "CFBundleVersion",
):
    if key in plist and plist.get(key) not in ("", None):
        add("PASS", f"{key} present in Info.plist")
    else:
        add("FAIL", f"{key} missing from Info.plist")

schemes, url_names, has_url_types = scheme_set(plist)
bundle_candidates = []
if bundle_identifier:
    bundle_candidates.append(bundle_identifier)
for value in product_bundle_identifiers(xcodeproj_path):
    if value not in bundle_candidates:
        bundle_candidates.append(value)
product_bundle_identifier_token = "$" + "(PRODUCT_BUNDLE_IDENTIFIER)"
build_setting_prefix = "$" + "("
if product_bundle_identifier_token not in bundle_candidates:
    bundle_candidates.append(product_bundle_identifier_token)

concrete_candidates = [v for v in bundle_candidates if build_setting_prefix not in v and v]
expected_name_values = set(bundle_candidates)
if has_url_types and not any(name in expected_name_values for name in url_names):
    expected_display = ", ".join(bundle_candidates)
    found_display = ", ".join(url_names) if url_names else "<none>"
    add("FAIL", f"Prompt 02: CFBundleURLName must be the native bundle identifier; found {found_display}, expected one of: {expected_display}")
elif has_url_types:
    add("PASS", "CFBundleURLName uses the native bundle identifier")

if gd_app_id and gd_app_id != bundle_identifier:
    prohibited = [
        f"{gd_app_id}.sc",
        f"{gd_app_id}.sc2",
        f"{gd_app_id}.sc3",
    ]
    if gd_version:
        prohibited.append(f"{gd_app_id}.sc2.{gd_version}")
    for scheme in prohibited:
        if scheme in schemes:
            add("FAIL", f"Prompt 02: URL scheme {scheme} uses GDApplicationID; use the native bundle identifier instead")

for scheme in sorted(schemes):
    if scheme.endswith(".sc"):
        add("FAIL", f"Prompt 02: URL scheme {scheme} is invalid; do not register bare .sc")

def scheme_present(suffix):
    for prefix in bundle_candidates:
        if not prefix:
            continue
        if f"{prefix}{suffix}" in schemes:
            return True
    return False

if has_url_types:
    required_suffixes = [".sc2", ".sc3"]
    if gd_version:
        required_suffixes.insert(1, f".sc2.{gd_version}")
    for suffix in required_suffixes:
        if scheme_present(suffix):
            add("PASS", f"Dynamics URL scheme {suffix} registered for native bundle identifier")
        else:
            expected = [f"{prefix}{suffix}" for prefix in bundle_candidates if prefix]
            add("FAIL", f"Prompt 02: Missing required Dynamics URL scheme: one of {', '.join(expected)}")

if "com.good.gd.discovery" in schemes:
    add("PASS", "Dynamics discovery URL scheme com.good.gd.discovery registered")
else:
    add("FAIL", "Prompt 02: Missing required Dynamics URL scheme: com.good.gd.discovery")

has_enterprise = "com.good.gd.discovery.enterprise" in schemes
has_good = "com.good.gd.discovery.good" in schemes
if has_enterprise and has_good:
    add("FAIL", "Prompt 02: Do not register both com.good.gd.discovery.enterprise and com.good.gd.discovery.good")

setup = normalize_setup(bootstrap_setup_type(bootstrap_path))
if not setup:
    setup = "in-house"

if setup == "partner-third-party":
    if has_enterprise:
        add("FAIL", "Prompt 02: Partner/third-party apps must not register com.good.gd.discovery.enterprise")
    if has_good:
        add("FAIL", "Prompt 02: Partner/third-party apps must not register com.good.gd.discovery.good")
    if not has_enterprise and not has_good:
        add("PASS", "Partner/third-party discovery scheme policy satisfied")
elif setup == "blackberry-developed":
    if has_enterprise:
        add("FAIL", "Prompt 02: BlackBerry-developed apps must not register com.good.gd.discovery.enterprise")
    if has_good:
        add("PASS", "BlackBerry-developed discovery URL scheme com.good.gd.discovery.good registered")
    else:
        add("FAIL", "Prompt 02: Missing required Dynamics URL scheme for BlackBerry-developed setup: com.good.gd.discovery.good")
    if gd_app_id and not gd_app_id.startswith(("com.good.", "com.blackberry.", "com.rim.")):
        add("FAIL", "Prompt 02: com.good.gd.discovery.good is only valid for BlackBerry-owned GDApplicationID prefixes")
else:
    if has_enterprise:
        add("PASS", "In-house/UEM-managed discovery URL scheme com.good.gd.discovery.enterprise registered")
    else:
        add("FAIL", "Prompt 02: Missing required Dynamics URL scheme for in-house/UEM-managed setup: com.good.gd.discovery.enterprise")
    if has_good:
        add("FAIL", "Prompt 02: In-house/UEM-managed apps must not register com.good.gd.discovery.good")

for kind, message in messages:
    print(f"{kind}:{message}")

sys.exit(1 if any(kind == "FAIL" for kind, _ in messages) else 0)
PYEOF
)
    rc=$?
    set -e
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
            PASS:*) pass "${line#PASS:}" ;;
            WARN:*) warn "${line#WARN:}" ;;
            FAIL:*) fail "${line#FAIL:}" ;;
            *) warn "$line" ;;
        esac
    done <<< "$output"
    if [[ $rc -ne 0 ]]; then
        fail "Info.plist Dynamics configuration checks failed"
    fi
    return 0
}

phase_1_to_11_checks() {
    detect_project_files

    if should_run_phase "1-configuration"; then
        record_phase "1-configuration"
        echo -e "${BOLD}Phase 1: Configuration${NC}"
        if [[ -n "$INFO_PLIST" ]]; then
            validate_info_plist_configuration
            if [[ -n "$XCODEPROJ" ]] && grep -q "$(basename "$INFO_PLIST") .*in Resources" "$XCODEPROJ/project.pbxproj" 2>/dev/null; then
                warn "Info.plist appears in Copy Bundle Resources; verify duplicate-output risk is resolved"
            fi
        else
            fail "Info.plist not found"
        fi
        echo ""
    fi

    if should_run_phase "2-framework-integration"; then
        record_phase "2-framework-integration"
        echo -e "${BOLD}Phase 2: Framework Integration${NC}"
        if [[ -n "$PODFILE" ]] && grep -q "BlackBerryDynamics" "$PODFILE"; then
            pass "BlackBerryDynamics integrated via CocoaPods"
        elif [[ -n "$XCODEPROJ" ]] && grep -qiE "BlackBerry-Dynamics-iOS-SDK|blackberry-dynamics-ios-sdk" "$XCODEPROJ/project.pbxproj" 2>/dev/null; then
            pass "BlackBerryDynamics integrated via official SPM"
        elif find "$PROJECT_ROOT" -maxdepth 4 -name "BlackBerryDynamics.xcframework" 2>/dev/null | grep -q .; then
            pass "BlackBerryDynamics.xcframework found (manual integration)"
        else
            fail "BlackBerryDynamics not detected in SPM/manual integration"
        fi
        echo ""
    fi

    if should_run_phase "3-keychain-sharing"; then
        record_phase "3-keychain-sharing"
        echo -e "${BOLD}Phase 3: Keychain Sharing${NC}"
        if [[ -n "$ENTITLEMENTS" ]]; then
            grep -q "com.good.gd.data" "$ENTITLEMENTS" && pass "Keychain group com.good.gd.data configured" || fail "Keychain group com.good.gd.data missing"
        else
            warn "No .entitlements file found"
        fi
        echo ""
    fi

    RG_EXCLUDES=(
        --glob "!dynamics-migration-tool/**"
        --glob "!.cursor/**"
        --glob "!.kiro/**"
        --glob "!Pods/**"
        --glob "!.build/**"
        --glob "!DerivedData/**"
        --glob "!**/Tests/**"
        --glob "!**/*Tests/**"
        --glob "!**/*UITests/**"
        --glob "!**/*-macOS/**"
        --glob "!**/*-watchOS/**"
        --glob "!**/*-tvOS/**"
        --glob "!**/Examples/**"
        --glob "!**/Example/**"
    )
    # Relative source roots excluded from app-scoped scans (rg + non-rg fallback).
    APP_EXCLUDE_ROOTS=()
    # Exclude framework/library/test source roots from target-map so library
    # trees (e.g. DGCharts Source/) do not fail app-scoped storage phases.
    if [[ -f "$TARGET_MAP_FILE" ]]; then
        while IFS= read -r exclude_root; do
            [[ -z "$exclude_root" ]] && continue
            RG_EXCLUDES+=(--glob "!${exclude_root}/**")
            APP_EXCLUDE_ROOTS+=("$exclude_root")
        done < <(
            python3 - "$TARGET_MAP_FILE" <<'PY' 2>/dev/null
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    sys.exit(0)
seen = set()
for t in data.get("targets") or []:
    if not isinstance(t, dict):
        continue
    if t.get("type") not in {"framework", "library", "tests", "other"}:
        continue
    for root in t.get("sourceRoots") or []:
        if not isinstance(root, str):
            continue
        root = root.strip().strip("/")
        if not root or root in seen:
            continue
        seen.add(root)
        print(root)
PY
        )
    fi
    # Non-rg file walk used when ripgrep is unavailable. Honors the same
    # basename skip set and target-map APP_EXCLUDE_ROOTS as RG_EXCLUDES.
    # mode=exists → exit 0/1; mode=count → print match line count.
    app_search_python() {
        local mode="$1"
        local pattern="$2"
        shift 2
        local exclude_json
        exclude_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${APP_EXCLUDE_ROOTS[@]+"${APP_EXCLUDE_ROOTS[@]}"}")
        python3 - "$mode" "$PROJECT_ROOT" "$pattern" "$exclude_json" "$@" <<'PYEOF'
import json
import re
import sys
from pathlib import Path

mode = sys.argv[1]
project_root = Path(sys.argv[2])
pattern = sys.argv[3]
try:
    excluded_roots = {r.strip().strip("/") for r in json.loads(sys.argv[4]) if isinstance(r, str) and r.strip()}
except Exception:
    excluded_roots = set()
include_globs = []
for arg in sys.argv[5:]:
    if arg.startswith("--include="):
        include_globs.append(arg.split("=", 1)[1])
    elif arg.startswith("--glob="):
        # Phase 11-style globs: "*.swift" or bare "Podfile"
        include_globs.append(arg.split("=", 1)[1])
if not include_globs:
    include_globs = ["*.swift", "*.m", "*.h", "*.mm"]

skip_parts = {
    "dynamics-migration-tool", ".cursor", ".kiro", "Pods", ".build",
    "DerivedData", ".git", "Tests", "Examples", "Example",
}
skip_suffixes = ("Tests", "UITests", "-macOS", "-watchOS", "-tvOS")
regex = re.compile(pattern, re.MULTILINE)
count = 0

def iter_candidates():
    seen = set()
    for include in include_globs:
        if "/" in include or include.startswith("!"):
            continue
        if "*" in include or "?" in include or "[" in include:
            paths = project_root.rglob(include)
        else:
            # Bare filename (e.g. Podfile)
            paths = project_root.rglob(include)
        for path in paths:
            if not path.is_file():
                continue
            key = path.resolve()
            if key in seen:
                continue
            seen.add(key)
            parts = path.parts
            if skip_parts.intersection(parts):
                continue
            if any(part.endswith(skip_suffixes) for part in parts):
                continue
            try:
                rel = path.relative_to(project_root).as_posix()
            except ValueError:
                continue
            if any(rel == root or rel.startswith(root + "/") for root in excluded_roots):
                continue
            yield path, rel

for path, _rel in iter_candidates():
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        continue
    if mode == "exists":
        if regex.search(text):
            sys.exit(0)
        continue
    # Match `rg -n | wc -l`: count matching lines, not total occurrences.
    for line in text.splitlines():
        if regex.search(line):
            count += 1

if mode == "exists":
    sys.exit(1)
print(count)
PYEOF
    }
    app_grep() {
        local pattern="$1"
        shift
        pattern="${pattern//\\|/|}"
        local rg_args=()
        local arg
        for arg in "$@"; do
            case "$arg" in
                --include=*)
                    rg_args+=(--glob "${arg#--include=}")
                    ;;
            esac
        done
        local rc
        set +e
        if command -v rg >/dev/null 2>&1; then
            rg -q --no-messages "$pattern" "$PROJECT_ROOT" "${RG_EXCLUDES[@]}" "${rg_args[@]}"
            rc=$?
        else
            # Python fallback: same skip dirs + target-map APP_EXCLUDE_ROOTS as rg
            app_search_python exists "$pattern" "$@"
            rc=$?
        fi
        set -e
        return $rc
    }

    app_grep_stripped() {
        local pattern="$1"
        shift
        local rc
        set +e
        python3 - "$PROJECT_ROOT" "$TOOL_DIR/tooling/lib" "$TARGET_MAP_FILE" "$pattern" "$@" <<'PYEOF'
import json
import re
import sys
from pathlib import Path

project_root = Path(sys.argv[1])
lib_dir = Path(sys.argv[2])
target_map_path = Path(sys.argv[3])
pattern = sys.argv[4].replace(r"\|", "|")
include_args = sys.argv[5:]

sys.path.insert(0, str(lib_dir))
from source_parsing import strip_comments_and_strings  # type: ignore

include_globs = []
for arg in include_args:
    if arg.startswith("--include="):
        include_globs.append(arg.split("=", 1)[1])
if not include_globs:
    include_globs = ["*.swift", "*.m", "*.h", "*.mm"]

skip_parts = {
    "dynamics-migration-tool", ".cursor", ".kiro", "Pods", ".build",
    "DerivedData", ".git", "Tests", "Examples", "Example",
}
skip_suffixes = ("Tests", "UITests", "-macOS", "-watchOS", "-tvOS")
excluded_roots = set()
if target_map_path.is_file():
    try:
        tm = json.loads(target_map_path.read_text(encoding="utf-8"))
        for t in tm.get("targets") or []:
            if not isinstance(t, dict):
                continue
            if t.get("type") not in {"framework", "library", "tests", "other"}:
                continue
            for root in t.get("sourceRoots") or []:
                if isinstance(root, str) and root.strip():
                    excluded_roots.add(root.strip().strip("/"))
    except Exception:
        pass

regex = re.compile(pattern, re.MULTILINE)

for include in include_globs:
    for path in project_root.rglob(include):
        if not path.is_file():
            continue
        parts = path.parts
        if skip_parts.intersection(parts):
            continue
        if any(part.endswith(skip_suffixes) for part in parts):
            continue
        try:
            rel = path.relative_to(project_root).as_posix()
        except ValueError:
            continue
        if any(rel == root or rel.startswith(root + "/") for root in excluded_roots):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        stripped = strip_comments_and_strings(text, nested_block_comments=path.suffix in {".swift", ".m", ".mm"})
        if regex.search(stripped):
            sys.exit(0)
sys.exit(1)
PYEOF
        rc=$?
        set -e
        return $rc
    }

    domain_is_applicable() {
        local domain_id="$1"
        local rc
        set +e
        python3 - "$ANALYSIS_FILE" "$domain_id" <<'PYEOF'
import json
import sys
from pathlib import Path

analysis_path = Path(sys.argv[1])
domain_id = sys.argv[2]
if not analysis_path.exists():
    sys.exit(0)
try:
    data = json.loads(analysis_path.read_text(encoding="utf-8"))
except Exception:
    sys.exit(0)
for domain in data.get("executionPlan", []):
    if isinstance(domain, dict) and domain.get("domainId") == domain_id:
        if domain.get("applicability", "applicable") == "not-applicable":
            sys.exit(1)
        sys.exit(0)
sys.exit(0)
PYEOF
        rc=$?
        set -e
        return $rc
    }

    icc_domain_is_applicable() {
        domain_is_applicable "icc"
    }

    run_storage_contract_check() {
        local phase_kind="$1"
        local phase_name="$2"
        local output rc
        set +e
        output=$(PHASE_KIND="$phase_kind" python3 - <<PYEOF
import json
import os
import re
import sys
from pathlib import Path

analysis_path = Path("$ANALYSIS_FILE")
plan_path = Path("$PLAN_STATE_FILE")
phase_kind = os.environ.get("PHASE_KIND", "").strip()

ALLOWED = {"migrated", "removed", "blocked", "deferred", "notApplicable"}
BASE_FIELDS = [
    "id",
    "targetId",
    "relativePath",
    "symbol",
    "matchedApi",
    "sensitivity",
    "lifecycleReachability",
    "confidence",
    "evidenceSnippet",
]
CONTRACT_FIELDS = [
    "storageFamily",
    "operation",
    "pathOwnership",
    "proposedTreatment",
]

PASS, WARN, FAIL = [], [], []

def add(kind, message):
    if kind == "PASS":
        PASS.append(message)
    elif kind == "WARN":
        WARN.append(message)
    else:
        FAIL.append(message)

def norm_text(value):
    if isinstance(value, str):
        return value.lower()
    return ""

def has_text(value):
    return isinstance(value, str) and bool(value.strip())

try:
    analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
except Exception as exc:
    add("FAIL", f"migration-analysis.json invalid: {exc}")
    for msg in PASS:
        print(f"PASS:{msg}")
    for msg in WARN:
        print(f"WARN:{msg}")
    for msg in FAIL:
        print(f"FAIL:{msg}")
    sys.exit(1)

if plan_path.exists():
    try:
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
    except Exception as exc:
        add("FAIL", f"migration-plan-state.json invalid: {exc}")
        for msg in PASS:
            print(f"PASS:{msg}")
        for msg in WARN:
            print(f"WARN:{msg}")
        for msg in FAIL:
            print(f"FAIL:{msg}")
        sys.exit(1)
else:
    plan = {"dispositions": []}

analysis_run = str(analysis.get("runId", "")).strip()
dispositions = {}
for row in plan.get("dispositions", []):
    if not isinstance(row, dict):
        continue
    if analysis_run and row.get("runId") != analysis_run:
        continue
    cs_id = row.get("callSiteId")
    if not has_text(cs_id):
        continue
    if cs_id in dispositions:
        add("FAIL", f"duplicate active disposition for call-site '{cs_id}'")
        continue
    dispositions[cs_id] = row

execution_plan = analysis.get("executionPlan", [])
if not isinstance(execution_plan, list):
    add("FAIL", "executionPlan must be an array in migration-analysis.json")
    execution_plan = []

def domain_entry(domain_id):
    for entry in execution_plan:
        if isinstance(entry, dict) and entry.get("domainId") == domain_id:
            return entry
    return None

def callsite_categories(callsite):
    tokens = " ".join(
        str(callsite.get(k, "") or "")
        for k in ("matchedApi", "operation", "storageFamily", "wrapperLibrary", "proposedTreatment")
    ).lower()
    categories = set()
    if re.search(r"(sqlite3|fmdb|grdb|sqlite\.swift|sqlcipher|databasequeue|connection\()", tokens):
        categories.add("sql")
    if re.search(r"(core data|nspersistent|gdpersistentstorecoordinator|swiftdata|modelcontainer|@model|@query)", tokens):
        categories.add("coredata")
    if re.search(r"(filemanager|filehandle|data\\.write|string\\.write|write\\(to:|outputstream|gdcwritestream|archive|keyedarchiver|plist|createfile|write)", tokens):
        categories.add("file-writer")
    if re.search(r"(data\\s*\\(\\s*contentsof:?|string\\s*\\(\\s*contentsof:?|data\\.contentsof|string\\.contentsof|inputstream|gdcreadstream|forreading|url\\(fileurlwithpath|cache|viewer|quicklook|unarchive|read)", tokens):
        categories.add("file-reader")
    if re.search(r"(userdefaults|secitem|keychain|keychainaccess|swiftkeychainwrapper|cryptokit|commoncrypto|rncryptor|sqlcipher|sqlite3_key)", tokens):
        categories.add("prefs-keychain-crypto")
    return categories

def check_callsite_contract(domain_id, expected_prompt, callsite, require_sensitive_closed=False, enforce_swiftdata=False, enforce_keychain=False):
    cs_id = callsite.get("id")
    if not has_text(cs_id):
        add("FAIL", f"{domain_id}: call-site missing id")
        return

    missing_base = [key for key in BASE_FIELDS if callsite.get(key) in (None, "")]
    if missing_base:
        add("FAIL", f"{cs_id}: missing required analysis fields: {', '.join(missing_base)}")

    missing_contract = [key for key in CONTRACT_FIELDS if callsite.get(key) in (None, "")]
    if missing_contract:
        add("FAIL", f"{cs_id}: missing storage contract fields: {', '.join(missing_contract)}")

    disposition = dispositions.get(cs_id)
    if disposition is None:
        add("FAIL", f"{domain_id}: missing disposition for call-site '{cs_id}'")
        return

    if disposition.get("domainId") != domain_id:
        add("FAIL", f"{cs_id}: disposition domain mismatch ({disposition.get('domainId')!r})")
    if disposition.get("promptId") != expected_prompt:
        add("FAIL", f"{cs_id}: disposition prompt mismatch (expected {expected_prompt}, got {disposition.get('promptId')!r})")

    status = disposition.get("status")
    if status not in ALLOWED:
        add("FAIL", f"{cs_id}: invalid disposition status {status!r}")
        return

    rationale = disposition.get("rationale")
    if status in {"blocked", "deferred", "notApplicable"} and not has_text(rationale):
        add("FAIL", f"{cs_id}: status '{status}' requires a non-empty rationale")

    sensitivity = norm_text(callsite.get("sensitivity"))
    confidence = norm_text(callsite.get("confidence"))
    matched_api = norm_text(callsite.get("matchedApi"))

    if confidence == "low" and status == "migrated":
        add("FAIL", f"{cs_id}: low-confidence (opaque) call-site cannot be marked migrated")

    if require_sensitive_closed and sensitivity == "sensitive" and status not in {"migrated", "removed"}:
        add("FAIL", f"{cs_id}: sensitive storage call-site is not closed (status={status})")

    if enforce_swiftdata and re.search(r"(swiftdata|modelcontainer|modelcontext|@model|@query|#predicate)", matched_api):
        if status != "blocked":
            add("FAIL", f"{cs_id}: SwiftData call-site must be blocked until redesign is approved")

    if enforce_keychain and re.search(r"(secitem|keychain)", matched_api):
        policy_decision = callsite.get("keychainPolicyDecision") or callsite.get("proposedTreatment")
        notes = ""
        evidence = disposition.get("evidence")
        if isinstance(evidence, dict):
            notes = evidence.get("notes") or ""
        if not has_text(policy_decision):
            add("FAIL", f"{cs_id}: Keychain call-site missing explicit policy decision")
        if sensitivity == "sensitive" and not (has_text(notes) or has_text(rationale)):
            add("FAIL", f"{cs_id}: sensitive Keychain call-site missing policy/design evidence")

    if re.search(r"(cryptokit|commoncrypto|rncryptor|sqlcipher|sqlite3_key)", matched_api):
        evidence = disposition.get("evidence")
        notes = ""
        if isinstance(evidence, dict):
            notes = evidence.get("notes") or ""
        if not (has_text(notes) or has_text(rationale)):
            add("FAIL", f"{cs_id}: local-crypto decision requires evidence notes or rationale")

def evaluate_domain(domain_id, expected_prompt, phase_filter=None, require_sensitive_closed=False, enforce_swiftdata=False, enforce_keychain=False):
    entry = domain_entry(domain_id)
    if entry is None:
        add("WARN", f"{domain_id}: domain missing from executionPlan; skipping {phase_kind} checks")
        return
    if not isinstance(entry, dict):
        add("FAIL", f"{domain_id}: invalid executionPlan entry")
        return
    if entry.get("applicability", "applicable") == "not-applicable":
        add("PASS", f"{domain_id}: marked not-applicable")
        return

    callsites = [cs for cs in (entry.get("callSites") or []) if isinstance(cs, dict)]
    if phase_filter:
        callsites = [cs for cs in callsites if phase_filter(cs)]
    if not callsites:
        add("PASS", f"{domain_id}: no call-sites matched {phase_kind} filter (not present in this app)")
        return

    for callsite in callsites:
        check_callsite_contract(
            domain_id=domain_id,
            expected_prompt=expected_prompt,
            callsite=callsite,
            require_sensitive_closed=require_sensitive_closed,
            enforce_swiftdata=enforce_swiftdata,
            enforce_keychain=enforce_keychain,
        )
    add("PASS", f"{domain_id}: validated {len(callsites)} call-site(s) for {phase_kind}")

if phase_kind == "sql":
    evaluate_domain("secureSql", "04", phase_filter=lambda cs: "sql" in callsite_categories(cs), require_sensitive_closed=True)
elif phase_kind == "coredata":
    evaluate_domain("secureCoreData", "04b", phase_filter=lambda cs: "coredata" in callsite_categories(cs), require_sensitive_closed=True, enforce_swiftdata=True)
elif phase_kind == "writers":
    evaluate_domain("secureFileStorage", "05", phase_filter=lambda cs: "file-writer" in callsite_categories(cs), require_sensitive_closed=True)
elif phase_kind == "readers":
    evaluate_domain("secureFileStorage", "05", phase_filter=lambda cs: "file-reader" in callsite_categories(cs), require_sensitive_closed=True)
elif phase_kind == "preferences":
    evaluate_domain("secureFileStorage", "05", phase_filter=lambda cs: "prefs-keychain-crypto" in callsite_categories(cs), require_sensitive_closed=True, enforce_keychain=True)
elif phase_kind == "final":
    evaluate_domain("secureSql", "04", require_sensitive_closed=True)
    evaluate_domain("secureCoreData", "04b", require_sensitive_closed=True, enforce_swiftdata=True)
    evaluate_domain("secureFileStorage", "05", require_sensitive_closed=True, enforce_keychain=True)
else:
    add("FAIL", f"Unknown storage validation phase kind: {phase_kind!r}")

for msg in PASS:
    print(f"PASS:{msg}")
for msg in WARN:
    print(f"WARN:{msg}")
for msg in FAIL:
    print(f"FAIL:{msg}")
sys.exit(1 if FAIL else 0)
PYEOF
)
        rc=$?
        set -e
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            case "$line" in
                PASS:*) pass "${line#PASS:}" ;;
                WARN:*) warn "${line#WARN:}" ;;
                FAIL:*) fail "${line#FAIL:}" ;;
                *) warn "$line" ;;
            esac
        done <<< "$output"
        if [[ $rc -ne 0 ]]; then
            fail "$phase_name checks failed"
        fi
    }

    run_network_web_contract_check() {
        local phase_kind="$1"
        local phase_name="$2"
        local output rc
        local current_source_fp
        current_source_fp=$(get_fingerprint "source-tree")
        set +e
        output=$(PHASE_KIND="$phase_kind" CURRENT_SOURCE_FP="$current_source_fp" python3 - <<PYEOF
import json
import os
import re
import sys
from pathlib import Path

analysis_path = Path("$ANALYSIS_FILE")
plan_path = Path("$PLAN_STATE_FILE")
reach_path = Path("$AUTH_REACHABILITY_FILE")
phase_kind = os.environ.get("PHASE_KIND", "").strip()
current_source_fp = os.environ.get("CURRENT_SOURCE_FP", "").strip()

ALLOWED = {"migrated", "removed", "blocked", "deferred", "notApplicable"}
PASS, WARN, FAIL = [], [], []

NETWORK_PHASES = {
    "network-request-timing",
    "network-session",
    "network-protocol-pinning",
    "network-socket",
    "network-background",
    "network-final",
}
WEBVIEW_PHASES = {
    "webview-support",
    "webview-content",
    "webview-unsupported",
    "webview-final",
}

NETWORK_CONTRACT_FIELDS = [
    "transportFamily",
    "requestInitiationPoint",
    "executionMode",
    "customProtocolDecision",
    "pinningTrustDecision",
    "backgroundSessionDecision",
    "sessionConfiguration",
    "delegateHandling",
    "catalogRowId",
]
WEBVIEW_CONTRACT_FIELDS = [
    "webviewSupportState",
    "webviewInitPoint",
    "webContentSource",
    "webContentClassification",
    "customSchemeDecision",
    "processPoolDecision",
    "dataStoreDecision",
    "unsupportedFeatureDecision",
    "downloadUploadDecision",
    "catalogRowId",
]
BASE_FIELDS = ["id", "targetId", "relativePath", "symbol", "matchedApi", "line", "lifecycleReachability", "sensitivity", "confidence"]

def add(kind, message):
    if kind == "PASS":
        PASS.append(message)
    elif kind == "WARN":
        WARN.append(message)
    else:
        FAIL.append(message)

def has_text(value):
    return isinstance(value, str) and bool(value.strip())

def norm(value):
    if isinstance(value, str):
        return value.strip().lower()
    return ""

def contains_socket_surface(text):
    return bool(re.search(r"(nwconnection|cfsocket|cfstreamcreatepairwithsockettohost|nsstream|inputstream|outputstream|gcdasyncsocket|cocoaasyncsocket|websockettask|urlsessionwebsockettask|socket\\()", text))

def contains_session_surface(text):
    return bool(re.search(r"(urlsession|nsurlsession|nsurlconnection)", text))

def load_json(path, label):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        add("FAIL", f"{label} invalid: {exc}")
        return None

analysis = load_json(analysis_path, "migration-analysis.json")
if analysis is None:
    for msg in PASS:
        print(f"PASS:{msg}")
    for msg in WARN:
        print(f"WARN:{msg}")
    for msg in FAIL:
        print(f"FAIL:{msg}")
    sys.exit(1)

plan = {"dispositions": []}
if plan_path.exists():
    loaded = load_json(plan_path, "migration-plan-state.json")
    if loaded is not None:
        plan = loaded

reach = {}
if reach_path.exists():
    loaded = load_json(reach_path, "auth-reachability.json")
    if loaded is not None:
        reach = loaded
else:
    if phase_kind in {"network-request-timing", "network-final", "webview-support", "webview-final"}:
        add("FAIL", "auth-reachability.json missing for timing/reachability checks")

run_id = str(analysis.get("runId", "")).strip()
dispositions = {}
for row in (plan.get("dispositions") or []):
    if not isinstance(row, dict):
        continue
    if run_id and row.get("runId") != run_id:
        continue
    cs_id = row.get("callSiteId")
    if not has_text(cs_id):
        continue
    if cs_id in dispositions:
        add("FAIL", f"duplicate active disposition for call-site '{cs_id}'")
        continue
    dispositions[cs_id] = row

execution_plan = analysis.get("executionPlan")
if not isinstance(execution_plan, list):
    add("FAIL", "executionPlan must be an array")
    execution_plan = []

reach_by_callsite = {}
for finding in (reach.get("reachabilityFindings") or []):
    if isinstance(finding, dict):
        cs_id = finding.get("callSiteId")
        if has_text(cs_id):
            reach_by_callsite[cs_id] = finding

def domain_entry(domain_id):
    for entry in execution_plan:
        if isinstance(entry, dict) and entry.get("domainId") == domain_id:
            return entry
    return None

def stale_reachability_check():
    reach_fp = str(reach.get("sourceFingerprint", "")).strip()
    if reach_fp and current_source_fp and reach_fp != current_source_fp:
        add("FAIL", "authorization/network evidence is stale relative to current source fingerprint")

def validate_disposition(callsite_id, expected_domain, expected_prompt):
    row = dispositions.get(callsite_id)
    if row is None:
        add("FAIL", f"{expected_domain}: missing disposition for call-site '{callsite_id}'")
        return None
    if row.get("domainId") != expected_domain:
        add("FAIL", f"{callsite_id}: disposition domain mismatch ({row.get('domainId')!r})")
    if row.get("promptId") != expected_prompt:
        add("FAIL", f"{callsite_id}: disposition prompt mismatch (expected {expected_prompt}, got {row.get('promptId')!r})")
    status = row.get("status")
    if status not in ALLOWED:
        add("FAIL", f"{callsite_id}: invalid disposition status {status!r}")
        return None
    if status in {"blocked", "deferred", "notApplicable"} and not has_text(row.get("rationale")):
        add("FAIL", f"{callsite_id}: status '{status}' requires rationale")
    return row

def check_callsite_base(callsite):
    cs_id = callsite.get("id")
    if not has_text(cs_id):
        add("FAIL", "call-site missing id")
        return None
    missing_base = [k for k in BASE_FIELDS if callsite.get(k) in (None, "")]
    if missing_base:
        add("FAIL", f"{cs_id}: missing required call-site fields: {', '.join(missing_base)}")
    return cs_id

def evaluate_network():
    entry = domain_entry("secureNetworking")
    if entry is None:
        add("WARN", "secureNetworking domain missing from executionPlan")
        return
    if entry.get("applicability", "applicable") == "not-applicable":
        add("PASS", "secureNetworking marked not-applicable")
        return
    callsites = [cs for cs in (entry.get("callSites") or []) if isinstance(cs, dict)]
    if not callsites:
        add("FAIL", "secureNetworking applicable but has no call-sites")
        return

    for cs in callsites:
        cs_id = check_callsite_base(cs)
        if not cs_id:
            continue

        missing_contract = [k for k in NETWORK_CONTRACT_FIELDS if cs.get(k) in (None, "")]
        if missing_contract:
            add("FAIL", f"{cs_id}: missing network contract fields: {', '.join(missing_contract)}")

        disp = validate_disposition(cs_id, "secureNetworking", "06")
        if disp is None:
            continue

        status = disp.get("status")
        matched = norm(cs.get("matchedApi"))
        transport = norm(cs.get("transportFamily"))
        custom_proto = norm(cs.get("customProtocolDecision"))
        pinning = norm(cs.get("pinningTrustDecision"))
        background_decision = norm(cs.get("backgroundSessionDecision"))
        lifecycle = norm(cs.get("lifecycleReachability"))
        execution_mode = norm(cs.get("executionMode"))
        replacement = norm(cs.get("replacementApi"))

        if "gdurlsession" in matched or "gdurlsession" in replacement:
            add("FAIL", f"{cs_id}: invented API GDURLSession is prohibited")

        if lifecycle == "pre-auth":
            add("FAIL", f"{cs_id}: network initiation marked pre-auth")

        finding = reach_by_callsite.get(cs_id, {})
        classification = norm(finding.get("classification"))
        if phase_kind in {"network-request-timing", "network-final"}:
            if classification == "definitely-pre-auth":
                add("FAIL", f"{cs_id}: definitely pre-auth network reachability")
            if classification == "unresolved-opaque" and status not in {"blocked", "deferred", "notApplicable"}:
                add("FAIL", f"{cs_id}: unresolved opaque startup edge must be blocked/deferred/notApplicable")

        if phase_kind in {"network-session", "network-final"} and contains_session_surface(matched):
            if not has_text(cs.get("sessionConfiguration")):
                add("FAIL", f"{cs_id}: URLSession/NSURLConnection call-site missing sessionConfiguration")
            if not has_text(cs.get("delegateHandling")):
                add("FAIL", f"{cs_id}: URLSession/NSURLConnection call-site missing delegateHandling")
            if not has_text(cs.get("requestInitiationPoint")):
                add("FAIL", f"{cs_id}: URLSession/NSURLConnection call-site missing requestInitiationPoint")

        if phase_kind in {"network-protocol-pinning", "network-final"}:
            if custom_proto in {"", "unknown", "unreviewed"}:
                add("FAIL", f"{cs_id}: customProtocolDecision must not be unknown")
            if pinning in {"", "unknown", "unreviewed"}:
                add("FAIL", f"{cs_id}: pinningTrustDecision must not be unknown")
            if ("conflict" in custom_proto or "conflict" in pinning) and status not in {"blocked", "deferred"}:
                add("FAIL", f"{cs_id}: protocol/pinning conflict requires blocked or deferred disposition")

        is_direct_socket = transport == "direct-socket" or contains_socket_surface(matched)
        if phase_kind in {"network-socket", "network-final"} and is_direct_socket:
            for field in ("socketHost", "socketPort", "socketTlsMode", "socketMigrationDecision"):
                if cs.get(field) in (None, ""):
                    add("FAIL", f"{cs_id}: direct socket call-site missing {field}")
            socket_decision = norm(cs.get("socketMigrationDecision"))
            if socket_decision in {"", "unknown", "unreviewed"}:
                add("FAIL", f"{cs_id}: socketMigrationDecision must not be unknown")
            if status not in {"migrated", "removed", "blocked"}:
                add("FAIL", f"{cs_id}: direct socket call-site must be migrated/removed/blocked (got {status})")

        if phase_kind in {"network-background", "network-final"} and ("background" in execution_mode or "background" in matched):
            if background_decision in {"", "unknown", "unreviewed"}:
                add("FAIL", f"{cs_id}: backgroundSessionDecision must not be unknown")
            if "g12" in background_decision and status not in {"blocked", "deferred"}:
                add("FAIL", f"{cs_id}: background session requiring G12 must be blocked/deferred")

    add("PASS", f"secureNetworking: validated {len(callsites)} call-site(s) for {phase_kind}")

def evaluate_webview():
    entry = domain_entry("webview")
    if entry is None:
        add("WARN", "webview domain missing from executionPlan")
        return
    if entry.get("applicability", "applicable") == "not-applicable":
        add("PASS", "webview marked not-applicable")
        return
    callsites = [cs for cs in (entry.get("callSites") or []) if isinstance(cs, dict)]
    if not callsites:
        add("FAIL", "webview applicable but has no call-sites")
        return

    for cs in callsites:
        cs_id = check_callsite_base(cs)
        if not cs_id:
            continue

        missing_contract = [k for k in WEBVIEW_CONTRACT_FIELDS if cs.get(k) in (None, "")]
        if missing_contract:
            add("FAIL", f"{cs_id}: missing webview contract fields: {', '.join(missing_contract)}")

        disp = validate_disposition(cs_id, "webview", "07")
        if disp is None:
            continue

        status = disp.get("status")
        lifecycle = norm(cs.get("lifecycleReachability"))
        support_state = norm(cs.get("webviewSupportState"))
        content_class = norm(cs.get("webContentClassification"))
        custom_scheme = norm(cs.get("customSchemeDecision"))
        process_pool = norm(cs.get("processPoolDecision"))
        data_store = norm(cs.get("dataStoreDecision"))
        unsupported = norm(cs.get("unsupportedFeatureDecision"))
        download_upload = norm(cs.get("downloadUploadDecision"))
        sensitivity = norm(cs.get("sensitivity"))

        if lifecycle == "pre-auth":
            add("FAIL", f"{cs_id}: WKWebView initialization marked pre-auth")

        finding = reach_by_callsite.get(cs_id, {})
        if phase_kind in {"webview-support", "webview-final"} and norm(finding.get("classification")) == "definitely-pre-auth":
            add("FAIL", f"{cs_id}: definitely pre-auth webview reachability")

        if phase_kind in {"webview-support", "webview-final"}:
            if support_state in {"", "missing", "unverified", "unknown"}:
                add("FAIL", f"{cs_id}: webviewSupportState must confirm GD support")

        if phase_kind in {"webview-content", "webview-final"}:
            if custom_scheme in {"", "unknown", "unreviewed"}:
                add("FAIL", f"{cs_id}: customSchemeDecision must not be unknown")
            if process_pool in {"", "unknown", "unreviewed"}:
                add("FAIL", f"{cs_id}: processPoolDecision must not be unknown")
            if data_store in {"", "unknown", "unreviewed"}:
                add("FAIL", f"{cs_id}: dataStoreDecision must not be unknown")
            if content_class in {"local-unmanaged", "local-file-unmanaged"} and sensitivity == "sensitive" and status not in {"blocked", "removed"}:
                add("FAIL", f"{cs_id}: sensitive unmanaged local file webview content must be blocked/removed")
            if "unmanaged" in download_upload and status not in {"blocked", "deferred"}:
                add("FAIL", f"{cs_id}: unmanaged download/upload path requires blocked/deferred disposition")

        if phase_kind in {"webview-unsupported", "webview-final"}:
            if unsupported in {"", "unknown", "unreviewed"}:
                add("FAIL", f"{cs_id}: unsupportedFeatureDecision must not be unknown")
            if ("active-unsupported" in unsupported or "unsupported-active" in unsupported) and status not in {"blocked", "removed"}:
                add("FAIL", f"{cs_id}: active unsupported WK feature must be blocked or removed")

    add("PASS", f"webview: validated {len(callsites)} call-site(s) for {phase_kind}")

if phase_kind in NETWORK_PHASES:
    evaluate_network()
    if phase_kind in {"network-request-timing", "network-final"}:
        stale_reachability_check()
elif phase_kind in WEBVIEW_PHASES:
    evaluate_webview()
    if phase_kind in {"webview-support", "webview-final"}:
        stale_reachability_check()
else:
    add("FAIL", f"Unknown network/web validation phase kind: {phase_kind!r}")

for msg in PASS:
    print(f"PASS:{msg}")
for msg in WARN:
    print(f"WARN:{msg}")
for msg in FAIL:
    print(f"FAIL:{msg}")

sys.exit(1 if FAIL else 0)
PYEOF
)
        rc=$?
        set -e
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            case "$line" in
                PASS:*) pass "${line#PASS:}" ;;
                WARN:*) warn "${line#WARN:}" ;;
                FAIL:*) fail "${line#FAIL:}" ;;
                *) warn "$line" ;;
            esac
        done <<< "$output"
        if [[ $rc -ne 0 ]]; then
            fail "$phase_name checks failed"
        fi
    }

    run_dlp_icc_policy_contract_check() {
        local phase_kind="$1"
        local phase_name="$2"
        local output rc
        set +e
        output=$(PHASE_KIND="$phase_kind" python3 - <<PYEOF
import json
import os
import re
import sys
from pathlib import Path

analysis_path = Path("$ANALYSIS_FILE")
plan_path = Path("$PLAN_STATE_FILE")
phase_kind = os.environ.get("PHASE_KIND", "").strip()

ALLOWED = {"migrated", "removed", "blocked", "deferred", "notApplicable"}
DIRECTIONS = {
    "unmanaged-to-managed",
    "managed-to-unmanaged",
    "managed-to-managed",
    "metadata-only",
    "unknown-or-bidirectional",
}
SURFACE_HINTS = {
    "share-sheet",
    "document-picker",
    "document-interaction",
    "files",
    "icloud",
    "cloudkit",
    "photos",
    "airdrop",
    "drag-drop",
    "quick-look",
    "file-provider",
    "custom-url",
    "universal-link",
    "pasteboard",
    "third-party-sdk",
    "webview-transfer",
}
POLICY_APIS = {
    "getapplicationconfig",
    "getapplicationpolicy",
    "getapplicationpolicystring",
    "gdappeventpolicyupdate",
    "gdpolicyupdatenotification",
    "none",
}

PASS, WARN, FAIL = [], [], []

def add(kind, message):
    if kind == "PASS":
        PASS.append(message)
    elif kind == "WARN":
        WARN.append(message)
    else:
        FAIL.append(message)

def has_text(value):
    return isinstance(value, str) and bool(value.strip())

def norm(value):
    if isinstance(value, str):
        return value.strip().lower()
    return ""

def load_json(path, label):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        add("FAIL", f"{label} invalid: {exc}")
        return None

analysis = load_json(analysis_path, "migration-analysis.json")
if analysis is None:
    for msg in PASS:
        print(f"PASS:{msg}")
    for msg in WARN:
        print(f"WARN:{msg}")
    for msg in FAIL:
        print(f"FAIL:{msg}")
    sys.exit(1)

plan = {"dispositions": []}
if plan_path.exists():
    loaded = load_json(plan_path, "migration-plan-state.json")
    if loaded is not None:
        plan = loaded

run_id = str(analysis.get("runId", "")).strip()
dispositions = {}
for row in (plan.get("dispositions") or []):
    if not isinstance(row, dict):
        continue
    if run_id and row.get("runId") != run_id:
        continue
    cs_id = row.get("callSiteId")
    if not has_text(cs_id):
        continue
    if cs_id in dispositions:
        add("FAIL", f"duplicate active disposition for call-site '{cs_id}'")
        continue
    dispositions[cs_id] = row

execution_plan = analysis.get("executionPlan")
if not isinstance(execution_plan, list):
    add("FAIL", "executionPlan must be an array")
    execution_plan = []

def domain_entry(domain_id):
    for entry in execution_plan:
        if isinstance(entry, dict) and entry.get("domainId") == domain_id:
            return entry
    return None

def check_base(callsite, domain_id):
    cs_id = callsite.get("id")
    if not has_text(cs_id):
        add("FAIL", f"{domain_id}: call-site missing id")
        return None
    required = ["id", "targetId", "relativePath", "symbol", "matchedApi", "line", "lifecycleReachability", "sensitivity", "confidence"]
    missing = [k for k in required if callsite.get(k) in (None, "")]
    if missing:
        add("FAIL", f"{cs_id}: missing required analysis fields: {', '.join(missing)}")
    return cs_id

def validate_disposition(cs_id, expected_domain, expected_prompt):
    row = dispositions.get(cs_id)
    if row is None:
        add("FAIL", f"{expected_domain}: missing disposition for call-site '{cs_id}'")
        return None
    if row.get("domainId") != expected_domain:
        add("FAIL", f"{cs_id}: disposition domain mismatch ({row.get('domainId')!r})")
    if row.get("promptId") != expected_prompt:
        add("FAIL", f"{cs_id}: disposition prompt mismatch (expected {expected_prompt}, got {row.get('promptId')!r})")
    status = row.get("status")
    if status not in ALLOWED:
        add("FAIL", f"{cs_id}: invalid disposition status {status!r}")
        return None
    if status in {"blocked", "deferred", "notApplicable"} and not has_text(row.get("rationale")):
        add("FAIL", f"{cs_id}: status '{status}' requires rationale")
    return row

def applicable_calls(domain_id):
    entry = domain_entry(domain_id)
    if entry is None:
        add("WARN", f"{domain_id}: domain missing from executionPlan")
        return []
    if not isinstance(entry, dict):
        add("FAIL", f"{domain_id}: invalid executionPlan entry")
        return []
    if entry.get("applicability", "applicable") == "not-applicable":
        add("PASS", f"{domain_id}: marked not-applicable")
        return []
    calls = [cs for cs in (entry.get("callSites") or []) if isinstance(cs, dict)]
    if not calls:
        add("WARN", f"{domain_id}: applicable but no call-sites listed")
    return calls

def check_external_inventory():
    callsites = applicable_calls("dlpPasteboard")
    checked = 0
    for cs in callsites:
        cs_id = check_base(cs, "dlpPasteboard")
        if not cs_id:
            continue
        checked += 1
        disp = validate_disposition(cs_id, "dlpPasteboard", "09")
        direction = norm(cs.get("movementDirection"))
        surface = norm(cs.get("surface"))
        payload = norm(cs.get("payloadKind"))
        treatment = norm(cs.get("selectedTreatment") or cs.get("proposedTreatment"))

        if direction not in DIRECTIONS:
            add("FAIL", f"{cs_id}: movementDirection must be one of {sorted(DIRECTIONS)}")
        if not has_text(surface):
            add("FAIL", f"{cs_id}: missing surface classification")
        elif not any(hint in surface for hint in SURFACE_HINTS):
            add("WARN", f"{cs_id}: surface '{surface}' is non-canonical")
        if payload in {"", "unknown"}:
            add("FAIL", f"{cs_id}: payloadKind must be classified")
        if treatment in {"", "unknown"}:
            add("FAIL", f"{cs_id}: selectedTreatment/proposedTreatment missing")
        if direction == "unknown-or-bidirectional" and disp is not None and disp.get("status") == "migrated":
            add("FAIL", f"{cs_id}: unknown/bidirectional movement cannot be marked migrated")
    if checked:
        add("PASS", f"dlpPasteboard: validated {checked} call-site(s) for inventory/direction")

def check_inbound_secure_copy():
    callsites = applicable_calls("dlpPasteboard")
    checked = 0
    for cs in callsites:
        direction = norm(cs.get("movementDirection"))
        if direction != "unmanaged-to-managed":
            continue
        cs_id = check_base(cs, "dlpPasteboard")
        if not cs_id:
            continue
        checked += 1
        disp = validate_disposition(cs_id, "dlpPasteboard", "09")
        copy_status = norm(cs.get("inboundSecureCopyStatus"))
        staging = norm(cs.get("plaintextStagingStatus"))
        sensitivity = norm(cs.get("sensitivity"))

        if staging == "present":
            add("FAIL", f"{cs_id}: unmanaged plaintext staging detected")
        if sensitivity in {"sensitive", "semi-sensitive"} and disp is not None and disp.get("status") == "migrated":
            if copy_status not in {"copied-to-secure-storage", "not-required", "metadata-only"}:
                add("FAIL", f"{cs_id}: inbound secure-copy status missing or unresolved")
    if checked:
        add("PASS", f"dlpPasteboard: validated {checked} inbound call-site(s)")

def check_outbound_egress():
    callsites = applicable_calls("dlpPasteboard")
    checked = 0
    for cs in callsites:
        direction = norm(cs.get("movementDirection"))
        if direction != "managed-to-unmanaged":
            continue
        cs_id = check_base(cs, "dlpPasteboard")
        if not cs_id:
            continue
        checked += 1
        disp = validate_disposition(cs_id, "dlpPasteboard", "09")
        if disp is None:
            continue
        status = disp.get("status")
        sensitivity = norm(cs.get("sensitivity"))
        approval = norm(cs.get("outboundApprovalStatus"))
        staging = norm(cs.get("plaintextStagingStatus"))
        treatment = norm(cs.get("selectedTreatment") or cs.get("proposedTreatment"))

        if staging == "present":
            add("FAIL", f"{cs_id}: unmanaged plaintext staging detected")
        if sensitivity in {"sensitive", "semi-sensitive"}:
            if status == "migrated":
                if approval not in {"approved-managed-destination", "migrated-appkinetics", "approved-exception"}:
                    add("FAIL", f"{cs_id}: migrated sensitive outbound flow missing managed approval evidence")
            elif status not in {"blocked", "removed", "notApplicable"} and approval in {"", "unknown", "pending"}:
                add("FAIL", f"{cs_id}: active unapproved protected export path")
        if "share-sheet" in norm(cs.get("surface")) and sensitivity == "sensitive" and status == "migrated":
            if treatment not in {"migrated-appkinetics", "managed-approved"}:
                add("FAIL", f"{cs_id}: sensitive share-sheet path cannot remain unmanaged")
    if checked:
        add("PASS", f"dlpPasteboard: validated {checked} outbound call-site(s)")

def check_icc_source():
    callsites = applicable_calls("icc")
    checked = 0
    for cs in callsites:
        cs_id = check_base(cs, "icc")
        if not cs_id:
            continue
        checked += 1
        disp = validate_disposition(cs_id, "icc", "08")
        role = norm(cs.get("iccRole"))
        service_id = norm(cs.get("serviceId"))
        service_version = norm(cs.get("serviceVersion"))
        service_method = norm(cs.get("serviceMethod"))
        transfer = norm(cs.get("transferFileBehavior"))
        residual = norm(cs.get("residualSharePathStatus"))

        if role in {"", "none", "unknown"}:
            add("FAIL", f"{cs_id}: iccRole must be provider/consumer/both when ICC is applicable")
        if role in {"provider", "consumer", "both"}:
            if service_id in {"", "unknown", "generic", "com.example.service"}:
                add("FAIL", f"{cs_id}: serviceId must be a verified contract identifier")
            if service_version in {"", "unknown"}:
                add("FAIL", f"{cs_id}: serviceVersion must be specified")
            if service_method in {"", "unknown"}:
                add("FAIL", f"{cs_id}: serviceMethod must be specified")
        if transfer in {"unmanaged-staging", "unmanaged-staging-present"}:
            add("FAIL", f"{cs_id}: unmanaged plaintext staging in transfer behavior")
        if residual == "active-unmanaged" and disp is not None and disp.get("status") not in {"blocked", "removed"}:
            add("FAIL", f"{cs_id}: residual unmanaged ICC/share path remains active")
    if checked:
        add("PASS", f"icc: validated {checked} call-site(s) for service closure")

def check_icc_registration():
    callsites = applicable_calls("icc")
    checked = 0
    for cs in callsites:
        cs_id = check_base(cs, "icc")
        if not cs_id:
            continue
        checked += 1
        disp = validate_disposition(cs_id, "icc", "08")
        registration = norm(cs.get("serviceRegistrationStatus"))
        role = norm(cs.get("iccRole"))
        if disp is None:
            continue
        if disp.get("status") == "migrated" and role in {"provider", "both"}:
            if registration not in {"verified", "not-required"}:
                add("FAIL", f"{cs_id}: provider ICC path missing verified plist registration status")
    if checked:
        add("PASS", f"icc: validated {checked} call-site(s) for registration closure")

def check_residual_share_paths():
    checked = 0
    for domain_id, prompt_id in (("dlpPasteboard", "09"), ("icc", "08")):
        for cs in applicable_calls(domain_id):
            cs_id = check_base(cs, domain_id)
            if not cs_id:
                continue
            checked += 1
            disp = validate_disposition(cs_id, domain_id, prompt_id)
            if disp is None:
                continue
            sensitivity = norm(cs.get("sensitivity"))
            surface = norm(cs.get("surface"))
            residual = norm(cs.get("residualSharePathStatus"))
            status = disp.get("status")
            if any(token in surface for token in ("custom-url", "universal-link", "share-sheet", "document-interaction")):
                if sensitivity in {"sensitive", "semi-sensitive"} and residual in {"", "unknown", "active-unmanaged"} and status not in {"blocked", "removed"}:
                    add("FAIL", f"{cs_id}: residual unmanaged URL/share payload path not closed")
    if checked:
        add("PASS", f"validated {checked} call-site(s) for residual URL/share closure")

def check_policy_timing():
    callsites = applicable_calls("policyManagement")
    checked = 0
    for cs in callsites:
        cs_id = check_base(cs, "policyManagement")
        if not cs_id:
            continue
        checked += 1
        disp = validate_disposition(cs_id, "policyManagement", "09b")
        if disp is None:
            continue
        api = norm(cs.get("policyApi"))
        timing = norm(cs.get("policyReadTiming"))
        lifecycle = norm(cs.get("lifecycleReachability"))
        matched = norm(cs.get("matchedApi"))
        status = disp.get("status")
        if api not in POLICY_APIS:
            add("FAIL", f"{cs_id}: unknown policy API classification '{api}'")
        if ("getapplicationpolicy" in api or "getapplicationconfig" in api or "getapplicationpolicystring" in api or "getapplicationpolicy" in matched) and status not in {"blocked", "removed"}:
            if timing == "pre-auth" or lifecycle == "pre-auth":
                add("FAIL", f"{cs_id}: pre-auth policy read detected")
    if checked:
        add("PASS", f"policyManagement: validated {checked} call-site(s) for timing closure")

def check_policy_cache_update():
    callsites = applicable_calls("policyManagement")
    checked = 0
    for cs in callsites:
        cs_id = check_base(cs, "policyManagement")
        if not cs_id:
            continue
        checked += 1
        disp = validate_disposition(cs_id, "policyManagement", "09b")
        if disp is None:
            continue
        status = disp.get("status")
        update = norm(cs.get("policyUpdateHandling"))
        cache = norm(cs.get("policyCacheLocation"))
        default_strategy = norm(cs.get("policyDefaultStrategy"))
        if status == "migrated":
            if update in {"", "unknown", "ignored"}:
                add("FAIL", f"{cs_id}: policy update handling missing or ignored")
            if cache in {"userdefaults", "file", "unmanaged-userdefaults", "unmanaged-file"}:
                add("FAIL", f"{cs_id}: unmanaged policy cache remains active")
            if default_strategy in {"", "unknown"}:
                add("FAIL", f"{cs_id}: default policy handling must be explicit")
    if checked:
        add("PASS", f"policyManagement: validated {checked} call-site(s) for cache/update closure")

def check_final():
    checked = 0
    for domain_id, prompt_id in (("dlpPasteboard", "09"), ("icc", "08"), ("policyManagement", "09b")):
        for cs in applicable_calls(domain_id):
            cs_id = check_base(cs, domain_id)
            if not cs_id:
                continue
            checked += 1
            disp = validate_disposition(cs_id, domain_id, prompt_id)
            if disp is None:
                continue
            status = disp.get("status")
            if status in {"blocked", "deferred"}:
                add("FAIL", f"{cs_id}: final closure does not allow blocked/deferred disposition")
    if checked:
        add("PASS", f"final tranche-5 closure validated for {checked} call-site(s)")

if phase_kind == "external-inventory":
    check_external_inventory()
elif phase_kind == "inbound-secure-copy":
    check_inbound_secure_copy()
elif phase_kind == "outbound-egress":
    check_outbound_egress()
elif phase_kind == "icc-source":
    check_icc_source()
elif phase_kind == "icc-registration":
    check_icc_registration()
elif phase_kind == "residual-share":
    check_residual_share_paths()
elif phase_kind == "policy-timing":
    check_policy_timing()
elif phase_kind == "policy-cache-update":
    check_policy_cache_update()
elif phase_kind == "final":
    check_external_inventory()
    check_inbound_secure_copy()
    check_outbound_egress()
    check_icc_source()
    check_icc_registration()
    check_residual_share_paths()
    check_policy_timing()
    check_policy_cache_update()
    check_final()
else:
    add("FAIL", f"Unknown DLP/ICC/policy validation phase kind: {phase_kind!r}")

for msg in PASS:
    print(f"PASS:{msg}")
for msg in WARN:
    print(f"WARN:{msg}")
for msg in FAIL:
    print(f"FAIL:{msg}")

sys.exit(1 if FAIL else 0)
PYEOF
)
        rc=$?
        set -e
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            case "$line" in
                PASS:*) pass "${line#PASS:}" ;;
                WARN:*) warn "${line#WARN:}" ;;
                FAIL:*) fail "${line#FAIL:}" ;;
                *) warn "$line" ;;
            esac
        done <<< "$output"
        if [[ $rc -ne 0 ]]; then
            fail "$phase_name checks failed"
        fi
    }

    run_auth_reachability_analysis() {
        local analyzer="$TOOL_DIR/tooling/lib/analyze-auth-reachability.py"
        if [[ ! -f "$analyzer" ]]; then
            fail "Authorization reachability analyzer missing: tooling/lib/analyze-auth-reachability.py"
            return 1
        fi
        local out rc
        set +e
        out=$(python3 "$analyzer" \
            --bootstrap "$BOOTSTRAP_FILE" \
            --target-map "$TARGET_MAP_FILE" \
            --analysis "$ANALYSIS_FILE" \
            --output "$AUTH_REACHABILITY_FILE" \
            --project-root "$PROJECT_ROOT" 2>&1)
        rc=$?
        set -e
        if [[ $rc -ne 0 ]]; then
            fail "Authorization reachability analysis failed"
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                warn "reachability: $line"
            done <<< "$out"
            return 1
        fi
        pass "${out#OK: }"
        fingerprint_file "$AUTH_REACHABILITY_FILE" "auth-reachability.json"
        return 0
    }

    validate_check_event_receiver_disabled() {
        local output rc
        if [[ -z "$INFO_PLIST" ]]; then
            fail "Prompt 03: Notification-based authorization requires Info.plist BlackBerryDynamics.CheckEventReceiver=false, but Info.plist was not found"
            return 0
        fi
        set +e
        output=$(python3 - "$INFO_PLIST" <<'PYEOF'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    with path.open("rb") as fh:
        plist = plistlib.load(fh)
except Exception as exc:
    print(f"FAIL:Prompt 03: cannot parse Info.plist while checking BlackBerryDynamics.CheckEventReceiver: {exc}")
    sys.exit(1)

dynamics = plist.get("BlackBerryDynamics")
if not isinstance(dynamics, dict):
    print("FAIL:Prompt 03: Notification-based authorization requires top-level Info.plist BlackBerryDynamics.CheckEventReceiver=false")
    sys.exit(1)

value = dynamics.get("CheckEventReceiver")
if value is False:
    print("PASS:BlackBerryDynamics.CheckEventReceiver=false configured for notification-based authorization")
    sys.exit(0)

print("FAIL:Prompt 03: Notification-based authorization requires BlackBerryDynamics.CheckEventReceiver=false")
sys.exit(1)
PYEOF
)
        rc=$?
        set -e
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            case "$line" in
                PASS:*) pass "${line#PASS:}" ;;
                FAIL:*) fail "${line#FAIL:}" ;;
                *) warn "$line" ;;
            esac
        done <<< "$output"
        if [[ $rc -ne 0 ]]; then
            fail "Notification authorization Info.plist receiver-check validation failed"
        fi
        return 0
    }

    if should_run_phase "4-authorization-integration"; then
        record_phase "4-authorization-integration"
        echo -e "${BOLD}Phase 4a: Authorization Integration${NC}"
        app_grep "GDiOS\|GDiOSDelegate\|\.authorize\(|authorizeAutonomously\(" --include="*.swift" --include="*.m" --include="*.h" && pass "GDiOS authorization setup found" || fail "GDiOS authorization setup not found"
        local has_delegate_auth=false
        local has_notification_auth=false
        if app_grep "GDiOSDelegate\|handleEvent\|handle\\(_ anEvent: GDAppEvent\\)" --include="*.swift" --include="*.m" --include="*.h"; then
            has_delegate_auth=true
            pass "Delegate-based authorization handling found"
        fi
        if app_grep "GDStateChangeNotification\|GDStateChangeKeyCopy\|\\.GDStateChange\|state\\.isAuthorized" --include="*.swift" --include="*.m" --include="*.h"; then
            has_notification_auth=true
            pass "Notification-based authorization handling found"
        fi
        if [[ "$has_delegate_auth" != true && "$has_notification_auth" != true ]]; then
            fail "No valid authorization event handling pattern found (delegate or GDStateChange)"
        fi
        if [[ "$has_notification_auth" == true && "$has_delegate_auth" != true ]]; then
            validate_check_event_receiver_disabled
        fi
        app_grep "GDAppEventAuthorized\|case \\.authorized\|state\\.isAuthorized" --include="*.swift" --include="*.m" --include="*.h" && pass "Authorized-state handling found" || fail "Authorized-state handling not found"
        echo ""
    fi

    if should_run_phase "4-lifecycle-window-root-ui"; then
        record_phase "4-lifecycle-window-root-ui"
        echo -e "${BOLD}Phase 4b: Lifecycle / Window / Root UI${NC}"
        local lc_output lc_rc
        set +e
        lc_output=$(python3 - <<PYEOF
import json, sys
from pathlib import Path

analysis_path = Path("$ANALYSIS_FILE")
errors = []

try:
    analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"FAIL:migration-analysis.json invalid: {exc}")
    sys.exit(1)

lifecycle = analysis.get("lifecycleModel")
if not isinstance(lifecycle, dict):
    errors.append("lifecycleModel missing from migration-analysis.json")
else:
    pattern = lifecycle.get("primaryPattern")
    if not isinstance(pattern, str) or not pattern:
        errors.append("lifecycleModel.primaryPattern missing")
    roots = lifecycle.get("roots")
    if roots is None:
        errors.append("lifecycleModel.roots missing; prompt 00 must inventory lifecycle roots")
    elif not isinstance(roots, list):
        errors.append("lifecycleModel.roots must be an array")
    risks = lifecycle.get("preAuthRisks")
    if risks is not None and not isinstance(risks, list):
        errors.append("lifecycleModel.preAuthRisks must be an array when present")

if errors:
    for e in errors:
        print(f"FAIL:{e}")
    sys.exit(1)

print("PASS:lifecycleModel contract present")
PYEOF
)
        lc_rc=$?
        set -e
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            case "$line" in
                PASS:*) pass "${line#PASS:}" ;;
                FAIL:*) fail "${line#FAIL:}" ;;
                *) warn "$line" ;;
            esac
        done <<< "$lc_output"
        [[ $lc_rc -ne 0 ]] && fail "Lifecycle model contract checks failed"

        # Flutter hybrid advisory — out of scope for this toolkit release.
        # Only probe inside PROJECT_ROOT (not parent dirs) to avoid monorepo FPs.
        local flutter_detected=false
        if [[ -f "$PROJECT_ROOT/pubspec.yaml" ]]; then
            flutter_detected=true
        elif app_grep "FlutterEngine\|FlutterViewController\|GeneratedPluginRegistrant\|import Flutter" --include="*.swift" --include="*.m" --include="*.h" --include="*.mm"; then
            flutter_detected=true
        elif [[ -d "$PROJECT_ROOT/Flutter" ]]; then
            flutter_detected=true
        fi
        if [[ "$flutter_detected" == true ]]; then
            warn "Flutter hybrid signals detected — this toolkit release does not migrate Flutter apps (no official Dynamics Flutter SDK); expect Tier C / no-go and do not invent FlutterEngine Dynamics wiring"
            if [[ -f "$ANALYSIS_FILE" ]]; then
                if ! python3 - "$ANALYSIS_FILE" <<'PY' 2>/dev/null
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
try:
    data = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    sys.exit(1)
blob = json.dumps(data).lower()
if "flutter" in blob:
    sys.exit(0)
sys.exit(1)
PY
                then
                    warn "Flutter signals present in project but migration-analysis.json does not mention Flutter — re-run Prompt 00 to record unsupportedDetections"
                fi
            fi
        fi

        # Share Extension / app-extension Dynamics-unsupported callout
        local share_ext_output
        share_ext_output=$(python3 - "$PROJECT_ROOT" "$TARGET_MAP_FILE" "$ANALYSIS_FILE" <<'PY' 2>/dev/null
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
target_map_path = Path(sys.argv[2])
analysis_path = Path(sys.argv[3])

share_targets = []
extension_targets = []

def is_share_target(t):
    point = (t.get("extensionPointIdentifier") or "").strip()
    reason = (t.get("unsupportedReason") or "").lower()
    name = re.sub(r"[^a-z0-9]", "", (t.get("name") or "").lower())
    if point == "com.apple.share-services":
        return True
    if "share extension" in reason or "share extensions" in reason:
        return True
    if "shareextension" in name or name.endswith("share"):
        return True
    return False

if target_map_path.is_file():
    try:
        tm = json.loads(target_map_path.read_text(encoding="utf-8"))
    except Exception:
        tm = {}
    for t in tm.get("targets") or []:
        if not isinstance(t, dict):
            continue
        ttype = t.get("type")
        if ttype in {"extension", "widget", "appclip"}:
            extension_targets.append(t)
        if ttype == "extension" and is_share_target(t):
            share_targets.append(t)

# Plist fallback when target-map missing or incomplete
plist_share = False
for plist in root.rglob("Info.plist"):
    rel = str(plist.relative_to(root))
    if any(p in rel for p in ("Pods/", ".build/", "DerivedData/", "Carthage/")):
        continue
    try:
        text = plist.read_text(encoding="utf-8", errors="replace")
    except OSError:
        continue
    if "com.apple.share-services" in text:
        plist_share = True
        break

if not share_targets and not plist_share and not extension_targets:
    print("OK:no-share-or-extension-targets")
    sys.exit(0)

if share_targets or plist_share:
    names = ", ".join(sorted({t.get("name") or "?" for t in share_targets})) or "(plist evidence)"
    print(f"WARN:Share Extension detected ({names}) — Dynamics does not support Share Extensions; isolate/non-shipping and do not authorize inside the extension (steering/17-app-extensions-and-share-extensions.md)")

# Fail if Dynamics linked/imported under Share Extension source roots
dynamics_pat = re.compile(
    r"BlackBerryDynamics|GDiOS\.authorize|import\s+BlackBerryDynamics|@import\s+BlackBerryDynamics",
    re.IGNORECASE,
)
for t in share_targets:
    roots = t.get("sourceRoots") or []
    for sr in roots:
        if not isinstance(sr, str) or not sr:
            continue
        base = (root / sr).resolve()
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if path.suffix.lower() not in {".swift", ".m", ".mm", ".h", ".hpp"}:
                continue
            try:
                blob = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if dynamics_pat.search(blob):
                rel = path.relative_to(root)
                print(
                    f"FAIL:Dynamics API usage in Share Extension source {rel} "
                    f"(target {t.get('name')}) — remove Dynamics from the extension"
                )

# App target still depends on Share Extension → still embedded signal
app_names = []
share_names = {t.get("name") for t in share_targets if t.get("name")}
if target_map_path.is_file():
    try:
        tm = json.loads(target_map_path.read_text(encoding="utf-8"))
    except Exception:
        tm = {}
    for t in tm.get("targets") or []:
        if t.get("type") != "application":
            continue
        deps = set(t.get("dependencies") or [])
        hit = sorted(deps & share_names)
        if hit:
            app_names.append(f"{t.get('name')}: {', '.join(hit)}")
if app_names:
    print(
        "WARN:Application target still depends on Share Extension target(s) "
        f"({'; '.join(app_names)}) — exclude from Dynamics scheme/Archive/Embed for Dynamics shipping"
    )

if analysis_path.is_file() and (share_targets or plist_share):
    try:
        analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
        blob = json.dumps(analysis).lower()
    except Exception:
        blob = ""
    if "share" not in blob and "share-extension" not in blob and "share extension" not in blob:
        print("WARN:Share Extension signals present but migration-analysis.json does not mention Share — re-run Prompt 00")

if extension_targets and not share_targets and not plist_share:
    names = ", ".join(sorted({t.get("name") or "?" for t in extension_targets}))
    print(f"WARN:App Extension/widget targets detected ({names}) — cannot access Dynamics secure container; isolate per steering/17-app-extensions-and-share-extensions.md")
PY
) || share_ext_output="WARN:Share Extension detection helper failed"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            case "$line" in
                OK:*) pass "${line#OK:}" ;;
                WARN:*) warn "${line#WARN:}" ;;
                FAIL:*) fail "${line#FAIL:}" ;;
                *) warn "$line" ;;
            esac
        done <<< "$share_ext_output"

        local has_main_storyboard=false
        if [[ -n "$INFO_PLIST" ]]; then
            if plutil -extract UIMainStoryboardFile raw -o - "$INFO_PLIST" >/dev/null 2>&1; then
                has_main_storyboard=true
            elif /usr/libexec/PlistBuddy -c "Print :UIMainStoryboardFile" "$INFO_PLIST" >/dev/null 2>&1; then
                has_main_storyboard=true
            fi
        fi
        if [[ "$has_main_storyboard" == true ]]; then
            if app_grep "onAuthorized\|GDStateChange\|GDAppEventAuthorized\|state\\.isAuthorized" --include="*.swift" --include="*.m" --include="*.h"; then
                warn "UIMainStoryboardFile present; verify storyboard startup is deferred until authorization"
            else
                fail "UIMainStoryboardFile present without explicit post-authorization startup handling"
            fi
        fi

        if app_grep "@main[[:space:]]+struct[[:space:]].*:[[:space:]]*App" --include="*.swift"; then
            app_grep "UIApplicationDelegateAdaptor\|GDStateChange\|GDiOSDelegate" --include="*.swift" && pass "SwiftUI authorization bridge found" || fail "SwiftUI App detected without UIApplicationDelegateAdaptor or GDStateChange bridge"
            if app_grep "static[[:space:]]+var[[:space:]]+isAuthorized" --include="*.swift" && app_grep "if[[:space:]]+[A-Za-z_][A-Za-z0-9_\\.]*\\.isAuthorized" --include="*.swift"; then
                fail "SwiftUI static isAuthorized body-gating pattern detected (can freeze on placeholder UI)"
            fi
        fi

        if app_grep "UISceneDelegate\|UIWindowSceneDelegate" --include="*.swift" --include="*.m" --include="*.h"; then
            if app_grep "openURLContexts\|continue userActivity\|willConnectTo" --include="*.swift" --include="*.m"; then
                app_grep "state\\.isAuthorized\|GDStateChange\|GDAppEventAuthorized\|onAuthorized" --include="*.swift" --include="*.m" && pass "Scene lifecycle callbacks show authorization-aware handling" || fail "Scene lifecycle callbacks found without Dynamics authorization-aware handling (GDStateChange / GDAppEventAuthorized / state.isAuthorized)"
            fi
        fi

        if app_grep "UIWindow\\(frame:[[:space:]]*UIScreen\\.main\\.bounds\\)\|UIWindow\\(windowScene:" --include="*.swift" --include="*.m"; then
            fail "Manual UIWindow construction detected; SDK-managed window must be reused instead"
        fi

        if [[ -n "$XCODEPROJ" ]] && grep -q "SWIFT_VERSION = 6.0" "$XCODEPROJ/project.pbxproj" 2>/dev/null; then
            if app_grep "@preconcurrency[[:space:]]+.*GDiOSDelegate" --include="*.swift"; then
                fail "Swift 6 strict concurrency: @preconcurrency on GDiOSDelegate detected (unsupported workaround)"
            fi
            if app_grep "GDiOSDelegate" --include="*.swift"; then
                app_grep "nonisolated[[:space:]]+func[[:space:]]+handle\\(" --include="*.swift" \
                    && app_grep "Task[[:space:]]*\\{[[:space:]]*@MainActor[[:space:]]+in" --include="*.swift" \
                    && pass "Swift 6 strict-concurrency bridge (nonisolated + MainActor trampoline) detected" \
                    || fail "Swift 6 strict concurrency: missing nonisolated handle(_:) + Task { @MainActor in ... } bridge"
            fi
        fi
        echo ""
    fi

    if should_run_phase "4-preauth-reachability"; then
        record_phase "4-preauth-reachability"
        echo -e "${BOLD}Phase 4c: Pre-Authorization Reachability${NC}"
        if run_auth_reachability_analysis; then
            local reach_output reach_rc
            set +e
            reach_output=$(python3 - <<PYEOF
import json, sys
from pathlib import Path

path = Path("$AUTH_REACHABILITY_FILE")
if not path.exists():
    print("FAIL:auth-reachability.json missing")
    sys.exit(1)

data = json.loads(path.read_text(encoding="utf-8"))
summary = data.get("summary") or {}
pre = int(summary.get("definitelyPreAuthCount", 0))
unresolved = int(summary.get("unresolvedOpaqueCount", 0))
gated = int(summary.get("conditionallyGatedCount", 0))
structural = int(summary.get("structuralHazardCount", 0))
print(f"PASS:reachability findings analyzed (pre-auth={pre}, unresolved={unresolved}, gated={gated}, structural={structural})")
if pre > 0:
    print("FAIL:definite pre-auth sensitive reachability detected")
    for row in data.get("reachabilityFindings") or []:
        if not isinstance(row, dict) or row.get("classification") != "definitely-pre-auth":
            continue
        kind = ((row.get("evidence") or {}).get("hazardKind")) or "call-site"
        print(f"FAIL:pre-auth [{kind}] {row.get('callSiteId')}: {row.get('reason')}")
if unresolved > 0:
    print("WARN:opaque/unresolved sensitive startup edges detected; prompt 03b closure must resolve or block with evidence")
sys.exit(1 if pre > 0 else 0)
PYEOF
)
            reach_rc=$?
            set -e
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                case "$line" in
                    PASS:*) pass "${line#PASS:}" ;;
                    WARN:*) warn "${line#WARN:}" ;;
                    FAIL:*) fail "${line#FAIL:}" ;;
                    *) warn "$line" ;;
                esac
            done <<< "$reach_output"
            [[ $reach_rc -ne 0 ]] && fail "Pre-authorization reachability checks failed"
        fi
        echo ""
    fi

    if should_run_phase "4-residual-authorization-closure"; then
        record_phase "4-residual-authorization-closure"
        echo -e "${BOLD}Phase 4d: Residual Authorization Closure${NC}"
        local current_source_fp
        current_source_fp=$(get_fingerprint "source-tree")
        local closure_output closure_rc
        set +e
        closure_output=$(CURRENT_SOURCE_FP="$current_source_fp" python3 - <<PYEOF
import json
import os
import sys
from pathlib import Path

analysis = json.loads(Path("$ANALYSIS_FILE").read_text(encoding="utf-8"))
plan = json.loads(Path("$PLAN_STATE_FILE").read_text(encoding="utf-8")) if Path("$PLAN_STATE_FILE").exists() else {"dispositions": []}
reach_path = Path("$AUTH_REACHABILITY_FILE")

if not reach_path.exists():
    print("FAIL:auth-reachability.json missing; run phase 4c first")
    sys.exit(1)

reach = json.loads(reach_path.read_text(encoding="utf-8"))
run_id = str(analysis.get("runId", ""))
dispositions = {}
for row in plan.get("dispositions", []):
    if not isinstance(row, dict):
        continue
    if run_id and row.get("runId") != run_id:
        continue
    cs_id = row.get("callSiteId")
    if isinstance(cs_id, str) and cs_id:
        dispositions[cs_id] = row

analysis_callsites = set()
for domain in analysis.get("executionPlan", []):
    if not isinstance(domain, dict):
        continue
    if domain.get("domainId") != "authorization":
        continue
    if domain.get("applicability", "applicable") == "not-applicable":
        continue
    for cs in domain.get("callSites", []):
        if isinstance(cs, dict) and cs.get("id"):
            analysis_callsites.add(cs["id"])

errors = []
for cs_id in sorted(analysis_callsites):
    if cs_id not in dispositions:
        errors.append(f"missing call-site disposition for authorization domain: {cs_id}")

for finding in reach.get("reachabilityFindings", []):
    if not isinstance(finding, dict):
        continue
    cs_id = finding.get("callSiteId")
    if not isinstance(cs_id, str) or not cs_id:
        continue
    classification = finding.get("classification")
    row = dispositions.get(cs_id)
    status = (row or {}).get("status")
    prompt_id = (row or {}).get("promptId")
    rationale = (row or {}).get("rationale")

    if classification == "definitely-pre-auth":
        errors.append(f"definite pre-auth sensitive reachability remains: {cs_id}")
        continue

    if classification == "unresolved-opaque":
        if row is None:
            errors.append(f"opaque sensitive startup edge missing disposition: {cs_id}")
            continue
        if status not in {"blocked", "deferred", "notApplicable"}:
            errors.append(f"opaque sensitive startup edge must be blocked/deferred/notApplicable: {cs_id}={status!r}")
        if status in {"blocked", "deferred", "notApplicable"} and (not isinstance(rationale, str) or not rationale.strip()):
            errors.append(f"opaque sensitive startup edge requires rationale: {cs_id}")
        if prompt_id not in {"03", "03b"}:
            errors.append(f"wrong prompt ownership for authorization disposition: {cs_id} -> {prompt_id!r}")

reach_fp = str(reach.get("sourceFingerprint", ""))
current_fp = os.environ.get("CURRENT_SOURCE_FP", "")
if reach_fp and current_fp and reach_fp != current_fp:
    errors.append("authorization reachability evidence is stale relative to current source fingerprint")

if errors:
    for e in errors:
        print(f"FAIL:{e}")
    sys.exit(1)

print("PASS:authorization residual closure complete for current source fingerprint")
PYEOF
)
        closure_rc=$?
        set -e
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            case "$line" in
                PASS:*) pass "${line#PASS:}" ;;
                FAIL:*) fail "${line#FAIL:}" ;;
                *) warn "$line" ;;
            esac
        done <<< "$closure_output"
        [[ $closure_rc -ne 0 ]] && fail "Residual authorization closure checks failed"
        echo ""
    fi

    if should_run_phase "5-secure-file-writers"; then
        record_phase "5-secure-file-writers"
        echo -e "${BOLD}Phase 5: Secure File Writers${NC}"
        run_storage_contract_check "writers" "Secure file writer closure"
        if app_grep "(^|[^A-Za-z0-9_])FileManager\.default\|NSFileManager\|FileHandle\(forWriting\|FileHandle\(forUpdating\|NSFileHandle\|Data\.write\(to:\|String\.write\(to:\|OutputStream\(" --include="*.swift" --include="*.m" --include="*.h"; then
            if app_grep "GDFileManager\|GDFileHandle\|GDCWriteStream" --include="*.swift" --include="*.m" --include="*.h"; then
                pass "Secure writer APIs detected (GDFileManager/GDFileHandle/GDCWriteStream)"
            else
                fail "Unmanaged file writer APIs detected without secure writer replacements"
            fi
        else
            skip "No writer-side file APIs detected"
        fi
        if app_grep "GDFileManager\.default\.temporaryDirectory" --include="*.swift" --include="*.m" --include="*.h"; then
            fail "GDFileManager.default.temporaryDirectory usage detected (unsupported for migration output)"
        fi
        echo ""
    fi

    if should_run_phase "5b-secure-file-readers-follow-on"; then
        record_phase "5b-secure-file-readers-follow-on"
        echo -e "${BOLD}Phase 5b: Secure File Readers / Follow-On Consumers${NC}"
        run_storage_contract_check "readers" "Secure file reader/follow-on closure"
        if app_grep "Data\(contentsOf:\|String\(contentsOf:\|InputStream\(|FileHandle\(forReading\|URL\(fileURLWithPath:" --include="*.swift" --include="*.m" --include="*.h"; then
            if app_grep "GDFileManager\|GDFileHandle\|GDCReadStream" --include="*.swift" --include="*.m" --include="*.h"; then
                pass "Secure reader APIs detected for local-file consumers"
            else
                fail "Local reader/follow-on APIs detected without secure reader path"
            fi
        else
            skip "No reader-side follow-on file APIs detected"
        fi
        echo ""
    fi

    if should_run_phase "5c-preferences-keychain-crypto"; then
        record_phase "5c-preferences-keychain-crypto"
        echo -e "${BOLD}Phase 5c: UserDefaults / Keychain / Local Crypto${NC}"
        run_storage_contract_check "preferences" "Preferences/Keychain/Crypto closure"
        if app_grep "UserDefaults\|SecItemAdd\|SecItemCopyMatching\|KeychainAccess\|SwiftKeychainWrapper\|CryptoKit\|CommonCrypto\|SQLCipher\|sqlite3_key" --include="*.swift" --include="*.m" --include="*.mm" --include="*.h"; then
            pass "Detected preferences/keychain/crypto surfaces for policy validation"
        else
            skip "No preferences/keychain/crypto persistence APIs detected"
        fi
        if app_grep "UserDefaults\.standard\.set\(" --include="*.swift"; then
            # Prefer iOS application roots when target-map is available so Mac /
            # shared UI-preference noise does not force mechanical renames.
            local ud_warn=true
            if [[ -f "$TARGET_MAP_FILE" ]]; then
                if python3 - "$PROJECT_ROOT" "$TARGET_MAP_FILE" <<'PY' 2>/dev/null
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
tm = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
app_roots = []
for t in tm.get("targets") or []:
    if isinstance(t, dict) and t.get("type") == "application":
        for r in t.get("sourceRoots") or []:
            if isinstance(r, str) and r.strip():
                app_roots.append((root / r.strip()).resolve())
pattern = re.compile(r"UserDefaults\.standard\.set\(")
sensitive = re.compile(r"(token|password|secret|credential|auth|session|cookie|keychain|api[_-]?key)", re.I)
hits = 0
for base in app_roots or [root]:
    if not base.exists():
        continue
    for path in base.rglob("*.swift"):
        parts = set(path.parts)
        if parts & {"Pods", ".build", "DerivedData", "Tests", "dynamics-migration-tool"}:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for m in pattern.finditer(text):
            window = text[max(0, m.start() - 80): m.end() + 120]
            if sensitive.search(window):
                hits += 1
if hits:
    sys.exit(0)
sys.exit(1)
PY
                then
                    warn "Sensitive-looking UserDefaults.standard.set( usage in application sources; verify migration or explicit block"
                else
                    ud_warn=false
                    skip "UserDefaults.standard.set( present but no sensitive-key hits in application roots"
                fi
            fi
            if [[ "$ud_warn" == true && ! -f "$TARGET_MAP_FILE" ]]; then
                warn "UserDefaults writes detected; verify sensitive keys were migrated or explicitly blocked"
            fi
        fi
        echo ""
    fi

    if should_run_phase "6-secure-core-data-swiftdata"; then
        record_phase "6-secure-core-data-swiftdata"
        echo -e "${BOLD}Phase 6: Secure Core Data / SwiftData Closure${NC}"
        run_storage_contract_check "coredata" "Core Data/SwiftData closure"
        if app_grep "NSPersistentContainer\|NSPersistentStoreCoordinator\|NSManagedObjectContext" --include="*.swift" --include="*.m" --include="*.h"; then
            app_grep "GDPersistentStoreCoordinator\|GDEncryptedIncrementalStoreType\|GDEncryptedBinaryStoreType" --include="*.swift" --include="*.m" --include="*.h" && pass "GDPersistentStoreCoordinator + encrypted store types detected" || fail "Core Data detected but encrypted Dynamics store setup not found"
        else
            skip "No Core Data APIs detected"
        fi
        if app_grep "@Model\|ModelContainer\|ModelContext\|@Query\|#Predicate" --include="*.swift"; then
            fail "SwiftData usage detected — must be explicitly blocked/design-only until secure redesign is approved"
        fi
        if app_grep "addPersistentStore" --include="*.swift" --include="*.m" --include="*.h" && app_grep "at:[[:space:]]*nil" --include="*.swift" --include="*.m" --include="*.h"; then
            fail "Potential insecure Core Data store URL detected (addPersistentStore with nil URL)"
        fi
        echo ""
    fi

    if should_run_phase "7-secure-sql-wrappers"; then
        record_phase "7-secure-sql-wrappers"
        echo -e "${BOLD}Phase 7: Secure SQL / Wrapper Closure${NC}"
        run_storage_contract_check "sql" "SQL and wrapper closure"
        # Unmanaged opens / unsupported wrappers. FMDB/FMDatabase retained under a
        # Dynamics-linked module is allowed when check-sql-linkage.py passes —
        # do not treat bare FMDB identifiers as an automatic fail.
        if app_grep "sqlite3_open\(|sqlite3_open_v2\(|GRDB\|DatabaseQueue\|import SQLite\|SQLCipher\|sqlite3_key\|PRAGMA key" --include="*.swift" --include="*.m" --include="*.mm" --include="*.h" --include="*.c"; then
            fail "Unmanaged SQL API/wrapper usage still detected (sqlite3_open/GRDB/SQLite.swift/SQLCipher)"
        else
            pass "No unmanaged SQL open / unsupported wrapper paths detected"
        fi
        if app_grep "FMDatabase\|FMDatabaseQueue\|FMDB" --include="*.swift" --include="*.m" --include="*.mm" --include="*.h" --include="*.c"; then
            warn "FMDB surface still present — require Dynamics SQLite full linkage (see Phase 7 ABI check); open-only sqlite3enc bridges are insufficient"
        fi
        if app_grep "sqlite3enc_open\|sqlite3enc_open_v2\|sqlite3enc\.h" --include="*.swift" --include="*.m" --include="*.mm" --include="*.h" --include="*.c"; then
            pass "Encrypted sqlite3enc APIs detected"
        elif domain_is_applicable "secureSql"; then
            warn "No sqlite3enc usage detected in source tree"
        else
            skip "secureSql not-applicable — skipping sqlite3enc expectation"
        fi
        if app_grep "sqlite3enc_open\|sqlite3enc_open_v2" --include="*.swift" && ! app_grep "SWIFT_OBJC_BRIDGING_HEADER" --include="*.pbxproj"; then
            fail "Swift sqlite3enc usage detected without SWIFT_OBJC_BRIDGING_HEADER configuration"
        fi
        if app_grep "import GD_C\.SecureStore\.SQLite" --include="*.swift"; then
            warn "Swift direct import of GD_C.SecureStore.SQLite detected; verify compatibility with current integration mode"
        fi
        # ABI / linkage invariant (scans Modules/SPM even when APP_EXCLUDE_ROOTS
        # hides library trees from app_grep). Encrypted handles + system
        # libsqlite3 → device SIGSEGV on sqlite3_exec.
        local sql_link_out sql_link_rc
        set +e
        sql_link_out=$(python3 "$SCRIPT_DIR/lib/check-sql-linkage.py" --project-root "$PROJECT_ROOT" 2>/dev/null)
        sql_link_rc=$?
        set -e
        if [[ -n "$sql_link_out" ]]; then
            while IFS= read -r line; do
                case "$line" in
                    PASS:*) pass "${line#PASS:}" ;;
                    WARN:*) warn "${line#WARN:}" ;;
                    FAIL:*) fail "${line#FAIL:}" ;;
                    SKIP:*) skip "${line#SKIP:}" ;;
                esac
            done <<< "$sql_link_out"
        elif [[ "$sql_link_rc" -ne 0 ]]; then
            warn "SQL linkage checker returned no output (rc=$sql_link_rc)"
        fi
        echo ""
    fi

    if should_run_phase "5d-storage-final-closure"; then
        record_phase "5d-storage-final-closure"
        echo -e "${BOLD}Phase 5d: Storage Final Closure${NC}"
        run_storage_contract_check "final" "Final storage closure"
        if app_grep "sqlite3_open\(|sqlite3_open_v2\(|GRDB\|import SQLite\|SQLCipher\|sqlite3_key" --include="*.swift" --include="*.m" --include="*.mm" --include="*.h" --include="*.c"; then
            fail "Storage final closure failed: unmanaged SQL surfaces still present"
        fi
        if app_grep "@Model\|ModelContainer\|ModelContext\|@Query\|#Predicate" --include="*.swift"; then
            fail "Storage final closure failed: SwiftData persistence remains active"
        fi
        echo ""
    fi

    if should_run_phase "8a-network-request-timing"; then
        record_phase "8a-network-request-timing"
        echo -e "${BOLD}Phase 8a: Network Request Timing${NC}"
        run_network_web_contract_check "network-request-timing" "Network request timing closure"
        if app_grep "GDURLSession" --include="*.swift" --include="*.m" --include="*.h"; then
            fail "Invented API GDURLSession detected"
        fi
        echo ""
    fi

    if should_run_phase "8b-network-session-configuration"; then
        record_phase "8b-network-session-configuration"
        echo -e "${BOLD}Phase 8b: Network Session/Configuration Review${NC}"
        run_network_web_contract_check "network-session" "Network session/configuration closure"
        if app_grep "URLSession\|NSURLSession\|NSURLConnection" --include="*.swift" --include="*.m" --include="*.h"; then
            pass "Foundation networking surfaces detected and validated for post-authorization routing"
        else
            skip "No URLSession/NSURLConnection surfaces detected"
        fi
        echo ""
    fi

    if should_run_phase "8c-network-custom-protocol-pinning"; then
        record_phase "8c-network-custom-protocol-pinning"
        echo -e "${BOLD}Phase 8c: Custom Protocol and Pinning Review${NC}"
        run_network_web_contract_check "network-protocol-pinning" "Custom protocol/pinning closure"
        if app_grep "URLProtocol\|NSURLProtocol\|didReceive challenge\|serverTrust\|SecTrust\|SecTrustEvaluate\|URLAuthenticationChallenge" --include="*.swift" --include="*.m" --include="*.h"; then
            pass "Custom protocol/pinning surfaces detected and classified"
        else
            skip "No custom URLProtocol/pinning surfaces detected"
        fi
        echo ""
    fi

    if should_run_phase "8d-network-socket-closure"; then
        record_phase "8d-network-socket-closure"
        echo -e "${BOLD}Phase 8d: Direct Socket Closure${NC}"
        run_network_web_contract_check "network-socket" "Direct socket closure"
        if app_grep_stripped "NWConnection\|CFSocket\|CFStreamCreatePairWithSocketToHost\|NSStream\|InputStream\|OutputStream\|GCDAsyncSocket\|CocoaAsyncSocket\|URLSessionWebSocketTask\|webSocketTask" --include="*.swift" --include="*.m" --include="*.h"; then
            warn "Direct socket/websocket surfaces remain in source; ensure each path is migrated or explicitly blocked in ledger"
        else
            pass "No unmanaged direct socket APIs detected in source scan"
        fi
        echo ""
    fi

    if should_run_phase "8e-network-background-session-classification"; then
        record_phase "8e-network-background-session-classification"
        echo -e "${BOLD}Phase 8e: Background Session Classification${NC}"
        run_network_web_contract_check "network-background" "Background session classification closure"
        if app_grep "background\\(withIdentifier:\|sessionSendsLaunchEvents\|handleEventsForBackgroundURLSession" --include="*.swift" --include="*.m" --include="*.h"; then
            pass "Background networking candidates detected and classification required"
        else
            skip "No explicit background URLSession surfaces detected"
        fi
        if app_grep "didReceiveRemoteNotification\|performFetchWithCompletionHandler\|BGTaskScheduler" --include="*.swift" --include="*.m" --include="*.h"; then
            if app_grep "state\\.isAuthorized\|GDAppEventAuthorized\|canAuthorizeAutonomously\|authorizeAutonomously" --include="*.swift" --include="*.m" --include="*.h"; then
                pass "Background callback paths show authorization-aware handling markers"
            else
                fail "Background callback paths detected without authorization-aware handling markers"
            fi
            if app_grep "authorizeAutonomously" --include="*.swift" --include="*.m" --include="*.h" && ! app_grep "canAuthorizeAutonomously" --include="*.swift" --include="*.m" --include="*.h"; then
                fail "authorizeAutonomously usage detected without canAuthorizeAutonomously pre-check"
            fi
        fi
        echo ""
    fi

    if should_run_phase "8f-network-final-closure"; then
        record_phase "8f-network-final-closure"
        echo -e "${BOLD}Phase 8f: Network Final Closure${NC}"
        run_network_web_contract_check "network-final" "Network final closure"
        echo ""
    fi

    if should_run_phase "8g-webview-support-initialization"; then
        record_phase "8g-webview-support-initialization"
        echo -e "${BOLD}Phase 8g: WKWebView Support Initialization${NC}"
        run_network_web_contract_check "webview-support" "WKWebView support initialization closure"
        if app_grep "WKWebView" --include="*.swift" --include="*.m" --include="*.h"; then
            if app_grep "BlackBerryDynamics\\.GDNET\|WKWebView\\+GDNET\|supportWKWebView" --include="*.swift" --include="*.m" --include="*.h"; then
                pass "WKWebView support integration markers detected"
            else
                fail "WKWebView detected without explicit Dynamics support markers"
            fi
        else
            skip "No WKWebView surfaces detected"
        fi
        echo ""
    fi

    if should_run_phase "8h-webview-content-routing"; then
        record_phase "8h-webview-content-routing"
        echo -e "${BOLD}Phase 8h: WKWebView Content Routing${NC}"
        run_network_web_contract_check "webview-content" "WKWebView content routing closure"
        if app_grep "loadFileURL\|loadHTMLString\|setURLSchemeHandler\|WKURLSchemeHandler\|WKWebsiteDataStore\|WKProcessPool" --include="*.swift" --include="*.m" --include="*.h"; then
            pass "WKWebView content-routing surfaces detected and classified"
        else
            skip "No advanced WKWebView content-routing surfaces detected"
        fi
        echo ""
    fi

    if should_run_phase "8i-webview-unsupported-feature-closure"; then
        record_phase "8i-webview-unsupported-feature-closure"
        echo -e "${BOLD}Phase 8i: WKWebView Unsupported Feature Closure${NC}"
        run_network_web_contract_check "webview-unsupported" "WKWebView unsupported-feature closure"
        if app_grep "WKDownload\|WKFindConfiguration\|removeAllUserScripts\|WKContentWorld\|SFSafariViewController" --include="*.swift" --include="*.m" --include="*.h"; then
            pass "Unsupported or high-risk WK/Web surfaces detected and decisioned"
        else
            skip "No unsupported WK/Web surfaces detected"
        fi
        echo ""
    fi

    if should_run_phase "8j-webview-final-closure"; then
        record_phase "8j-webview-final-closure"
        echo -e "${BOLD}Phase 8j: WKWebView Final Closure${NC}"
        run_network_web_contract_check "webview-final" "WKWebView final closure"
        echo ""
    fi

    if should_run_phase "9a-external-surface-inventory-direction"; then
        record_phase "9a-external-surface-inventory-direction"
        echo -e "${BOLD}Phase 9a: External Surface Inventory and Direction${NC}"
        run_dlp_icc_policy_contract_check "external-inventory" "External surface direction taxonomy"
        echo ""
    fi

    if should_run_phase "9b-inbound-secure-copy-closure"; then
        record_phase "9b-inbound-secure-copy-closure"
        echo -e "${BOLD}Phase 9b: Inbound Secure Copy Closure${NC}"
        run_dlp_icc_policy_contract_check "inbound-secure-copy" "Inbound unmanaged-to-managed secure copy closure"
        echo ""
    fi

    if should_run_phase "9c-outbound-dlp-blocker-closure"; then
        record_phase "9c-outbound-dlp-blocker-closure"
        echo -e "${BOLD}Phase 9c: Outbound DLP and Blocker Closure${NC}"
        run_dlp_icc_policy_contract_check "outbound-egress" "Outbound protected export closure"
        if app_grep "UIPasteboard" --include="*.swift" --include="*.m" --include="*.h"; then
            app_grep "GDNativePasteboardAccess" --include="*.swift" --include="*.m" --include="*.h" && pass "GDNativePasteboardAccess found for native pasteboard access" || fail "UIPasteboard found without GDNativePasteboardAccess"
        else
            skip "No programmatic pasteboard access detected"
        fi
        echo ""
    fi

    if should_run_phase "9d-appkinetics-source-closure"; then
        record_phase "9d-appkinetics-source-closure"
        echo -e "${BOLD}Phase 9d: AppKinetics Source Closure${NC}"
        run_dlp_icc_policy_contract_check "icc-source" "AppKinetics source/service closure"
        echo ""
    fi

    if should_run_phase "9e-appkinetics-plist-registration"; then
        record_phase "9e-appkinetics-plist-registration"
        echo -e "${BOLD}Phase 9e: AppKinetics Registration Closure${NC}"
        run_dlp_icc_policy_contract_check "icc-registration" "AppKinetics Info.plist registration closure"
        if ! icc_domain_is_applicable; then
            skip "ICC domain marked not-applicable; skipping AppKinetics plist registration markers scan"
        elif app_grep "GDServices\\|GDServiceID\\|GDServiceName\\|GDServiceVersion" --include="*.plist"; then
            pass "AppKinetics service registration markers found in plist files"
        else
            # When every ICC call site is removed/notApplicable, "no services"
            # is intentional — do not WARN (that blocked Prompt 10 recording).
            local icc_needs_registration=true
            if [[ -f "$PLAN_STATE_FILE" && -f "$ANALYSIS_FILE" ]]; then
                if python3 - "$ANALYSIS_FILE" "$PLAN_STATE_FILE" <<'PY' 2>/dev/null
import json, sys
from pathlib import Path
analysis = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
plan = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
icc_ids = []
for domain in analysis.get("executionPlan") or []:
    if not isinstance(domain, dict) or domain.get("domainId") != "icc":
        continue
    if domain.get("applicability", "applicable") == "not-applicable":
        sys.exit(0)
    for cs in domain.get("callSites") or []:
        if isinstance(cs, dict) and cs.get("id"):
            icc_ids.append(cs["id"])
dispositions = {
    row.get("callSiteId"): row.get("status")
    for row in (plan.get("dispositions") or [])
    if isinstance(row, dict) and row.get("callSiteId")
}
if not icc_ids:
    sys.exit(0)
closed = {"removed", "notApplicable"}
if all(dispositions.get(cs_id) in closed for cs_id in icc_ids):
    sys.exit(0)
sys.exit(1)
PY
                then
                    icc_needs_registration=false
                fi
            fi
            if [[ "$icc_needs_registration" == true ]]; then
                warn "No AppKinetics plist registration markers found in source scan"
            else
                skip "ICC call sites removed/notApplicable — no GDServiceID registration required"
            fi
        fi
        echo ""
    fi

    if should_run_phase "9f-residual-url-share-surface"; then
        record_phase "9f-residual-url-share-surface"
        echo -e "${BOLD}Phase 9f: Residual URL/Share Surface Closure${NC}"
        run_dlp_icc_policy_contract_check "residual-share" "Residual URL/share payload closure"
        echo ""
    fi

    if should_run_phase "9g-policy-timing"; then
        record_phase "9g-policy-timing"
        echo -e "${BOLD}Phase 9g: Policy Timing Closure${NC}"
        run_dlp_icc_policy_contract_check "policy-timing" "Policy API timing closure"
        echo ""
    fi

    if should_run_phase "9h-policy-cache-update-handling"; then
        record_phase "9h-policy-cache-update-handling"
        echo -e "${BOLD}Phase 9h: Policy Cache and Update Closure${NC}"
        run_dlp_icc_policy_contract_check "policy-cache-update" "Policy cache/update closure"
        echo ""
    fi

    if should_run_phase "9i-dlp-icc-policy-final-closure"; then
        record_phase "9i-dlp-icc-policy-final-closure"
        echo -e "${BOLD}Phase 9i: DLP/ICC/Policy Final Closure${NC}"
        run_dlp_icc_policy_contract_check "final" "DLP/ICC/policy final closure"
        echo ""
    fi

    if should_run_phase "10-build-verification"; then
        record_phase "10-build-verification"
        echo -e "${BOLD}Phase 10: Build Verification${NC}"
        if [[ -z "$XCWORKSPACE" && -z "$XCODEPROJ" ]]; then
            warn "Could not determine build scheme — use --scheme SchemeName"
        elif [[ -f "$PROJECT_ROOT/Podfile" || -d "$PROJECT_ROOT/Pods" ]]; then
            if [[ -z "$XCWORKSPACE" ]]; then
                fail "CocoaPods integration detected but no .xcworkspace found; CocoaPods projects must build via workspace"
            elif [[ -n "$XCODEPROJ" ]]; then
                pass "CocoaPods workspace discovered; treat .xcworkspace as canonical build entrypoint"
            else
                pass "CocoaPods workspace discovered as canonical build entrypoint"
            fi
        else
            pass "Build entrypoint discovered"
        fi
        echo ""
    fi

    if should_run_phase "11-migration-comments"; then
        record_phase "11-migration-comments"
        echo -e "${BOLD}Phase 11: Migration Comments${NC}"
        local comment_count
        set +e
        if command -v rg >/dev/null 2>&1; then
            comment_count=$(rg -n --no-messages "\[BB_DYNAMICS-MIGRATION\]" "$PROJECT_ROOT" \
                "${RG_EXCLUDES[@]}" \
                --glob "*.swift" \
                --glob "*.m" \
                --glob "*.h" \
                --glob "*.plist" \
                --glob "*.entitlements" \
                --glob "Podfile" | wc -l | tr -d ' ')
        else
            # Same exclusions as app_grep / RG_EXCLUDES when ripgrep is missing
            comment_count=$(app_search_python count '\[BB_DYNAMICS-MIGRATION\]' \
                --glob="*.swift" \
                --glob="*.m" \
                --glob="*.h" \
                --glob="*.plist" \
                --glob="*.entitlements" \
                --glob="Podfile" | tr -d '[:space:]')
        fi
        set -e
        comment_count="${comment_count:-0}"
        if [[ "$comment_count" -gt 0 ]]; then
            pass "Found $comment_count migration comments"
        else
            warn "No [BB_DYNAMICS-MIGRATION] comments found"
        fi
        echo ""
    fi
}

phase_12_report_contract() {
    if ! should_run_phase "12-migration-report"; then
        return
    fi
    record_phase "12-migration-report"
    echo -e "${BOLD}Phase 12: Migration Report${NC}"
    if [[ ! -f "$REPORT_FILE" ]]; then
        fail "migration-report.json not found"
        echo ""
        return
    fi
    local output
    set +e
    output=$(python3 - <<PYEOF
import json, sys
from pathlib import Path

report_path = Path("$REPORT_FILE")
catalog_path = Path("$API_CATALOG_FILE")
auth_reachability_path = Path("$AUTH_REACHABILITY_FILE")
analysis_path = Path("$ANALYSIS_FILE")
expected_run = "$CURRENT_RUN_ID"
expected_version = "$TOOL_VERSION"
errors = []
warnings = []

try:
    report = json.loads(report_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"ERROR:invalid JSON: {exc}")
    sys.exit(1)

if report.get("schemaVersion") != "2.1.0":
    errors.append(f"schemaVersion must be 2.1.0 (got {report.get('schemaVersion')!r})")
if report.get("platform") != "iOS":
    errors.append("platform must be iOS")

required = [
    "toolkit", "runProvenance", "targetMapSummary", "lifecycleSummary",
    "executedPromptAudit", "closureSummary", "blockers", "unresolvedCallSites",
    "validationProof", "apiCatalogEvidence", "runtimeEvidenceStatus",
    "securityPosture", "migrationConfidence", "releaseReadiness"
]
for k in required:
    if k not in report:
        errors.append(f"missing required top-level key '{k}'")

analysis = {}
if analysis_path.exists():
    try:
        analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
    except Exception as exc:
        warnings.append(f"cannot parse migration-analysis.json for network/web closure checks: {exc}")
else:
    warnings.append("migration-analysis.json missing for network/web closure checks")

applicable_domains = set()
if isinstance(analysis, dict):
    for entry in analysis.get("executionPlan", []):
        if not isinstance(entry, dict):
            continue
        domain_id = entry.get("domainId")
        if not isinstance(domain_id, str):
            continue
        if entry.get("applicability", "applicable") != "not-applicable":
            applicable_domains.add(domain_id)

network_web_applicable = bool({"secureNetworking", "webview"} & applicable_domains)
if network_web_applicable:
    nw = report.get("networkWebClosure")
    if not isinstance(nw, dict):
        errors.append("networkWebClosure is required when secureNetworking/webview domains are applicable")
    else:
        if "secureNetworking" in applicable_domains:
            if not isinstance(nw.get("urlSession"), dict):
                errors.append("networkWebClosure.urlSession is required when secureNetworking is applicable")
            if not isinstance(nw.get("directSockets"), dict):
                errors.append("networkWebClosure.directSockets is required when secureNetworking is applicable")
            if not isinstance(nw.get("protocolAndPinning"), dict):
                errors.append("networkWebClosure.protocolAndPinning is required when secureNetworking is applicable")
            if not isinstance(nw.get("backgroundSessions"), dict):
                errors.append("networkWebClosure.backgroundSessions is required when secureNetworking is applicable")
        if "webview" in applicable_domains and not isinstance(nw.get("webview"), dict):
            errors.append("networkWebClosure.webview is required when webview domain is applicable")

tranche5_applicable = bool({"dlpPasteboard", "icc", "policyManagement"} & applicable_domains)
if tranche5_applicable:
    t5 = report.get("dlpIccPolicyClosure")
    if not isinstance(t5, dict):
        errors.append("dlpIccPolicyClosure is required when dlpPasteboard/icc/policyManagement domains are applicable")
    else:
        if "dlpPasteboard" in applicable_domains:
            if not isinstance(t5.get("externalSurfaces"), dict):
                errors.append("dlpIccPolicyClosure.externalSurfaces is required when dlpPasteboard is applicable")
            if not isinstance(t5.get("inbound"), dict):
                errors.append("dlpIccPolicyClosure.inbound is required when dlpPasteboard is applicable")
            if not isinstance(t5.get("outbound"), dict):
                errors.append("dlpIccPolicyClosure.outbound is required when dlpPasteboard is applicable")
        if "icc" in applicable_domains and not isinstance(t5.get("appkinetics"), dict):
            errors.append("dlpIccPolicyClosure.appkinetics is required when icc is applicable")
        if "policyManagement" in applicable_domains and not isinstance(t5.get("policy"), dict):
            errors.append("dlpIccPolicyClosure.policy is required when policyManagement is applicable")

lifecycle = report.get("lifecycleSummary", {})
if not isinstance(lifecycle, dict):
    errors.append("lifecycleSummary must be an object")
else:
    lifecycle_required = [
        "selectedAuthorizationPattern",
        "postAuthBoundary",
        "windowStrategy",
        "lifecycleRootCount",
        "prompt03Validation",
        "prompt03bValidation",
        "reachabilityGeneratedAt",
        "reachabilitySourceFingerprint",
    ]
    for key in lifecycle_required:
        if key not in lifecycle:
            errors.append(f"lifecycleSummary.{key} is required for authorization tranche evidence")
    for key in ("prompt03Validation", "prompt03bValidation"):
        if key in lifecycle and lifecycle.get(key) not in {"pass", "warn", "fail"}:
            errors.append(f"lifecycleSummary.{key} must be pass|warn|fail")
    if auth_reachability_path.exists():
        try:
            reachability = json.loads(auth_reachability_path.read_text(encoding="utf-8"))
            reach_fp = str(reachability.get("sourceFingerprint", ""))
            if reach_fp and lifecycle.get("reachabilitySourceFingerprint") and reach_fp != lifecycle.get("reachabilitySourceFingerprint"):
                errors.append("lifecycleSummary.reachabilitySourceFingerprint must match auth-reachability.json sourceFingerprint")
        except Exception as exc:
            errors.append(f"cannot parse auth-reachability.json: {exc}")

toolkit = report.get("toolkit", {})
if not isinstance(toolkit, dict):
    errors.append("toolkit must be an object")
else:
    if toolkit.get("name") != "dynamics-migration-tool":
        errors.append("toolkit.name must be dynamics-migration-tool")
    if toolkit.get("platform") != "iOS":
        errors.append("toolkit.platform must be iOS")
    if toolkit.get("reportSchemaVersion") != "2.1.0":
        errors.append("toolkit.reportSchemaVersion must be 2.1.0")
    if expected_version and toolkit.get("version") != expected_version:
        errors.append("toolkit.version must match VERSION file")

rp = report.get("runProvenance", {})
if not isinstance(rp, dict):
    errors.append("runProvenance must be an object")
else:
    run = rp.get("runId")
    if not run:
        errors.append("runProvenance.runId is required")
    if expected_run and run and run != expected_run:
        errors.append(f"runProvenance.runId mismatch (expected {expected_run}, got {run})")

handoff = report.get("uemAdminHandoff", {})
if not isinstance(handoff, dict):
    errors.append("uemAdminHandoff must be an object")
else:
    handoff_bundle = handoff.get("bundleIdentifier")
    handoff_version = handoff.get("gdApplicationVersion")
    if not isinstance(handoff_bundle, str) or not handoff_bundle.strip():
        errors.append("uemAdminHandoff.bundleIdentifier is required")
    if not isinstance(handoff_version, str) or not handoff_version.strip():
        errors.append("uemAdminHandoff.gdApplicationVersion is required")
    registered = handoff.get("registeredUrlSchemes")
    if not isinstance(registered, list) or not all(isinstance(s, str) and s for s in registered):
        errors.append("uemAdminHandoff.registeredUrlSchemes must list completed Dynamics URL scheme registrations")
        registered_set = set()
    else:
        registered_set = set(registered)

    required_plist_keys = handoff.get("requiredPlistKeys")
    mandatory_keys = [
        "GDApplicationID",
        "GDApplicationVersion",
        "CFBundleURLTypes",
        "NSFaceIDUsageDescription",
        "NSCameraUsageDescription",
    ]
    if not isinstance(required_plist_keys, dict):
        errors.append("uemAdminHandoff.requiredPlistKeys must record completed/missing status for mandatory Prompt 02 plist keys")
    else:
        for key in mandatory_keys:
            status = required_plist_keys.get(key)
            if status != "present":
                errors.append(f"uemAdminHandoff.requiredPlistKeys.{key} must be present")
        receiver_status = required_plist_keys.get("BlackBerryDynamics.CheckEventReceiver")
        if receiver_status not in {"present", "not-applicable"}:
            errors.append("uemAdminHandoff.requiredPlistKeys.BlackBerryDynamics.CheckEventReceiver must be present or not-applicable")

    if isinstance(handoff_bundle, str) and handoff_bundle.strip() and isinstance(handoff_version, str) and handoff_version.strip():
        base = handoff_bundle.strip()
        version = handoff_version.strip()
        for scheme in (
            f"{base}.sc2",
            f"{base}.sc2.{version}",
            f"{base}.sc3",
            "com.good.gd.discovery",
        ):
            if scheme not in registered_set:
                errors.append(f"uemAdminHandoff.registeredUrlSchemes missing required scheme: {scheme}")

        setup = str(handoff.get("applicationSetupType") or "in-house").strip().lower()
        setup = setup.replace("_", "-").replace(" ", "-")
        if setup in {"partner", "third-party", "thirdparty", "partner-third-party"}:
            if "com.good.gd.discovery.enterprise" in registered_set:
                errors.append("partner/third-party reports must not list com.good.gd.discovery.enterprise")
            if "com.good.gd.discovery.good" in registered_set:
                errors.append("partner/third-party reports must not list com.good.gd.discovery.good")
        elif setup in {"blackberry", "blackberry-developed", "blackberry-internal"}:
            if "com.good.gd.discovery.good" not in registered_set:
                errors.append("uemAdminHandoff.registeredUrlSchemes missing required scheme: com.good.gd.discovery.good")
            if "com.good.gd.discovery.enterprise" in registered_set:
                errors.append("BlackBerry-developed reports must not list com.good.gd.discovery.enterprise")
        else:
            if "com.good.gd.discovery.enterprise" not in registered_set:
                errors.append("uemAdminHandoff.registeredUrlSchemes missing required scheme: com.good.gd.discovery.enterprise")
            if "com.good.gd.discovery.good" in registered_set:
                errors.append("in-house/UEM-managed reports must not list com.good.gd.discovery.good")

vp = report.get("validationProof", {})
if not isinstance(vp, dict):
    errors.append("validationProof must be an object")
else:
    mode = vp.get("mode")
    if mode != "full":
        errors.append(f"validationProof.mode must be 'full' for final report (got {mode!r})")
    phases = vp.get("phases")
    if not isinstance(phases, list) or not phases:
        errors.append("validationProof.phases must be a non-empty array")
    if vp.get("isStale") is True:
        errors.append("validationProof.isStale must be false")

catalog_ids = set()
if catalog_path.exists():
    try:
        cat = json.loads(catalog_path.read_text(encoding="utf-8"))
        for row in cat.get("rows", []):
            rid = row.get("id")
            if isinstance(rid, str) and rid:
                catalog_ids.add(rid)
    except Exception as exc:
        errors.append(f"cannot parse API catalog: {exc}")
else:
    errors.append("API catalog missing")

for idx, api in enumerate(report.get("apisReplaced", [])):
    if not isinstance(api, dict):
        errors.append(f"apisReplaced[{idx}] must be an object")
        continue
    row_id = api.get("catalogRowId")
    if not isinstance(row_id, str) or not row_id:
        errors.append(f"apisReplaced[{idx}].catalogRowId is required")
    elif row_id not in catalog_ids:
        errors.append(f"apisReplaced[{idx}].catalogRowId unknown: {row_id}")

def mentions_flutter(obj):
    try:
        return "flutter" in json.dumps(obj).lower()
    except Exception:
        return False

flutter_flagged = False
ufs = report.get("unsupportedFeatures")
if isinstance(ufs, list):
    for item in ufs:
        if mentions_flutter(item):
            flutter_flagged = True
            break
if not flutter_flagged and mentions_flutter(analysis.get("unsupportedDetections")):
    flutter_flagged = True
    warnings.append("Flutter detected in analysis but missing from report unsupportedFeatures")
if flutter_flagged:
    rr = report.get("releaseReadiness")
    rec = rr.get("recommendation") if isinstance(rr, dict) else None
    if rec != "no-go":
        errors.append("Flutter hybrid is out of scope for this toolkit release; releaseReadiness.recommendation must be no-go")

def mentions_share_extension(obj):
    try:
        blob = json.dumps(obj).lower()
    except Exception:
        return False
    return (
        "share-extension" in blob
        or "share extension" in blob
        or "shareextension" in blob
        or "com.apple.share-services" in blob
    )

share_flagged = False
if isinstance(ufs, list):
    for item in ufs:
        if mentions_share_extension(item):
            share_flagged = True
            break
if not share_flagged and mentions_share_extension(analysis.get("unsupportedDetections")):
    share_flagged = True
    warnings.append("Share Extension detected in analysis but missing from report unsupportedFeatures")

# target-map / project evidence → report must call Share Extension out
target_map_path = Path("$TARGET_MAP_FILE")
share_in_project = False
if target_map_path.is_file():
    try:
        tm = json.loads(target_map_path.read_text(encoding="utf-8"))
        for t in tm.get("targets") or []:
            if not isinstance(t, dict) or t.get("type") != "extension":
                continue
            point = (t.get("extensionPointIdentifier") or "")
            reason = (t.get("unsupportedReason") or "").lower()
            name = (t.get("name") or "").lower()
            if (
                point == "com.apple.share-services"
                or "share extension" in reason
                or "shareextension" in name.replace(" ", "").replace("-", "").replace("_", "")
                or name.rstrip().endswith("share")
            ):
                share_in_project = True
                break
    except Exception:
        pass
if share_in_project and not share_flagged and not mentions_share_extension(report):
    errors.append(
        "Share Extension target detected in target-map but missing from report unsupportedFeatures "
        "(Dynamics does not support Share Extensions)"
    )
elif share_in_project and not share_flagged:
    warnings.append("Share Extension in target-map should appear in report unsupportedFeatures")

# First-activate / SQL runtime smoke: when secureSql or authorization is
# applicable, pending runtime evidence cannot be "go" — require go-with-risks
# or no-go and an explicit blocking/risk note about first Dynamics activate.
runtime = report.get("runtimeEvidenceStatus") if isinstance(report.get("runtimeEvidenceStatus"), dict) else {}
runtime_ver = str(runtime.get("runtimeVerification") or "").strip().lower()
rr = report.get("releaseReadiness") if isinstance(report.get("releaseReadiness"), dict) else {}
rec = str(rr.get("recommendation") or "").strip()
needs_first_activate = bool({"secureSql", "authorization"} & applicable_domains)
if needs_first_activate and runtime_ver in {"", "pending", "unavailable"}:
    if rec == "go":
        errors.append(
            "secureSql/authorization applicable with runtimeVerification pending/unavailable: "
            "releaseReadiness.recommendation cannot be 'go' until first Dynamics activate smoke "
            "(post-auth root install + sqlite3enc open/exec) is recorded; use go-with-risks or no-go"
        )
    else:
        notes = runtime.get("notes") if isinstance(runtime.get("notes"), list) else []
        blocking = rr.get("blockingItems") if isinstance(rr.get("blockingItems"), list) else []
        blob = " ".join(str(x) for x in list(notes) + list(blocking)).lower()
        if "first" not in blob and "activat" not in blob and "runtime" not in blob and "device" not in blob:
            warnings.append(
                "secureSql/authorization applicable but runtimeVerification is pending/unavailable — "
                "document first Dynamics activate smoke (root install + SQL open/exec) in "
                "runtimeEvidenceStatus.notes or releaseReadiness.blockingItems"
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
PYEOF
)
    local rc=$?
    set -e
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
            OK:*) pass "${line#OK:}" ;;
            WARN:*) warn "${line#WARN:}" ;;
            ERROR:*) fail "${line#ERROR:}" ;;
            *) warn "$line" ;;
        esac
    done <<< "$output"
    [[ $rc -ne 0 ]] && fail "migration-report.json does not satisfy report contract"
    echo ""
}

run_preflight_mode() {
    echo -e "${BOLD}Preflight Environment${NC}"
    command -v xcodebuild >/dev/null 2>&1 && pass "xcodebuild available" || fail "xcodebuild missing"
    if compgen -G "$PROJECT_ROOT/*.xcodeproj" >/dev/null || compgen -G "$PROJECT_ROOT/*.xcworkspace" >/dev/null; then
        pass "Xcode project/workspace detected"
    else
        fail "No .xcodeproj or .xcworkspace found"
    fi
    echo ""
}

write_last_check() {
    local result="fail"
    if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
        result="pass"
    elif [[ $FAIL -eq 0 ]]; then
        result="warn"
    fi
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
    mkdir -p "$OUTPUT_DIR"
    local phases_file errors_file blockers_file warnings_file fingerprints_file
    phases_file=$(mktemp)
    errors_file=$(mktemp)
    blockers_file=$(mktemp)
    warnings_file=$(mktemp)
    fingerprints_file=$(mktemp)

    printf '%s\n' "${PHASES_EXECUTED[@]-}" > "$phases_file"
    printf '%s\n' "${ERRORS_LIST[@]-}" > "$errors_file"
    printf '%s\n' "${BLOCKERS_LIST[@]-}" > "$blockers_file"
    printf '%s\n' "${WARNINGS_LIST[@]-}" > "$warnings_file"
    : > "$fingerprints_file"
    local row
    for row in "${FINGERPRINT_ROWS[@]}"; do
        printf '%s\n' "$row" >> "$fingerprints_file"
    done

    VALIDATION_MODE_ENV="$VALIDATION_MODE" \
    CHECK_PROMPT_ID_ENV="$CHECK_PROMPT_ID" \
    CURRENT_RUN_ID_ENV="$CURRENT_RUN_ID" \
    VALIDATION_RUN_ID_ENV="$VALIDATION_RUN_ID" \
    RESULT_ENV="$result" \
    FAIL_ENV="$FAIL" \
    WARN_ENV="$WARN" \
    TS_ENV="$ts" \
    TOOL_VERSION_ENV="$TOOL_VERSION" \
    CHECK_PROMPT_MAP_ENV="$CHECK_PROMPT_MAP" \
    DIAGNOSTICS_CONTRACT_PY_ENV="$TOOL_DIR/tooling/lib/diagnostics-contract.py" \
    python3 - "$LAST_CHECK_FILE" "$phases_file" "$errors_file" "$blockers_file" "$warnings_file" "$fingerprints_file" <<'PYEOF'
import importlib.util
import json
import os
import sys
from pathlib import Path

last_check, phases_f, errors_f, blockers_f, warnings_f, fps_f = sys.argv[1:]

def read_lines(path: str):
    p = Path(path)
    if not p.exists():
        return []
    return [line.strip() for line in p.read_text(encoding="utf-8").splitlines() if line.strip()]

fingerprints = {}
for row in read_lines(fps_f):
    key, _, value = row.partition("=")
    if key:
        fingerprints[key] = value

mode = os.environ.get("VALIDATION_MODE_ENV", "full")
payload = {
    "schemaVersion": "1.0.0",
    "diagnosticContractVersion": "1.0.0",
    "platform": "ios",
    "runId": os.environ.get("CURRENT_RUN_ID_ENV", ""),
    "validationRunId": os.environ.get("VALIDATION_RUN_ID_ENV", ""),
    "validationMode": mode,
    "promptScope": os.environ.get("CHECK_PROMPT_ID_ENV", "") if mode == "prompt-scoped" else None,
    "phasesExecuted": read_lines(phases_f),
    "result": os.environ.get("RESULT_ENV", "fail"),
    "isStale": False,
    "failCount": int(os.environ.get("FAIL_ENV", "0")),
    "warnCount": int(os.environ.get("WARN_ENV", "0")),
    "timestamp": os.environ.get("TS_ENV", ""),
    "sourceFingerprints": fingerprints,
    "toolkitVersion": os.environ.get("TOOL_VERSION_ENV", ""),
    "validatorPath": "tooling/validate.sh",
    "errors": read_lines(errors_f),
    "blockers": read_lines(blockers_f),
    "warnings": read_lines(warnings_f),
    "violations": [],
}

for msg in payload["errors"]:
    payload["violations"].append({
        "severity": "fail",
        "phase": "unknown",
        "domain": "",
        "message": msg,
    })
for msg in payload["warnings"]:
    payload["violations"].append({
        "severity": "warn",
        "phase": "unknown",
        "domain": "",
        "message": msg,
    })

diagnostics_py = os.environ.get("DIAGNOSTICS_CONTRACT_PY_ENV", "")
if diagnostics_py and Path(diagnostics_py).is_file():
    spec = importlib.util.spec_from_file_location("diagnostics_contract", diagnostics_py)
    if spec and spec.loader:
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        payload["violations"] = mod.normalize_diagnostics(
            payload["violations"],
            platform="ios",
            prompt_id=payload.get("promptScope") or payload.get("validationMode") or "full",
            phases=payload.get("phasesExecuted") or [],
            check_map=mod.load_json(os.environ.get("CHECK_PROMPT_MAP_ENV", "")),
        )

Path(last_check).write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PYEOF
    rm -f "$phases_file" "$errors_file" "$blockers_file" "$warnings_file" "$fingerprints_file"
    echo -e "  ${CYAN}Validation proof written: output/.last-check.json (mode=$VALIDATION_MODE, result=$result)${NC}"
}

record_loop_state_from_sidecar() {
    local result_label="$1"
    [ -f "$LOOP_STATE_SH" ] || return 0

    local prompt_id="$CHECK_PROMPT_ID"
    if [[ -z "$prompt_id" ]]; then
        prompt_id="$VALIDATION_MODE"
    fi

    local _loop_out=""
    local _loop_rc=0
    set +e
    _loop_out="$(
        bash "$LOOP_STATE_SH" record \
            --prompt-id "$prompt_id" \
            --stage "validation" \
            --result "$result_label" \
            --sidecar "$LAST_CHECK_FILE" \
            --validation-run-id "$VALIDATION_RUN_ID" \
            --owner-prompt "$prompt_id" \
            --safe-next-action "rerun-owner-prompt" 2>/dev/null
    )"
    _loop_rc=$?
    set -e
    if [[ $_loop_rc -eq 3 ]]; then
        echo "ESCALATION REQUIRED: retry budget exhausted for prompt=$prompt_id stage=validation." >&2
        [[ -n "$_loop_out" ]] && echo "$_loop_out" >&2
        return 3
    fi
    return 0
}

echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  BlackBerry Dynamics iOS Migration — Validation${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}Toolkit Version: ${BOLD}${TOOL_VERSION}${NC}"
echo -e "${CYAN}Supported Dynamics SDK: ${BOLD}${SUPPORTED_SDK_VERSION}${NC}"
if [[ "$VALIDATION_MODE" == "prompt-scoped" ]]; then
    echo -e "${CYAN}Mode: ${BOLD}prompt-scoped ($CHECK_PROMPT_ID)${NC}"
elif [[ "$VALIDATION_MODE" == "preflight" ]]; then
    echo -e "${CYAN}Mode: ${BOLD}preflight${NC}"
else
    echo -e "${CYAN}Mode: ${BOLD}full${NC}"
fi
echo ""

load_prompt_registry
phase_0_artifact_provenance
if [[ "$VALIDATION_MODE" == "preflight" ]]; then
    run_preflight_mode
else
    phase_1_to_11_checks
    phase_12_report_contract
fi

echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
TOTAL=$((PASS + FAIL + WARN))
echo -e "${BOLD}Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$WARN warnings${NC} (of $TOTAL checks)"
if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}Migration tool self-check PASSED${NC}"
elif [[ $FAIL -eq 0 ]]; then
    echo -e "${YELLOW}${BOLD}Migration tool self-check PASSED with warnings${NC}"
else
    echo -e "${RED}${BOLD}Migration tool self-check FAILED — $FAIL issue(s) to resolve${NC}"
fi
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"

write_last_check
PHASES_CSV="$(IFS=,; echo "${PHASES_EXECUTED[*]-}")"
if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
    OBS_VALIDATION_STATUS="passed"
elif [[ $FAIL -eq 0 ]]; then
    OBS_VALIDATION_STATUS="warn"
else
    OBS_VALIDATION_STATUS="failed"
fi
observability_event \
    --operation-type validation-run \
    --prompt-id "${CHECK_PROMPT_ID:-$VALIDATION_MODE}" \
    --phase "$PHASES_CSV" \
    --status "$OBS_VALIDATION_STATUS" \
    --start-ms "$VALIDATE_START_EPOCH_MS" \
    --metadata-json "{\"mode\":\"$VALIDATION_MODE\",\"passCount\":$PASS,\"failCount\":$FAIL,\"warnCount\":$WARN,\"validationRunId\":\"$VALIDATION_RUN_ID\"}"
if [[ $FAIL -eq 0 ]]; then
    record_loop_state_from_sidecar "passed" || true
    exit 0
fi

if ! record_loop_state_from_sidecar "failed"; then
    exit 3
fi
exit 1
