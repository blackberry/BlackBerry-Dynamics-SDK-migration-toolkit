# BlackBerry Dynamics Migration — validator phase 2
#
# Sourced by tooling/validate.sh once should_run_phase "2" passes.
# Inherits PASS/FAIL/WARN counters, helpers (check_pass/check_fail/
# check_warn, fail_or_defer, strip_audit_noise, NATIVE_SCAN_PY, …)
# and the module-map scope vars from the parent shell.
#
# Do not edit the inner body without preserving validation semantics
# (see docs/android-dynamics-migration-tool-production-readiness-review.md
# and the per-domain steering files for what each check enforces).
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2086,SC2046,SC2016

    # ========================================
    # Phase 2: Gradle
    # ========================================
    echo "Phase 2: Gradle"
    echo "-----------------------------------------"

# Gradle dep check: search the primary module's build file plus, when
# the primary is configured via a Gradle convention plugin (for example
# `id(AppPlugins.Android.compose)`), the plugin's
# source file too. Either location is a legitimate place to declare
# the SDK dependency depending on how the project edits its build
# graph (see steering/04-multi-module-projects.md, "Editing strategy").
SDK_DEP_FOUND=false
for gf in $MM_GRADLE_FILES; do
    [ -f "$gf" ] || continue
    if grep -q "com.blackberry.blackberrydynamics:android_handheld_platform" "$gf" 2>/dev/null; then
        SDK_DEP_FOUND=true
        break
    fi
done
if [ "$SDK_DEP_FOUND" = true ]; then
    check_pass "Dynamics SDK dependency added"
else
    check_fail "Dynamics SDK dependency not found — re-run prompt 01 (gradle-integration)"
fi
echo ""
