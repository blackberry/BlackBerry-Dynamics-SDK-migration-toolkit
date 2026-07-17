# BlackBerry Dynamics Migration — pre-flight checks
#
# Sourced (not invoked) by tooling/validate.sh when --preflight is
# supplied. Exits the parent shell on completion (success or failure)
# exactly like the original inline block.
#
# Inherits $TOOL_DIR, $SCRIPT_DIR, $TOOL_VERSION, $PROJECT_DIR.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154

    echo "========================================="
    echo "BlackBerry Dynamics — Pre-Flight Check"
    echo "========================================="
    echo "Toolkit Version: $TOOL_VERSION"
    echo "Project: $PROJECT_DIR"
    echo ""

    if [ ! -d "$PROJECT_DIR" ]; then
        echo "❌ Directory not found: $PROJECT_DIR"
        exit 1
    fi

    cd "$PROJECT_DIR"

    PREFLIGHT_FAIL=0

    # Check JAVA_HOME
    if [ -z "$JAVA_HOME" ]; then
        echo "❌ JAVA_HOME is not set — set it to a JDK 17+ installation"
        PREFLIGHT_FAIL=$((PREFLIGHT_FAIL + 1))
    else
        echo "✅ JAVA_HOME=$JAVA_HOME"
        JAVA_BIN=""
        if [ -x "$JAVA_HOME/bin/java" ]; then
            JAVA_BIN="$JAVA_HOME/bin/java"
        elif [ -x "$JAVA_HOME/tooling/java" ]; then
            JAVA_BIN="$JAVA_HOME/tooling/java"
        fi
        if [ -z "$JAVA_BIN" ]; then
            echo "❌ JAVA_HOME is set but no executable java found at $JAVA_HOME/bin/java or $JAVA_HOME/tooling/java"
            PREFLIGHT_FAIL=$((PREFLIGHT_FAIL + 1))
        else
            JDK_VERSION=$("$JAVA_BIN" -version 2>&1 | awk 'NR==1 { if (match($0, /"[0-9]+(\.[0-9]+)*/)) { v=substr($0, RSTART+1, RLENGTH-1); split(v, a, "."); print a[1] } }')
            if [ -n "$JDK_VERSION" ] && [ "$JDK_VERSION" -ge 17 ] 2>/dev/null; then
                echo "✅ JDK version: $JDK_VERSION (>= 17)"
            else
                echo "❌ JDK version $JDK_VERSION is below 17 — Dynamics migration requires JDK 17+"
                PREFLIGHT_FAIL=$((PREFLIGHT_FAIL + 1))
            fi
        fi
    fi

    # Check ANDROID_HOME / ANDROID_SDK_ROOT
    ANDROID_SDK="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
    if [ -z "$ANDROID_SDK" ]; then
        echo "❌ Neither ANDROID_HOME nor ANDROID_SDK_ROOT is set — set one to your Android SDK installation"
        PREFLIGHT_FAIL=$((PREFLIGHT_FAIL + 1))
    else
        echo "✅ Android SDK at $ANDROID_SDK"
    fi

    # Check primary app build.gradle exists. Use the module map when
    # available; otherwise fall back to the canonical app/ directory so
    # preflight remains usable on raw projects before bootstrap has run.
    PREFLIGHT_PRIMARY_BUILD=""
    if [ -f "$TOOL_DIR/output/module-map.json" ]; then
        # Source the accessor library to read the primary build file path
        # without parsing JSON inline.
        # shellcheck disable=SC1091
        . "$SCRIPT_DIR/lib/module-map.sh"
        if mm_load 2>/dev/null; then
            PREFLIGHT_PRIMARY_BUILD="$(mm_primary_build_file 2>/dev/null || true)"
        fi
    fi
    if [ -z "$PREFLIGHT_PRIMARY_BUILD" ]; then
        if [ -f "app/build.gradle.kts" ]; then
            PREFLIGHT_PRIMARY_BUILD="app/build.gradle.kts"
        elif [ -f "app/build.gradle" ]; then
            PREFLIGHT_PRIMARY_BUILD="app/build.gradle"
        fi
    fi
    if [ -z "$PREFLIGHT_PRIMARY_BUILD" ] || [ ! -f "$PREFLIGHT_PRIMARY_BUILD" ]; then
        echo "❌ Not an Android project (no primary app module build file found)"
        echo "   Expected app/build.gradle(.kts) or a populated module map at"
        echo "   dynamics-migration-tool/output/module-map.json."
        exit 1
    fi

    # Detect AGP version and check JDK compatibility. Search both the
    # root build files and the primary app module's build file.
    AGP_VERSION=""
    for BFILE in build.gradle build.gradle.kts "$PREFLIGHT_PRIMARY_BUILD"; do
        if [ -f "$BFILE" ]; then
            VER=$(grep -oE "com\.android\.tools\.build:gradle:[0-9]+\.[0-9]+" "$BFILE" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
            [ -n "$VER" ] && AGP_VERSION="$VER" && break
        fi
    done
    if [ -z "$AGP_VERSION" ]; then
        for BFILE in build.gradle build.gradle.kts settings.gradle settings.gradle.kts; do
            if [ -f "$BFILE" ]; then
                VER=$(grep -oE "com\.android\.(application|library).*version[[:space:]]*['\"]([0-9]+\.[0-9]+)" "$BFILE" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
                [ -n "$VER" ] && AGP_VERSION="$VER" && break
            fi
        done
    fi

    if [ -n "$AGP_VERSION" ]; then
        echo "  AGP version detected: $AGP_VERSION"
        AGP_MAJOR=$(echo "$AGP_VERSION" | cut -d. -f1)
        AGP_MINOR=$(echo "$AGP_VERSION" | cut -d. -f2)
        if [ -n "$JDK_VERSION" ] && [ "$JDK_VERSION" -ge 21 ] 2>/dev/null; then
            if [ "$AGP_MAJOR" -lt 8 ] 2>/dev/null || { [ "$AGP_MAJOR" -eq 8 ] && [ "$AGP_MINOR" -lt 2 ]; } 2>/dev/null; then
                echo "❌ AGP $AGP_VERSION is incompatible with JDK $JDK_VERSION — upgrade AGP to 8.2+ or use JDK 17"
                PREFLIGHT_FAIL=$((PREFLIGHT_FAIL + 1))
            else
                echo "✅ AGP $AGP_VERSION is compatible with JDK $JDK_VERSION"
            fi
        fi
    else
        echo "  ⚠️  Could not detect AGP version — check manually"
    fi

    # Check Gradle wrapper
    if [ -f "./gradlew" ]; then
        echo "✅ Gradle wrapper found"
    else
        echo "❌ gradlew not found — cannot verify build"
        PREFLIGHT_FAIL=$((PREFLIGHT_FAIL + 1))
    fi

    # Attempt a build
    echo ""
    echo "Running pre-flight build (./gradlew assembleDebug)..."
    if [ -f "./gradlew" ]; then
        chmod +x ./gradlew 2>/dev/null
        export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
        BUILD_LOG=$(mktemp)
        if ./gradlew assembleDebug > "$BUILD_LOG" 2>&1; then
            echo "✅ Project builds successfully — ready for migration"
            rm -f "$BUILD_LOG"
        else
            echo "❌ Pre-flight build FAILED — fix before starting migration"
            echo ""
            echo "--- Last 30 lines of build output ---"
            tail -30 "$BUILD_LOG"
            echo "--- End of build output ---"
            echo ""
            if grep -q "JdkImageTransform\|androidJdkImage\|jlink" "$BUILD_LOG" 2>/dev/null; then
                echo "💡 Diagnosis: AGP/JDK transform path issue. Remove migration-added Java 17 compileOptions/kotlinOptions, then retry. If needed, upgrade AGP to 8.2+ or use JDK 17."
            fi
            if grep -q "Could not resolve.*blackberrydynamics" "$BUILD_LOG" 2>/dev/null; then
                echo "💡 Diagnosis: Cannot download Dynamics SDK. Check Maven repo URL and network."
            fi
            if grep -q "Manifest merger failed" "$BUILD_LOG" 2>/dev/null; then
                echo "💡 Diagnosis: Manifest merger conflict. Add tools:replace for conflicting attributes."
            fi
            rm -f "$BUILD_LOG"
            PREFLIGHT_FAIL=$((PREFLIGHT_FAIL + 1))
        fi
    fi

    echo ""
    if [ "$PREFLIGHT_FAIL" -eq 0 ]; then
        echo "🎉 Pre-flight check PASSED — your project is ready for migration"
        exit 0
    else
        echo "❌ Pre-flight check FAILED ($PREFLIGHT_FAIL issue(s)) — fix these before starting migration"
        exit 1
    fi
