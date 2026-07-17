#!/usr/bin/env bash
# BlackBerry Dynamics Migration — changed-file detector for incremental validation.
#
# Emits the repo-relative paths that changed since a baseline, one per line,
# for tooling/lib/resolve-domains.py to map onto validator phases. The
# third-party developer never calls this directly — record-prompt-execution.sh
# and validate.sh --mode incremental use it internally.
#
# Usage (from the project root):
#   bash dynamics-migration-tool/tooling/lib/changed-files.sh since <baseline>
#   bash dynamics-migration-tool/tooling/lib/changed-files.sh checkpoint-write
#   bash dynamics-migration-tool/tooling/lib/changed-files.sh baseline-write
#
#   <baseline> ∈ { start | last-checkpoint | last-prompt }
#
# Output contract for `since`:
#   - Zero or more repo-relative paths (one per line), already filtered to
#     drop toolkit / agent-wiring noise (see git-working-tree.sh).
#   - The single token "UNKNOWN" (and exit 0) when the change set cannot be
#     determined safely. Callers MUST treat UNKNOWN as "fall back to a full
#     validation run" — never as "nothing changed".
#
# SAFETY: this detector intentionally OVER-approximates. Between migration
# prompts the agent's edits are usually uncommitted, so `since last-prompt`
# reports every uncommitted change (a superset of this prompt's edits). A
# superset only ever runs MORE phases, never fewer — it cannot hide a
# regression. The prompt-10 full sweep remains the mandatory final gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# changed-files.sh lives in tooling/lib/. TOOLING_DIR is tooling/, and
# TOOL_DIR is the dynamics-migration-tool/ root (which owns output/).
TOOLING_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
GIT_WORKING_TREE="$TOOLING_DIR/git-working-tree.sh"
CHECKPOINT_FILE="$TOOL_DIR/output/.validation-checkpoint.json"

CMD="${1:-since}"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch_ms() { python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0; }

git_available() {
    command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1
}

current_head_sha() {
    git rev-parse HEAD 2>/dev/null || echo ""
}

# Read a string field out of the checkpoint JSON (best effort).
checkpoint_field() {
    local key="$1"
    [ -f "$CHECKPOINT_FILE" ] || { echo ""; return 0; }
    CHK_KEY="$key" python3 - "$CHECKPOINT_FILE" <<'PY' 2>/dev/null || echo ""
import json, os, sys
key = os.environ["CHK_KEY"]
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)
cur = data
for part in key.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        print("")
        sys.exit(0)
print(cur if isinstance(cur, str) else "")
PY
}

# Filter a list of repo-relative paths through git-working-tree's ignore
# rules so toolkit/agent-wiring churn never drives phase selection.
filter_paths() {
    if [ ! -f "$GIT_WORKING_TREE" ]; then
        cat
        return 0
    fi
    # git-working-tree.sh exposes only porcelain/counts subcommands; reuse
    # its ignore logic by reimplementing the small prefix test here to keep
    # this script self-contained and deterministic.
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        case "$p" in
            dynamics-migration-tool/*|.cursor/*|.kiro/*|AGENTS.md) continue ;;
            dynamics-migration-tool|.cursor|.kiro) continue ;;
        esac
        printf '%s\n' "$p"
    done
}

# Collect uncommitted (staged + unstaged + untracked) paths plus the diff
# against $1 (a git ref) when provided and resolvable. De-duplicates.
collect_changed_since_ref() {
    local ref="$1"
    {
        git diff --name-only 2>/dev/null || true
        git diff --name-only --cached 2>/dev/null || true
        git ls-files --others --exclude-standard 2>/dev/null || true
        if [ -n "$ref" ] && git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
            git diff --name-only "$ref" 2>/dev/null || true
        fi
    } | sed 's#^\./##' | sort -u
}

cmd_since() {
    local baseline="${1:-last-prompt}"
    case "$baseline" in
        start|last-checkpoint|last-prompt) ;;
        *)
            echo "UNKNOWN"
            return 0
            ;;
    esac

    if ! git_available; then
        # No git: we cannot compute a reliable delta. Fall back to full.
        echo "UNKNOWN"
        return 0
    fi

    local ref=""
    case "$baseline" in
        start)           ref="$(checkpoint_field 'git.startRef')" ;;
        last-checkpoint) ref="$(checkpoint_field 'git.lastCheckpointRef')" ;;
        last-prompt)
            ref="$(checkpoint_field 'git.lastCheckpointRef')"
            [ -z "$ref" ] && ref="$(checkpoint_field 'git.startRef')"
            ;;
    esac

    # When no baseline ref is recorded yet we still report the uncommitted
    # working-tree delta (the agent's edits since the last commit). That is a
    # safe superset; only declare UNKNOWN if there is genuinely no signal.
    local out
    out="$(collect_changed_since_ref "$ref" | filter_paths)"
    printf '%s\n' "$out" | sed '/^$/d'
}

# baseline-write: record the pre-migration baseline (migrate.sh calls this).
cmd_baseline_write() {
    mkdir -p "$TOOL_DIR/output" 2>/dev/null || true
    local sha=""
    local avail="false"
    if git_available; then
        avail="true"
        sha="$(current_head_sha)"
    fi
    GIT_AVAIL="$avail" START_REF="$sha" GEN_AT="$(now_iso)" START_MS="$(now_epoch_ms)" \
    CHK_PATH="$CHECKPOINT_FILE" python3 <<'PY'
import json, os
path = os.environ["CHK_PATH"]
data = {}
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
if not isinstance(data, dict):
    data = {}
git = data.get("git") if isinstance(data.get("git"), dict) else {}
git["available"] = os.environ["GIT_AVAIL"] == "true"
git["startRef"] = os.environ["START_REF"]
# Initialize lastCheckpointRef to the start ref so the first incremental run
# has a baseline before any checkpoint has been written.
git.setdefault("lastCheckpointRef", os.environ["START_REF"])
data["git"] = git
data["schemaVersion"] = "1.0.0"
data["generatedAt"] = os.environ["GEN_AT"]
data["startEpochMs"] = int(os.environ["START_MS"] or 0)
data.setdefault("lastValidatedEpochMs", 0)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
    echo "Wrote validation baseline to dynamics-migration-tool/output/.validation-checkpoint.json"
}

# checkpoint-write: advance the "last successful validation" marker. The
# recorder calls this after a passing validation so the next prompt's
# incremental delta is measured from here.
cmd_checkpoint_write() {
    mkdir -p "$TOOL_DIR/output" 2>/dev/null || true
    local sha=""
    git_available && sha="$(current_head_sha)"
    SHA="$sha" GEN_AT="$(now_iso)" NOW_MS="$(now_epoch_ms)" CHK_PATH="$CHECKPOINT_FILE" python3 <<'PY'
import json, os
path = os.environ["CHK_PATH"]
data = {}
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
if not isinstance(data, dict):
    data = {}
git = data.get("git") if isinstance(data.get("git"), dict) else {}
sha = os.environ["SHA"]
# Only advance the committed-ref baseline when there actually is a commit.
if sha:
    git["lastCheckpointRef"] = sha
    git.setdefault("available", True)
data.setdefault("schemaVersion", "1.0.0")
data["git"] = git
data["lastValidatedEpochMs"] = int(os.environ["NOW_MS"] or 0)
data["generatedAt"] = os.environ["GEN_AT"]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

case "$CMD" in
    since)            cmd_since "${2:-last-prompt}" ;;
    baseline-write)   cmd_baseline_write ;;
    checkpoint-write) cmd_checkpoint_write ;;
    *)
        echo "Usage: $0 since <start|last-checkpoint|last-prompt> | baseline-write | checkpoint-write" >&2
        exit 2
        ;;
esac
