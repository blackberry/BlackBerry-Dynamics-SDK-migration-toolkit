#!/usr/bin/env python3
"""
BlackBerry Dynamics Migration — Module discovery.

Reads the project structure starting at PROJECT_ROOT, classifies every
Gradle module reachable from settings.gradle(.kts), identifies the
primary application module, walks its dependency graph, and emits a
v1.0.0 module-map.json to stdout.

Invoked by tooling/bootstrap.sh. Pure static analysis: never invokes
Gradle, never makes network calls, never modifies files.

Usage:
    discover-modules.py PROJECT_ROOT [--app-module NAME]

Exit codes:
    0  — module map emitted successfully to stdout
    1  — discovery failed; reason on stderr
    2  — multiple application modules detected and --app-module not
         supplied; candidate list on stderr; the bootstrap will surface
         this to the developer who must re-run with --app-module.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
from typing import Dict, List, Optional, Set, Tuple


# ---------------------------------------------------------------------
# Source-set helpers (mirrored from module-map.sh)
# ---------------------------------------------------------------------

def is_test_source_set(name: str) -> bool:
    for prefix in ("test", "androidTest"):
        if name == prefix:
            return True
        if name.startswith(prefix) and len(name) > len(prefix) and name[len(prefix)].isupper():
            return True
    return False


def describe_source_sets(module_abs: str, module_path: str) -> List[Dict]:
    src_dir = os.path.join(module_abs, "src")
    if not os.path.isdir(src_dir):
        return []

    results = []
    try:
        entries = sorted(os.listdir(src_dir))
    except OSError:
        return []

    for ss in entries:
        ss_abs = os.path.join(src_dir, ss)
        if not os.path.isdir(ss_abs):
            continue
        if is_test_source_set(ss):
            continue

        java_roots = []
        kotlin_roots = []
        if os.path.isdir(os.path.join(ss_abs, "java")):
            java_roots.append(f"{module_path}/src/{ss}/java")
        if os.path.isdir(os.path.join(ss_abs, "kotlin")):
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

    results.sort(key=lambda s: (0 if s["name"] == "main" else 1, s["name"]))
    return results


def settings_json_placement(module_abs: str, module_path: str) -> Dict:
    src_dir = os.path.join(module_abs, "src")
    targets = set()
    targets.add(f"{module_path}/src/main/assets/settings.json")

    if os.path.isdir(src_dir):
        for ss in sorted(os.listdir(src_dir)):
            ss_abs = os.path.join(src_dir, ss)
            if not os.path.isdir(ss_abs):
                continue
            if is_test_source_set(ss):
                continue
            if os.path.isdir(os.path.join(ss_abs, "assets")):
                targets.add(f"{module_path}/src/{ss}/assets/settings.json")

    ordered = sorted(targets, key=lambda p: (0 if "/src/main/" in p else 1, p))
    return {
        "strategy": "per-flavor" if len(ordered) > 1 else "main-only",
        "targets": ordered,
    }


# ---------------------------------------------------------------------
# Gradle settings.gradle(.kts) parsing
# ---------------------------------------------------------------------

# Match include("...") / include(":x", ":y") / include ":x", ":y"
INCLUDE_RE = re.compile(
    r"""(?<![A-Za-z0-9_.])include\b\s*\(?\s*((?:["'][^"']+["']\s*,?\s*)+)\)?""",
    re.MULTILINE,
)

# Match pluginManagement { includeBuild("...") } and top-level
# includeBuild("..."). We treat both as plugin-host candidates.
INCLUDE_BUILD_RE = re.compile(
    r"""includeBuild\s*\(?\s*["']([^"']+)["']""",
    re.MULTILINE,
)


def strip_comments(text: str) -> str:
    # Strip line comments (// ...) and block comments (/* ... */).
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def parse_settings(settings_path: str) -> Tuple[List[str], List[str]]:
    """Returns (included_module_paths, included_build_dirs).

    included_module_paths are repo-relative filesystem paths (':a:b' -> 'a/b').
    included_build_dirs are filesystem paths to composite-build roots.
    """
    if not os.path.isfile(settings_path):
        return ([], [])

    with open(settings_path, encoding="utf-8") as f:
        text = strip_comments(f.read())

    modules = []
    for match in INCLUDE_RE.finditer(text):
        for piece in re.findall(r"""["']([^"']+)["']""", match.group(1)):
            # Strip leading colon, convert :a:b to a/b
            mod = piece.lstrip(":")
            modules.append(mod.replace(":", "/"))

    builds = []
    for match in INCLUDE_BUILD_RE.finditer(text):
        builds.append(match.group(1).strip("/"))

    # Dedup while preserving order
    seen = set()
    modules = [m for m in modules if not (m in seen or seen.add(m))]
    seen = set()
    builds = [b for b in builds if not (b in seen or seen.add(b))]
    return modules, builds


# ---------------------------------------------------------------------
# Build-file classification
# ---------------------------------------------------------------------

# Direct application of com.android.application:
#   plugins { id("com.android.application") }
#   plugins { id 'com.android.application' }
#   apply plugin: 'com.android.application'
#   alias(libs.plugins.android.application)         <- only when catalog resolves to this id (we treat it as direct)
#   id("com.android.application")
ANDROID_APP_PLUGIN_RE = re.compile(
    r"""(?:id\s*\(?\s*["']com\.android\.application["']\)?
        |apply\s+plugin\s*:\s*["']com\.android\.application["']
        |alias\s*\(\s*libs\.plugins\.android\.application\s*\))""",
    re.VERBOSE,
)
ANDROID_LIB_PLUGIN_RE = re.compile(
    r"""(?:id\s*\(?\s*["']com\.android\.library["']\)?
        |apply\s+plugin\s*:\s*["']com\.android\.library["']
        |alias\s*\(\s*libs\.plugins\.android\.library\s*\))""",
    re.VERBOSE,
)
KMP_PLUGIN_RE = re.compile(
    r"""(?:id\s*\(?\s*["']org\.jetbrains\.kotlin\.multiplatform["']\)?
        |kotlin\s*\(\s*["']multiplatform["']\s*\)
        |apply\s+plugin\s*:\s*["']org\.jetbrains\.kotlin\.multiplatform["'])""",
    re.VERBOSE,
)

# Generic plugin id captures inside a plugins { ... } block.
PLUGIN_BLOCK_RE = re.compile(
    r"""plugins\s*\{(.*?)\}""",
    re.DOTALL,
)
PLUGIN_ID_LINE_RE = re.compile(
    r"""id\s*\(?\s*["']([^"']+)["']\)?""",
)
PLUGIN_ID_VAR_RE = re.compile(
    # Catches `id(SomePlugins.App.something)` — constants-holder style plugin refs.
    r"""id\s*\(\s*([A-Z][A-Za-z0-9_.]*)\s*\)""",
)
PLUGIN_ALIAS_RE = re.compile(
    r"""alias\s*\(\s*libs\.plugins\.([A-Za-z0-9_.]+)\s*\)""",
)


def find_build_file(module_abs: str) -> Optional[str]:
    for name in ("build.gradle.kts", "build.gradle"):
        p = os.path.join(module_abs, name)
        if os.path.isfile(p):
            return p
    return None


def read_build_file(path: Optional[str]) -> str:
    if not path or not os.path.isfile(path):
        return ""
    try:
        with open(path, encoding="utf-8") as f:
            return strip_comments(f.read())
    except OSError:
        return ""


def applies_plugin(text: str, regex: re.Pattern) -> bool:
    return bool(regex.search(text))


def extract_application_id(text: str) -> Optional[str]:
    m = re.search(r"""applicationId\s*=?\s*["']([^"']+)["']""", text)
    return m.group(1) if m else None


def extract_plugin_ids_from_block(text: str) -> List[str]:
    """Pull every plugin id literal applied in any plugins { ... } block."""
    ids = []
    for block in PLUGIN_BLOCK_RE.findall(text):
        for m in PLUGIN_ID_LINE_RE.finditer(block):
            ids.append(m.group(1))
        for m in PLUGIN_ALIAS_RE.finditer(block):
            ids.append("alias:" + m.group(1))
        for m in PLUGIN_ID_VAR_RE.finditer(block):
            ids.append("var:" + m.group(1))
    return ids


# ---------------------------------------------------------------------
# Convention plugin discovery
# ---------------------------------------------------------------------

PRECOMPILED_PLUGIN_DIRS = ("src/main/kotlin", "src/main/groovy", "src/main/java")

CONVENTION_HOST_DIR_NAMES = ("buildSrc", "build-plugin", "build-logic", "build_plugin")


def find_convention_plugin_hosts(project_root: str, included_builds: List[str]) -> List[str]:
    """Return absolute paths to potential convention-plugin host directories."""
    hosts = []
    for name in CONVENTION_HOST_DIR_NAMES:
        path = os.path.join(project_root, name)
        if os.path.isdir(path):
            hosts.append(path)
    for built in included_builds:
        path = os.path.join(project_root, built)
        if os.path.isdir(path):
            hosts.append(path)
    # Dedup
    seen = set()
    out = []
    for h in hosts:
        if h not in seen:
            seen.add(h)
            out.append(h)
    return out


def discover_convention_plugins(host_dir: str, project_root: str) -> List[Dict]:
    """Scan a convention-plugin host for precompiled .gradle(.kts) plugins
    and Kotlin convention-plugin classes that register plugin ids.

    Returns a list of {pluginId, sourceFile (rel), appliesAndroidPlugin}.
    """
    found = []

    # 1. Precompiled script plugins:  <host>/src/main/{kotlin,groovy}/<id>.gradle(.kts)
    for sub in PRECOMPILED_PLUGIN_DIRS:
        scan_dir = os.path.join(host_dir, sub)
        if not os.path.isdir(scan_dir):
            continue
        for entry in sorted(os.listdir(scan_dir)):
            full = os.path.join(scan_dir, entry)
            if not os.path.isfile(full):
                continue
            # Convention-plugin filenames: <id>.gradle.kts or <id>.gradle
            if entry.endswith(".gradle.kts"):
                plugin_id = entry[: -len(".gradle.kts")]
            elif entry.endswith(".gradle"):
                plugin_id = entry[: -len(".gradle")]
            else:
                continue
            text = read_build_file(full)
            applies = None
            if applies_plugin(text, ANDROID_APP_PLUGIN_RE):
                applies = "com.android.application"
            elif applies_plugin(text, ANDROID_LIB_PLUGIN_RE):
                applies = "com.android.library"
            found.append({
                "pluginId": plugin_id,
                "sourceFile": os.path.relpath(full, project_root),
                "appliesAndroidPlugin": applies,
            })

    return found


def resolve_plugin_id_var(project_root: str, host_dirs: List[str], var_expr: str) -> Optional[str]:
    """Best-effort resolution of `id(SomeConst.App.foo)` to a plugin id string
    by parsing convention-plugin hosts for nested `object` declarations
    containing `const val foo = "..."`.

    var_expr is e.g. 'AppPlugins.Android.compose' or 'Plugins.androidApp'.
    The last segment is the const name; preceding segments are the enclosing
    object names that must be matched to disambiguate (Library.android vs App.android).
    """
    parts = var_expr.split(".")
    if not parts:
        return None
    leaf = parts[-1]
    enclosing = parts[:-1]   # e.g. ['AppPlugins', 'Library']

    for host in host_dirs:
        for sub in PRECOMPILED_PLUGIN_DIRS:
            scan_dir = os.path.join(host, sub)
            if not os.path.isdir(scan_dir):
                continue
            for root, _dirs, files in os.walk(scan_dir):
                for f in files:
                    if not (f.endswith(".kt") or f.endswith(".java")):
                        continue
                    full = os.path.join(root, f)
                    try:
                        with open(full, encoding="utf-8") as fh:
                            text = fh.read()
                    except OSError:
                        continue
                    resolved = _resolve_const_in_object_hierarchy(text, enclosing, leaf)
                    if resolved is not None:
                        return resolved
    return None


def _resolve_const_in_object_hierarchy(text: str, enclosing: List[str], leaf: str) -> Optional[str]:
    """Search Kotlin source for a `const val <leaf> = "..."` declaration that
    sits inside the nested object hierarchy described by `enclosing`.

    `enclosing` is e.g. ['AppPlugins', 'Library'] meaning the const
    must live inside `object AppPlugins { object Library { ... } }`.
    Names are matched in order; the outermost name can also appear as
    `class` or `package object` or be the file's top-level (no wrapping).
    """
    text = strip_comments(text)
    leaf_pattern = re.compile(rf"""(?:const\s+val\s+)?{re.escape(leaf)}\s*=\s*["']([^"']+)["']""")

    if not enclosing:
        m = leaf_pattern.search(text)
        return m.group(1) if m else None

    # Find every "object NAME {" and recursively descend, tracking depth so
    # we know when each object ends.
    # Build a list of (start_index, end_index, object_name) by brace matching.
    object_re = re.compile(r"""\bobject\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{""")

    # Walk through the text finding 'object NAME {' blocks; for each match,
    # find its matching closing brace, then recursively try to resolve.
    def find_block_end(s: str, open_idx: int) -> int:
        # open_idx points at '{'. Returns index of the matching '}'.
        depth = 1
        i = open_idx + 1
        while i < len(s) and depth > 0:
            c = s[i]
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
            elif c in ('"', "'"):
                # skip string literal
                quote = c
                i += 1
                while i < len(s) and s[i] != quote:
                    if s[i] == '\\':
                        i += 2
                        continue
                    i += 1
            i += 1
        return i - 1

    def search_in(scope_text: str, scope_offset: int, depth: int) -> Optional[str]:
        # depth is index into `enclosing` we want to match next
        if depth >= len(enclosing):
            m = leaf_pattern.search(scope_text)
            return m.group(1) if m else None

        target_name = enclosing[depth]
        for match in object_re.finditer(scope_text):
            if match.group(1) != target_name:
                continue
            # find the open brace in the original text
            open_brace_local = scope_text.find('{', match.end() - 1)
            if open_brace_local < 0:
                continue
            close_brace_local = find_block_end(scope_text, open_brace_local)
            inner = scope_text[open_brace_local + 1:close_brace_local]
            result = search_in(inner, scope_offset + open_brace_local + 1, depth + 1)
            if result is not None:
                return result
        return None

    return search_in(text, 0, 0)


# ---------------------------------------------------------------------
# Dependency graph walking
# ---------------------------------------------------------------------

# project(":a:b") and projects.aB nested accessor forms.
PROJECT_DEP_RE = re.compile(
    r"""(implementation|api|compileOnly|runtimeOnly|testImplementation|androidTestImplementation|testApi|androidTestApi|testCompileOnly|androidTestCompileOnly|testRuntimeOnly|androidTestRuntimeOnly|debugImplementation|releaseImplementation)\s*\(?\s*(?:project\s*\(\s*["'](:[^"']+)["']\s*\)|projects\.([A-Za-z0-9_.]+))""",
    re.MULTILINE,
)
PROD_CONFIGS = {"implementation", "api", "compileOnly", "runtimeOnly",
                "debugImplementation", "releaseImplementation"}
TEST_CONFIGS = {"testImplementation", "androidTestImplementation", "testApi",
                "androidTestApi", "testCompileOnly", "androidTestCompileOnly",
                "testRuntimeOnly", "androidTestRuntimeOnly"}

# Hyphen-aware camelCase splitter for typesafe accessors.
# `feature.account.settings.impl` from the accessor `projects.feature.account.settings.impl`
# maps to module path `feature/account/settings/impl`.
# `appCommon` (single segment) maps to `app-common`.
def typesafe_to_module_path(expr: str, known_paths: Set[str]) -> Optional[str]:
    """Convert a typesafe project accessor like 'feature.account.settings.impl'
    or 'appCommon' to a known module path. Try multiple kebab-case splittings
    and verify against known_paths."""
    parts = expr.split(".")
    # For each segment, generate candidates: camelCase preserved AND
    # camelCase to kebab-case.
    def kebab(s):
        return re.sub(r"(?<!^)(?=[A-Z])", "-", s).lower()

    # Generate every product of kebab vs no-kebab per segment, but in
    # practice typesafe accessors always kebab.
    candidate_segments = [kebab(p) for p in parts]
    candidate = "/".join(candidate_segments)
    if candidate in known_paths:
        return candidate
    # Try exact-as-given (without kebab)
    candidate = "/".join(parts).lower()
    if candidate in known_paths:
        return candidate
    return None


def parse_module_dependencies(text: str, known_paths: Set[str]) -> List[Tuple[str, str]]:
    """Return a list of (config, target_module_path) tuples.
    Skips coordinates that aren't project deps."""
    deps = []
    for match in PROJECT_DEP_RE.finditer(text):
        config = match.group(1)
        gradle_path = match.group(2)  # like ':a:b' or None
        typesafe = match.group(3)     # like 'a.b' or None
        target = None
        if gradle_path:
            target = gradle_path.lstrip(":").replace(":", "/")
        elif typesafe:
            target = typesafe_to_module_path(typesafe, known_paths)
        if target:
            deps.append((config, target))
    return deps


# ---------------------------------------------------------------------
# Main discovery
# ---------------------------------------------------------------------

def now_iso():
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def emit_fallback_app_dir(project_root: str) -> Dict:
    """Synthesize the v1.0.0 module map for a canonical app/-shaped project."""
    app_abs = os.path.join(project_root, "app")
    build_file = None
    for cand in ("build.gradle", "build.gradle.kts"):
        if os.path.isfile(os.path.join(app_abs, cand)):
            build_file = f"app/{cand}"
            break
    if not build_file:
        raise RuntimeError("No app/build.gradle(.kts) found for fallback")

    text = read_build_file(os.path.join(project_root, build_file))
    app_id = extract_application_id(text)

    return {
        "conventionPlugins": [],
        "discoveryMethod": "fallback-app-dir",
        "excludedTestOnlyModules": [],
        "generatedAt": now_iso(),
        "libraryModulesInScope": [],
        "otherAppModules": [],
        "outOfScopeModules": [],
        "primaryAppModule": {
            "apkOutputGlob": "app/build/outputs/apk/**/*.apk",
            "applicationId": app_id,
            "buildFile": build_file,
            "buildFileType": "direct",
            "conventionPluginRef": None,
            "name": "app",
            "path": "app",
            "settingsJsonPlacement": settings_json_placement(app_abs, "app"),
            "sourceSets": describe_source_sets(app_abs, "app"),
        },
        "projectShape": "single-module",
        "schemaVersion": "1.0.0",
        "warnings": [],
    }


def discover_multi_module(project_root: str, app_module_override: Optional[str]) -> Dict:
    """Full discovery for multi-module projects."""
    warnings: List[str] = []

    # ---- 1. Parse settings.gradle(.kts) ----
    settings_path = None
    for cand in ("settings.gradle.kts", "settings.gradle"):
        p = os.path.join(project_root, cand)
        if os.path.isfile(p):
            settings_path = p
            break
    if not settings_path:
        raise RuntimeError("No settings.gradle(.kts) found")

    module_paths, included_builds = parse_settings(settings_path)
    # Remove duplicates while preserving order
    module_paths = list(dict.fromkeys(module_paths))

    # ---- 2. Discover convention plugins ----
    plugin_hosts = find_convention_plugin_hosts(project_root, included_builds)
    all_plugins: Dict[str, Dict] = {}  # by pluginId
    for host in plugin_hosts:
        for plug in discover_convention_plugins(host, project_root):
            all_plugins[plug["pluginId"]] = plug

    # Transitively resolve "appliesAndroidPlugin" — a convention plugin that
    # applies another convention plugin (id("com.example.app.android")) inherits
    # its appliesAndroidPlugin classification. Iterate to fixed point.
    changed = True
    iteration = 0
    while changed and iteration < 16:
        changed = False
        iteration += 1
        for pid, plug in all_plugins.items():
            if plug["appliesAndroidPlugin"]:
                continue
            text = read_build_file(os.path.join(project_root, plug["sourceFile"]))
            for inner_id_match in PLUGIN_ID_LINE_RE.finditer(
                "\n".join(PLUGIN_BLOCK_RE.findall(text))
            ):
                inner_id = inner_id_match.group(1)
                inner_plug = all_plugins.get(inner_id)
                if inner_plug and inner_plug["appliesAndroidPlugin"]:
                    plug["appliesAndroidPlugin"] = inner_plug["appliesAndroidPlugin"]
                    changed = True
                    break

    # ---- 3. Classify each module ----
    classifications: Dict[str, Dict] = {}  # module_path -> {kind, build_file, text, plugin_id, ...}
    app_module_paths: List[str] = []
    library_module_paths: List[str] = []
    kmp_module_paths: List[str] = []
    plugin_host_paths: Set[str] = set()

    # Treat anything under known plugin-host dirs as plugin-host (skipped)
    for host in plugin_hosts:
        rel = os.path.relpath(host, project_root)
        if rel == ".":
            continue
        plugin_host_paths.add(rel)

    for mod_path in module_paths:
        mod_abs = os.path.join(project_root, mod_path)
        bf = find_build_file(mod_abs)
        text = read_build_file(bf)

        # KMP override — KMP modules are skipped entirely
        if applies_plugin(text, KMP_PLUGIN_RE):
            kmp_module_paths.append(mod_path)
            classifications[mod_path] = {"kind": "kmp", "buildFile": bf, "text": text}
            continue

        # Direct application of Android plugin
        is_app_direct = applies_plugin(text, ANDROID_APP_PLUGIN_RE)
        is_lib_direct = applies_plugin(text, ANDROID_LIB_PLUGIN_RE)

        # Convention-plugin application: check every plugin id in plugins{}
        applied_via_plugin = None
        if not (is_app_direct or is_lib_direct):
            for pid in extract_plugin_ids_from_block(text):
                # Resolve var-expressions like 'AppPlugins.Android.compose'
                resolved_id = pid
                if pid.startswith("var:"):
                    resolved_id = resolve_plugin_id_var(project_root, plugin_hosts, pid[4:])
                    if not resolved_id:
                        continue
                elif pid.startswith("alias:"):
                    # We can't resolve version-catalog aliases here without parsing
                    # libs.versions.toml; the direct regex above already catches
                    # libs.plugins.android.application. Skip otherwise.
                    continue

                if resolved_id in all_plugins:
                    plug = all_plugins[resolved_id]
                    if plug["appliesAndroidPlugin"]:
                        applied_via_plugin = plug
                        break

        if applied_via_plugin and applied_via_plugin["appliesAndroidPlugin"] == "com.android.application":
            classifications[mod_path] = {
                "kind": "app",
                "buildFile": bf,
                "text": text,
                "buildFileType": "convention-plugin",
                "conventionPluginRef": applied_via_plugin,
            }
            app_module_paths.append(mod_path)
        elif applied_via_plugin and applied_via_plugin["appliesAndroidPlugin"] == "com.android.library":
            classifications[mod_path] = {
                "kind": "library",
                "buildFile": bf,
                "text": text,
                "buildFileType": "convention-plugin",
                "conventionPluginRef": applied_via_plugin,
            }
            library_module_paths.append(mod_path)
        elif is_app_direct:
            classifications[mod_path] = {
                "kind": "app",
                "buildFile": bf,
                "text": text,
                "buildFileType": "direct",
                "conventionPluginRef": None,
            }
            app_module_paths.append(mod_path)
        elif is_lib_direct:
            classifications[mod_path] = {
                "kind": "library",
                "buildFile": bf,
                "text": text,
                "buildFileType": "direct",
                "conventionPluginRef": None,
            }
            library_module_paths.append(mod_path)
        else:
            # Unclassifiable: not Android app, not Android library, not KMP.
            # Could be JVM library, plugin host, or unrecognized. Mark as
            # out-of-scope but keep the text/build_file for dep walking.
            classifications[mod_path] = {
                "kind": "other",
                "buildFile": bf,
                "text": text,
                "buildFileType": "direct",
                "conventionPluginRef": None,
            }

    # ---- 4. Pick primary app module ----
    if app_module_override:
        if app_module_override not in app_module_paths and app_module_override not in classifications:
            # Allow selecting a module even if classification missed it (manual override)
            cand_path = app_module_override
            if cand_path not in module_paths:
                raise RuntimeError(f"--app-module {app_module_override} is not declared in settings.gradle(.kts)")
        primary = app_module_override
    elif len(app_module_paths) == 0:
        raise RuntimeError("No application modules found (no module applies com.android.application directly or via convention plugin)")
    elif len(app_module_paths) == 1:
        primary = app_module_paths[0]
    elif "app" in app_module_paths:
        # Multi-app project where one of the apps lives in the canonical
        # 'app' directory: auto-prefer it. This preserves the
        # zero-developer-input experience for projects that historically
        # migrated successfully with the literal-app/ heuristic, while
        # other app modules are surfaced as 'otherAppModules[]' and
        # recorded in warnings[] so the developer can switch with
        # --app-module if desired.
        primary = "app"
        others = [m for m in app_module_paths if m != "app"]
        warnings.append(
            "Multiple application modules detected; auto-selected 'app' as primary. "
            "Other app modules: " + ", ".join(others) + ". "
            "Re-run with --app-module <name> to migrate one of them instead."
        )
    else:
        # Multi-app and none is the canonical 'app': surface candidates
        # and exit with sentinel code. The bootstrap surfaces this to
        # the developer who must re-run with --app-module.
        msg = ["Multiple application modules detected:"]
        for cand in app_module_paths:
            app_id = extract_application_id(classifications[cand]["text"]) or "(applicationId not statically resolvable)"
            msg.append(f"  - {cand}    ({app_id})")
        msg.append("Re-run bootstrap with --app-module <name> to select one.")
        sys.stderr.write("\n".join(msg) + "\n")
        sys.exit(2)

    # ---- 5. Walk dependencies from primary ----
    known_paths = set(module_paths)
    reachable_prod: Dict[str, Tuple[int, str]] = {}  # module -> (depth, edge_kind)
    reachable_test: Dict[str, str] = {}              # module -> edge_kind

    def walk(mod_path: str, depth: int, configs_seen: Set[str]):
        cls = classifications.get(mod_path)
        if not cls:
            return
        text = cls.get("text", "") or ""
        for config, target in parse_module_dependencies(text, known_paths):
            if config in PROD_CONFIGS:
                if target not in reachable_prod or reachable_prod[target][0] > depth + 1:
                    reachable_prod[target] = (depth + 1, _normalize_edge_kind(config))
                    walk(target, depth + 1, configs_seen | {config})
            elif config in TEST_CONFIGS:
                # Test edges contribute only via the primary module; don't
                # transitively re-classify
                if target not in reachable_test:
                    reachable_test[target] = config

    def _normalize_edge_kind(config: str) -> str:
        # debugImplementation, releaseImplementation, etc. -> 'implementation'
        if "implementation" in config.lower():
            return "implementation"
        if config == "api":
            return "api"
        if config == "compileOnly":
            return "compileOnly"
        if config == "runtimeOnly":
            return "runtimeOnly"
        return "implementation"

    walk(primary, 0, set())

    # Test-only modules: those reachable ONLY via test edges from the primary,
    # not via any production edge (transitively or directly).
    excluded_test_only = []
    for mod, edge in reachable_test.items():
        if mod not in reachable_prod:
            excluded_test_only.append({"name": _module_name(mod), "path": mod, "reachedVia": edge})

    # ---- 6. Build result objects ----
    primary_cls = classifications[primary]
    primary_abs = os.path.join(project_root, primary)
    primary_obj = {
        "apkOutputGlob": f"{primary}/build/outputs/apk/**/*.apk",
        "applicationId": extract_application_id(primary_cls["text"]),
        "buildFile": os.path.relpath(primary_cls["buildFile"], project_root) if primary_cls["buildFile"] else f"{primary}/build.gradle.kts",
        "buildFileType": primary_cls.get("buildFileType", "direct"),
        "conventionPluginRef": _shape_convention_ref(primary_cls.get("conventionPluginRef"), primary, app_module_paths, library_module_paths),
        "name": _module_name(primary),
        "path": primary,
        "settingsJsonPlacement": settings_json_placement(primary_abs, primary),
        "sourceSets": describe_source_sets(primary_abs, primary),
    }

    libraries_obj = []
    for lib_path, (depth, edge_kind) in sorted(reachable_prod.items()):
        cls = classifications.get(lib_path)
        if not cls:
            continue
        # Skip non-library kinds:
        #   - 'app' would be another app module (already captured in otherApps)
        #   - 'kmp' is intentionally out of scope for v1.0.0
        # 'library' (Android) and 'other' (JVM/java-library/kotlin-jvm) are
        # both treated as in-scope library modules: their Java/Kotlin source
        # may reference Dynamics APIs even when no Android resources are
        # involved.
        if cls["kind"] in ("app", "kmp"):
            continue
        lib_abs = os.path.join(project_root, lib_path)
        libraries_obj.append({
            "buildFile": os.path.relpath(cls["buildFile"], project_root) if cls["buildFile"] else f"{lib_path}/build.gradle.kts",
            "buildFileType": cls.get("buildFileType", "direct"),
            "containsRelevantApis": [],
            "conventionPluginRef": _shape_convention_ref(cls.get("conventionPluginRef"), lib_path, app_module_paths, library_module_paths),
            "edgeKind": edge_kind,
            "name": _module_name(lib_path),
            "path": lib_path,
            "reachableFromPrimary": True,
            "sourceSets": describe_source_sets(lib_abs, lib_path),
            "transitiveDepth": depth,
        })

    other_apps = []
    for mod in app_module_paths:
        if mod == primary:
            continue
        cls = classifications[mod]
        other_apps.append({
            "applicationId": extract_application_id(cls["text"]),
            "inScope": False,
            "name": _module_name(mod),
            "path": mod,
            "reason": f"developer-selected {_module_name(primary)}",
        })

    out_of_scope = []
    for mod in kmp_module_paths:
        out_of_scope.append({"name": _module_name(mod), "path": mod, "reason": "kmp-module-ignored"})
    for mod in module_paths:
        if mod in {primary} or mod in [a["path"] for a in other_apps]:
            continue
        if mod in [l["path"] for l in libraries_obj]:
            continue
        if mod in [t["path"] for t in excluded_test_only]:
            continue
        if mod in kmp_module_paths:
            continue
        if any(mod == ph or mod.startswith(ph + "/") for ph in plugin_host_paths):
            out_of_scope.append({"name": _module_name(mod), "path": mod, "reason": "convention-plugin-host"})
        else:
            out_of_scope.append({"name": _module_name(mod), "path": mod, "reason": "not-reachable-from-primary"})

    # Convention plugins inventory: for every plugin discovered, build the
    # canonical entry with consumedBy and editStrategy.
    convention_plugins_out = []
    for plug_id, plug in sorted(all_plugins.items()):
        consumed_by = []
        for mod_path, cls in classifications.items():
            ref = cls.get("conventionPluginRef")
            if ref and ref.get("pluginId") == plug_id:
                consumed_by.append(_module_name(mod_path))
        applies = plug.get("appliesAndroidPlugin")
        if not applies:
            edit_strategy = "not-applicable"
        else:
            # If the plugin is consumed by exactly one in-scope module
            # (the primary), edit-convention-plugin is feasible; otherwise
            # override-in-app-module.
            in_scope_consumers = [c for c in consumed_by if c == _module_name(primary)
                                  or c in [_module_name(l["path"]) for l in libraries_obj]]
            shared_with_other_apps = any(
                c in [_module_name(a["path"]) for a in other_apps] for c in consumed_by
            )
            if shared_with_other_apps or len(in_scope_consumers) > 1:
                edit_strategy = "override-in-app-module"
            else:
                edit_strategy = "edit-convention-plugin"
        convention_plugins_out.append({
            "appliesAndroidPlugin": applies,
            "consumedBy": sorted(consumed_by),
            "editStrategy": edit_strategy,
            "pluginId": plug_id,
            "sourceFile": plug["sourceFile"],
        })

    # The conventionPluginRef inside primary/libraries needs editStrategy too;
    # patch it from the canonical inventory.
    def _patch_strategy(obj):
        ref = obj.get("conventionPluginRef")
        if not ref:
            return
        for plug in convention_plugins_out:
            if plug["pluginId"] == ref["pluginId"]:
                # Filter to enum values only (edit-convention-plugin / override-in-app-module)
                strategy = plug["editStrategy"]
                if strategy == "not-applicable":
                    strategy = "override-in-app-module"
                ref["editStrategy"] = strategy
                ref["consumedBy"] = plug["consumedBy"]
                ref["appliesAndroidPlugin"] = plug["appliesAndroidPlugin"]
                break

    _patch_strategy(primary_obj)
    for lib in libraries_obj:
        _patch_strategy(lib)

    discovery_method = "user-supplied" if app_module_override else "settings-gradle-parse"

    project_shape = "multi-module" if len(module_paths) > 1 or len(app_module_paths) > 1 else "single-module"

    return {
        "conventionPlugins": convention_plugins_out,
        "discoveryMethod": discovery_method,
        "excludedTestOnlyModules": sorted(excluded_test_only, key=lambda x: x["path"]),
        "generatedAt": now_iso(),
        "libraryModulesInScope": libraries_obj,
        "otherAppModules": other_apps,
        "outOfScopeModules": sorted(out_of_scope, key=lambda x: x["path"]),
        "primaryAppModule": primary_obj,
        "projectShape": project_shape,
        "schemaVersion": "1.0.0",
        "warnings": warnings,
    }


def _module_name(mod_path: str) -> str:
    """Convert filesystem module path back to gradle-style project name without
    leading colon. e.g. 'feature/account/settings/impl' -> 'feature:account:settings:impl'.
    For top-level modules, returns just the directory name."""
    return mod_path.replace("/", ":")


def _shape_convention_ref(ref: Optional[Dict], mod_path: str,
                          app_paths: List[str], lib_paths: List[str]) -> Optional[Dict]:
    if not ref:
        return None
    return {
        "appliesAndroidPlugin": ref.get("appliesAndroidPlugin") or "com.android.application",
        "consumedBy": [],   # filled in later by convention_plugins_out merge
        "editStrategy": "override-in-app-module",  # patched later
        "pluginId": ref["pluginId"],
        "sourceFile": ref["sourceFile"],
    }


# ---------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("project_root", help="absolute path to the Android project root")
    parser.add_argument("--app-module", default=None, help="explicit primary app module (filesystem path; required for multi-app projects)")
    args = parser.parse_args()

    project_root = os.path.abspath(args.project_root)
    if not os.path.isdir(project_root):
        sys.stderr.write(f"discover-modules: project root does not exist: {project_root}\n")
        sys.exit(1)

    # Decide between fallback and multi-module discovery.
    # Fallback applies when:
    #   - app/build.gradle(.kts) exists, AND
    #   - settings.gradle(.kts) declares no other application modules
    # Otherwise we run the full discovery.
    has_app_dir = (
        os.path.isfile(os.path.join(project_root, "app", "build.gradle"))
        or os.path.isfile(os.path.join(project_root, "app", "build.gradle.kts"))
    )

    settings_path = None
    for cand in ("settings.gradle.kts", "settings.gradle"):
        p = os.path.join(project_root, cand)
        if os.path.isfile(p):
            settings_path = p
            break

    use_fallback = False
    if has_app_dir and not args.app_module:
        # Check whether settings.gradle declares more than one module that
        # could be an app module. If only :app is declared (or no settings
        # file exists), use the simple fallback.
        if not settings_path:
            use_fallback = True
        else:
            module_paths, _builds = parse_settings(settings_path)
            non_app = [m for m in module_paths if m != "app"]
            if not non_app:
                use_fallback = True
            else:
                # Other modules declared — check if any of them are app modules.
                # We do a quick scan of their build files to decide.
                other_apps = []
                for m in non_app:
                    bf = find_build_file(os.path.join(project_root, m))
                    text = read_build_file(bf)
                    if applies_plugin(text, ANDROID_APP_PLUGIN_RE):
                        other_apps.append(m)
                # If only :app is an app module, we can still use fallback to
                # preserve byte-for-byte backward compatibility — the multi-module
                # discovery would produce essentially the same output but with
                # discoveryMethod="settings-gradle-parse" and any reachable
                # libraries listed. Since libraries matter (they may need
                # source-edit migration), we should not use fallback when
                # libraries are declared — use full discovery instead.
                if other_apps:
                    use_fallback = False
                elif non_app:
                    # Only library modules — full discovery so they appear in libraryModulesInScope[]
                    use_fallback = False

    try:
        if use_fallback:
            result = emit_fallback_app_dir(project_root)
        else:
            result = discover_multi_module(project_root, args.app_module)
    except RuntimeError as e:
        sys.stderr.write(f"discover-modules: {e}\n")
        sys.exit(1)

    # Emit JSON to stdout, alphabetically sorted keys for deterministic diffs
    sys.stdout.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
    sys.exit(0)


if __name__ == "__main__":
    main()
