#!/usr/bin/env bash
# BlackBerry Dynamics iOS Migration — consented Git baseline helper.
#
# Called only after 00pre has received explicit developer consent. It creates a
# Git repository when absent, records local excludes for migration-tool
# artifacts, and creates the initial app-source baseline commit when the
# repository has no commits.
#
# It intentionally never edits global/local git config. If Git identity is
# missing, the developer receives copy-pasteable local/global config commands
# and reruns 00pre.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_ROOT="$(cd "$TOOL_DIR/.." && pwd)"

usage() {
    cat <<USAGE
Usage: bash dynamics-migration-tool/tooling/lib/ensure-git-baseline.sh --consented

Creates a Git repository and initial pre-migration baseline commit only after
00pre has captured explicit developer consent.
USAGE
}

CONSENTED=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --consented) CONSENTED=true; shift ;;
        --help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ "$CONSENTED" != true ]; then
    echo "ERROR: explicit developer consent is required before initializing Git." >&2
    echo "00pre must ask before invoking this helper." >&2
    exit 2
fi

if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is not installed or not on PATH." >&2
    echo "Install Git, then rerun 00pre." >&2
    exit 1
fi

cd "$PROJECT_ROOT"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Initializing Git repository for pre-migration baseline..."
    git init
fi

GIT_DIR="$(git rev-parse --git-dir)"
mkdir -p "$GIT_DIR/info"
EXCLUDE_FILE="$GIT_DIR/info/exclude"
touch "$EXCLUDE_FILE"

add_exclude_once() {
    local pattern="$1"
    if ! grep -Fxq "$pattern" "$EXCLUDE_FILE" 2>/dev/null; then
        printf '%s\n' "$pattern" >> "$EXCLUDE_FILE"
    fi
}

add_exclude_once "# Dynamics migration toolkit artifacts"
add_exclude_once "dynamics-migration-tool/"
add_exclude_once ".cursor/"
add_exclude_once ".kiro/"
add_exclude_once "AGENTS.md"

if git rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "Git repository already has a commit baseline: $(git rev-parse --short HEAD)"
    exit 0
fi

if ! git config user.name >/dev/null 2>&1 || ! git config user.email >/dev/null 2>&1; then
    echo "ERROR: Git author identity is not configured for this repository." >&2
    echo "" >&2
    echo "Configure a local identity for this migration app, then rerun 00pre:" >&2
    echo "  git config user.name \"Your Name\"" >&2
    echo "  git config user.email \"you@example.com\"" >&2
    echo "" >&2
    echo "Or configure a global identity for all local repositories:" >&2
    echo "  git config --global user.name \"Your Name\"" >&2
    echo "  git config --global user.email \"you@example.com\"" >&2
    echo "" >&2
    echo "No Git remote, GitHub account, or network access is required." >&2
    echo "The migration toolkit does not modify Git configuration." >&2
    exit 1
fi

echo ""
echo "Creating pre-migration baseline commit."
echo "The following app files will be staged; migration toolkit artifacts are excluded:"
git add -A --dry-run

git add -A

if git diff --cached --quiet; then
    echo "ERROR: no app files were staged for the pre-migration baseline." >&2
    echo "Check .gitignore/.git/info/exclude, then rerun 00pre." >&2
    exit 1
fi

if ! git commit -m "pre-migration baseline"; then
    echo "" >&2
    echo "ERROR: failed to create the pre-migration baseline commit." >&2
    echo "If Git reports identity issues, configure Git with:" >&2
    echo "  git config user.name \"Your Name\"" >&2
    echo "  git config user.email \"you@example.com\"" >&2
    echo "Then rerun 00pre. The migration toolkit does not modify Git configuration." >&2
    exit 1
fi

echo "Pre-migration baseline commit created: $(git rev-parse --short HEAD)"
