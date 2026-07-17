#!/usr/bin/env bash
# Filter git porcelain output for migration dirty-tree checks.
#
# Excludes paths that every migration run introduces (toolkit, Cursor/Kiro/Codex wiring).
# Usage (from project root):
#   bash dynamics-migration-tool/tooling/git-working-tree.sh porcelain
#   bash dynamics-migration-tool/tooling/git-working-tree.sh counts
#
# Exit 0 always when git is unavailable (no repo).

set -euo pipefail

# Toolkit install tree and agent wiring (see tooling/migrate.sh).
WORKING_TREE_IGNORE_PREFIXES=(
  "dynamics-migration-tool/"
  ".cursor/"
  ".kiro/"
)
# Single-file installs (Codex: migrate.sh --agent codex).
WORKING_TREE_IGNORE_EXACT=(
  "AGENTS.md"
)

__normalize_relpath() {
  local p="$1"
  # Porcelain may quote paths with spaces or special characters.
  if [[ "$p" == \"*\" ]]; then
    p="${p:1:${#p}-2}"
    p="${p//\\\"/\"}"
    p="${p//\\\\/\\}"
  fi
  # Drop leading ./ if present.
  p="${p#./}"
  printf '%s' "$p"
}

__is_ignored_relpath() {
  local path="$1"
  local prefix dir exact
  [[ -z "$path" ]] && return 0
  for exact in "${WORKING_TREE_IGNORE_EXACT[@]}"; do
    if [[ "$path" == "$exact" ]]; then
      return 0
    fi
  done
  for prefix in "${WORKING_TREE_IGNORE_PREFIXES[@]}"; do
    if [[ "$path" == "$prefix"* ]]; then
      return 0
    fi
    dir="${prefix%/}"
    if [[ "$path" == "$dir" ]]; then
      return 0
    fi
  done
  return 1
}

__line_has_relevant_path() {
  local line="$1"
  [[ ${#line} -lt 4 ]] && return 1
  local rest="${line:3}"
  local -a paths=()
  if [[ "$rest" == *" -> "* ]]; then
    paths+=("${rest%% -> *}")
    paths+=("${rest##* -> }")
  else
    paths+=("$rest")
  fi
  local p
  for p in "${paths[@]}"; do
    p="$(__normalize_relpath "$p")"
    if ! __is_ignored_relpath "$p"; then
      return 0
    fi
  done
  return 1
}

__cmd_porcelain() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if __line_has_relevant_path "$line"; then
      printf '%s\n' "$line"
    fi
  done < <(git status --porcelain 2>/dev/null || true)
}

__cmd_counts() {
  local untracked=0 modified=0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ "${line:0:2}" == "??" ]]; then
      untracked=$((untracked + 1))
    else
      modified=$((modified + 1))
    fi
  done < <(__cmd_porcelain)
  printf 'untracked=%d modified=%d\n' "$untracked" "$modified"
}

case "${1:-porcelain}" in
  porcelain)
    __cmd_porcelain
    ;;
  counts)
    __cmd_counts
    ;;
  *)
    echo "Usage: $0 porcelain|counts" >&2
    exit 2
    ;;
esac
