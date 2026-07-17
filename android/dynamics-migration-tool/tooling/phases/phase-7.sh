# BlackBerry Dynamics Migration — validator phase 7
#
# Sourced by tooling/validate.sh once should_run_phase "7" passes.
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
    # Phase 7: Policy
    # ========================================
    echo "Phase 7: Policy"
    echo "-----------------------------------------"

GD_POL=$(grep -r "getApplicationPolicy\|getApplicationPolicyString" "$SRC_DIR/" 2>/dev/null | wc -l | tr -d ' ')
STD_POL=$(grep -rn "RestrictionsManager" "$SRC_DIR/" 2>/dev/null \
    | strip_audit_noise \
    | count_hits_for_domain "policyManagement")

[ "$GD_POL" -gt 0 ] && check_pass "Dynamics policy API used ($GD_POL)" || check_warn "Dynamics policy not found (may not apply)"
[ "$STD_POL" -gt 0 ] && check_fail "RestrictionsManager still present ($STD_POL) — re-run prompt 03 (authorization)" || check_pass "RestrictionsManager removed"
POLICY_RESERVED_PREFIX_HITS=0
for res in $MM_IN_SCOPE_RES_DIRS; do
    [ -d "$res/xml" ] || continue
    POLICY_RESERVED_PREFIX_HITS=$((POLICY_RESERVED_PREFIX_HITS + $(grep -rnE "<key>blackberry\.[^<]+</key>" "$res/xml" 2>/dev/null | strip_audit_noise | grep -v "blackberry.security.EnableDLPWatermark" | wc -l | tr -d ' ')))
done
[ "$POLICY_RESERVED_PREFIX_HITS" -gt 0 ] && check_fail "Custom policy keys use reserved blackberry.* namespace ($POLICY_RESERVED_PREFIX_HITS)" || check_pass "No invalid blackberry.* custom policy key usage detected"

GENERIC_PROVIDER_EXPORTED=0
for mf in $MM_IN_SCOPE_MANIFESTS; do
    [ -f "$mf" ] || continue
    GENERIC_PROVIDER_EXPORTED=$((GENERIC_PROVIDER_EXPORTED + $(grep -rnE "<provider[[:space:]].*android:exported=\"true\"" "$mf" 2>/dev/null | strip_audit_noise | wc -l | tr -d ' ')))
done
[ "$GENERIC_PROVIDER_EXPORTED" -gt 0 ] && fail_or_defer "policyManagement" "Exported ContentProvider declarations detected ($GENERIC_PROVIDER_EXPORTED) — audit provider exposure" || check_pass "No exported ContentProvider declarations detected"

# WI-03: warn when getApplicationConfig/Policy is read outside cache-and-refresh
# paths (onUpdateConfig/onUpdatePolicy/onAuthorized or private refresh* helpers).
APP_CONFIG_SCAN="$SCRIPT_DIR/lib/app-config-policy-scan.py"
if [ -f "$APP_CONFIG_SCAN" ]; then
    POLICY_SCAN_ROOTS=()
    if [ -n "$MM_IN_SCOPE_SOURCE_ROOTS" ]; then
        while IFS= read -r _proot; do
            [ -n "$_proot" ] && POLICY_SCAN_ROOTS+=("$_proot")
        done <<EOF
$MM_IN_SCOPE_SOURCE_ROOTS
EOF
    fi
    if [ "${#POLICY_SCAN_ROOTS[@]}" -eq 0 ] && [ -n "$SRC_DIR" ]; then
        POLICY_SCAN_ROOTS=("$SRC_DIR")
    fi
    if [ "${#POLICY_SCAN_ROOTS[@]}" -eq 0 ]; then
        check_warn "No in-scope source roots — app-config cache scan skipped (WI-03)"
    else
        APP_CONFIG_RESULT="$(python3 "$APP_CONFIG_SCAN" "${POLICY_SCAN_ROOTS[@]}" 2>/dev/null || echo OK)"
        case "${APP_CONFIG_RESULT%%|*}" in
            UNCACHED)
                check_warn "getApplicationConfig/Policy read outside cache-and-refresh path — cache in Application and refresh in onUpdateConfig/onUpdatePolicy (WI-03). Hits: ${APP_CONFIG_RESULT#*|}"
                ;;
            OK)
                check_pass "Application config/policy reads follow cache-and-refresh pattern or none detected (WI-03)"
                ;;
            *)
                check_warn "Phase 7 app-config scan returned unexpected result: $APP_CONFIG_RESULT"
                ;;
        esac
    fi
else
    check_warn "app-config-policy-scan.py missing — WI-03 cache check skipped"
fi

echo ""
