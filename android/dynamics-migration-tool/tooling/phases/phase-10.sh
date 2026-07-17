# BlackBerry Dynamics Migration — validator phase 10
#
# Sourced by tooling/validate.sh once should_run_phase "10" passes.
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
    # Phase 10: API Audit
    # ========================================
    echo "Phase 10: API Audit"
    echo "-----------------------------------------"

# Roll the new (Room / OkHttp / Retrofit / unsupported network stacks /
# direct File / createTempFile) detections into the standard-API-remaining
# tally so this summary lines up with the per-phase failures above.
ROOM_UNMIGRATED=0
[ "$ROOM_FILE_COUNT" -gt 0 ] && [ "$BRIDGE_FACTORY_FILES" -eq 0 ] && ROOM_UNMIGRATED=$ROOM_FILE_COUNT
OKHTTP_UNMIGRATED=0
[ "$OKHTTP_FILE_COUNT" -gt 0 ] && [ "$INTERCEPTOR_COUNT" -eq 0 ] && OKHTTP_UNMIGRATED=$OKHTTP_FILE_COUNT
RETROFIT_UNMIGRATED=0
[ "$RETROFIT_FILE_COUNT" -gt 0 ] && [ "$INTERCEPTOR_COUNT" -eq 0 ] && RETROFIT_UNMIGRATED=$RETROFIT_FILE_COUNT
UNSUPPORTED_NET_STACKS=${UNSUPPORTED_NET_BLOCKERS:-0}
UNSUPPORTED_NET_DEPENDENCY_HINTS=${UNSUPPORTED_NET_DEP_HINTS:-0}

TOTAL_STD=$((STD_FS + STD_SQL + STD_HTTP + STD_SOCK + STD_POL + STD_CLIP \
    + COMPOSE_CLIPBOARD_UNMANAGED + CLIPBOARD_SERVICE_HITS + COMPOSE_ICC_VIEW_CHOOSER \
    + DIRECT_FILE_COUNT + TEMP_FILE_COUNT + EXTERNAL_STORAGE_API_SURFACE + SENSITIVE_PREF_KEYS \
    + ROOM_UNMIGRATED + OKHTTP_UNMIGRATED + RETROFIT_UNMIGRATED \
    + UNSUPPORTED_NET_STACKS + UNSUPPORTED_NET_DEPENDENCY_HINTS \
    + TRANSPORT_HARDENING_HITS + WEBVIEW_JS_INTERFACE + WEBVIEW_UNSAFE_SETTINGS))

# Deferral-corrected total: subtract whatever the developer has signed
# off as deferred in bootstrap.json. This is the number the final pass
# / fail check uses, so a fully-deferred app does not re-introduce a
# Phase 10 hard fail.
#
# IMPORTANT: EXTERNAL_STORAGE_API_SURFACE is intentionally NEVER
# subtracted, even when `secureFileStorage` is deferred. External
# storage / MediaStore / shared-storage writes break the Dynamics
# secure-container contract and are a SECURITY BLOCKER for production
# (see phase-4.sh — handled via `security_blocker "externalStorage"
# ...` and the non-waivable domain set in validate.sh /
# phase-0.sh). Earlier toolkit versions allowed a deferred
# secureFileStorage domain to subtract MediaStore / external-storage
# hits from Phase 10's "Standard APIs remaining" check; that behaviour
# has been removed so those writes remain hard failures.
TOTAL_STD_HARDFAIL=$TOTAL_STD
DEFERRED_NOTE=""
if is_domain_deferred "secureFileStorage"; then
    TOTAL_STD_HARDFAIL=$((TOTAL_STD_HARDFAIL - STD_FS - DIRECT_FILE_COUNT - TEMP_FILE_COUNT))
    DEFERRED_NOTE="$DEFERRED_NOTE secureFileStorage"
fi
if is_domain_deferred "secureSql"; then
    TOTAL_STD_HARDFAIL=$((TOTAL_STD_HARDFAIL - STD_SQL - ROOM_UNMIGRATED))
    DEFERRED_NOTE="$DEFERRED_NOTE secureSql"
fi
if is_domain_deferred "secureNetworking"; then
    TOTAL_STD_HARDFAIL=$((TOTAL_STD_HARDFAIL - STD_HTTP - STD_SOCK - OKHTTP_UNMIGRATED - RETROFIT_UNMIGRATED))
    DEFERRED_NOTE="$DEFERRED_NOTE secureNetworking"
fi
[ "$TOTAL_STD_HARDFAIL" -lt 0 ] && TOTAL_STD_HARDFAIL=0

DYNAMICS_TOTAL=$(grep -rn "com.good.gd" "$SRC_DIR_MM/" 2>/dev/null | strip_audit_noise | wc -l | tr -d ' ')

echo "  Standard APIs remaining (raw):              $TOTAL_STD"
echo "    breakdown: file=$STD_FS sqlite=$STD_SQL http=$STD_HTTP socket=$STD_SOCK policy=$STD_POL clipboard=$STD_CLIP compose-clipboard=$COMPOSE_CLIPBOARD_UNMANAGED clipboard-service=$CLIPBOARD_SERVICE_HITS compose-icc-chooser=$COMPOSE_ICC_VIEW_CHOOSER"
echo "               direct-File=$DIRECT_FILE_COUNT createTempFile=$TEMP_FILE_COUNT room-no-bridge=$ROOM_UNMIGRATED okhttp-no-interceptor=$OKHTTP_UNMIGRATED retrofit-no-interceptor=$RETROFIT_UNMIGRATED unsupported-net-stack=$UNSUPPORTED_NET_STACKS unsupported-net-dependency=$UNSUPPORTED_NET_DEPENDENCY_HINTS"
if [ -n "$DEFERRED_NOTE" ]; then
    echo "  Standard APIs remaining (after deferrals):  $TOTAL_STD_HARDFAIL"
    echo "    deferred domains: ${DEFERRED_NOTE# }"
fi
echo "  Dynamics APIs found:     $DYNAMICS_TOTAL"
echo ""

if [ "$TOTAL_STD_HARDFAIL" -eq 0 ]; then
    if [ "$TOTAL_STD" -eq 0 ]; then
        check_pass "No standard APIs remain"
    else
        check_warn "Standard APIs remain ($TOTAL_STD raw) but all are in developer-deferred domains"
    fi
else
    check_fail "Standard APIs still present ($TOTAL_STD_HARDFAIL — excluding deferrals; $TOTAL_STD raw) — review phases 4–8 above and re-run failing prompts"
fi
[ "$DYNAMICS_TOTAL" -gt 0 ] && check_pass "Dynamics APIs present" || check_warn "No Dynamics APIs found"

# ----------------------------------------------------------------
# SECURITY BLOCKER summary.
#
# Re-emit, at the very end of the validator run, every
# `security_blocker` line that was raised during the phase scans
# (Phase 4 external-storage surface is the canonical source today).
# The reason for re-emission is that a long phase log can bury a
# single SECURITY BLOCKER under hundreds of pass lines; this block
# guarantees the developer (and the report generator) sees them.
#
# Prompt 10's report-generation step reads
# `output/.security-blockers.log` and must:
#   - copy each row into `releaseReadiness.blockingItems[]`,
#   - record a corresponding `manualTodos[]` entry with
#     `blocking: true`,
#   - set `releaseReadiness.recommendation` to `"no-go"`,
#   - set `securityPosture.dataAtRest.status` to `"partial"` (or
#     `"unverified"` if external-storage usage is widespread),
#   - and when the report schema is at v2.1.0+ populate the
#     optional `securityBlockers[]` array.
# ----------------------------------------------------------------
SEC_BLOCKERS_LOG="dynamics-migration-tool/output/.security-blockers.log"
if [ -s "$SEC_BLOCKERS_LOG" ]; then
    echo ""
    echo "========================================================"
    echo "  SECURITY BLOCKERS — manual intervention required"
    echo "  before production use. Migration is NOT complete."
    echo "========================================================"
    awk -F'\t' '{printf "  [%s/%s] count=%s — %s\n", $1, $2, $3, $4}' "$SEC_BLOCKERS_LOG"
    echo "========================================================"
    echo "  These findings cannot be deferred. They must be"
    echo "  resolved (migrated into the Dynamics secure container)"
    echo "  or the migration must be reported as incomplete in"
    echo "  migration-report.json (recommendation: \"no-go\")."
    echo "========================================================"
fi
echo ""
