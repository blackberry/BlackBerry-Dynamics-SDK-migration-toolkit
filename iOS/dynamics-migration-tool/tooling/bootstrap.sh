#!/usr/bin/env bash
# BlackBerry Dynamics iOS Migration Tool — Bootstrap Script
#
# Writes bootstrap.json and target-map.json to output/ and
# cleans stale artifacts from previous runs.
#
# Called by migrate.sh (and by 00pre-bootstrap.md instructions) before
# any migration prompt runs. Must be re-entrant and deterministic.
#
# Usage:
#   bash dynamics-migration-tool/tooling/bootstrap.sh \
#       [--run-id <uuid>] \
#       [--agent cursor|kiro|generic] \
#       [--scheme SchemeName] \
#       [--help]
#
# Environment:
#   GD_AGENT      — agent type override (cursor|kiro|generic)
#   GD_SCHEME     — Xcode scheme override
#   GD_SKIP_CLEAN — set to 1 to skip stale-output cleanup

if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
if shopt -oq posix; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PROJECT_ROOT="$(cd "$TOOL_DIR/.." && pwd)"
OUTPUT_DIR="$TOOL_DIR/output"
# shellcheck source=lib/toolkit-version.sh
. "$SCRIPT_DIR/lib/toolkit-version.sh"
toolkit_version_load "$TOOL_DIR"
SCHEMA_VERSION="1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

AGENT="${GD_AGENT:-generic}"
USER_SCHEME="${GD_SCHEME:-}"
SKIP_CLEAN="${GD_SKIP_CLEAN:-0}"
RUN_ID=""

usage() {
    echo "Usage: $0 [--run-id <uuid>] [--agent cursor|kiro|generic] [--scheme NAME] [--skip-clean] [--help]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)   RUN_ID="$2"; shift 2 ;;
        --agent)    AGENT="$2"; shift 2 ;;
        --scheme)   USER_SCHEME="$2"; shift 2 ;;
        --skip-clean) SKIP_CLEAN=1; shift ;;
        --help|-h)  usage; exit 0 ;;
        *)          shift ;;
    esac
done

# Generate a run ID if not provided
if [[ -z "$RUN_ID" ]]; then
    if command -v python3 &>/dev/null; then
        RUN_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
    elif command -v uuidgen &>/dev/null; then
        RUN_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    else
        RUN_ID="$(date +%s)-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo "rand")"
    fi
fi

CREATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "$OUTPUT_DIR"

# ──────────────────────────────────────────────────────────────────
# 1. Stale-output cleanup
# ──────────────────────────────────────────────────────────────────

# Known generated migration artifacts (never touches app source)
KNOWN_ARTIFACTS=(
    "$OUTPUT_DIR/bootstrap.json"
    "$OUTPUT_DIR/target-map.json"
    "$OUTPUT_DIR/migration-analysis.json"
    "$OUTPUT_DIR/migration-plan-state.json"
    "$OUTPUT_DIR/migration-report.json"
    "$OUTPUT_DIR/tool-analysis-report.json"
    "$OUTPUT_DIR/architecture-diagrams.md"
    "$OUTPUT_DIR/.last-check.json"
    "$OUTPUT_DIR/migration-loop-state.json"
)

if [[ "$SKIP_CLEAN" != "1" ]]; then
    STALE_REPORT=false
    STALE_V200=false

    # Detect v2.0.0 report (incompatible with v2.1.0 run)
    if [[ -f "$OUTPUT_DIR/migration-report.json" ]]; then
        if grep -q '"schemaVersion".*"2\.0\.0"' "$OUTPUT_DIR/migration-report.json" 2>/dev/null; then
            STALE_V200=true
            echo -e "${YELLOW}WARNING: Stale v2.0.0 migration-report.json detected — removing before new run${NC}"
        fi
    fi

    # Check for any bootstrap from a different run
    if [[ -f "$OUTPUT_DIR/bootstrap.json" ]]; then
        EXISTING_RUN=$(python3 -c "
import json, sys
try:
    d = json.load(open('$OUTPUT_DIR/bootstrap.json'))
    print(d.get('runId',''))
except:
    print('')
" 2>/dev/null || echo "")
        if [[ -n "$EXISTING_RUN" && "$EXISTING_RUN" != "$RUN_ID" ]]; then
            STALE_REPORT=true
            echo -e "${YELLOW}WARNING: Existing bootstrap.json belongs to run '$EXISTING_RUN' — cleaning for new run '$RUN_ID'${NC}"
        fi
    fi

    CLEANED=0
    for artifact in "${KNOWN_ARTIFACTS[@]}"; do
        if [[ -f "$artifact" ]]; then
            rm -f "$artifact"
            CLEANED=$((CLEANED + 1))
        fi
    done
    if [[ $CLEANED -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Cleaned $CLEANED stale artifact(s) from output/"
    fi
fi

# ──────────────────────────────────────────────────────────────────
# 2. Detect project structure
# ──────────────────────────────────────────────────────────────────

XCWORKSPACE=""
XCODEPROJ=""
PODFILE=""
SPM_COUNT=0
HAS_SPM=false
INFO_PLIST=""

for ws in "$PROJECT_ROOT"/*.xcworkspace; do
    [[ -d "$ws" ]] && XCWORKSPACE="$ws" && break
done
for proj in "$PROJECT_ROOT"/*.xcodeproj; do
    [[ -d "$proj" ]] && XCODEPROJ="$proj" && break
done
[[ -f "$PROJECT_ROOT/Podfile" ]] && PODFILE="$PROJECT_ROOT/Podfile"

if [[ -n "$XCODEPROJ" && -f "$XCODEPROJ/project.pbxproj" ]]; then
    SPM_COUNT=$(grep -cE "XCRemoteSwiftPackageReference|XCLocalSwiftPackageReference" \
        "$XCODEPROJ/project.pbxproj" 2>/dev/null || true)
    [[ "${SPM_COUNT:-0}" -gt 0 ]] && HAS_SPM=true
fi

# Info.plist
for plist in "$PROJECT_ROOT"/*/Info.plist "$PROJECT_ROOT"/Info.plist; do
    [[ -f "$plist" ]] && INFO_PLIST="$plist" && break
done

# SDK integration mode
SDK_MODE="unresolved"
SDK_EVIDENCE=()
SDK_CONFIDENCE="low"
if [[ -n "$PODFILE" ]] && grep -q "BlackBerryDynamics" "$PODFILE" 2>/dev/null; then
    SDK_MODE="cocoapods"
    SDK_EVIDENCE+=("BlackBerryDynamics found in Podfile")
    SDK_CONFIDENCE="high"
elif [[ -n "$XCODEPROJ" ]]; then
    if grep -qiE "BlackBerry-Dynamics-iOS-SDK|blackberry-dynamics-ios-sdk" \
        "$XCODEPROJ/project.pbxproj" 2>/dev/null; then
        SDK_MODE="spm"
        SDK_EVIDENCE+=("Official BlackBerry-Dynamics-iOS-SDK SPM reference in project.pbxproj")
        SDK_CONFIDENCE="high"
    elif find "$PROJECT_ROOT" -maxdepth 4 -name "BlackBerryDynamics.xcframework" 2>/dev/null | grep -q .; then
        SDK_MODE="manual"
        SDK_EVIDENCE+=("BlackBerryDynamics.xcframework found manually")
        SDK_CONFIDENCE="medium"
    fi
fi
if [[ ${#SDK_EVIDENCE[@]} -eq 0 ]]; then
    SDK_EVIDENCE+=("No Dynamics SDK integration detected — run prompt 01 to add it")
fi

# Build entrypoint
BUILD_ENTRYPOINT_TYPE="unresolved"
BUILD_ENTRYPOINT_PATH=""
BUILD_ENTRYPOINT_REASON="Could not determine"
if [[ -z "$XCWORKSPACE" && -n "$XCODEPROJ" ]]; then
    BUILD_ENTRYPOINT_TYPE="project"
    BUILD_ENTRYPOINT_PATH="$(basename "$XCODEPROJ")"
    BUILD_ENTRYPOINT_REASON="Only .xcodeproj present"
elif [[ -n "$XCWORKSPACE" && -n "$PODFILE" ]]; then
    BUILD_ENTRYPOINT_TYPE="workspace"
    BUILD_ENTRYPOINT_PATH="$(basename "$XCWORKSPACE")"
    BUILD_ENTRYPOINT_REASON=".xcworkspace + Podfile detected"
elif [[ -n "$XCWORKSPACE" && -n "$XCODEPROJ" ]]; then
    BUILD_ENTRYPOINT_TYPE="project"
    BUILD_ENTRYPOINT_PATH="$(basename "$XCODEPROJ")"
    BUILD_ENTRYPOINT_REASON=".xcworkspace without Podfile; using .xcodeproj"
elif [[ -n "$XCWORKSPACE" ]]; then
    BUILD_ENTRYPOINT_TYPE="workspace"
    BUILD_ENTRYPOINT_PATH="$(basename "$XCWORKSPACE")"
    BUILD_ENTRYPOINT_REASON="Only .xcworkspace present"
fi

# Scheme detection (non-blocking — recorded as unresolved if absent)
SCHEME_NAME="$USER_SCHEME"
SCHEME_RESOLVED="false"
SCHEME_RESOLUTION_METHOD="not-attempted"
if [[ -n "$SCHEME_NAME" ]]; then
    SCHEME_RESOLVED="true"
    SCHEME_RESOLUTION_METHOD="user-provided"
fi

# Source control baseline
SC_COMMIT=""
SC_BRANCH=""
SC_DIRTY="false"
if ! command -v git &>/dev/null; then
    echo -e "${RED}ERROR${NC}: git is not installed or not on PATH." >&2
    echo "Install Git, then rerun 00pre." >&2
    exit 1
fi
if ! git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    echo -e "${RED}ERROR${NC}: Git baseline missing — iOS migrations require a Git repository." >&2
    echo "Re-run prompt 00pre. It must ask for explicit developer consent, then run:" >&2
    echo "  bash dynamics-migration-tool/tooling/lib/ensure-git-baseline.sh --consented" >&2
    exit 1
fi
if ! git -C "$PROJECT_ROOT" rev-parse --verify HEAD &>/dev/null 2>&1; then
    echo -e "${RED}ERROR${NC}: Git baseline missing — repository has no commit." >&2
    echo "Re-run prompt 00pre. It must ask for explicit developer consent, then run:" >&2
    echo "  bash dynamics-migration-tool/tooling/lib/ensure-git-baseline.sh --consented" >&2
    echo "" >&2
    echo "If Git identity is missing, configure a local identity for this migration app:" >&2
    echo "  git config user.name \"Your Name\"" >&2
    echo "  git config user.email \"you@example.com\"" >&2
    echo "Or configure a global identity:" >&2
    echo "  git config --global user.name \"Your Name\"" >&2
    echo "  git config --global user.email \"you@example.com\"" >&2
    echo "No Git remote, GitHub account, or network access is required." >&2
    exit 1
fi

SC_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")
SC_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
SC_STATUS=$(
    git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all 2>/dev/null \
        | python3 -c 'import sys
ignored = ("dynamics-migration-tool/", ".cursor/", ".kiro/")
for line in sys.stdin:
    path = line[3:].strip()
    if path == "AGENTS.md" or path.startswith(ignored):
        continue
    print(line, end="")'
)
if [[ -n "$SC_STATUS" ]]; then
    SC_DIRTY="true"
fi

# GDApplicationID from Info.plist (if present — provenance noted)
GD_APP_ID=""
GD_APP_VERSION=""
UEM_PROVENANCE="not-set"
if [[ -n "$INFO_PLIST" ]]; then
    GD_APP_ID=$(python3 -c "
import plistlib, sys
try:
    with open('$INFO_PLIST', 'rb') as f:
        d = plistlib.load(f)
    print(d.get('GDApplicationID', ''))
except:
    print('')
" 2>/dev/null || echo "")
    GD_APP_VERSION=$(python3 -c "
import plistlib, sys
try:
    with open('$INFO_PLIST', 'rb') as f:
        d = plistlib.load(f)
    print(d.get('GDApplicationVersion', ''))
except:
    print('')
" 2>/dev/null || echo "")
    if [[ -n "$GD_APP_ID" ]]; then
        UEM_PROVENANCE="inferred-from-plist"
    fi
fi

# ──────────────────────────────────────────────────────────────────
# 3. Write bootstrap.json
# ──────────────────────────────────────────────────────────────────

SDK_EVIDENCE_JSON=$(python3 -c "
import json, sys
evidence = sys.argv[1:]
print(json.dumps(evidence))
" "${SDK_EVIDENCE[@]}")

SCHEME_NAME_JSON="None"
if [[ -n "$SCHEME_NAME" ]]; then
    SCHEME_NAME_JSON=$(python3 - <<PYEOF
import json
print(json.dumps("$SCHEME_NAME"))
PYEOF
)
fi

python3 - <<PYEOF
import json, pathlib

bootstrap = {
    "schemaVersion": "$SCHEMA_VERSION",
    "platform": "ios",
    "toolkitVersion": "$TOOL_VERSION",
    "runId": "$RUN_ID",
    "createdAt": "$CREATED_AT",
    "projectRoot": "$PROJECT_ROOT",
    "outputDirectory": "$OUTPUT_DIR",
    "buildEntrypoint": {
        "type": "$BUILD_ENTRYPOINT_TYPE",
        "path": "$BUILD_ENTRYPOINT_PATH",
        "reason": "$BUILD_ENTRYPOINT_REASON",
    },
    "sdkIntegration": {
        "mode": "$SDK_MODE",
        "evidence": $SDK_EVIDENCE_JSON,
        "confidence": "$SDK_CONFIDENCE",
    },
    "buildScheme": {
        "resolved": "$SCHEME_RESOLVED" == "true",
        "name": $SCHEME_NAME_JSON,
        "resolutionMethod": "$SCHEME_RESOLUTION_METHOD",
    },
    "uemValues": {
        "gdApplicationId": "$GD_APP_ID" if "$GD_APP_ID" else None,
        "gdApplicationVersion": "$GD_APP_VERSION" if "$GD_APP_VERSION" else None,
        "applicationSetupType": None,
        "provenance": "$UEM_PROVENANCE",
    },
    "developerAttestations": {
        "confirmedCleanBuild": "not-asked",
        "confirmedSourceControlBaseline": "not-asked",
        "notes": [],
    },
    "sourceControl": {
        "commit": "$SC_COMMIT",
        "branch": "$SC_BRANCH",
        "isDirty": "$SC_DIRTY" == "true",
    },
    "lifecycleCandidates": [],
    "backgroundCandidates": [],
    "extensionCandidates": [],
    "agentType": "$AGENT",
    "executedPrompts": [],
    "provenance": {
        "generatedBy": "tooling/bootstrap.sh",
        "toolkitVersion": "$TOOL_VERSION",
    },
}

out = json.dumps(bootstrap, indent=2, ensure_ascii=False)
pathlib.Path("$OUTPUT_DIR/bootstrap.json").write_text(out, encoding="utf-8")
print("OK")
PYEOF

echo -e "  ${GREEN}✓${NC} bootstrap.json written (runId: $RUN_ID)"

# ──────────────────────────────────────────────────────────────────
# 4. Run target discovery
# ──────────────────────────────────────────────────────────────────

if [[ -f "$LIB_DIR/discover-targets.py" ]]; then
    DISCOVER_OUTPUT=""
    DISCOVER_EXIT=0
    DISCOVER_OUTPUT=$(python3 "$LIB_DIR/discover-targets.py" \
        --project-root "$PROJECT_ROOT" \
        --run-id "$RUN_ID" \
        --output "$OUTPUT_DIR/target-map.json" 2>&1) || DISCOVER_EXIT=$?
    if [[ $DISCOVER_EXIT -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC} target-map.json written"
        echo "$DISCOVER_OUTPUT" | while IFS= read -r line; do
            [[ "$line" == OK:* ]] && continue
            echo -e "  ${YELLOW}○${NC} $line"
        done
    else
        echo -e "  ${YELLOW}WARNING${NC}: target discovery reported issues:"
        echo "$DISCOVER_OUTPUT" | while IFS= read -r line; do
            echo -e "    $line"
        done
        # Write a minimal target-map so downstream steps don't fail on missing artifact
        python3 -c "
import json, pathlib, time
fallback = {
    'schemaVersion': '1.0.0',
    'platform': 'ios',
    'runId': '$RUN_ID',
    'generatedAt': '$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")',
    'projectRoot': '$PROJECT_ROOT',
    'buildEntrypoint': {'type': 'unresolved', 'path': None, 'reason': 'discovery failed'},
    'targets': [],
    'packageManager': {'hasPodfile': False, 'podfilePath': None, 'hasSpmDependencies': False, 'spmCount': 0},
    'ambiguities': ['Target discovery failed — re-run after fixing the project structure'],
    'provenance': {'discoveryMethod': 'fallback', 'requiresXcodebuild': False},
}
pathlib.Path('$OUTPUT_DIR/target-map.json').write_text(
    json.dumps(fallback, indent=2, ensure_ascii=False), encoding='utf-8'
)
"
        echo -e "  ${YELLOW}○${NC} Fallback target-map.json written (targets array is empty)"
    fi
else
    echo -e "  ${YELLOW}WARNING${NC}: lib/discover-targets.py not found — target-map skipped"
fi

echo ""
echo -e "${GREEN}Bootstrap complete.${NC} Run ID: ${BOLD}${RUN_ID}${NC}"
echo -e "Bootstrap artifacts:"
echo -e "  output/bootstrap.json"
echo -e "  output/target-map.json"
