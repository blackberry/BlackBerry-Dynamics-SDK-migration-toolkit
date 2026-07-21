#!/usr/bin/env bash
# BlackBerry Dynamics iOS Migration Tool — Setup Script
# Prepares an iOS project for AI-assisted migration to BlackBerry Dynamics.

# If invoked via `sh`, re-exec with bash.
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
if shopt -oq posix; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Defaults
AGENT="generic"
USER_SCHEME=""
SKIP_BUILD=true
# shellcheck source=lib/toolkit-version.sh
. "$SCRIPT_DIR/lib/toolkit-version.sh"
toolkit_version_load "$TOOL_DIR"

usage() {
    echo "Usage: $0 [--agent kiro|cursor|generic] [--scheme SchemeName] [--verify-build] [--skip-build-check] [--version] [--help]"
    echo ""
    echo "Options:"
    echo "  --agent kiro             Install steering files into .kiro/steering/"
    echo "  --agent cursor           Install steering files into .cursor/rules/"
    echo "  --agent generic          Print instructions for any AI agent (default)"
    echo "  --scheme SchemeName      Xcode scheme to build (used with --verify-build)"
    echo "  --verify-build           Run optional pre-flight compile verification"
    echo "  --skip-build-check       Backward-compatible no-op (build check is skipped by default)"
    echo "  --version                Show toolkit version"
    echo "  --help                   Show this help message"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)
            AGENT="$2"
            shift 2
            ;;
        --scheme)
            USER_SCHEME="$2"
            shift 2
            ;;
        --verify-build)
            SKIP_BUILD=false
            shift
            ;;
        --skip-build-check)
            SKIP_BUILD=true
            shift
            ;;
        --version)
            toolkit_version_print
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            exit 1
            ;;
    esac
done

echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}  BlackBerry Dynamics iOS Migration Tool${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Toolkit Version: ${BOLD}${TOOL_VERSION}${NC}"
echo -e "${BLUE}Supported Dynamics SDK: ${BOLD}${SUPPORTED_SDK_VERSION}${NC}"
echo ""

# ──────────────────────────────────────────────────────────────────
# 1. Verify iOS project structure
# ──────────────────────────────────────────────────────────────────
echo -e "${CYAN}[1/6] Verifying iOS project structure...${NC}"

XCWORKSPACE=""
XCODEPROJ=""
PODFILE=""
SPM_REFERENCE_COUNT=0
HAS_SPM_REFERENCES=false
INFO_PLIST=""
WORKSPACE_SHARED_SCHEME_COUNT=0
PROJECT_SHARED_SCHEME_COUNT=0
BUILD_ENTRYPOINT=""
BUILD_ENTRYPOINT_REASON=""

# Find .xcworkspace
for ws in "$PROJECT_ROOT"/*.xcworkspace; do
    if [[ -d "$ws" ]]; then
        XCWORKSPACE="$ws"
        break
    fi
done

# Find .xcodeproj
for proj in "$PROJECT_ROOT"/*.xcodeproj; do
    if [[ -d "$proj" ]]; then
        XCODEPROJ="$proj"
        break
    fi
done

# Find Podfile
if [[ -f "$PROJECT_ROOT/Podfile" ]]; then
    PODFILE="$PROJECT_ROOT/Podfile"
fi

# Detect SPM usage from Xcode project (Package.swift is NOT required)
if [[ -n "$XCODEPROJ" ]]; then
    PBXPROJ="$XCODEPROJ/project.pbxproj"
    if [[ -f "$PBXPROJ" ]]; then
        # grep -c prints "0" when no matches are found but exits with status 1;
        # avoid appending an extra fallback "0" that breaks numeric comparisons.
        SPM_REFERENCE_COUNT=$(grep -cE "XCRemoteSwiftPackageReference|XCLocalSwiftPackageReference" "$PBXPROJ" 2>/dev/null || true)
        if [[ "${SPM_REFERENCE_COUNT:-0}" -gt 0 ]]; then
            HAS_SPM_REFERENCES=true
        fi
    fi
fi

# Detect shared schemes in workspace/project
if [[ -n "$XCWORKSPACE" && -d "$XCWORKSPACE/xcshareddata/xcschemes" ]]; then
    shopt -s nullglob
    workspace_schemes=( "$XCWORKSPACE/xcshareddata/xcschemes/"*.xcscheme )
    WORKSPACE_SHARED_SCHEME_COUNT=${#workspace_schemes[@]}
    shopt -u nullglob
fi
if [[ -n "$XCODEPROJ" && -d "$XCODEPROJ/xcshareddata/xcschemes" ]]; then
    shopt -s nullglob
    project_schemes=( "$XCODEPROJ/xcshareddata/xcschemes/"*.xcscheme )
    PROJECT_SHARED_SCHEME_COUNT=${#project_schemes[@]}
    shopt -u nullglob
fi

# Find Info.plist (common locations)
for plist in "$PROJECT_ROOT"/*/Info.plist "$PROJECT_ROOT"/Info.plist; do
    if [[ -f "$plist" ]]; then
        INFO_PLIST="$plist"
        break
    fi
done

if [[ -z "$XCODEPROJ" && -z "$XCWORKSPACE" ]]; then
    echo -e "${RED}ERROR: No .xcodeproj or .xcworkspace found in $PROJECT_ROOT${NC}"
    echo "This tool must be run from the root of an iOS project."
    echo "Copy dynamics-migration-tool/ into your project root and try again."
    exit 1
fi

# Build entrypoint selection rule:
# - Only .xcodeproj -> project
# - .xcworkspace + Podfile -> workspace
# - .xcworkspace without Podfile -> project (if available), unless workspace has shared schemes
# - .xcworkspace + shared schemes -> workspace
if [[ -z "$XCWORKSPACE" && -n "$XCODEPROJ" ]]; then
    BUILD_ENTRYPOINT="project"
    BUILD_ENTRYPOINT_REASON="Only .xcodeproj present"
elif [[ -n "$XCWORKSPACE" && -n "$PODFILE" ]]; then
    BUILD_ENTRYPOINT="workspace"
    BUILD_ENTRYPOINT_REASON=".xcworkspace + Podfile detected"
elif [[ -n "$XCWORKSPACE" && "${WORKSPACE_SHARED_SCHEME_COUNT:-0}" -gt 0 ]]; then
    BUILD_ENTRYPOINT="workspace"
    BUILD_ENTRYPOINT_REASON="Workspace has shared schemes (${WORKSPACE_SHARED_SCHEME_COUNT})"
elif [[ -n "$XCWORKSPACE" && -n "$XCODEPROJ" ]]; then
    BUILD_ENTRYPOINT="project"
    BUILD_ENTRYPOINT_REASON=".xcworkspace without Podfile/shared schemes; using .xcodeproj"
elif [[ -n "$XCWORKSPACE" ]]; then
    BUILD_ENTRYPOINT="workspace"
    BUILD_ENTRYPOINT_REASON="Only .xcworkspace present"
fi

echo -e "  ${GREEN}✓${NC} Xcode project: ${XCODEPROJ:-$XCWORKSPACE}"
[[ -n "$PODFILE" ]] && echo -e "  ${GREEN}✓${NC} Podfile found"
if $HAS_SPM_REFERENCES; then
    echo -e "  ${GREEN}✓${NC} SPM package references found in project.pbxproj (${SPM_REFERENCE_COUNT})"
else
    echo -e "  ${YELLOW}○${NC} No SPM package references found in project.pbxproj"
fi
[[ -n "$INFO_PLIST" ]] && echo -e "  ${GREEN}✓${NC} Info.plist: $INFO_PLIST"
[[ -z "$INFO_PLIST" ]] && echo -e "  ${YELLOW}○${NC} Info.plist not found (will be located during migration)"
[[ -n "$XCWORKSPACE" ]] && echo -e "  ${BLUE}ℹ${NC} Workspace shared schemes: ${WORKSPACE_SHARED_SCHEME_COUNT}"
[[ -n "$XCODEPROJ" ]] && echo -e "  ${BLUE}ℹ${NC} Project shared schemes: ${PROJECT_SHARED_SCHEME_COUNT}"
echo -e "  ${BLUE}ℹ${NC} Build entrypoint: ${BUILD_ENTRYPOINT} (${BUILD_ENTRYPOINT_REASON})"

# Integration method hint (matrix)
if [[ -n "$PODFILE" ]] && $HAS_SPM_REFERENCES; then
    echo -e "  ${BLUE}ℹ${NC} Dependency topology: mixed CocoaPods + SPM (Dynamics integration should use official SPM: https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK)"
elif [[ -n "$PODFILE" ]]; then
    echo -e "  ${BLUE}ℹ${NC} Dependency topology: CocoaPods-only (Dynamics integration should use CocoaPods)"
elif $HAS_SPM_REFERENCES; then
    echo -e "  ${BLUE}ℹ${NC} Dependency topology: SPM-only (Dynamics integration should use official SPM: https://github.com/blackberry/BlackBerry-Dynamics-iOS-SDK)"
else
    echo -e "  ${YELLOW}○${NC} No Podfile/SPM references (manual framework integration path)"
fi

# ──────────────────────────────────────────────────────────────────
# 2. Check for existing Dynamics integration
# ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}[2/6] Checking for existing Dynamics integration...${NC}"

ALREADY_INTEGRATED=false

if [[ -n "$PODFILE" ]] && grep -q "BlackBerryDynamics" "$PODFILE" 2>/dev/null; then
    echo -e "  ${YELLOW}⚠${NC} BlackBerryDynamics pod already in Podfile"
    ALREADY_INTEGRATED=true
fi

if [[ -n "$INFO_PLIST" ]] && grep -q "GDApplicationID" "$INFO_PLIST" 2>/dev/null; then
    echo -e "  ${YELLOW}⚠${NC} GDApplicationID already in Info.plist"
    ALREADY_INTEGRATED=true
fi

if grep -rq "import BlackBerryDynamics\|GDiOS\|GDFileManager" "$PROJECT_ROOT" \
    --include="*.swift" --include="*.m" --include="*.h" 2>/dev/null; then
    echo -e "  ${YELLOW}⚠${NC} Dynamics imports found in source files"
    ALREADY_INTEGRATED=true
fi

if $ALREADY_INTEGRATED; then
    echo -e "  ${YELLOW}This project may already have some Dynamics integration.${NC}"
    echo -e "  ${YELLOW}The migration tool will still work — it will identify gaps.${NC}"
else
    echo -e "  ${GREEN}✓${NC} No existing Dynamics integration detected"
fi

# ──────────────────────────────────────────────────────────────────
# 3. Check prerequisites
# ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}[3/6] Checking prerequisites...${NC}"

if command -v xcodebuild &>/dev/null; then
    XCODE_VERSION=$(xcodebuild -version 2>/dev/null | head -1 || echo "unknown")
    echo -e "  ${GREEN}✓${NC} Xcode: $XCODE_VERSION"
else
    echo -e "  ${RED}✗${NC} Xcode command-line tools not found"
    echo "    Install with: xcode-select --install"
fi

if command -v pod &>/dev/null; then
    POD_VERSION=$(pod --version 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}✓${NC} CocoaPods: $POD_VERSION"
else
    if [[ -n "$PODFILE" ]] && ! $HAS_SPM_REFERENCES; then
        echo -e "  ${YELLOW}○${NC} CocoaPods not installed (needed for CocoaPods-only integration)"
        echo "    Install with: sudo gem install cocoapods"
    else
        echo -e "  ${BLUE}ℹ${NC} CocoaPods not installed (not required for SPM/manual-first topology)"
    fi
fi

# ──────────────────────────────────────────────────────────────────
# 4. Optional pre-flight build verification
# Developers are expected to start migration from a clean build.
# Use --verify-build to run a compile check in this script.
# ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}[4/6] Build verification...${NC}"

if $SKIP_BUILD; then
    echo -e "  ${BLUE}ℹ${NC} Skipping compile check (default behavior)."
    echo -e "  ${BLUE}ℹ${NC} Run with --verify-build to execute an unsigned simulator compile check."
else
    echo -e "  ${BLUE}ℹ${NC} Running optional compile check (--verify-build)"
    # Resolve scheme: user-provided > interactive selection
    SCHEME="$USER_SCHEME"
    TARGET=""
    BUILD_MODE="scheme"
    LIST_OUTPUT=""
    if [[ "$BUILD_ENTRYPOINT" == "workspace" && -n "$XCWORKSPACE" ]]; then
        LIST_OUTPUT="$(xcodebuild -workspace "$XCWORKSPACE" -list 2>/dev/null || true)"
    elif [[ "$BUILD_ENTRYPOINT" == "project" && -n "$XCODEPROJ" ]]; then
        LIST_OUTPUT="$(xcodebuild -project "$XCODEPROJ" -list 2>/dev/null || true)"
    fi

    AVAILABLE_SCHEMES=()
    while IFS= read -r scheme_line; do
        [[ -n "$scheme_line" ]] && AVAILABLE_SCHEMES+=("$scheme_line")
    done <<EOF
$(printf "%s\n" "$LIST_OUTPUT" | awk '
    /^[[:space:]]*Schemes:/ { in_schemes=1; next }
    in_schemes && NF {
        line=$0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line != "") print line
    }
')
EOF

    if [[ "${#AVAILABLE_SCHEMES[@]}" -gt 0 && -n "$SCHEME" ]]; then
        MATCHED=false
        for s in "${AVAILABLE_SCHEMES[@]}"; do
            if [[ "$s" == "$SCHEME" ]]; then
                MATCHED=true
                break
            fi
        done
        if ! $MATCHED; then
            echo ""
            echo -e "${RED}${BOLD}Provided scheme not found: '$SCHEME'${NC}"
            echo -e "${BOLD}Available schemes:${NC}"
            for i in "${!AVAILABLE_SCHEMES[@]}"; do
                printf "  %2d) %s\n" $((i + 1)) "${AVAILABLE_SCHEMES[$i]}"
            done
            echo ""
            echo -e "${BOLD}Re-run with one of the schemes above:${NC}"
            echo "  $0 --agent $AGENT --scheme \"Exact Scheme Name\""
            exit 1
        fi
    fi

    if [[ "${#AVAILABLE_SCHEMES[@]}" -gt 0 && -z "$SCHEME" ]]; then
        echo -e "  ${BLUE}ℹ${NC} Available schemes:"
        for i in "${!AVAILABLE_SCHEMES[@]}"; do
            printf "    %2d) %s\n" $((i + 1)) "${AVAILABLE_SCHEMES[$i]}"
        done

        if [[ "${#AVAILABLE_SCHEMES[@]}" -eq 1 ]]; then
            SCHEME="${AVAILABLE_SCHEMES[0]}"
            echo -e "  ${BLUE}ℹ${NC} Single scheme detected, using: ${BOLD}$SCHEME${NC}"
        elif [[ -t 0 ]]; then
            echo ""
            while true; do
                read -r -p "  Select scheme number for compile check: " scheme_idx
                if [[ "$scheme_idx" =~ ^[0-9]+$ ]] && (( scheme_idx >= 1 && scheme_idx <= ${#AVAILABLE_SCHEMES[@]} )); then
                    SCHEME="${AVAILABLE_SCHEMES[$((scheme_idx - 1))]}"
                    break
                fi
                echo "  Invalid selection. Enter a number from 1 to ${#AVAILABLE_SCHEMES[@]}."
            done
        else
            echo ""
            echo -e "${YELLOW}Multiple schemes detected in non-interactive mode.${NC}"
            echo -e "${BOLD}Please re-run with:${NC}"
            echo "  $0 --agent $AGENT --scheme \"Exact Scheme Name\""
            exit 1
        fi
    fi

    if [[ "${#AVAILABLE_SCHEMES[@]}" -eq 0 ]]; then
        # Fallback: project may not expose shared schemes; allow target selection.
        AVAILABLE_TARGETS=()
        while IFS= read -r target_line; do
            [[ -n "$target_line" ]] && AVAILABLE_TARGETS+=("$target_line")
        done <<EOF
$(printf "%s\n" "$LIST_OUTPUT" | awk '
    /^[[:space:]]*Targets:/ { in_targets=1; next }
    in_targets && /^[[:space:]]*Build Configurations:/ { in_targets=0 }
    in_targets && NF {
        line=$0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line != "") print line
    }
')
EOF

        if [[ "${#AVAILABLE_TARGETS[@]}" -eq 0 ]]; then
            echo ""
            echo -e "${RED}${BOLD}═══════════════════════════════════════════════════════════${NC}"
            echo -e "${RED}${BOLD}  SCHEME/TARGET NOT FOUND — Migration cannot proceed${NC}"
            echo -e "${RED}${BOLD}═══════════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "${RED}Could not detect buildable schemes or targets.${NC}"
            echo -e "${BOLD}List available entries with:${NC}"
            if [[ "$BUILD_ENTRYPOINT" == "workspace" && -n "$XCWORKSPACE" ]]; then
                echo "  xcodebuild -workspace \"$XCWORKSPACE\" -list"
            elif [[ "$BUILD_ENTRYPOINT" == "project" && -n "$XCODEPROJ" ]]; then
                echo "  xcodebuild -project \"$XCODEPROJ\" -list"
            fi
            exit 1
        fi

        echo -e "  ${YELLOW}No shared schemes found. Falling back to target selection.${NC}"
        echo -e "  ${BLUE}ℹ${NC} Available targets:"
        for i in "${!AVAILABLE_TARGETS[@]}"; do
            printf "    %2d) %s\n" $((i + 1)) "${AVAILABLE_TARGETS[$i]}"
        done

        if [[ "${#AVAILABLE_TARGETS[@]}" -eq 1 ]]; then
            TARGET="${AVAILABLE_TARGETS[0]}"
        elif [[ -t 0 ]]; then
            echo ""
            while true; do
                read -r -p "  Select target number for compile check: " target_idx
                if [[ "$target_idx" =~ ^[0-9]+$ ]] && (( target_idx >= 1 && target_idx <= ${#AVAILABLE_TARGETS[@]} )); then
                    TARGET="${AVAILABLE_TARGETS[$((target_idx - 1))]}"
                    break
                fi
                echo "  Invalid selection. Enter a number from 1 to ${#AVAILABLE_TARGETS[@]}."
            done
        else
            echo ""
            echo -e "${YELLOW}Multiple targets detected in non-interactive mode.${NC}"
            echo -e "${BOLD}Re-run with a shared scheme using:${NC}"
            echo "  $0 --agent $AGENT --scheme \"Exact Scheme Name\""
            exit 1
        fi

        BUILD_MODE="target"
    fi

    if [[ "$BUILD_MODE" == "scheme" ]]; then
        echo -e "  Scheme: ${BOLD}$SCHEME${NC}"
    else
        echo -e "  Target: ${BOLD}$TARGET${NC}"
    fi
    echo -e "  Running compile check (this may take a moment)..."

# Build for compile check only — always use unsigned simulator mode to avoid
# provisioning profile churn during AI-driven migration checks.
    BUILD_CMD=""
    if [[ "$BUILD_ENTRYPOINT" == "workspace" && -n "$XCWORKSPACE" ]]; then
        if [[ "$BUILD_MODE" == "scheme" ]]; then
            BUILD_CMD="xcodebuild -workspace \"$XCWORKSPACE\" -scheme \"$SCHEME\" -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build -quiet"
        else
            BUILD_CMD="xcodebuild -workspace \"$XCWORKSPACE\" -target \"$TARGET\" -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build -quiet"
        fi
    elif [[ "$BUILD_ENTRYPOINT" == "project" && -n "$XCODEPROJ" ]]; then
        if [[ "$BUILD_MODE" == "scheme" ]]; then
            BUILD_CMD="xcodebuild -project \"$XCODEPROJ\" -scheme \"$SCHEME\" -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build -quiet"
        else
            BUILD_CMD="xcodebuild -project \"$XCODEPROJ\" -target \"$TARGET\" -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build -quiet"
        fi
    fi

    if eval "$BUILD_CMD" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Project compiles successfully — safe to migrate"
    else
        echo ""
        echo -e "${RED}${BOLD}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}${BOLD}  BUILD FAILED — Migration cannot proceed${NC}"
        echo -e "${RED}${BOLD}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${RED}The project does not compile in its current state.${NC}"
        echo -e "${RED}Fix all compile errors BEFORE running the migration tool.${NC}"
        echo ""
        echo -e "${BOLD}To see the full build errors, run:${NC}"
        echo "  ${BUILD_CMD//\\}"
        echo ""
        echo -e "${BOLD}Common causes:${NC}"
        echo "  • Missing or outdated dependencies — run: pod install"
        echo "  • Xcode version mismatch — check: xcodebuild -version"
        echo "  • Swift/Obj-C compile errors in existing source code"
        echo ""
        echo -e "${YELLOW}Once the project compiles cleanly, re-run: $0 --agent $AGENT --scheme $SCHEME${NC}"
        exit 1
    fi
fi

# ──────────────────────────────────────────────────────────────────
# 5. Install steering files
# ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}[5/6] Installing steering files for agent: ${BOLD}$AGENT${NC}"

install_steering() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    cp "$TOOL_DIR"/steering/*.md "$dest_dir/"
    echo -e "  ${GREEN}✓${NC} Steering files copied to $dest_dir/"
}

case "$AGENT" in
    kiro)
        install_steering "$PROJECT_ROOT/.kiro/steering"
        ;;
    cursor)
        install_steering "$PROJECT_ROOT/.cursor/rules"
        ;;
    generic)
        echo -e "  ${BLUE}ℹ${NC} Generic agent mode — steering files remain in dynamics-migration-tool/steering/"
        echo -e "  ${BLUE}ℹ${NC} Feed them as context to your AI agent manually"
        ;;
    *)
        echo -e "${RED}Unknown agent: $AGENT${NC}"
        usage
        exit 1
        ;;
esac

# ──────────────────────────────────────────────────────────────────
# 6. Print migration instructions
# ──────────────────────────────────────────────────────────────────
print_ready_prompt() {
    local prompts_ref="dynamics-migration-tool/prompts"
    local steering_ref="dynamics-migration-tool/steering"
    if [[ "$AGENT" == "cursor" ]]; then
        prompts_ref="@dynamics-migration-tool/prompts"
        steering_ref="@dynamics-migration-tool/steering"
    fi

    cat <<PROMPT
I need to migrate this iOS app to BlackBerry Dynamics. The migration tool
is in dynamics-migration-tool/.

Read the migration prompts in $prompts_ref and execute them in this order:
00pre, 00, 00b, 01, 02, 03, 03b, 04, 04b, 05, 06, 07, 08, 09, 09b, 11, 10.
Optional after acceptance: 12.

For each prompt, read the prompt file and its referenced steering files in
$steering_ref. Always include 00-context.md, 06-inline-migration-comments.md,
14-api-provenance-and-replacement-catalog.md,
79-migration-plan-state-and-call-site-closure.md, and
96-repair-loop-conduct.md (optional bounded repair lane).

Start with 00pre-bootstrap.md. Do not proceed until
dynamics-migration-tool/output/bootstrap.json and
dynamics-migration-tool/output/target-map.json exist, are valid JSON, and
share the same runId.

Then run 00-analyze-app.md. Do not make application code changes until the
analysis and migration plan are complete and I have reviewed them.

After I approve the plan, continue through each applicable prompt
sequentially. Use documented Dynamics APIs only; do not invent APIs or stop
at findings that have cataloged replacements. For genuine product/security
ambiguity, ask me before choosing a direction.

iOS API guardrails: do not invent GDURLSession, GDPersistentContainer, or
GDSqlDatabase. Use cataloged public surfaces such as GDURLLoadingSystem,
GDSocket, GDPersistentStoreCoordinator, GDEncryptedBinaryStoreType,
GDEncryptedIncrementalStoreType, sqlite3enc_*, GDFileManager, GDFileHandle,
GDCReadStream/GDCWriteStream, and
GDNativePasteboardAccess.performActionOnNativePasteboard:.

Validation and recording contract:
- Prompt 00pre uses validate.sh --preflight, then record prompt 00pre.
- Prompts with no validator mode, such as 00 and 00b, do not need validation
  proof before recording, but their required artifacts must exist.
- Prompt-scoped prompts use validate.sh --check-prompt <prompt-id>, then
  record the prompt.
- Use --status completed for completed prompts.
- Use --status not-applicable only when prompt 00's executionPlan marks the
  prompt's owned domain not applicable and the prompt registry allows it.
- Do not edit bootstrap.json.executedPrompts[] or migration-plan-state.json by
  hand.

If validation or recording fails, fix the underlying source, generated
artifact, or closure-ledger evidence and rerun the same command. Do not patch
state files or validator output to bypass a gate.

When stuck: run dynamics-migration-tool/tooling/progress.sh, then repair the
owning prompt/domain. Do not thrash prompt 10 or re-run unrelated prompts to
clear a gate. If the recorder/validator prints ESCALATION REQUIRED (exit
code 3), STOP and ask the developer. Optional bounded repair for controlled
implementation/config prompts:
bash dynamics-migration-tool/tooling/repair-orchestrator.sh --prompt-id <id>
(obey exit 0/1/3; see steering/96-repair-loop-conduct.md). Prompt 10 stays
recorder-owned.

Prompt 10 is the final acceptance gate. Follow prompt 10's order: write a
schema-valid draft report after its prerequisite gate passes, run full
validation, fix any failures with full-file overwrite, then record prompt 10
completion. After prompt 10, generate the toolkit beta-feedback artifact with
dynamics-migration-tool/tooling/generate-tool-analysis-report.sh.
PROMPT
}

echo ""
echo -e "${CYAN}[6/6] Ready to migrate!${NC}"
echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Setup Complete${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Migration prompts are in: ${BOLD}dynamics-migration-tool/prompts/${NC}"
echo ""
echo -e "${BOLD}Prompt order:${NC}"
echo "  00pre — Bootstrap (REQUIRED FIRST — establishes run provenance)"
echo "  00  — Analyze app (REQUIRED, no code changes)"
echo "  00b — Generate architecture diagrams (REQUIRED)"
echo "  01  — Xcode integration (REQUIRED)"
echo "  02  — Configure Info.plist (REQUIRED — will ask for GDApplicationID)"
echo "  03  — Add Dynamics authorization (REQUIRED)"
echo "  03b — Authorization deferral audit (REQUIRED)"
echo "  04  — Migrate SQLite to encrypted (if applicable)"
echo "  04b — Migrate Core Data to encrypted (if applicable)"
echo "  05  — Migrate file storage (if applicable)"
echo "  06  — Migrate networking (if applicable)"
echo "  07  — Migrate WKWebView (if applicable)"
echo "  08  — Add AppKinetics ICC (if applicable)"
echo "  09  — Migrate external data movement and DLP (if applicable)"
echo "  09b — Migrate managed policy chain (if applicable)"
echo "  11  — Push channel audit/migration decisions (if applicable)"
echo "  10  — Generate migration report (REQUIRED)"
echo "  12  — Generate migration retrospective (OPTIONAL, post-10)"
echo ""

# Ready-to-paste prompt
echo -e "${BOLD}${CYAN}Ready-to-paste prompt for your AI agent:${NC}"
echo -e "${BOLD}────────────────────────────────────────${NC}"
print_ready_prompt
echo -e "${BOLD}────────────────────────────────────────${NC}"
echo ""
echo -e "${BOLD}Prompt order (updated):${NC}"
echo "  00pre — Bootstrap (REQUIRED FIRST — writes bootstrap.json + target-map.json)"
echo "  00    — Analyze app (REQUIRED, no code changes)"
echo "  00b   — Generate architecture diagrams (REQUIRED)"
echo "  01    — Xcode integration (REQUIRED)"
echo "  02    — Configure Info.plist (REQUIRED — will ask for GDApplicationID)"
echo "  03    — Add Dynamics authorization (REQUIRED)"
echo "  03b   — Authorization deferral audit (REQUIRED)"
echo "  04    — Migrate SQLite to encrypted (if applicable)"
echo "  04b   — Migrate Core Data to encrypted (if applicable)"
echo "  05    — Migrate file storage (if applicable)"
echo "  06    — Migrate networking (if applicable)"
echo "  07    — Migrate WKWebView (if applicable)"
echo "  08    — Add AppKinetics ICC (if applicable)"
echo "  09    — Migrate external data movement and DLP (if applicable)"
echo "  09b   — Migrate managed policy chain (if applicable)"
echo "  11    — Push channel audit/migration decisions (if applicable)"
echo "  10    — Generate migration report (REQUIRED)"
echo "  12    — Generate migration retrospective (OPTIONAL, post-10)"
echo ""
echo -e "Prompt-scoped validation uses: ${BOLD}bash ./dynamics-migration-tool/tooling/validate.sh --check-prompt <prompt-id>${NC}"
echo -e "Prompt 00pre preflight validation uses: ${BOLD}bash ./dynamics-migration-tool/tooling/validate.sh --preflight${NC}"
echo -e "Prompts 00 and 00b do not require validation proof before recording; their required artifacts must exist."
echo -e "Record each prompt after validation with: ${BOLD}bash ./dynamics-migration-tool/tooling/record-prompt-execution.sh --prompt-id <prompt-id> --status completed|not-applicable${NC}"
echo -e "  The recorder (record-prompt-execution.sh) is the only writer of bootstrap.json executedPrompts[]."
echo -e "  It enforces prerequisite gates from check-prompt-map.json before marking a prompt complete."
echo -e "Prompt 10 writes a schema-valid draft report, then runs full validation with: ${BOLD}bash ./dynamics-migration-tool/tooling/validate.sh${NC}"
echo -e "Generate toolkit analysis report for beta feedback with: ${BOLD}bash ./dynamics-migration-tool/tooling/generate-tool-analysis-report.sh${NC}"
echo -e "  (writes dynamics-migration-tool/output/tool-analysis-report.json)"
echo ""
