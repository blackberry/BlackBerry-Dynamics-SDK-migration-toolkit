# shellcheck shell=bash
#
# BlackBerry Dynamics Migration — Module Map accessors
#
# Single source of truth for "where in the project does the migration
# apply?". All scripts in tooling/ source this library and call mm_*
# functions instead of hardcoding app/ paths.
#
# Usage:
#   . "$SCRIPT_DIR/lib/module-map.sh"   (or equivalent path)
#   mm_load                              # required once before mm_* lookups
#   primary="$(mm_primary_path)"
#   for root in $(mm_in_scope_source_roots); do ... done
#
# All accessors echo their result to stdout. They never modify files,
# never invoke Gradle, and never make network calls. They are safe
# under `set -e`.
#
# This library uses python3 (already a dependency of bootstrap.sh) for
# JSON parsing rather than jq, to avoid adding a new external dep.
#
# Canonical schema: documentation/report-contract/module-map-schema-v1.0.0.md

# Resolve the toolkit and project roots from this file's location
# (the library is sourced; ${BASH_SOURCE[0]} resolves to lib/module-map.sh).
__MM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__MM_TOOL_DIR="$(cd "$__MM_LIB_DIR/.." && pwd)"
__MM_TOOLKIT_ROOT="$(cd "$__MM_TOOL_DIR/.." && pwd)"
__MM_PROJECT_ROOT="$(cd "$__MM_TOOLKIT_ROOT/.." && pwd)"
__MM_DEFAULT_PATH="$__MM_TOOLKIT_ROOT/output/module-map.json"
__MM_LOADED_PATH=""

# ---------------------------------------------------------------------
# mm_module_map_path — echoes the canonical on-disk location of
# module-map.json. Always echoes a path even when the file does not
# yet exist; callers should test with [ -f "$(mm_module_map_path)" ].
# ---------------------------------------------------------------------
mm_module_map_path() {
    echo "$__MM_DEFAULT_PATH"
}

# ---------------------------------------------------------------------
# mm_load [path] — eagerly verifies the module map is readable. If the
# file does not exist, mm_load synthesizes a single-module fallback in
# a temporary file (matching the v1.0.0 schema) and uses that, so
# downstream accessors always operate against valid data.
#
# Synthesized fallback applies only when:
#   - the file does not exist, AND
#   - app/build.gradle or app/build.gradle.kts exists at the project
#     root (i.e. the project genuinely is single-module-shaped).
#
# When neither file exists nor app/ exists, mm_load returns non-zero
# and downstream accessors fail loudly. This is the correct behavior:
# scripts should not run against an indeterminate project shape.
# ---------------------------------------------------------------------
mm_load() {
    local override="${1:-}"
    local target="${override:-$__MM_DEFAULT_PATH}"

    if [ -f "$target" ]; then
        __MM_LOADED_PATH="$target"
        return 0
    fi

    # Synthesized fallback for back-compat with single-module projects
    # that haven't yet run the new bootstrap. Mirrors the structure
    # bootstrap.sh would emit for discoveryMethod="fallback-app-dir".
    local app_build=""
    if [ -f "$__MM_PROJECT_ROOT/app/build.gradle" ]; then
        app_build="app/build.gradle"
    elif [ -f "$__MM_PROJECT_ROOT/app/build.gradle.kts" ]; then
        app_build="app/build.gradle.kts"
    else
        echo "module-map.sh: $target not found and no app/build.gradle(.kts) — cannot synthesize fallback" >&2
        return 1
    fi

    local synth="$__MM_TOOLKIT_ROOT/output/.mm-fallback.json"
    mkdir -p "$__MM_TOOLKIT_ROOT/output" 2>/dev/null || true
    __mm_emit_fallback_map "$app_build" > "$synth"
    __MM_LOADED_PATH="$synth"
    return 0
}

# Synthesize a v1.0.0 module-map.json describing a canonical app/-shaped
# single-module project. Used by mm_load when the on-disk map is absent.
__mm_emit_fallback_map() {
    local app_build="$1"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Discover physically-present source sets and their sub-paths
    local source_sets_json
    source_sets_json="$(__mm_describe_source_sets "$__MM_PROJECT_ROOT/app" "app")"

    # APK output glob (single-module convention)
    local apk_glob="app/build/outputs/apk/**/*.apk"

    # settings.json placement: main + any flavor assets/ that exist
    local sjson_targets_json
    sjson_targets_json="$(__mm_describe_settings_json_targets "$__MM_PROJECT_ROOT/app" "app")"
    local sjson_strategy="main-only"
    # If the JSON array has more than one entry, switch to per-flavor
    if [ "$(printf '%s' "$sjson_targets_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" -gt 1 ]; then
        sjson_strategy="per-flavor"
    fi

    # applicationId from build file (best-effort regex; handles both
    # Kotlin DSL `applicationId = "..."` and Groovy DSL `applicationId '...'`).
    local app_id
    app_id="$(grep -oE "applicationId[[:space:]]*[=]?[[:space:]]*[\"'][^\"']+[\"']" "$__MM_PROJECT_ROOT/$app_build" 2>/dev/null \
        | head -1 \
        | sed -E "s/.*[\"']([^\"']+)[\"'].*/\1/")"
    [ -z "$app_id" ] && app_id="null" || app_id="\"$app_id\""

    cat <<EOF
{
  "conventionPlugins": [],
  "discoveryMethod": "fallback-app-dir",
  "excludedTestOnlyModules": [],
  "generatedAt": "$now",
  "libraryModulesInScope": [],
  "otherAppModules": [],
  "outOfScopeModules": [],
  "primaryAppModule": {
    "apkOutputGlob": "$apk_glob",
    "applicationId": $app_id,
    "buildFile": "$app_build",
    "buildFileType": "direct",
    "conventionPluginRef": null,
    "name": "app",
    "path": "app",
    "settingsJsonPlacement": {
      "strategy": "$sjson_strategy",
      "targets": $sjson_targets_json
    },
    "sourceSets": $source_sets_json
  },
  "projectShape": "single-module",
  "schemaVersion": "1.0.0",
  "warnings": []
}
EOF
}

# Enumerate source sets physically present under <module_abs>/src/ and
# emit them as a JSON array. <module_path> is the repo-relative module
# path used to construct relative paths inside the JSON.
#
# Source set discovery is filesystem-driven: every subdirectory of src/
# that contains at least one of {java, kotlin, AndroidManifest.xml,
# assets, res} becomes an entry.
__mm_describe_source_sets() {
    local module_abs="$1"
    local module_path="$2"
    local src_dir="$module_abs/src"

    if [ ! -d "$src_dir" ]; then
        echo "[]"
        return 0
    fi

    python3 - "$module_abs" "$module_path" <<'PY'
import json
import os
import sys

module_abs = sys.argv[1]
module_path = sys.argv[2]
src_dir = os.path.join(module_abs, "src")

results = []
try:
    entries = sorted(os.listdir(src_dir))
except OSError:
    entries = []

def _is_test_source_set(name):
    # Exclude 'test', 'androidTest' and any combination source set
    # that starts with one of them followed by a capitalized suffix:
    #   test, testDebug, testFossDebug, androidTest, androidTestRelease, ...
    # Do NOT exclude unrelated names like 'testing' or 'androidTestUtils'
    # (the second character after the prefix must be uppercase or absent).
    for prefix in ("test", "androidTest"):
        if name == prefix:
            return True
        if name.startswith(prefix) and len(name) > len(prefix) and name[len(prefix)].isupper():
            return True
    return False

for ss in entries:
    ss_abs = os.path.join(src_dir, ss)
    if not os.path.isdir(ss_abs):
        continue
    # Exclude test source sets — they don't ship in production builds
    # and Dynamics auth is not active during tests.
    if _is_test_source_set(ss):
        continue

    java_roots = []
    kotlin_roots = []
    java = os.path.join(ss_abs, "java")
    kotlin = os.path.join(ss_abs, "kotlin")
    if os.path.isdir(java):
        java_roots.append(f"{module_path}/src/{ss}/java")
    if os.path.isdir(kotlin):
        kotlin_roots.append(f"{module_path}/src/{ss}/kotlin")

    manifest = os.path.join(ss_abs, "AndroidManifest.xml")
    res = os.path.join(ss_abs, "res")
    assets = os.path.join(ss_abs, "assets")

    has_anything = (
        java_roots
        or kotlin_roots
        or os.path.isfile(manifest)
        or os.path.isdir(res)
        or os.path.isdir(assets)
    )
    if not has_anything:
        continue

    results.append({
        "assets": f"{module_path}/src/{ss}/assets" if os.path.isdir(assets) else None,
        "javaRoots": java_roots,
        "kotlinRoots": kotlin_roots,
        "manifest": f"{module_path}/src/{ss}/AndroidManifest.xml" if os.path.isfile(manifest) else None,
        "name": ss,
        "res": f"{module_path}/src/{ss}/res" if os.path.isdir(res) else None,
    })

# Ensure 'main' is first when present, then alphabetical for the rest
results.sort(key=lambda s: (0 if s["name"] == "main" else 1, s["name"]))
print(json.dumps(results, indent=2, sort_keys=True))
PY
}

# Decide where settings.json must be written. Strategy:
#   - For every source set with an assets/ dir, target that dir.
#   - Always include src/main/assets/ so an unflavored build picks it up.
#
# Output: JSON array of repo-relative paths.
__mm_describe_settings_json_targets() {
    local module_abs="$1"
    local module_path="$2"

    python3 - "$module_abs" "$module_path" <<'PY'
import json
import os
import sys

module_abs = sys.argv[1]
module_path = sys.argv[2]
src_dir = os.path.join(module_abs, "src")

targets = set()
# Always ensure main is targeted, even if assets/ doesn't exist yet
# (prompt 02 will create it).
targets.add(f"{module_path}/src/main/assets/settings.json")

def _is_test_source_set(name):
    for prefix in ("test", "androidTest"):
        if name == prefix:
            return True
        if name.startswith(prefix) and len(name) > len(prefix) and name[len(prefix)].isupper():
            return True
    return False

if os.path.isdir(src_dir):
    for ss in sorted(os.listdir(src_dir)):
        ss_abs = os.path.join(src_dir, ss)
        if not os.path.isdir(ss_abs):
            continue
        if _is_test_source_set(ss):
            continue
        if os.path.isdir(os.path.join(ss_abs, "assets")):
            targets.add(f"{module_path}/src/{ss}/assets/settings.json")

# Stable order: main first, then alphabetical
ordered = sorted(targets, key=lambda p: (0 if "/src/main/" in p else 1, p))
print(json.dumps(ordered, indent=2))
PY
}

# ---------------------------------------------------------------------
# Internal: mm_query <python-expression-on-MAP-dict>
# Evaluates a Python expression with `m` bound to the loaded map.
# ---------------------------------------------------------------------
__mm_require_loaded() {
    if [ -z "$__MM_LOADED_PATH" ]; then
        if ! mm_load; then
            echo "module-map.sh: mm_load failed; refusing to query" >&2
            return 1
        fi
    fi
}

__mm_query() {
    __mm_require_loaded || return $?
    python3 - "$__MM_LOADED_PATH" <<PY
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
$1
PY
}

# ---------------------------------------------------------------------
# Public accessors
# ---------------------------------------------------------------------

# Path of the primary app module (e.g. "app", "app-primary")
mm_primary_path() {
    __mm_query 'print(m["primaryAppModule"]["path"])'
}

# Name of the primary app module (Gradle project name without colon)
mm_primary_name() {
    __mm_query 'print(m["primaryAppModule"]["name"])'
}

# Path of the primary app module's build file
mm_primary_build_file() {
    __mm_query 'print(m["primaryAppModule"]["buildFile"])'
}

# applicationId resolved at discovery time, or empty string if null
mm_primary_application_id() {
    __mm_query 'v = m["primaryAppModule"].get("applicationId");
print("" if v is None else v)'
}

# APK output glob for the primary app module
mm_primary_apk_glob() {
    __mm_query 'print(m["primaryAppModule"]["apkOutputGlob"])'
}

# discoveryMethod (fallback-app-dir | settings-gradle-parse | user-supplied)
mm_discovery_method() {
    __mm_query 'print(m["discoveryMethod"])'
}

# projectShape (single-module | multi-module)
mm_project_shape() {
    __mm_query 'print(m["projectShape"])'
}

# Newline-separated list of source set names for the primary app module
mm_primary_source_set_names() {
    __mm_query 'print("\n".join(s["name"] for s in m["primaryAppModule"]["sourceSets"]))'
}

# Newline-separated list of all java/kotlin roots across all source sets
# of the primary app module. Only roots that physically exist appear here.
mm_primary_source_roots() {
    __mm_query '
roots = []
for s in m["primaryAppModule"]["sourceSets"]:
    roots.extend(s.get("javaRoots") or [])
    roots.extend(s.get("kotlinRoots") or [])
print("\n".join(roots))'
}

# Newline-separated list of manifest paths across all source sets of the
# primary app module (only non-null entries).
mm_primary_manifests() {
    __mm_query '
mans = [s["manifest"] for s in m["primaryAppModule"]["sourceSets"] if s.get("manifest")]
print("\n".join(mans))'
}

# Newline-separated list of res/ directories across all source sets of
# the primary app module (only non-null entries).
mm_primary_res_dirs() {
    __mm_query '
out = [s["res"] for s in m["primaryAppModule"]["sourceSets"] if s.get("res")]
print("\n".join(out))'
}

# Newline-separated list of assets/ directories across all source sets
# of the primary app module (only non-null entries).
mm_primary_assets_dirs() {
    __mm_query '
out = [s["assets"] for s in m["primaryAppModule"]["sourceSets"] if s.get("assets")]
print("\n".join(out))'
}

# Newline-separated list of paths where settings.json must be written.
mm_settings_json_targets() {
    __mm_query 'print("\n".join(m["primaryAppModule"]["settingsJsonPlacement"]["targets"]))'
}

# settings.json placement strategy (main-only | per-flavor)
mm_settings_json_strategy() {
    __mm_query 'print(m["primaryAppModule"]["settingsJsonPlacement"]["strategy"])'
}

# Newline-separated list of all in-scope module paths (primary + libraries).
# This is the canonical "what to scan" list for source-edit prompts and
# for validate.sh's per-module loops.
mm_in_scope_module_paths() {
    __mm_query '
out = [m["primaryAppModule"]["path"]]
out.extend(lib["path"] for lib in m.get("libraryModulesInScope") or [])
print("\n".join(out))'
}

# Newline-separated list of in-scope library module paths (libraries only,
# excluding the primary app module).
mm_library_module_paths() {
    __mm_query '
out = [lib["path"] for lib in m.get("libraryModulesInScope") or []]
print("\n".join(out))'
}

# Newline-separated list of every java/kotlin source root across all
# in-scope modules and all source sets (primary + libraries).
mm_in_scope_source_roots() {
    __mm_query '
roots = []
for s in m["primaryAppModule"]["sourceSets"]:
    roots.extend(s.get("javaRoots") or [])
    roots.extend(s.get("kotlinRoots") or [])
for lib in m.get("libraryModulesInScope") or []:
    for s in lib.get("sourceSets") or []:
        roots.extend(s.get("javaRoots") or [])
        roots.extend(s.get("kotlinRoots") or [])
print("\n".join(roots))'
}

# Newline-separated list of every manifest across all in-scope modules.
mm_in_scope_manifests() {
    __mm_query '
mans = [s["manifest"] for s in m["primaryAppModule"]["sourceSets"] if s.get("manifest")]
for lib in m.get("libraryModulesInScope") or []:
    for s in lib.get("sourceSets") or []:
        if s.get("manifest"):
            mans.append(s["manifest"])
print("\n".join(mans))'
}

# Newline-separated list of every res/ dir across all in-scope modules.
mm_in_scope_res_dirs() {
    __mm_query '
out = [s["res"] for s in m["primaryAppModule"]["sourceSets"] if s.get("res")]
for lib in m.get("libraryModulesInScope") or []:
    for s in lib.get("sourceSets") or []:
        if s.get("res"):
            out.append(s["res"])
print("\n".join(out))'
}

# Look up the conventionPluginRef.sourceFile for a given module path.
# Echoes empty string if the module is not under a convention plugin.
mm_convention_plugin_for() {
    local module_path="$1"
    __mm_query "
target = '$module_path'
if m['primaryAppModule']['path'] == target:
    ref = m['primaryAppModule'].get('conventionPluginRef')
else:
    ref = None
    for lib in m.get('libraryModulesInScope') or []:
        if lib['path'] == target:
            ref = lib.get('conventionPluginRef')
            break
print('' if not ref else ref.get('sourceFile') or '')"
}

# Echo the editStrategy for the primary app module
# (edit-convention-plugin | override-in-app-module | direct).
# 'direct' is returned when buildFileType is 'direct' (no convention
# plugin involved) — it is not one of the conventionPluginRef.editStrategy
# enum values, but is convenient for callers that just want a single
# action keyword.
mm_primary_edit_strategy() {
    __mm_query "
p = m['primaryAppModule']
if p.get('buildFileType') == 'convention-plugin':
    ref = p.get('conventionPluginRef') or {}
    print(ref.get('editStrategy') or 'override-in-app-module')
else:
    print('direct')"
}

# Number of warnings recorded during discovery.
mm_warning_count() {
    __mm_query 'print(len(m.get("warnings") or []))'
}

# Print all discovery warnings, one per line.
mm_warnings() {
    __mm_query 'print("\n".join(m.get("warnings") or []))'
}
