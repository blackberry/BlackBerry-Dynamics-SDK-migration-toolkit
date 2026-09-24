#!/bin/bash

# BlackBerry Dynamics Migration — Bootstrap Probe
#
# Performs the deterministic environment, network, and SDK-class checks
# that prompt 00pre-bootstrap.md depends on. Writes the structured
# probe results to dynamics-migration-tool/output/.bootstrap-probe.json
# (a temporary file the agent merges into the final bootstrap.json).
#
# Usage:
#   bash dynamics-migration-tool/tooling/bootstrap.sh probe
#
# Exits 0 only when every required check passes. Exits 1 with a clear
# remediation message on any failure.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/toolkit-version.sh
. "$SCRIPT_DIR/lib/toolkit-version.sh"
toolkit_version_load "$TOOL_DIR"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$TOOL_DIR/output"
PROBE_FILE="$OUT_DIR/.bootstrap-probe.json"
DEFAULT_DYNAMICS_SDK_VERSION="${BOOTSTRAP_DYNAMICS_SDK_VERSION:-$SUPPORTED_SDK_VERSION}"

# Scratch files used to pass multi-line / array data to the Python emit step
SCRATCH_DIR="$(mktemp -d -t bootstrap-scratch.XXXXXX)"
ERRORS_FILE="$SCRATCH_DIR/errors.txt"
WARNINGS_FILE="$SCRATCH_DIR/warnings.txt"
CLASS_INDEX_FILE="$SCRATCH_DIR/class_index.txt"
: > "$ERRORS_FILE"
: > "$WARNINGS_FILE"
: > "$CLASS_INDEX_FILE"
cleanup_scratch() { rm -rf "$SCRATCH_DIR"; }
trap cleanup_scratch EXIT

SUBCOMMAND=""
APP_MODULE_OVERRIDE=""

# Parse subcommand and flags in any order. Accepts `--app-module=foo`
# and `--app-module foo`.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-module=*)
            APP_MODULE_OVERRIDE="${1#--app-module=}"
            shift
            ;;
        --app-module)
            if [ -z "${2:-}" ]; then
                echo "--app-module requires a value" >&2
                exit 2
            fi
            APP_MODULE_OVERRIDE="$2"
            shift 2
            ;;
        --version|--help)
            SUBCOMMAND="$1"
            shift
            ;;
        probe)
            SUBCOMMAND="probe"
            shift
            ;;
        *)
            if [ -z "$SUBCOMMAND" ]; then
                SUBCOMMAND="$1"
            else
                echo "Unknown argument: $1" >&2
                exit 2
            fi
            shift
            ;;
    esac
done
SUBCOMMAND="${SUBCOMMAND:-probe}"

case "$SUBCOMMAND" in
    probe) ;;
    --version)
        toolkit_version_print
        exit 0
        ;;
    --help)
        echo "Usage: bash dynamics-migration-tool/tooling/bootstrap.sh probe [--app-module <name>]"
        echo ""
        echo "Probes environment, network, and Dynamics SDK class availability."
        echo "Writes results to dynamics-migration-tool/output/.bootstrap-probe.json."
        echo ""
        echo "Options:"
        echo "  --app-module <name>   Select the primary application module by"
        echo "                        repo-relative path (e.g. 'app-primary')."
        echo "                        Required for projects with multiple"
        echo "                        com.android.application modules and no"
        echo "                        canonical 'app/' directory; otherwise the"
        echo "                        canonical 'app' module is selected"
        echo "                        automatically."
        echo ""
        echo "Exit 0 on full pass; exit 1 on any failure; exit 3 when multiple"
        echo "application modules are detected and the developer must re-run"
        echo "with --app-module to disambiguate."
        exit 0
        ;;
    *)
        echo "Unknown subcommand: $SUBCOMMAND" >&2
        echo "Run with --help for usage." >&2
        exit 2
        ;;
esac

mkdir -p "$OUT_DIR"

echo "========================================="
echo "BlackBerry Dynamics — Bootstrap Probe"
echo "========================================="
echo "Toolkit Version: $TOOL_VERSION"
echo "Supported Dynamics SDK: $SUPPORTED_SDK_VERSION"
echo "Project: $PROJECT_ROOT"
echo ""

cd "$PROJECT_ROOT"

# --------- result accumulators ---------
PROBE_OK=true

probe_fail() {
    PROBE_OK=false
    printf '%s\n' "$1" >> "$ERRORS_FILE"
    echo "❌ $1" >&2
}
probe_warn() {
    printf '%s\n' "$1" >> "$WARNINGS_FILE"
    echo "⚠  $1"
}
probe_pass() {
    echo "✅ $1"
}

print_blackberry_maven_remediation() {
    cat >&2 <<'EOF'

BlackBerry Maven remediation
----------------------------
The bootstrap fallback could not prove that Gradle's effective repository
set can reach the BlackBerry Dynamics Maven repository:

  https://software.download.blackberry.com/repository/maven/

Apply the repository in the Gradle plane that owns dependency resolution for
this project, then re-run:

  bash dynamics-migration-tool/tooling/bootstrap.sh probe

If settings.gradle(.kts) has dependencyResolutionManagement with
RepositoriesMode.PREFER_SETTINGS or RepositoriesMode.FAIL_ON_PROJECT_REPOS,
add the repository there:

Groovy settings.gradle:

  dependencyResolutionManagement {
      repositories {
          maven { url 'https://software.download.blackberry.com/repository/maven/' }
      }
  }

Kotlin settings.gradle.kts:

  dependencyResolutionManagement {
      repositories {
          maven(url = "https://software.download.blackberry.com/repository/maven/")
      }
  }

If the project uses project-level repositories, especially
RepositoriesMode.PREFER_PROJECT, add the repository to the project-level
repositories block that applies to the app module:

Groovy build.gradle:

  allprojects {
      repositories {
          maven { url 'https://software.download.blackberry.com/repository/maven/' }
      }
  }

Kotlin build.gradle.kts:

  allprojects {
      repositories {
          maven(url = "https://software.download.blackberry.com/repository/maven/")
      }
  }

The fallback init script injects both settings-level and project-level
repositories, but some builds clear or replace repositories during evaluation.
In those projects the app's Gradle files must carry the repository explicitly.

EOF
}

# ========================================
# 1. OS / shell
# ========================================
echo "1. Operating environment"
echo "-----------------------------------------"
OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
OS_VERSION="$(uname -r 2>/dev/null || echo unknown)"
SHELL_NAME="$(basename "${SHELL:-/tooling/sh}")"
probe_pass "OS: $OS_NAME $OS_VERSION (shell: $SHELL_NAME)"
echo ""

# ========================================
# 2. JAVA_HOME / JDK 17+
# ========================================
echo "2. JDK"
echo "-----------------------------------------"
JDK_VERSION=""
JAVA_BIN=""
if [ -z "${JAVA_HOME:-}" ]; then
    probe_fail "JAVA_HOME is not set — set it to a JDK 17+ installation"
else
    if [ -x "$JAVA_HOME/bin/java" ]; then
        JAVA_BIN="$JAVA_HOME/bin/java"
    elif [ -x "$JAVA_HOME/tooling/java" ]; then
        JAVA_BIN="$JAVA_HOME/tooling/java"
    fi

    if [ -z "$JAVA_BIN" ]; then
        probe_fail "JAVA_HOME=$JAVA_HOME but neither $JAVA_HOME/bin/java nor $JAVA_HOME/tooling/java is executable"
    else
        JDK_VERSION="$("$JAVA_BIN" -version 2>&1 \
        | awk 'NR==1 { if (match($0, /"[0-9]+(\.[0-9]+)*/)) { v=substr($0, RSTART+1, RLENGTH-1); split(v, a, "."); print a[1] } }')"
        if [ -n "$JDK_VERSION" ] && [ "$JDK_VERSION" -ge 17 ] 2>/dev/null; then
            probe_pass "JDK $JDK_VERSION at $JAVA_HOME (java: $JAVA_BIN)"
        else
            probe_fail "JDK version ${JDK_VERSION:-unknown} at $JAVA_HOME is below 17 — Dynamics requires JDK 17+"
        fi
    fi
fi
echo ""

# ========================================
# 3. Android SDK
# ========================================
echo "3. Android SDK"
echo "-----------------------------------------"
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$ANDROID_SDK" ]; then
    probe_fail "Neither ANDROID_HOME nor ANDROID_SDK_ROOT is set"
elif [ ! -d "$ANDROID_SDK" ]; then
    probe_fail "Android SDK directory does not exist: $ANDROID_SDK"
else
    probe_pass "Android SDK at $ANDROID_SDK"
fi
echo ""

# ========================================
# 4. Gradle wrapper
# ========================================
echo "4. Gradle wrapper"
echo "-----------------------------------------"
GRADLE_VERSION=""
if [ ! -f "./gradlew" ]; then
    probe_fail "./gradlew not found in project root"
else
    chmod +x ./gradlew 2>/dev/null || true
    GRADLE_VERSION="$(./gradlew --version 2>/dev/null \
        | awk -F': *' '/^Gradle / { print $0 }' \
        | awk '{ print $2 }' | head -1)"
    if [ -n "$GRADLE_VERSION" ]; then
        probe_pass "Gradle $GRADLE_VERSION"
    else
        probe_warn "Gradle wrapper exists but --version did not return a version string"
    fi
fi
echo ""

# ========================================
# 5. Project shape and module map
# ========================================
echo "5. Project shape and module map"
echo "-----------------------------------------"

MODULE_MAP_FILE="$OUT_DIR/module-map.json"
DISCOVER_PY="$SCRIPT_DIR/lib/discover-modules.py"
DISCOVER_LOG="$(mktemp -t bootstrap-discover.XXXXXX)"

if [ ! -f "$DISCOVER_PY" ]; then
    probe_fail "tooling/lib/discover-modules.py not found — toolkit installation is incomplete"
else
    DISCOVER_ARGS=("$PROJECT_ROOT")
    if [ -n "$APP_MODULE_OVERRIDE" ]; then
        DISCOVER_ARGS+=("--app-module" "$APP_MODULE_OVERRIDE")
    fi

    set +e
    python3 "$DISCOVER_PY" "${DISCOVER_ARGS[@]}" \
        > "$MODULE_MAP_FILE.tmp" \
        2> "$DISCOVER_LOG"
    DISCOVER_RC=$?
    set -e

    case "$DISCOVER_RC" in
        0)
            mv "$MODULE_MAP_FILE.tmp" "$MODULE_MAP_FILE"
            ;;
        2)
            # Sentinel: multi-app project, no --app-module supplied
            rm -f "$MODULE_MAP_FILE.tmp"
            echo "❌ Multi-app project detected; primary application module is ambiguous." >&2
            echo "" >&2
            cat "$DISCOVER_LOG" >&2
            echo "" >&2
            echo "   Re-run bootstrap.sh with --app-module <name>, e.g.:" >&2
            echo "     bash dynamics-migration-tool/tooling/bootstrap.sh probe --app-module app-primary" >&2
            rm -f "$DISCOVER_LOG"
            exit 3
            ;;
        *)
            rm -f "$MODULE_MAP_FILE.tmp"
            probe_fail "Module discovery failed (exit $DISCOVER_RC):"
            sed 's/^/   /' "$DISCOVER_LOG" >&2
            ;;
    esac
fi
rm -f "$DISCOVER_LOG"

# ----- legacy variables, derived from the module map ------------------
# Source the accessor library so the rest of the script continues to
# reference the primary build file in a structure-aware way. We can't
# rely on the old `app/build.gradle` literal anymore — multi-module
# projects place the primary build file under app-primary/, etc.
. "$SCRIPT_DIR/lib/module-map.sh"
if [ -f "$MODULE_MAP_FILE" ]; then
    if ! mm_load "$MODULE_MAP_FILE"; then
        probe_fail "Generated module-map.json could not be loaded"
    fi
else
    # Fall back to synthesized map (single-module legacy path)
    if ! mm_load; then
        probe_fail "No module map and no app/ directory — not a recognized Android project"
    fi
fi

PROJECT_SHAPE="$(mm_project_shape 2>/dev/null || echo single-module)"
PRIMARY_PATH="$(mm_primary_path 2>/dev/null || echo app)"
APP_GRADLE="$(mm_primary_build_file 2>/dev/null || echo app/build.gradle)"
PRIMARY_NAME="$(mm_primary_name 2>/dev/null || echo app)"
DISCOVERY_METHOD="$(mm_discovery_method 2>/dev/null || echo fallback-app-dir)"

# Legacy 'app:' Gradle target name used by sections 7 and 8 below.
GRADLE_PRIMARY_TARGET=":$PRIMARY_NAME"

# Language detection — scan the union of every in-scope source root,
# not just app/src/main. Single-module projects still see only one root
# (app/src/main/java) so the result is identical to the old heuristic.
JAVA_FILES=""
KT_FILES=""
while IFS= read -r root; do
    [ -z "$root" ] && continue
    [ ! -d "$root" ] && continue
    if [ -z "$JAVA_FILES" ]; then
        JAVA_FILES=$(find "$root" -name "*.java" 2>/dev/null | head -1)
    fi
    if [ -z "$KT_FILES" ]; then
        KT_FILES=$(find "$root" -name "*.kt" 2>/dev/null | head -1)
    fi
    [ -n "$JAVA_FILES" ] && [ -n "$KT_FILES" ] && break
done <<EOF
$(mm_in_scope_source_roots 2>/dev/null)
EOF
LANGUAGE="Unknown"
if [ -n "$JAVA_FILES" ] && [ -n "$KT_FILES" ]; then
    LANGUAGE="Mixed"
elif [ -n "$KT_FILES" ]; then
    LANGUAGE="Kotlin"
elif [ -n "$JAVA_FILES" ]; then
    LANGUAGE="Java"
fi

# minSdk / compileSdk extraction — read from the primary app module's
# build file. For convention-plugin-driven modules we additionally
# fall back to the convention plugin's source file if the values
# aren't declared in the consuming build file.
MIN_SDK=""
COMPILE_SDK=""
__extract_sdk_levels() {
    local f="$1"
    [ -z "$f" ] || [ ! -f "$f" ] && return
    if [ -z "$MIN_SDK" ]; then
        MIN_SDK=$(grep -oE "minSdk(Version)?\s*[= ]\s*[0-9]+" "$f" 2>/dev/null \
            | grep -oE "[0-9]+" | head -1)
    fi
    if [ -z "$COMPILE_SDK" ]; then
        COMPILE_SDK=$(grep -oE "compileSdk(Version)?\s*[= ]\s*[0-9]+" "$f" 2>/dev/null \
            | grep -oE "[0-9]+" | head -1)
    fi
}
__extract_sdk_levels "$APP_GRADLE"
CP_SOURCE_FILE="$(mm_convention_plugin_for "$PRIMARY_PATH" 2>/dev/null || echo "")"
if [ -n "$CP_SOURCE_FILE" ]; then
    __extract_sdk_levels "$CP_SOURCE_FILE"
fi

probe_pass "$PROJECT_SHAPE / primary: $PRIMARY_PATH / language: $LANGUAGE / minSdk: ${MIN_SDK:-unknown} / compileSdk: ${COMPILE_SDK:-unknown}"
if [ -f "$MODULE_MAP_FILE" ]; then
    LIB_COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["libraryModulesInScope"]))' "$MODULE_MAP_FILE" 2>/dev/null || echo 0)"
    OTHER_APP_COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["otherAppModules"]))' "$MODULE_MAP_FILE" 2>/dev/null || echo 0)"
    EXCL_TEST_COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["excludedTestOnlyModules"]))' "$MODULE_MAP_FILE" 2>/dev/null || echo 0)"
    probe_pass "Module map: $MODULE_MAP_FILE  (libs in scope: $LIB_COUNT, other apps: $OTHER_APP_COUNT, excluded test-only: $EXCL_TEST_COUNT, discovery: $DISCOVERY_METHOD)"
    MM_WARNING_COUNT="$(mm_warning_count 2>/dev/null || echo 0)"
    if [ "${MM_WARNING_COUNT:-0}" -gt 0 ] 2>/dev/null; then
        while IFS= read -r w; do
            [ -n "$w" ] && probe_warn "module-map: $w"
        done <<EOF
$(mm_warnings 2>/dev/null)
EOF
    fi
fi
echo ""

# ========================================
# 6. Git fingerprint
# ========================================
echo "6. Git fingerprint"
echo "-----------------------------------------"
GIT_BRANCH=""
GIT_COMMIT=""
GIT_PRESENT="false"
GIT_REMOTE=""
GIT_DIRTY="false"
if git rev-parse --git-dir >/dev/null 2>&1; then
    GIT_PRESENT="true"
    GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    GIT_REMOTE="$(git config --get remote.origin.url 2>/dev/null || echo "")"
    if [ -n "$(bash "$SCRIPT_DIR/git-working-tree.sh" porcelain 2>/dev/null)" ]; then
        GIT_DIRTY="true"
        probe_warn "Working tree has uncommitted app changes (toolkit, .cursor/.kiro, AGENTS.md excluded)"
    fi
    probe_pass "branch: $GIT_BRANCH @ ${GIT_COMMIT:0:10}"
else
    probe_fail "Git baseline missing — Android migrations require a Git repository with a pre-migration baseline commit"
    cat <<'EOF'
   Re-run prompt 00pre. It must ask for explicit developer consent, then run:
     bash dynamics-migration-tool/tooling/lib/ensure-git-baseline.sh --consented

   The helper initializes Git if needed, excludes toolkit artifacts via
   .git/info/exclude, and creates the pre-migration app-source baseline commit.
EOF
fi
echo ""

# Stop early if any of the prerequisite blocks failed
if [ "$PROBE_OK" = false ]; then
    echo ""
    echo "❌ Bootstrap probe FAILED on environment prerequisites." >&2
    echo "   Resolve the issues above and re-run." >&2
    # still write a probe file so the agent can read errors
    PHASE="environment"
else
    PHASE="environment-ok"
fi

# ========================================
# 7. Network probe — resolve Dynamics SDK
# ========================================
RESOLVED_SDK_VERSION=""
RESOLVED_SDK_ARTIFACT=""
DEPS_LOG=""
SDK_PROBE_COMMAND="./gradlew ${GRADLE_PRIMARY_TARGET}:dependencies --configuration debugRuntimeClasspath"
SDK_PROBE_COMMAND_DESCRIPTION="Resolved the Dynamics SDK from ${PRIMARY_NAME} debugRuntimeClasspath via Gradle."
SDK_PROBE_FALLBACK_USED=false
if [ "$PROBE_OK" = true ]; then
    echo "7. Network probe (resolving Dynamics SDK via Gradle)"
    echo "-----------------------------------------"
    DEPS_LOG="$(mktemp -t bootstrap-deps.XXXXXX)"
    # Product-flavor apps do not expose plain debugRuntimeClasspath — they use
    # <flavor>DebugRuntimeClasspath. Discover those configs, prefer ones matching
    # the primary module name, then fall back to unflavored debugRuntimeClasspath
    # and finally root :dependencies.
    RUNTIME_CFG_INIT="$(mktemp -t bootstrap-runtime-cfgs.XXXXXX.gradle)"
    cat > "$RUNTIME_CFG_INIT" <<'EOF'
gradle.projectsEvaluated {
    def target = System.getProperty('bootstrap.primaryTarget')
    def p = (target == null || target.trim().isEmpty()) ? null : rootProject.findProject(target)
    if (p == null) { println 'BOOTSTRAP_DEBUG_RUNTIME_CONFIGS='; return }
    def names = p.configurations.names.findAll { it.endsWith('DebugRuntimeClasspath') }.sort()
    println 'BOOTSTRAP_DEBUG_RUNTIME_CONFIGS=' + names.join(',')
}
EOF
    RUNTIME_CFG_LIST="$(./gradlew -I "$RUNTIME_CFG_INIT" \
        -Dbootstrap.primaryTarget="$GRADLE_PRIMARY_TARGET" \
        help -q 2>/dev/null \
        | sed -n 's/^BOOTSTRAP_DEBUG_RUNTIME_CONFIGS=//p' | tail -1 || true)"
    rm -f "$RUNTIME_CFG_INIT"

    CANDIDATE_CFGS=""
    if [ -n "$RUNTIME_CFG_LIST" ]; then
        IFS=',' read -r -a _discovered_cfgs <<< "$RUNTIME_CFG_LIST"
        for _cfg in "${_discovered_cfgs[@]}"; do
            case "$_cfg" in
                "${PRIMARY_NAME}"DebugRuntimeClasspath|"${PRIMARY_NAME}"*DebugRuntimeClasspath)
                    CANDIDATE_CFGS="${CANDIDATE_CFGS} ${_cfg}"
                    ;;
            esac
        done
        for _cfg in "${_discovered_cfgs[@]}"; do
            case " ${CANDIDATE_CFGS} " in
                *" ${_cfg} "*) ;;
                *) CANDIDATE_CFGS="${CANDIDATE_CFGS} ${_cfg}" ;;
            esac
        done
    fi
    case " ${CANDIDATE_CFGS} " in
        *" debugRuntimeClasspath "*) ;;
        *) CANDIDATE_CFGS="${CANDIDATE_CFGS} debugRuntimeClasspath" ;;
    esac

    DEPS_RESOLVED=false
    RESOLVED_RUNTIME_CFG=""
    RESOLVE_SCOPE=""
    for _cfg in $CANDIDATE_CFGS; do
        if ./gradlew "${GRADLE_PRIMARY_TARGET}:dependencies" --configuration "$_cfg" \
                > "$DEPS_LOG" 2>&1; then
            SDK_PROBE_COMMAND="./gradlew ${GRADLE_PRIMARY_TARGET}:dependencies --configuration ${_cfg}"
            RESOLVED_RUNTIME_CFG="$_cfg"
            RESOLVE_SCOPE="module"
            DEPS_RESOLVED=true
            break
        fi
    done
    if [ "$DEPS_RESOLVED" = false ] && ./gradlew :dependencies --configuration debugRuntimeClasspath \
            > "$DEPS_LOG" 2>&1; then
        SDK_PROBE_COMMAND="./gradlew :dependencies --configuration debugRuntimeClasspath"
        RESOLVED_RUNTIME_CFG="debugRuntimeClasspath"
        RESOLVE_SCOPE="root"
        DEPS_RESOLVED=true
    fi
    if [ "$DEPS_RESOLVED" = false ]; then
        probe_fail "Gradle dependency resolution failed — last 30 lines below"
        echo "--- gradle output (tail) ---" >&2
        tail -30 "$DEPS_LOG" >&2
        echo "--- end gradle output ---" >&2
    elif [ "$RESOLVE_SCOPE" = "root" ]; then
        SDK_PROBE_COMMAND_DESCRIPTION="Resolved the Dynamics SDK from root project ${RESOLVED_RUNTIME_CFG} via Gradle."
    elif [ -n "$RESOLVED_RUNTIME_CFG" ]; then
        SDK_PROBE_COMMAND_DESCRIPTION="Resolved the Dynamics SDK from ${PRIMARY_NAME} ${RESOLVED_RUNTIME_CFG} via Gradle."
    fi

    if [ "$PROBE_OK" = true ]; then
        RESOLVED_SDK_ARTIFACT="$(grep -oE 'com\.blackberry\.blackberrydynamics:[A-Za-z0-9_]+:[0-9]+(\.[0-9]+)+(-[A-Za-z0-9.+_-]+)?' "$DEPS_LOG" \
            | sort -u | head -1 || true)"
        if [ -n "$RESOLVED_SDK_ARTIFACT" ]; then
            RESOLVED_SDK_VERSION="${RESOLVED_SDK_ARTIFACT##*:}"
            if [ "$RESOLVE_SCOPE" = "root" ]; then
                SDK_PROBE_COMMAND_DESCRIPTION="Resolved Dynamics SDK $RESOLVED_SDK_VERSION from root project ${RESOLVED_RUNTIME_CFG:-debugRuntimeClasspath} via Gradle."
            else
                SDK_PROBE_COMMAND_DESCRIPTION="Resolved Dynamics SDK $RESOLVED_SDK_VERSION from ${PRIMARY_NAME} ${RESOLVED_RUNTIME_CFG:-debugRuntimeClasspath} via Gradle."
            fi
            probe_pass "Resolved Dynamics SDK: $RESOLVED_SDK_ARTIFACT"
        else
            probe_warn "No Dynamics artifact found in app runtimeClasspath yet (fresh project before prompt 01 is expected). Attempting bootstrap fallback resolver."
            FALLBACK_LOG="$(mktemp -t bootstrap-fallback.XXXXXX)"
            # Persist the fallback init script to a stable, in-tool path so the
            # recorded probeCommand is reproducible after the run completes
            # (the previous `mktemp` path vanished as soon as the script exited).
            FALLBACK_INIT="$OUT_DIR/.bootstrap-fallback-init.gradle"
            mkdir -p "$OUT_DIR"
            cat > "$FALLBACK_INIT" <<'EOF'
gradle.ext.bootstrapBlackBerryRepoUrl = 'https://software.download.blackberry.com/repository/maven/'
gradle.ext.bootstrapRepositoriesMode = 'unknown'
gradle.ext.bootstrapSettingsRepoUrls = []
gradle.ext.bootstrapSettingsRepoInjectionError = null
gradle.ext.bootstrapProjectRepoInjectionErrors = []

def bootstrapNormalizeRepoUrl = { raw ->
    raw == null ? '' : raw.toString().replaceAll('/+$', '')
}

def bootstrapRepoUrl = { repo ->
    try {
        return repo.hasProperty('url') ? repo.url?.toString() : null
    } catch (Throwable ignored) {
        return null
    }
}

def bootstrapIsBlackBerryRepo = { raw ->
    bootstrapNormalizeRepoUrl(raw) == bootstrapNormalizeRepoUrl(gradle.ext.bootstrapBlackBerryRepoUrl)
}

def bootstrapRepoUrls = { repos ->
    repos.collect { repo ->
        def url = bootstrapRepoUrl(repo)
        url == null ? "${repo.name ?: repo.class.simpleName}" : url
    }
}

def bootstrapHasBlackBerryRepo = { repos ->
    repos.any { repo -> bootstrapIsBlackBerryRepo(bootstrapRepoUrl(repo)) }
}

def bootstrapEnsureSettingsRepo = { settings ->
    try {
        def drm = settings.dependencyResolutionManagement
        try {
            gradle.ext.bootstrapRepositoriesMode = drm.repositoriesMode.get().toString()
        } catch (Throwable ignored) {
            gradle.ext.bootstrapRepositoriesMode = 'unknown'
        }
        if (!bootstrapHasBlackBerryRepo(drm.repositories)) {
            drm.repositories.maven {
                name = 'BlackBerryDynamicsBootstrap'
                url gradle.ext.bootstrapBlackBerryRepoUrl
            }
        }
        gradle.ext.bootstrapSettingsRepoUrls = bootstrapRepoUrls(drm.repositories)
    } catch (Throwable t) {
        gradle.ext.bootstrapSettingsRepoInjectionError = "${t.class.simpleName}: ${t.message}"
    }
}

def bootstrapEnsureProjectRepos = { root ->
    def errors = []
    root.allprojects { project ->
        try {
            if (!bootstrapHasBlackBerryRepo(project.repositories)) {
                project.repositories.maven {
                    name = 'BlackBerryDynamicsBootstrap'
                    url gradle.ext.bootstrapBlackBerryRepoUrl
                }
            }
        } catch (Throwable t) {
            errors << "${project.path}: ${t.class.simpleName}: ${t.message}"
        }
    }
    gradle.ext.bootstrapProjectRepoInjectionErrors = errors
    return errors
}

gradle.settingsEvaluated { settings ->
    bootstrapEnsureSettingsRepo(settings)
}

gradle.projectsLoaded {
    rootProject {
        tasks.register("bootstrapVerifyDynamicsRepositories") {
            doLast {
                def projectErrors = bootstrapEnsureProjectRepos(rootProject)
                def settingsUrls = gradle.ext.bootstrapSettingsRepoUrls ?: []
                def projectRepoRows = []
                rootProject.allprojects { project ->
                    bootstrapRepoUrls(project.repositories).each { url ->
                        projectRepoRows << [path: project.path, url: url]
                    }
                }
                def settingsHasBlackBerry = settingsUrls.any { bootstrapIsBlackBerryRepo(it) }
                def projectHasBlackBerry = projectRepoRows.any { row -> bootstrapIsBlackBerryRepo(row.url) }
                def mode = (gradle.ext.bootstrapRepositoriesMode ?: 'unknown').toString()
                println("BOOTSTRAP_REPOSITORIES_MODE ${mode}")
                settingsUrls.each { println("BOOTSTRAP_SETTINGS_REPOSITORY ${it}") }
                projectRepoRows.each { row -> println("BOOTSTRAP_PROJECT_REPOSITORY ${row.path} ${row.url}") }
                if (gradle.ext.bootstrapSettingsRepoInjectionError) {
                    println("BOOTSTRAP_SETTINGS_REPOSITORY_ERROR ${gradle.ext.bootstrapSettingsRepoInjectionError}")
                }
                projectErrors.each { println("BOOTSTRAP_PROJECT_REPOSITORY_ERROR ${it}") }

                if (!settingsHasBlackBerry && !projectHasBlackBerry) {
                    throw new GradleException("BlackBerry Maven repository is absent from both settings-level and project-level repositories after bootstrap injection.")
                }
                if (mode.contains('PREFER_PROJECT') && !projectHasBlackBerry) {
                    throw new GradleException("repositoriesMode=PREFER_PROJECT: project-level repositories override settings-level repositories, and BlackBerry Maven is missing from project repositories.")
                }
                if ((mode.contains('PREFER_SETTINGS') || mode.contains('FAIL_ON_PROJECT_REPOS')) && !settingsHasBlackBerry) {
                    throw new GradleException("repositoriesMode=${mode}: settings-level repositories own dependency resolution, and BlackBerry Maven is missing from dependencyResolutionManagement.repositories.")
                }
                println("BOOTSTRAP_EFFECTIVE_BLACKBERRY_REPOSITORY settings=${settingsHasBlackBerry} project=${projectHasBlackBerry}")
            }
        }
        tasks.register("bootstrapResolveDynamicsArtifacts") {
            dependsOn("bootstrapVerifyDynamicsRepositories")
            doLast {
                def v = System.getProperty("bootstrapDynamicsVersion")
                if (v == null || v.trim().isEmpty()) {
                    throw new GradleException("Missing -DbootstrapDynamicsVersion")
                }
                def coords = [
                    "com.blackberry.blackberrydynamics:android_handheld_platform:${v}",
                    "com.blackberry.blackberrydynamics:android_handheld_resources:${v}",
                    "com.blackberry.blackberrydynamics:android_handheld_backup_support:${v}",
                    "com.blackberry.blackberrydynamics:android_webview:${v}",
                ]
                def deps = coords.collect { dependencies.create(it) }
                def detached = configurations.detachedConfiguration(*deps)
                detached.transitive = true
                detached.resolve().each { f ->
                    println("BOOTSTRAP_RESOLVED_FILE " + f.name)
                }
            }
        }
    }
}
EOF

            if ./gradlew -I "$FALLBACK_INIT" bootstrapResolveDynamicsArtifacts \
                    -DbootstrapDynamicsVersion="$DEFAULT_DYNAMICS_SDK_VERSION" \
                    > "$FALLBACK_LOG" 2>&1; then
                RESOLVED_SDK_VERSION="$DEFAULT_DYNAMICS_SDK_VERSION"
                RESOLVED_SDK_ARTIFACT="com.blackberry.blackberrydynamics:android_handheld_platform:$RESOLVED_SDK_VERSION"
                # Record the literal, reproducible command (note: relative to
                # project root, with the stable in-tool init-script path).
                SDK_PROBE_COMMAND="./gradlew -I dynamics-migration-tool/output/.bootstrap-fallback-init.gradle bootstrapResolveDynamicsArtifacts -DbootstrapDynamicsVersion=$DEFAULT_DYNAMICS_SDK_VERSION"
                SDK_PROBE_COMMAND_DESCRIPTION="Probed BlackBerry Maven via in-tool Gradle init script (dynamics-migration-tool/output/.bootstrap-fallback-init.gradle) requesting Dynamics SDK $DEFAULT_DYNAMICS_SDK_VERSION."
                SDK_PROBE_FALLBACK_USED=true
                probe_pass "Fallback resolver pulled Dynamics SDK $RESOLVED_SDK_VERSION for bootstrap probing"
            else
                probe_fail "No com.blackberry.blackberrydynamics:* artifact found in classpath, and fallback resolver also failed. The Gradle repository list may not include BlackBerry Maven in the repository plane that owns dependency resolution, or Maven may not yet publish the toolkit's default Dynamics SDK pin ($DEFAULT_DYNAMICS_SDK_VERSION). Last 30 lines below."
                echo "--- fallback gradle output (tail) ---" >&2
                tail -30 "$FALLBACK_LOG" >&2
                echo "--- end fallback gradle output ---" >&2
                echo "If maven-metadata.xml still lists only 14.x while this toolkit targets 15.1, override temporarily with BOOTSTRAP_DYNAMICS_SDK_VERSION=<published-version> once you confirm the artifact is reachable, then re-pin to 15.1.8766.18 when Maven publishes it." >&2
                print_blackberry_maven_remediation
            fi
            rm -f "$FALLBACK_LOG"
            # Intentionally keep $FALLBACK_INIT around: SDK_PROBE_COMMAND
            # references it so the recorded probe is reproducible by a human
            # auditor after the fact. It is cheap, deterministic, and lives
            # under output/ which is committed alongside the audit trail.
        fi
    fi
    echo ""
fi

# ========================================
# 7b. Process model (multi-process discovery)
# ========================================
echo "7b. Process model"
echo "-----------------------------------------"
PROCESS_MODEL_FILE="$SCRATCH_DIR/process-model.json"
MANIFEST_LIST_FILE="$SCRATCH_DIR/manifest-list.txt"
: > "$MANIFEST_LIST_FILE"
if mm_load "$MODULE_MAP_FILE" 2>/dev/null; then
    mm_primary_manifests 2>/dev/null >> "$MANIFEST_LIST_FILE" || true
    PRIMARY_PATH_FOR_MERGED="$(mm_primary_path 2>/dev/null || echo "")"
    if [ -n "$PRIMARY_PATH_FOR_MERGED" ]; then
        while IFS= read -r merged; do
            [ -n "$merged" ] && printf '%s\n' "$merged" >> "$MANIFEST_LIST_FILE"
        done < <(find "$PROJECT_ROOT/$PRIMARY_PATH_FOR_MERGED/build" \
            -path "*/merged_manifest/*/AndroidManifest.xml" 2>/dev/null | head -5)
    fi
fi
# In-scope source roots for background-entry-point source scanning
# (WorkManager subclasses are not declared in the manifest and must be
# located in source). Also used to resolve the owning module name for
# each manifest-declared service/receiver.
IN_SCOPE_SOURCE_ROOTS_FILE="$SCRATCH_DIR/in-scope-source-roots.txt"
: > "$IN_SCOPE_SOURCE_ROOTS_FILE"
PRIMARY_MODULE_PATH_FOR_PROBE=""
if mm_load "$MODULE_MAP_FILE" 2>/dev/null; then
    mm_in_scope_source_roots 2>/dev/null > "$IN_SCOPE_SOURCE_ROOTS_FILE" || true
    PRIMARY_MODULE_PATH_FOR_PROBE="$(mm_primary_path 2>/dev/null || echo "")"
fi
export PROJECT_ROOT PROCESS_MODEL_FILE MANIFEST_LIST_FILE IN_SCOPE_SOURCE_ROOTS_FILE PRIMARY_MODULE_PATH_FOR_PROBE MODULE_MAP_FILE
python3 - <<'PY'
import json
import os
import re
import xml.etree.ElementTree as ET

project_root = os.environ.get("PROJECT_ROOT", ".")
out_path = os.environ["PROCESS_MODEL_FILE"]
manifest_list_path = os.environ.get("MANIFEST_LIST_FILE", "")
in_scope_roots_path = os.environ.get("IN_SCOPE_SOURCE_ROOTS_FILE", "")
primary_module_path = os.environ.get("PRIMARY_MODULE_PATH_FOR_PROBE", "") or "app"
module_map_path = os.environ.get("MODULE_MAP_FILE", "")

manifest_paths = []
if manifest_list_path and os.path.isfile(manifest_list_path):
    with open(manifest_list_path) as f:
        manifest_paths = [ln.strip() for ln in f if ln.strip()]

seen = set()
ordered = []
for p in manifest_paths:
    ap = os.path.abspath(os.path.join(project_root, p)) if not os.path.isabs(p) else p
    if ap in seen or not os.path.isfile(ap):
        continue
    seen.add(ap)
    ordered.append(ap)

# Module-name lookup: map module path -> module name from module-map.json.
# Used so background-entry-point entries record the owning Gradle module
# name (not just the on-disk path).
module_path_to_name = {}
primary_module_name = "app"
in_scope_modules = []  # list of (path, name)
if module_map_path and os.path.isfile(module_map_path):
    try:
        with open(module_map_path, encoding="utf-8") as f:
            mm = json.load(f)
        prim = (mm or {}).get("primaryAppModule") or {}
        if isinstance(prim, dict) and prim.get("path"):
            module_path_to_name[prim["path"]] = prim.get("name") or "app"
            primary_module_name = prim.get("name") or "app"
            in_scope_modules.append((prim["path"], primary_module_name))
        for lib in (mm.get("libraryModulesInScope") or []):
            if isinstance(lib, dict) and lib.get("path"):
                module_path_to_name[lib["path"]] = lib.get("name") or os.path.basename(lib["path"])
                in_scope_modules.append((lib["path"], lib.get("name") or os.path.basename(lib["path"])))
    except Exception:
        pass

def module_for_path(rel_path):
    """Return the in-scope module name whose path is the longest prefix of rel_path."""
    best_path = ""
    best_name = primary_module_name
    for mpath, mname in in_scope_modules:
        norm = mpath.rstrip("/")
        if (rel_path == norm or rel_path.startswith(norm + "/")) and len(norm) > len(best_path):
            best_path = norm
            best_name = mname
    return best_name

in_scope_source_roots = []
if in_scope_roots_path and os.path.isfile(in_scope_roots_path):
    with open(in_scope_roots_path) as f:
        in_scope_source_roots = [ln.strip() for ln in f if ln.strip()]

ANDROID_NS = "{http://schemas.android.com/apk/res/android}"
TOOLS_NS = "{http://schemas.android.com/tools}"
discovery = "source-manifest-scan"
if any("/merged_manifest/" in p for p in ordered):
    discovery = "merged-manifest"

components = []
manifest_services_and_receivers = []  # (rel_manifest, kind, name)
manifest_providers = []
app_startup_providers = []
app_startup_initializers = []
workmanager_metadata_entries = []
workmanager_initializer_enabled = False
workmanager_initializer_disabled = False

def local_name(tag):
    return tag.split("}", 1)[-1] if "}" in tag else tag

def resolve_component_name(raw_name, pkg):
    if not raw_name:
        return ""
    if raw_name.startswith("."):
        return (pkg + raw_name) if pkg else raw_name.lstrip(".")
    if "." in raw_name:
        return raw_name
    return f"{pkg}.{raw_name}" if pkg else raw_name

def parse_manifest(path):
    global workmanager_initializer_enabled
    global workmanager_initializer_disabled
    try:
        tree = ET.parse(path)
        root = tree.getroot()
    except Exception:
        return
    pkg = root.get("package") or root.get(f"{ANDROID_NS}package") or ""
    rel_manifest = os.path.relpath(path, project_root)
    module_name = module_for_path(rel_manifest)
    for elem in root.iter():
        kind = local_name(elem.tag)
        if kind not in ("activity", "service", "receiver", "provider"):
            continue
        raw_name = elem.get(f"{ANDROID_NS}name") or ""
        name = resolve_component_name(raw_name, pkg)
        if not name:
            continue
        if kind in ("service", "receiver"):
            manifest_services_and_receivers.append((rel_manifest, kind, name))
        if kind in ("activity", "service", "provider"):
            proc = elem.get(f"{ANDROID_NS}process")
            classification = "auxiliary" if proc else "main"
            components.append({
                "classification": classification,
                "kind": kind,
                "manifest": rel_manifest,
                "name": name,
                "process": proc,
            })
        if kind == "provider":
            manifest_providers.append({
                "manifest": rel_manifest,
                "module": module_name,
                "name": name,
                "process": elem.get(f"{ANDROID_NS}process"),
            })
            provider_tools_node = (elem.get(f"{TOOLS_NS}node") or "").strip().lower()
            provider_removed = "remove" in provider_tools_node
            if name == "androidx.work.impl.WorkManagerInitializer":
                if provider_removed:
                    workmanager_initializer_disabled = True
                else:
                    workmanager_initializer_enabled = True
            if name == "androidx.startup.InitializationProvider":
                app_startup_providers.append({
                    "manifest": rel_manifest,
                    "module": module_name,
                    "name": name,
                    "process": elem.get(f"{ANDROID_NS}process"),
                    "removedByToolsNode": provider_removed,
                })
                for child in list(elem):
                    if local_name(child.tag) != "meta-data":
                        continue
                    md_name = resolve_component_name(
                        child.get(f"{ANDROID_NS}name") or "",
                        pkg,
                    )
                    md_value = (child.get(f"{ANDROID_NS}value") or "").strip()
                    md_tools_node = (child.get(f"{TOOLS_NS}node") or "").strip().lower()
                    md_removed = provider_removed or ("remove" in md_tools_node)
                    if md_name == "androidx.work.WorkManagerInitializer":
                        workmanager_metadata_entries.append({
                            "manifest": rel_manifest,
                            "module": module_name,
                            "name": md_name,
                            "removedByToolsNode": md_removed,
                            "value": md_value,
                        })
                        if md_removed:
                            workmanager_initializer_disabled = True
                        else:
                            workmanager_initializer_enabled = True
                        continue
                    if md_value == "androidx.startup" and md_name and not md_removed:
                        app_startup_initializers.append({
                            "manifest": rel_manifest,
                            "module": module_name,
                            "name": md_name,
                            "provider": name,
                        })

for path in ordered:
    parse_manifest(path)

# ---------------------------------------------------------------------
# Background entry point discovery.
#
# Three sources:
#   1. Manifest <service> entries whose source declares it extends a
#      known push/job base class.
#   2. Manifest <receiver> entries whose source touches a Dynamics
#      secure API (heuristic — flag for prompt 03c review).
#   3. Source files anywhere in in-scope source roots whose class
#      declaration extends a WorkManager ListenableWorker base class.
# Discovery is offline + deterministic.
# ---------------------------------------------------------------------
BACKGROUND_SERVICE_BASES = [
    "com.google.firebase.messaging.FirebaseMessagingService",
    "androidx.core.app.JobIntentService",
    "android.support.v4.app.JobIntentService",
    "android.app.job.JobService",
    "androidx.work.multiprocess.RemoteWorkerService",
]
WORKER_BASES = [
    "androidx.work.ListenableWorker",
    "androidx.work.Worker",
    "androidx.work.CoroutineWorker",
    "androidx.work.RxWorker",
    "androidx.work.rxjava3.RxWorker",
]
WORKMANAGER_CONFIG_PROVIDER_RE = re.compile(
    r"\bclass\s+[A-Za-z_][A-Za-z0-9_]*[^\n{]*"
    r"(?:implements\s+[^\n{]*\b(?:androidx\.work\.)?Configuration\.Provider\b"
    r"|:\s*[^\n{]*\b(?:androidx\.work\.)?Configuration\.Provider\b)"
)
WORKMANAGER_WORKER_FACTORY_RE = re.compile(
    r"\bclass\s+[A-Za-z_][A-Za-z0-9_]*[^\n{]*"
    r"(?:extends\s+[^\n{]*\b(?:androidx\.work\.)?WorkerFactory\b"
    r"|:\s*[^\n{]*\b(?:androidx\.work\.)?WorkerFactory\b)"
)
SECURE_API_TOKENS = (
    "GDFileSystem",
    "com.good.gd.file.",
    "com.good.gd.database.",
    "GDHttpClient",
    "GDSocket",
    "getApplicationPolicy",
)

# Build a class-name -> (absolute file path, parent FQCN candidates) index
# for every .java / .kt under the in-scope source roots. We only need the
# class-name line, not the full file body. Limit file sizes for safety.
class_index = {}  # short class name -> list[(abs_path, head_text)]
for root in in_scope_source_roots:
    abs_root = root if os.path.isabs(root) else os.path.join(project_root, root)
    if not os.path.isdir(abs_root):
        continue
    for dirpath, _, files in os.walk(abs_root):
        for fn in files:
            if not fn.endswith((".java", ".kt")):
                continue
            ap = os.path.join(dirpath, fn)
            try:
                with open(ap, encoding="utf-8", errors="replace") as f:
                    head = f.read(8192)
            except OSError:
                continue
            m = re.search(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)", head)
            if not m:
                continue
            class_index.setdefault(m.group(1), []).append((ap, head))

def parents_in_file(head_text):
    """Best-effort list of FQCN-ish parent tokens from `extends` and Kotlin `: X`."""
    parents = []
    imports = dict(re.findall(r"^\s*import\s+([\w\.]+)\.([A-Za-z_][A-Za-z0-9_]*)\s*;?\s*$", head_text, re.MULTILINE))
    for m in re.finditer(r"\bextends\s+([A-Za-z_][\w\.]*)", head_text):
        parents.append(m.group(1))
    for m in re.finditer(r"class\s+[A-Za-z_][A-Za-z0-9_]*[^\n{]*?:\s*([A-Za-z_][\w\.]*)\s*\(", head_text):
        parents.append(m.group(1))
    # Resolve simple-name imports to FQCN.
    resolved = []
    for p in parents:
        if "." in p:
            resolved.append(p)
        elif p in imports:
            resolved.append(f"{imports[p]}.{p}")
        else:
            resolved.append(p)
    return resolved

def short(fqcn):
    return fqcn.rsplit(".", 1)[-1]

def fqcn_for_decl(cls_name, head_text):
    pkg_m = re.search(r"^\s*package\s+([\w\.]+)", head_text, re.MULTILINE)
    return f"{pkg_m.group(1)}.{cls_name}" if pkg_m else cls_name

background_entry_points = []
recorded_names = set()  # de-dup keyed on FQCN
workmanager_configuration_providers = []
workmanager_worker_factories = []
seen_workmanager_cfg = set()
seen_workmanager_factories = set()

# 1. Manifest services -> match against known push/job base classes.
for rel_manifest, kind, fqcn in manifest_services_and_receivers:
    if kind != "service":
        continue
    sname = short(fqcn)
    file_matches = class_index.get(sname, [])
    matched_base = None
    matched_file = None
    for ap, head in file_matches:
        # If multiple files share a short name, prefer one whose package matches.
        pkg_m = re.search(r"^\s*package\s+([\w\.]+)", head, re.MULTILINE)
        if pkg_m and fqcn != f"{pkg_m.group(1)}.{sname}":
            continue
        for parent in parents_in_file(head):
            for base in BACKGROUND_SERVICE_BASES:
                if parent == base or parent == short(base):
                    matched_base = base
                    matched_file = ap
                    break
            if matched_base:
                break
        if matched_base:
            break
    if matched_base:
        rel_file = os.path.relpath(matched_file, project_root) if matched_file else None
        background_entry_points.append({
            "baseClass": matched_base,
            "kind": "service",
            "manifest": rel_manifest,
            "module": module_for_path(rel_manifest),
            "name": fqcn,
        })
        recorded_names.add(fqcn)

# 2. Manifest receivers -> flag those whose source touches secure APIs.
for rel_manifest, kind, fqcn in manifest_services_and_receivers:
    if kind != "receiver":
        continue
    if fqcn in recorded_names:
        continue
    sname = short(fqcn)
    file_matches = class_index.get(sname, [])
    flagged = False
    matched_file = None
    for ap, head in file_matches:
        pkg_m = re.search(r"^\s*package\s+([\w\.]+)", head, re.MULTILINE)
        if pkg_m and fqcn != f"{pkg_m.group(1)}.{sname}":
            continue
        try:
            with open(ap, encoding="utf-8", errors="replace") as f:
                body = f.read()
        except OSError:
            continue
        if any(tok in body for tok in SECURE_API_TOKENS):
            flagged = True
            matched_file = ap
            break
    if flagged:
        background_entry_points.append({
            "baseClass": "android.content.BroadcastReceiver",
            "kind": "receiver",
            "manifest": rel_manifest,
            "module": module_for_path(rel_manifest),
            "name": fqcn,
        })
        recorded_names.add(fqcn)

# 3. WorkManager workers (declared in source, not manifest).
for cls_name, entries in class_index.items():
    for ap, head in entries:
        for parent in parents_in_file(head):
            matched_base = None
            for base in WORKER_BASES:
                if parent == base or parent == short(base):
                    matched_base = base
                    break
            if not matched_base:
                continue
            pkg_m = re.search(r"^\s*package\s+([\w\.]+)", head, re.MULTILINE)
            fqcn = f"{pkg_m.group(1)}.{cls_name}" if pkg_m else cls_name
            if fqcn in recorded_names:
                break
            rel_file = os.path.relpath(ap, project_root)
            background_entry_points.append({
                "baseClass": matched_base,
                "kind": "worker",
                "manifest": None,
                "module": module_for_path(rel_file),
                "name": fqcn,
            })
            recorded_names.add(fqcn)
            break

for cls_name, entries in class_index.items():
    for ap, head in entries:
        fqcn = fqcn_for_decl(cls_name, head)
        rel_file = os.path.relpath(ap, project_root)
        module_name = module_for_path(rel_file)
        if WORKMANAGER_CONFIG_PROVIDER_RE.search(head) and fqcn not in seen_workmanager_cfg:
            workmanager_configuration_providers.append({
                "module": module_name,
                "name": fqcn,
                "source": rel_file,
            })
            seen_workmanager_cfg.add(fqcn)
        if WORKMANAGER_WORKER_FACTORY_RE.search(head) and fqcn not in seen_workmanager_factories:
            workmanager_worker_factories.append({
                "module": module_name,
                "name": fqcn,
                "source": rel_file,
            })
            seen_workmanager_factories.add(fqcn)

if workmanager_initializer_enabled:
    workmanager_initializer_state = "enabled"
elif workmanager_initializer_disabled:
    workmanager_initializer_state = "disabled"
else:
    workmanager_initializer_state = "not-detected"

model = {
    "backgroundEntryPoints": sorted(
        background_entry_points,
        key=lambda b: (b["kind"], b["name"]),
    ),
    "components": sorted(components, key=lambda c: (c["name"], c["kind"])),
    "discoveryMethod": discovery,
    "mainProcessName": None,
    "schemaVersion": "1.0.0",
    "startupModel": {
        "schemaVersion": "1.0.0",
        "manifestProviders": sorted(
            manifest_providers,
            key=lambda p: (p["name"], p["manifest"]),
        ),
        "appStartupProviders": sorted(
            app_startup_providers,
            key=lambda p: (p["manifest"], p["name"]),
        ),
        "appStartupInitializers": sorted(
            app_startup_initializers,
            key=lambda i: (i["name"], i["manifest"]),
        ),
        "workManager": {
            "defaultInitializer": workmanager_initializer_state,
            "initializerMetadataEntries": sorted(
                workmanager_metadata_entries,
                key=lambda m: (m["manifest"], m["name"]),
            ),
            "configurationProviderClasses": sorted(
                workmanager_configuration_providers,
                key=lambda c: c["name"],
            ),
            "workerFactoryClasses": sorted(
                workmanager_worker_factories,
                key=lambda c: c["name"],
            ),
        },
    },
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(model, f, indent=2, sort_keys=True)
    f.write("\n")
print(
    f"processModel: {len(components)} component(s), "
    f"{len(background_entry_points)} background entry point(s), "
    f"{len(manifest_providers)} provider(s), "
    f"{len(app_startup_initializers)} app-startup initializer(s), "
    f"discovery={discovery}"
)
PY
if [ -f "$PROCESS_MODEL_FILE" ]; then
    AUX_COUNT="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for c in d.get("components",[]) if c.get("classification")=="auxiliary"))' "$PROCESS_MODEL_FILE" 2>/dev/null || echo 0)"
    BG_COUNT="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("backgroundEntryPoints",[])))' "$PROCESS_MODEL_FILE" 2>/dev/null || echo 0)"
    PROVIDER_COUNT="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("startupModel",{}).get("manifestProviders",[])))' "$PROCESS_MODEL_FILE" 2>/dev/null || echo 0)"
    APP_INIT_COUNT="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("startupModel",{}).get("appStartupInitializers",[])))' "$PROCESS_MODEL_FILE" 2>/dev/null || echo 0)"
    probe_pass "processModel written ($AUX_COUNT auxiliary component(s), $BG_COUNT background entry point candidate(s), $PROVIDER_COUNT provider(s), $APP_INIT_COUNT app-startup initializer(s) — per-candidate intent is captured by prompt 03c)"
else
    probe_fail "processModel discovery failed — check manifests in module-map.json"
fi
echo ""

# ========================================
# 8. SDK class index
# ========================================
# These are the Dynamics classes the migration prompts reference. Each
# entry is checked against the resolved AAR(s) in the Gradle cache.
REQUIRED_CLASSES=(
    "com.good.gd.GDAndroid"
    "com.good.gd.GDStateListener"
    "com.good.gd.database.sqlite.SQLiteOpenHelper"
    "com.good.gd.database.sqlite.SQLiteDatabase"
    "com.good.gd.file.GDFileSystem"
    "com.good.gd.file.FileInputStream"
    "com.good.gd.file.FileOutputStream"
    "com.blackberry.okhttpsupport.interceptor.BBCustomInterceptor"
    "com.blackberry.okhttpsupport.cookie.BBCookieJar"
    "com.good.gd.net.GDSocket"
    "com.good.gd.apache.http.client.HttpClient"
    "com.blackberry.bbwebview.BBWebView"
    "com.good.gd.icc.GDServiceClient"
    "com.good.gd.widget.GDEditText"
    "com.good.gd.widget.GDTextView"
    "com.good.gd.widget.GDAutoCompleteTextView"
    "com.good.gd.widget.GDMultiAutoCompleteTextView"
    "com.good.gd.widget.GDSearchView"
    "com.good.gd.widget.GDAppCompatEditText"
    "com.good.gd.widget.GDAppCompatTextView"
    "com.good.gd.widget.GDAppCompatCheckedTextView"
    "com.good.gd.widget.GDAppCompatAutoCompleteTextView"
    "com.good.gd.widget.GDAppCompatMultiAutoCompleteTextView"
    "com.good.gd.widget.GDAppCompatSearchView"
    "com.good.gd.content.ClipboardManager"
)
# Note: com.good.gd.widget.GDWebView is intentionally NOT listed here.
# GDWebView is legacy/deprecated; BBWebView (com.blackberry.bbwebview.BBWebView)
# is the only supported WebView migration target.

if [ "$PROBE_OK" = true ]; then
    echo "8. SDK class index"
    echo "-----------------------------------------"
    GRADLE_CACHE="${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2/files-2.1/com.blackberry.blackberrydynamics"
    if [ ! -d "$GRADLE_CACHE" ]; then
        probe_fail "Dynamics SDK Gradle cache not found at $GRADLE_CACHE — re-run ./gradlew ${GRADLE_PRIMARY_TARGET}:dependencies"
    else
        # Enumerate classes from every embedded JAR inside every Dynamics AAR
        # in the cache. Newer SDK AARs may ship an empty classes.jar and place
        # bytecode in libs/*.jar, so we must scan all jar entries.
        ALL_CLASSES_LIST="$(mktemp -t bootstrap-classes.XXXXXX)"
        SEEN_CLASSES_COUNT=0
        while IFS= read -r aar; do
            tmp_extract="$(mktemp -d -t bootstrap-aar.XXXXXX)"
            JAR_ENTRIES="$(unzip -Z1 "$aar" 2>/dev/null | grep -E '\.jar$' || true)"
            if [ -n "$JAR_ENTRIES" ]; then
                while IFS= read -r jar_entry; do
                    [ -z "$jar_entry" ] && continue
                    EMBEDDED_JAR="$tmp_extract/embedded.jar"
                    if unzip -p "$aar" "$jar_entry" > "$EMBEDDED_JAR" 2>/dev/null; then
                        unzip -l "$EMBEDDED_JAR" 2>/dev/null \
                            | awk '{ print $4 }' \
                            | grep -E '\.class$' >> "$ALL_CLASSES_LIST" || true
                        SEEN_CLASSES_COUNT=$((SEEN_CLASSES_COUNT + 1))
                    fi
                    rm -f "$EMBEDDED_JAR"
                done <<< "$JAR_ENTRIES"
            fi
            rm -rf "$tmp_extract"
        done < <(find "$GRADLE_CACHE" -type f -name "*.aar" 2>/dev/null)

        # Some Dynamics artifacts ship as plain .jar (e.g. handheld_resources).
        while IFS= read -r jar; do
            unzip -l "$jar" 2>/dev/null \
                | awk '{ print $4 }' \
                | grep -E '\.class$' >> "$ALL_CLASSES_LIST" || true
            SEEN_CLASSES_COUNT=$((SEEN_CLASSES_COUNT + 1))
        done < <(find "$GRADLE_CACHE" -type f -name "*.jar" 2>/dev/null)

        if [ "$SEEN_CLASSES_COUNT" -eq 0 ]; then
            probe_fail "No Dynamics AAR/JAR archives found under $GRADLE_CACHE"
        else
            INDEX_FAIL_COUNT=0
            for fqcn in "${REQUIRED_CLASSES[@]}"; do
                path_form="${fqcn//.//}.class"
                if grep -q "^${path_form}\$" "$ALL_CLASSES_LIST" 2>/dev/null; then
                    printf '%s\tfound\n' "$fqcn" >> "$CLASS_INDEX_FILE"
                else
                    printf '%s\tnot-found\n' "$fqcn" >> "$CLASS_INDEX_FILE"
                    INDEX_FAIL_COUNT=$((INDEX_FAIL_COUNT + 1))
                fi
            done
            if [ "$INDEX_FAIL_COUNT" -eq 0 ]; then
                probe_pass "All ${#REQUIRED_CLASSES[@]} required Dynamics classes found"
            else
                probe_fail "$INDEX_FAIL_COUNT of ${#REQUIRED_CLASSES[@]} required Dynamics classes NOT found in resolved AAR(s) — SDK version may be too old or the wrong artifact is being resolved"
                while IFS=$'\t' read -r missing_class status; do
                    if [ "$status" = "not-found" ]; then
                        echo "    missing: $missing_class" >&2
                    fi
                done < "$CLASS_INDEX_FILE"
            fi
        fi
        rm -f "$ALL_CLASSES_LIST"
    fi
    echo ""
fi

# ========================================
# 9. Emit JSON probe file
# ========================================
mkdir -p "$OUT_DIR"

# Export shell variables for the Python heredoc (avoids string-interpolation
# pitfalls with multi-word values).
export PROBE_FILE_OUT="$PROBE_FILE"
export PROBE_OK_VAL="$PROBE_OK"
export ERRORS_FILE WARNINGS_FILE CLASS_INDEX_FILE
export OS_NAME OS_VERSION SHELL_NAME LANGUAGE PROJECT_SHAPE
export ANDROID_SDK GRADLE_VERSION JDK_VERSION
export MIN_SDK COMPILE_SDK
export GIT_BRANCH GIT_COMMIT GIT_PRESENT GIT_REMOTE GIT_DIRTY
export RESOLVED_SDK_ARTIFACT RESOLVED_SDK_VERSION
export SDK_PROBE_COMMAND
export SDK_PROBE_COMMAND_DESCRIPTION
export SDK_PROBE_FALLBACK_USED
export TOOL_VERSION PROJECT_ROOT
export PROBE_JAVA_HOME="${JAVA_HOME:-}"
export MODULE_MAP_FILE_PATH="${MODULE_MAP_FILE:-}"
export PROCESS_MODEL_FILE_PATH="${PROCESS_MODEL_FILE:-}"
export CATALOG_FILE_PATH="$TOOL_DIR/contracts/api-catalog.v1.0.0.json"

python3 - <<'PY'
import datetime
import json
import os
import uuid

def _read_lines(path):
    if not path or not os.path.isfile(path):
        return []
    with open(path) as f:
        return [line.rstrip("\n") for line in f if line.strip()]

def _opt(name):
    val = os.environ.get(name, "")
    return val if val else None

def _opt_int(name):
    val = os.environ.get(name, "")
    return int(val) if val.isdigit() else None

errors = _read_lines(os.environ.get("ERRORS_FILE"))
warnings = _read_lines(os.environ.get("WARNINGS_FILE"))

sdk_class_index = {}
class_index_path = os.environ.get("CLASS_INDEX_FILE")
if class_index_path and os.path.isfile(class_index_path):
    with open(class_index_path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            if "\t" not in line:
                continue
            fqcn, status = line.split("\t", 1)
            sdk_class_index[fqcn] = status

ok = os.environ.get("PROBE_OK_VAL") == "true"
now = (
    datetime.datetime.now(datetime.timezone.utc)
    .replace(microsecond=0)
    .isoformat()
    .replace("+00:00", "Z")
)

module_map_summary = None
mm_path = os.environ.get("MODULE_MAP_FILE_PATH", "")
if mm_path and os.path.isfile(mm_path):
    try:
        with open(mm_path) as _f:
            _mm = json.load(_f)
        primary = _mm.get("primaryAppModule") or {}
        module_map_summary = {
            "discoveryMethod": _mm.get("discoveryMethod"),
            "libraryModulesInScopeCount": len(_mm.get("libraryModulesInScope") or []),
            "otherAppModulesCount": len(_mm.get("otherAppModules") or []),
            "path": os.path.relpath(mm_path, os.environ.get("PROJECT_ROOT", ".")),
            "primaryAppModule": {
                "name": primary.get("name"),
                "path": primary.get("path"),
            },
            "projectShape": _mm.get("projectShape"),
        }
    except (OSError, ValueError):
        module_map_summary = None

process_model = None
pm_path = os.environ.get("PROCESS_MODEL_FILE_PATH", "")
if pm_path and os.path.isfile(pm_path):
    try:
        with open(pm_path) as _pf:
            process_model = json.load(_pf)
    except (OSError, ValueError):
        process_model = None

catalog_version = None
catalog_sha256 = None
catalog_path = os.environ.get("CATALOG_FILE_PATH", "")
if catalog_path and os.path.isfile(catalog_path):
    try:
        with open(catalog_path, "rb") as _cf_bin:
            import hashlib
            catalog_sha256 = hashlib.sha256(_cf_bin.read()).hexdigest()
        with open(catalog_path, "r", encoding="utf-8") as _cf:
            _catalog_json = json.load(_cf)
            if isinstance(_catalog_json, dict):
                _cv = _catalog_json.get("catalogVersion")
                if isinstance(_cv, str) and _cv.strip():
                    catalog_version = _cv
    except (OSError, ValueError):
        catalog_version = None
        catalog_sha256 = None

run_id = str(uuid.uuid4())

probe = {
    "schemaVersion": "1.0.0",
    "runId": run_id,
    "generatedAt": now,
    "catalogVersion": catalog_version,
    "ok": ok,
    "errors": errors,
    "warnings": warnings,
    "environment": {
        "androidCompileSdk": _opt_int("COMPILE_SDK"),
        "androidMinSdk": _opt_int("MIN_SDK"),
        "androidSdkRoot": _opt("ANDROID_SDK"),
        "gradleVersion": _opt("GRADLE_VERSION"),
        "javaHome": _opt("PROBE_JAVA_HOME"),
        "jdk": _opt("JDK_VERSION"),
        "language": _opt("LANGUAGE") or "Unknown",
        "os": _opt("OS_NAME") or "unknown",
        "osVersion": _opt("OS_VERSION") or "unknown",
        "shell": _opt("SHELL_NAME") or "unknown",
        "workingDir": os.path.realpath(os.environ.get("PROJECT_ROOT", ".")),
    },
    "moduleMap": module_map_summary,
    "processModel": process_model,
    "git": {
        "branch": _opt("GIT_BRANCH"),
        "commit": _opt("GIT_COMMIT"),
        "dirty": os.environ.get("GIT_DIRTY") == "true",
        "present": os.environ.get("GIT_PRESENT") == "true",
        "remote": _opt("GIT_REMOTE"),
    },
    "sdkProbe": {
        "dynamicsSdkArtifact": _opt("RESOLVED_SDK_ARTIFACT"),
        "dynamicsSdkResolvedVersion": _opt("RESOLVED_SDK_VERSION"),
        "fallbackInitScriptUsed": os.environ.get("SDK_PROBE_FALLBACK_USED") == "true",
        "probeCommand": _opt("SDK_PROBE_COMMAND"),
        "probeCommandDescription": _opt("SDK_PROBE_COMMAND_DESCRIPTION"),
        "probePassedAt": now if ok else None,
    },
    "sdkClassIndex": sdk_class_index,
    "provenance": {
        "runId": run_id,
        "generatedAt": now,
        "toolkitVersion": _opt("TOOL_VERSION") or "unknown",
        "catalogVersion": catalog_version,
        "catalogSha256": catalog_sha256,
        "catalogContract": "contracts/api-catalog.v1.0.0.json",
        "gitCommit": _opt("GIT_COMMIT"),
        "sdkArtifact": _opt("RESOLVED_SDK_ARTIFACT"),
        "sdkResolvedVersion": _opt("RESOLVED_SDK_VERSION"),
        "sdkSha256": None,
    },
    "toolkit": {
        "name": "dynamics-migration-tool",
        "platform": "Android",
        "version": _opt("TOOL_VERSION") or "unknown",
    },
}

# Invariant: bootstrap.generatedAt and provenance.generatedAt must be identical.
if probe.get("generatedAt") != (probe.get("provenance") or {}).get("generatedAt"):
    raise RuntimeError("bootstrap probe invariant violated: generatedAt != provenance.generatedAt")

with open(os.environ["PROBE_FILE_OUT"], "w") as f:
    json.dump(probe, f, indent=2, sort_keys=True)
    f.write("\n")
PY

[ -n "$DEPS_LOG" ] && rm -f "$DEPS_LOG"

echo "Probe results written to: $PROBE_FILE"
echo ""

if [ "$PROBE_OK" = true ]; then
    echo "🎉 Bootstrap probe PASSED. Agent should now merge these results"
    echo "   with the human-collected fields (uem, attestations, agent, permissions)"
    echo "   and write the final dynamics-migration-tool/output/bootstrap.json."
    exit 0
else
    echo "❌ Bootstrap probe FAILED. See errors above. Migration cannot continue." >&2
    exit 1
fi
