# BlackBerry Dynamics Migration — validator phase 9
#
# Sourced by tooling/validate.sh once should_run_phase "9" passes.
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
    # Phase 9: Build
    # ========================================
    echo "Phase 9: Build"
    echo "-----------------------------------------"

if [ -f "./gradlew" ]; then
    chmod +x ./gradlew 2>/dev/null
    export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
    # Reuse-last-build optimization: if the last successful assembleDebug is
    # still current relative to source / Gradle inputs, skip the rebuild. The
    # full validator otherwise pays the build cost on every prompt-10 run.
    BUILD_MARKER="dynamics-migration-tool/output/.last-successful-build"
    # Resolve the debug APK from the primary module's APK glob. The
    # canonical AGP layout is `<module>/build/outputs/apk/debug/<module>-debug.apk`,
    # which the glob covers; fall back to first match for reuse decision.
    DEBUG_APK=""
    # shellcheck disable=SC2086
    for cand in $(ls $PRIMARY_APK_GLOB 2>/dev/null); do
        case "$cand" in
            *-debug.apk|*debug/*.apk)
                DEBUG_APK="$cand"
                break
                ;;
        esac
    done
    [ -z "$DEBUG_APK" ] && DEBUG_APK="$PRIMARY_PATH/build/outputs/apk/debug/${PRIMARY_PATH##*/}-debug.apk"

    BUILD_REUSED=false
    if [ -f "$DEBUG_APK" ] && [ -f "$BUILD_MARKER" ]; then
        # Build inputs: every in-scope source root, the primary build
        # file (and convention plugin source if applicable), and the
        # root-level Gradle config. Anything newer than the marker
        # invalidates the cached "successful build" verdict.
        BUILD_INPUTS="$MM_IN_SCOPE_SOURCE_ROOTS $MM_GRADLE_FILES build.gradle build.gradle.kts settings.gradle settings.gradle.kts gradle.properties"
        # shellcheck disable=SC2086
        STALE_INPUT="$(find $BUILD_INPUTS 2>/dev/null -type f -newer "$BUILD_MARKER" 2>/dev/null | head -1)"
        if [ -z "$STALE_INPUT" ]; then
            BUILD_REUSED=true
            check_pass "Project builds successfully (reusing last successful build @ $(date -r "$BUILD_MARKER" +%FT%TZ 2>/dev/null || stat -f %Sm "$BUILD_MARKER" 2>/dev/null || echo last-success))"
        fi
    fi
    if [ "$BUILD_REUSED" = false ]; then
        echo "  Building project (debug variant)..."
        BUILD_LOG=$(mktemp)
        if ./gradlew assembleDebug > "$BUILD_LOG" 2>&1; then
            check_pass "Project builds successfully (debug)"
            mkdir -p "$(dirname "$BUILD_MARKER")"
            : > "$BUILD_MARKER"
            rm -f "$BUILD_LOG"
        else
            check_fail "Build failed"
            echo ""
            echo "  --- Last 20 lines of build output ---"
            tail -20 "$BUILD_LOG"
            echo "  --- End of build output ---"
            echo ""
            if grep -q "JdkImageTransform\|androidJdkImage\|jlink" "$BUILD_LOG" 2>/dev/null; then
                echo "  💡 Diagnosis: AGP/JDK transform path issue. Remove migration-added Java 17 compileOptions/kotlinOptions, then retry. If needed, upgrade AGP to 8.2+ or use JDK 17."
            fi
            if grep -q "Could not resolve.*blackberrydynamics" "$BUILD_LOG" 2>/dev/null; then
                echo "  💡 Diagnosis: Cannot download Dynamics SDK. Check Maven repo URL and network."
            fi
            if grep -q "Manifest merger failed" "$BUILD_LOG" 2>/dev/null; then
                echo "  💡 Diagnosis: Manifest merger conflict. Add tools:replace for conflicting attributes. See prompt 03."
            fi
            rm -f "$BUILD_LOG"
        fi
    fi
else
    check_warn "gradlew not found — skipping build test"
fi

SIM_MODE_ENABLED=0
TEST_CREDS_PRESENT=0
for assets in $MM_PRIMARY_ASSETS_DIRS; do
    [ -d "$assets" ] || continue
    sim_file="$assets/com.blackberry.dynamics.settings.json"
    if [ -f "$sim_file" ]; then
        SIM_MODE_ENABLED=$((SIM_MODE_ENABLED + $(grep -rn "\"GDEnterpriseSimulation\"[[:space:]]*:[[:space:]]*true" "$sim_file" 2>/dev/null | wc -l | tr -d ' ')))
    fi
    TEST_CREDS_PRESENT=$((TEST_CREDS_PRESENT + $(ls "$assets"/*test*credentials*.json 2>/dev/null | wc -l | tr -d ' ')))
done
[ "$SIM_MODE_ENABLED" -gt 0 ] && check_fail "GDEnterpriseSimulation=true detected — disable for enterprise release" || check_pass "GDEnterpriseSimulation not enabled"
[ "$TEST_CREDS_PRESENT" -gt 0 ] && check_fail "Test credentials asset detected in main assets ($TEST_CREDS_PRESENT)" || check_pass "No test-credentials asset in main assets"

echo ""
