#!/usr/bin/env bash
# Load toolkit version + supported Dynamics SDK metadata.
#
# Source from tooling scripts after TOOL_DIR is set:
#   # shellcheck source=toolkit-version.sh
#   . "$SCRIPT_DIR/lib/toolkit-version.sh"
#   toolkit_version_load "$TOOL_DIR"
#
# Exports:
#   TOOL_VERSION            — component version from VERSION (matches Jenkins/Nexus)
#   SUPPORTED_SDK_VERSION   — Dynamics SDK target from supported-sdk.properties
#
# VERSION is stamped by platform build.sh:
#   Build System: --version <getBuildVersion()>
#   Local:        MAJOR.MINOR.PATCH.999999 from repo-root version.properties
# supported-sdk.properties is the only per-platform version-like metadata and is
# independent of the component version.

toolkit_version_load() {
    local tool_dir="${1:-}"
    local sdk_file version_file supported_sdk key value

    if [ -z "$tool_dir" ]; then
        echo "ERROR: toolkit_version_load requires the toolkit root directory" >&2
        return 1
    fi

    version_file="$tool_dir/VERSION"
    sdk_file="$tool_dir/supported-sdk.properties"
    supported_sdk=""

    if [ ! -f "$version_file" ]; then
        echo "ERROR: VERSION file not found at $version_file" >&2
        return 1
    fi
    TOOL_VERSION="$(tr -d '[:space:]' < "$version_file")"
    if [ -z "$TOOL_VERSION" ]; then
        echo "ERROR: VERSION file is empty: $version_file" >&2
        return 1
    fi

    if [ ! -f "$sdk_file" ]; then
        echo "ERROR: supported-sdk.properties not found at $sdk_file" >&2
        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            ''|\#*) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        key="$(printf '%s' "$key" | tr -d '[:space:]')"
        value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "$key" in
            SUPPORTED_SDK_VERSION) supported_sdk="$value" ;;
        esac
    done < "$sdk_file"

    if [ -z "$supported_sdk" ]; then
        echo "ERROR: SUPPORTED_SDK_VERSION missing from $sdk_file" >&2
        return 1
    fi

    SUPPORTED_SDK_VERSION="$supported_sdk"
    export TOOL_VERSION SUPPORTED_SDK_VERSION
}

toolkit_version_print() {
    if [ -z "${TOOL_VERSION:-}" ] || [ -z "${SUPPORTED_SDK_VERSION:-}" ]; then
        echo "ERROR: call toolkit_version_load before toolkit_version_print" >&2
        return 1
    fi
    echo "dynamics-migration-tool ${TOOL_VERSION} (supported Dynamics SDK ${SUPPORTED_SDK_VERSION})"
}
