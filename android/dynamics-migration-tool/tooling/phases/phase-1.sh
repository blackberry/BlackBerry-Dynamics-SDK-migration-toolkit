# BlackBerry Dynamics Migration — validator phase 1
#
# Sourced by tooling/validate.sh once should_run_phase "1" passes.
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
    # Phase 1: Configuration
    # ========================================
    echo "Phase 1: Configuration"
    echo "-----------------------------------------"

# Pick the first settings.json that physically exists from the targets
# the module map declares. Single-module projects always have exactly
# one target (app/src/main/assets/settings.json) so behavior is
# preserved. Multi-flavor and multi-source-set projects can have
# several targets — any one of them being well-formed satisfies the
# check; missing targets are surfaced as warnings so reviewers know
# which flavor needs attention.
SETTINGS_JSON_PATH=""
for tgt in $MM_SETTINGS_JSON_TARGETS; do
    if [ -f "$tgt" ]; then
        SETTINGS_JSON_PATH="$tgt"
        break
    fi
done
if [ -n "$SETTINGS_JSON_PATH" ]; then
    check_pass "settings.json exists ($SETTINGS_JSON_PATH)"
    grep -q "GDApplicationID" "$SETTINGS_JSON_PATH" 2>/dev/null && \
        check_pass "GDApplicationID present" || check_fail "GDApplicationID missing — re-run prompt 02 (create-settings-json)"
    grep -q "GDLibraryMode" "$SETTINGS_JSON_PATH" 2>/dev/null && \
        check_pass "GDLibraryMode present" || check_fail "GDLibraryMode missing — re-run prompt 02 (create-settings-json)"
    grep -q "GDApplicationVersion" "$SETTINGS_JSON_PATH" 2>/dev/null && \
        check_pass "GDApplicationVersion present" || check_fail "GDApplicationVersion missing — re-run prompt 02 (create-settings-json)"
    # Warn for per-flavor projects when a declared target is missing.
    for tgt in $MM_SETTINGS_JSON_TARGETS; do
        [ "$tgt" = "$SETTINGS_JSON_PATH" ] && continue
        [ -f "$tgt" ] || check_warn "Declared settings.json target missing: $tgt — copy from $SETTINGS_JSON_PATH if this flavor ships"
    done
else
    check_fail "settings.json not found — re-run prompt 02 (create-settings-json)"
fi
# Aggregate manifest-hardening counts across every primary-app-module
# manifest the module map declares (main + flavor combinations). Single-
# module projects have exactly one manifest, so the totals match the
# pre-PR3 single-file checks. The "$MANIFEST_PRESENT" variable lets the
# downstream `if any manifest exists` gate match the prior semantics.
MANIFEST_PRESENT=false
CLEARTEXT_COUNT=0
DEBUGGABLE_COUNT=0
ALLOW_BACKUP_TRUE=0
FILE_PROVIDER_DECL=0
BROAD_STORAGE_PERMS=0
GD_REQUIRED_PERM_REMOVE_COUNT=0
GD_REQUIRED_PERM_REMOVE_HITS=""
for mf in $MM_PRIMARY_MANIFESTS; do
    [ -f "$mf" ] || continue
    MANIFEST_PRESENT=true
    CLEARTEXT_COUNT=$((CLEARTEXT_COUNT + $(grep -rn "usesCleartextTraffic=\"true\"" "$mf" 2>/dev/null | wc -l | tr -d ' ')))
    DEBUGGABLE_COUNT=$((DEBUGGABLE_COUNT + $(grep -rn "android:debuggable=\"true\"" "$mf" 2>/dev/null | wc -l | tr -d ' ')))
    ALLOW_BACKUP_TRUE=$((ALLOW_BACKUP_TRUE + $(grep -rn "android:allowBackup=\"true\"" "$mf" 2>/dev/null | wc -l | tr -d ' ')))
    FILE_PROVIDER_DECL=$((FILE_PROVIDER_DECL + $(grep -rn "androidx.core.content.FileProvider" "$mf" 2>/dev/null | wc -l | tr -d ' ')))
    BROAD_STORAGE_PERMS=$((BROAD_STORAGE_PERMS + $(grep -rnE "MANAGE_EXTERNAL_STORAGE|WRITE_EXTERNAL_STORAGE|READ_EXTERNAL_STORAGE|READ_MEDIA_IMAGES|READ_MEDIA_VIDEO|READ_MEDIA_AUDIO" "$mf" 2>/dev/null | wc -l | tr -d ' ')))
    # MANDATORY (steering/10-gradle-integration.md "Required Manifest
    # Permissions"): no <uses-permission> for INTERNET / ACCESS_NETWORK_STATE
    # / ACCESS_WIFI_STATE may carry tools:node="remove" — that pattern
    # strips the SDK's injected permission from the merged manifest and
    # causes GDInitializationError on first activity launch. The check
    # matches the element across line boundaries (apps commonly split the
    # attributes onto multiple lines).
    GD_PERM_REMOVE_HERE=$(python3 - "$mf" <<'PY' 2>/dev/null || echo 0
import re, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as f:
        src = f.read()
except OSError:
    print(0); sys.exit(0)
# Match any <uses-permission ...> element whose android:name targets one
# of the three required permissions AND that carries tools:node="remove".
pattern = re.compile(
    r'<uses-permission\b[^>]*?'
    r'(?:android:name="android\.permission\.(?:INTERNET|ACCESS_NETWORK_STATE|ACCESS_WIFI_STATE)"[^>]*?tools:node="remove"'
    r'|tools:node="remove"[^>]*?android:name="android\.permission\.(?:INTERNET|ACCESS_NETWORK_STATE|ACCESS_WIFI_STATE)")'
    r'[^>]*/?>',
    re.DOTALL,
)
print(len(pattern.findall(src)))
PY
)
    GD_PERM_REMOVE_HERE=${GD_PERM_REMOVE_HERE:-0}
    if [ "$GD_PERM_REMOVE_HERE" -gt 0 ] 2>/dev/null; then
        GD_REQUIRED_PERM_REMOVE_COUNT=$((GD_REQUIRED_PERM_REMOVE_COUNT + GD_PERM_REMOVE_HERE))
        GD_REQUIRED_PERM_REMOVE_HITS="$GD_REQUIRED_PERM_REMOVE_HITS $mf"
    fi
done

if [ "$MANIFEST_PRESENT" = true ]; then
    [ "$CLEARTEXT_COUNT" -gt 0 ] && check_fail "android:usesCleartextTraffic=\"true\" detected ($CLEARTEXT_COUNT) — disallowed for enterprise migration" || check_pass "No cleartext traffic enabled in manifest"
    [ "$DEBUGGABLE_COUNT" -gt 0 ] && check_fail "android:debuggable=\"true\" detected ($DEBUGGABLE_COUNT) — not allowed for enterprise release posture" || check_pass "No debuggable=true flag in manifest"
    [ "$ALLOW_BACKUP_TRUE" -gt 0 ] && check_fail "android:allowBackup=\"true\" detected ($ALLOW_BACKUP_TRUE) — use false for Dynamics-managed data" || check_pass "allowBackup not set to true"
    if [ "$GD_REQUIRED_PERM_REMOVE_COUNT" -gt 0 ] 2>/dev/null; then
        # Trim leading space from the hit list for a cleaner message.
        GD_REQUIRED_PERM_REMOVE_HITS_TRIMMED="${GD_REQUIRED_PERM_REMOVE_HITS# }"
        check_fail "tools:node=\"remove\" on required Dynamics permission (INTERNET / ACCESS_NETWORK_STATE / ACCESS_WIFI_STATE) detected ($GD_REQUIRED_PERM_REMOVE_COUNT element(s) in: $GD_REQUIRED_PERM_REMOVE_HITS_TRIMMED) — strips the SDK-injected permission from the merged manifest and crashes the app with GDInitializationError on first activity launch. Re-run prompt 01 Step 7 (Required Manifest Permissions Audit); see steering/10-gradle-integration.md \"Required Manifest Permissions (MANDATORY)\"."
    else
        check_pass "No tools:node=\"remove\" on Dynamics-required permissions (INTERNET / ACCESS_NETWORK_STATE / ACCESS_WIFI_STATE)"
    fi

    if [ "$FILE_PROVIDER_DECL" -gt 0 ]; then
        check_warn "FileProvider declaration present ($FILE_PROVIDER_DECL) — prompt 08 / phase 8b enforces post-ICC provider + file_paths cleanup and DLP review"
    else
        check_pass "No FileProvider declaration found in manifest"
    fi

    [ "$BROAD_STORAGE_PERMS" -gt 0 ] && fail_or_defer "secureFileStorage" "Broad storage/media permissions still declared ($BROAD_STORAGE_PERMS) — review and remove for container-only posture" || check_pass "No broad storage/media permissions detected"
fi

# network_security_config.xml lives under res/xml/ in any source set
# of the primary app module. Aggregate across every res/ directory.
NSC_PRESENT=false
NSC_CLEARTEXT=0
NSC_USER_ANCHOR=0
for res in $MM_PRIMARY_RES_DIRS; do
    nsc="$res/xml/network_security_config.xml"
    [ -f "$nsc" ] || continue
    NSC_PRESENT=true
    NSC_CLEARTEXT=$((NSC_CLEARTEXT + $(grep -rnE "cleartextTrafficPermitted=\"true\"" "$nsc" 2>/dev/null | wc -l | tr -d ' ')))
    NSC_USER_ANCHOR=$((NSC_USER_ANCHOR + $(grep -rnE "certificates[[:space:]]+src=\"user\"" "$nsc" 2>/dev/null | wc -l | tr -d ' ')))
done
if [ "$NSC_PRESENT" = true ]; then
    [ "$NSC_CLEARTEXT" -gt 0 ] && check_fail "network_security_config enables cleartext traffic ($NSC_CLEARTEXT) — disallowed for enterprise migration" || check_pass "network_security_config does not enable cleartext traffic"
    [ "$NSC_USER_ANCHOR" -gt 0 ] && check_warn "network_security_config trusts user CA store ($NSC_USER_ANCHOR) — review enterprise PKI intent and document justification" || check_pass "network_security_config does not trust user CA store"
else
    check_pass "No custom network_security_config.xml detected"
fi

echo ""
