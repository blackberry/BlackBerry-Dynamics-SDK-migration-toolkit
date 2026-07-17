#!/bin/bash

# BlackBerry Dynamics Migration Tool — Emulator Probe (Non-Blocking)
#
# Purpose:
#   Phase A helper for local runtime smoke readiness. This script probes for
#   connected emulator/device targets, optionally auto-starts an AVD, and
#   optionally installs the migrated APK.
#   It is intentionally NON-BLOCKING for migration flows.
#
# Non-blocking contract:
#   - Missing adb / no devices / install failures do NOT fail migration.
#   - Exit code is 0 for operational outcomes.
#   - Script prints explicit next-step guidance when install cannot run.
#
# Usage:
#   bash dynamics-migration-tool/tooling/emulator-probs.sh [options]
#
# Options:
#   --apk <path>            Install this APK when a target exists
#   --apk-glob <pattern>    Install newest APK matching glob
#                           (default: derived from output/module-map.json
#                            primaryAppModule.apkOutputGlob, falling back
#                            to app/build/outputs/apk/debug/*.apk)
#   --serial <device-id>    Target a specific device serial
#   --no-auto-start         Do not attempt to start an AVD when none is connected
#   --boot-timeout <sec>    Max wait for auto-started emulator boot (default: 90)
#   --json                  Emit a final one-line JSON summary
#   --version               Print toolkit version and exit
#   --help                  Show this help message

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/toolkit-version.sh
. "$SCRIPT_DIR/lib/toolkit-version.sh"
toolkit_version_load "$TOOL_DIR"

APK_PATH=""

# Default APK glob is module-map-driven so multi-module projects
# (e.g. app-primary/) install the right APK without
# requiring --apk-glob. Single-module projects with a synthesized
# fallback get the same value as the legacy literal default. If the
# accessor library cannot resolve a glob (no map AND no app/ directory),
# fall back to the legacy literal so this script never errors during
# argument parsing.
APK_GLOB="app/build/outputs/apk/debug/*.apk"
if [ -f "$SCRIPT_DIR/lib/module-map.sh" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/lib/module-map.sh"
    if mm_load 2>/dev/null; then
        # The module map's apkOutputGlob covers all variants
        # (app/build/outputs/apk/**/*.apk). Narrow to debug for the
        # default install target unless the caller overrides --apk-glob.
        __mm_apk_root="$(mm_primary_apk_glob 2>/dev/null || echo "")"
        if [ -n "$__mm_apk_root" ]; then
            # Convert /**/*.apk to /debug/*.apk for the default install.
            APK_GLOB="${__mm_apk_root%/**/*.apk}/debug/*.apk"
        fi
    fi
fi

TARGET_SERIAL=""
EMIT_JSON=false
AUTO_START=true
BOOT_TIMEOUT_SEC=90

usage() {
    cat <<USAGE
Usage: bash dynamics-migration-tool/tooling/emulator-probs.sh [options]

Options:
  --apk <path>            Install this APK when a target exists
  --apk-glob <pattern>    Install newest APK matching glob
                          (default: <primary-app-module>/build/outputs/apk/debug/*.apk
                           — derived from output/module-map.json or
                           falling back to app/build/outputs/apk/debug/*.apk)
  --serial <device-id>    Target a specific device serial
  --no-auto-start         Do not auto-start an AVD if none connected
  --boot-timeout <sec>    Max wait for auto-started emulator boot (default: 90)
  --json                  Emit a final one-line JSON summary
  --version               Print toolkit version and exit
  --help                  Show this help message

Notes:
  - This script is non-blocking by design.
  - If no emulator/device is available, migration still proceeds.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apk)       APK_PATH="$2"; shift 2 ;;
        --apk-glob)  APK_GLOB="$2"; shift 2 ;;
        --serial)    TARGET_SERIAL="$2"; shift 2 ;;
        --no-auto-start) AUTO_START=false; shift ;;
        --boot-timeout)  BOOT_TIMEOUT_SEC="$2"; shift 2 ;;
        --json)      EMIT_JSON=true; shift ;;
        --version)   toolkit_version_print; exit 0 ;;
        --help)      usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ! [[ "$BOOT_TIMEOUT_SEC" =~ ^[0-9]+$ ]]; then
    echo "❌ --boot-timeout must be an integer (seconds)" >&2
    exit 2
fi

cd "$PROJECT_ROOT"

echo "========================================="
echo "Emulator Probe (Non-Blocking)"
echo "========================================="
echo "Toolkit Version: $TOOL_VERSION"
echo "Project: $PROJECT_ROOT"
echo ""

ADB_BIN=""
if command -v adb >/dev/null 2>&1; then
    ADB_BIN="$(command -v adb)"
elif [ -n "${ANDROID_HOME:-}" ] && [ -x "${ANDROID_HOME}/platform-tools/adb" ]; then
    ADB_BIN="${ANDROID_HOME}/platform-tools/adb"
elif [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -x "${ANDROID_SDK_ROOT}/platform-tools/adb" ]; then
    ADB_BIN="${ANDROID_SDK_ROOT}/platform-tools/adb"
fi

EMULATOR_BIN=""
if command -v emulator >/dev/null 2>&1; then
    EMULATOR_BIN="$(command -v emulator)"
elif [ -n "${ANDROID_HOME:-}" ] && [ -x "${ANDROID_HOME}/emulator/emulator" ]; then
    EMULATOR_BIN="${ANDROID_HOME}/emulator/emulator"
elif [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -x "${ANDROID_SDK_ROOT}/emulator/emulator" ]; then
    EMULATOR_BIN="${ANDROID_SDK_ROOT}/emulator/emulator"
fi

probe_ok=true
install_attempted=false
install_performed=false
selected_serial=""
selected_apk=""
summary_reason=""
auto_start_attempted=false
auto_start_performed=false
auto_start_avd=""

if [ -z "$ADB_BIN" ]; then
    probe_ok=false
    summary_reason="adb-not-found"
    echo "⚠️  adb not found in PATH/ANDROID_HOME/ANDROID_SDK_ROOT."
    echo "    Emulator/device probing is skipped."
    echo ""
    echo "At the end of migration, installation of app won't happen as there is no known emulator/devices."
    echo "Please test on your own with the resulting APK."
else
    DEVICES_RAW="$("$ADB_BIN" devices 2>/dev/null || true)"
    DEVICE_SERIALS="$(printf '%s\n' "$DEVICES_RAW" | awk '$2=="device"{print $1}')"

    if [ -z "$DEVICE_SERIALS" ] && [ "$AUTO_START" = true ] && [ -z "$TARGET_SERIAL" ]; then
        auto_start_attempted=true
        if [ -z "$EMULATOR_BIN" ]; then
            echo "⚠️  No connected emulator/device and emulator binary not found."
        else
            AVD_LIST="$("$EMULATOR_BIN" -list-avds 2>/dev/null || true)"
            FIRST_AVD="$(printf '%s\n' "$AVD_LIST" | awk 'NF{print; exit}')"
            if [ -z "$FIRST_AVD" ]; then
                echo "⚠️  No connected emulator/device and no local AVD definitions found."
            else
                auto_start_avd="$FIRST_AVD"
                echo "No connected emulator/device detected. Trying to start AVD:"
                echo "  $FIRST_AVD"
                # Start in background; keep window behavior default (developer-visible).
                # Non-blocking contract remains: failures only affect probe summary.
                "$EMULATOR_BIN" -avd "$FIRST_AVD" -netdelay none -netspeed full >/tmp/dynamics-emulator-start.log 2>&1 &
                EMU_PID=$!
                sleep 2
                if kill -0 "$EMU_PID" >/dev/null 2>&1; then
                    auto_start_performed=true
                    elapsed=0
                    step=3
                    while [ "$elapsed" -lt "$BOOT_TIMEOUT_SEC" ]; do
                        DEVICES_RAW="$("$ADB_BIN" devices 2>/dev/null || true)"
                        DEVICE_SERIALS="$(printf '%s\n' "$DEVICES_RAW" | awk '$2=="device"{print $1}' | grep '^emulator-' || true)"
                        if [ -n "$DEVICE_SERIALS" ]; then
                            break
                        fi
                        sleep "$step"
                        elapsed=$((elapsed + step))
                    done
                    if [ -n "$DEVICE_SERIALS" ]; then
                        echo "✅ Auto-started emulator is connected."
                    else
                        echo "⚠️  Emulator start attempted but no ready emulator appeared within ${BOOT_TIMEOUT_SEC}s."
                    fi
                else
                    echo "⚠️  Emulator process failed to start."
                fi
            fi
        fi
    fi

    if [ -z "$DEVICE_SERIALS" ]; then
        probe_ok=false
        summary_reason="no-device"
        echo "⚠️  No known emulator/device is connected."
        echo ""
        echo "At the end of migration, installation of app won't happen as there is no known emulator/devices."
        echo "Please test on your own with the resulting APK."
    else
        echo "✅ Connected device/emulator(s):"
        while IFS= read -r s; do
            [ -n "$s" ] && echo "   - $s"
        done <<EOF
$DEVICE_SERIALS
EOF
        echo ""

        if [ -n "$TARGET_SERIAL" ]; then
            if printf '%s\n' "$DEVICE_SERIALS" | grep -qx "$TARGET_SERIAL"; then
                selected_serial="$TARGET_SERIAL"
            else
                probe_ok=false
                summary_reason="requested-serial-not-found"
                echo "⚠️  Requested --serial '$TARGET_SERIAL' is not connected."
                echo ""
                echo "At the end of migration, installation of app won't happen as there is no known emulator/devices."
                echo "Please test on your own with the resulting APK."
            fi
        else
            selected_serial="$(printf '%s\n' "$DEVICE_SERIALS" | head -1)"
        fi
    fi

    if [ "$probe_ok" = true ] && [ -n "$selected_serial" ]; then
        if [ -n "$APK_PATH" ]; then
            selected_apk="$APK_PATH"
        else
            selected_apk="$(compgen -G "$APK_GLOB" | head -1 || true)"
        fi

        if [ -z "$selected_apk" ]; then
            summary_reason="no-apk-found"
            echo "⚠️  No APK found to install."
            echo "    Checked: --apk '${APK_PATH:-<not-set>}' / --apk-glob '$APK_GLOB'"
            echo "    Build your APK and re-run this probe for install:"
            echo "      ./gradlew assembleDebug"
        elif [ ! -f "$selected_apk" ]; then
            summary_reason="apk-path-missing"
            echo "⚠️  APK path does not exist: $selected_apk"
            echo "    Build the APK first, then retry probe/install."
        else
            install_attempted=true
            echo "Installing APK to $selected_serial:"
            echo "  $selected_apk"
            if "$ADB_BIN" -s "$selected_serial" install -r "$selected_apk" >/tmp/dynamics-apk-install.log 2>&1; then
                install_performed=true
                summary_reason="install-success"
                echo "✅ APK installed successfully."
            else
                summary_reason="install-failed"
                echo "⚠️  APK install failed (non-blocking)."
                echo "    Last install output:"
                sed -n '1,8p' /tmp/dynamics-apk-install.log
                echo "    Continue migration and validate manually with the resulting APK."
            fi
        fi
    fi
fi

echo ""
echo "-----------------------------------------"
echo "Emulator Probe Summary (Non-Blocking)"
echo "-----------------------------------------"
echo "probe_ready:        $probe_ok"
echo "selected_serial:    ${selected_serial:-<none>}"
echo "install_attempted:  $install_attempted"
echo "install_performed:  $install_performed"
echo "auto_start_attempted: $auto_start_attempted"
echo "auto_start_performed: $auto_start_performed"
echo "auto_start_avd:     ${auto_start_avd:-<none>}"
echo "reason:             ${summary_reason:-ok}"
echo ""

if [ "$EMIT_JSON" = true ]; then
    export PROBE_READY="$probe_ok"
    export SELECTED_SERIAL="${selected_serial:-}"
    export INSTALL_ATTEMPTED="$install_attempted"
    export INSTALL_PERFORMED="$install_performed"
    export AUTO_START_ATTEMPTED="$auto_start_attempted"
    export AUTO_START_PERFORMED="$auto_start_performed"
    export AUTO_START_AVD="${auto_start_avd:-}"
    export SUMMARY_REASON="${summary_reason:-ok}"
    python3 - <<'PY'
import json
import os

def as_bool(val: str) -> bool:
    return str(val).strip().lower() == "true"

selected = os.environ.get("SELECTED_SERIAL", "").strip()
print(json.dumps({
    "probeReady": as_bool(os.environ.get("PROBE_READY", "false")),
    "selectedSerial": selected if selected else None,
    "installAttempted": as_bool(os.environ.get("INSTALL_ATTEMPTED", "false")),
    "installPerformed": as_bool(os.environ.get("INSTALL_PERFORMED", "false")),
    "autoStartAttempted": as_bool(os.environ.get("AUTO_START_ATTEMPTED", "false")),
    "autoStartPerformed": as_bool(os.environ.get("AUTO_START_PERFORMED", "false")),
    "autoStartAvd": (os.environ.get("AUTO_START_AVD", "").strip() or None),
    "reason": os.environ.get("SUMMARY_REASON", "ok"),
}))
PY
fi

# Non-blocking by contract.
exit 0
