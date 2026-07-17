# BlackBerry Dynamics Migration — validator phase comments
#
# Sourced by tooling/validate.sh once should_run_phase "comments" passes.
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
    # Migration Comments Audit
    # ========================================
    echo "Migration Comments"
    echo "-----------------------------------------"

# Count audit comments across every in-scope source root (primary +
# libraries) so library-side migration tags are tallied. On single-
# module projects this collapses to the legacy app/src/main/ scope.
# Build the search target list as space-separated paths; if no roots
# exist (extreme fallback), default to the primary main src dir.
COMMENT_AUDIT_TARGETS="$MM_IN_SCOPE_SOURCE_ROOTS"
[ -z "$COMMENT_AUDIT_TARGETS" ] && COMMENT_AUDIT_TARGETS="$SRC_DIR"
# shellcheck disable=SC2086
COMMENT_COUNT=$(grep -rn "\[BB_DYNAMICS-MIGRATION\]" $COMMENT_AUDIT_TARGETS 2>/dev/null | wc -l | tr -d ' ')
echo "  [BB_DYNAMICS-MIGRATION] comments found: $COMMENT_COUNT"
# shellcheck disable=SC2086
WAIVER_TAG_COUNT=$(grep -rn "\[BB_DYNAMICS-WAIVER:" $COMMENT_AUDIT_TARGETS 2>/dev/null | wc -l | tr -d ' ')

if [ "$COMMENT_COUNT" -gt 0 ]; then
    check_pass "Migration comments present"
else
    if [ "$DYNAMICS_TOTAL" -gt 0 ]; then
        check_fail "No migration comments found — migrated code paths exist but [BB_DYNAMICS-MIGRATION] tags are missing"
    else
        check_warn "No migration comments found (no Dynamics code paths detected)"
    fi
fi

# Defense-in-depth: this toolkit recognizes only [BB_DYNAMICS-MIGRATION]
# as a valid audit tag and does not support line-level exceptions. A
# common pattern an LLM may attempt is to introduce a waiver-style tag
# (e.g. [BB_DYNAMICS-WAIVER:<id>]) to suppress findings. Explicitly
# reject the most likely shape so the failure is loud and actionable.
if [ "$WAIVER_TAG_COUNT" -gt 0 ]; then
    check_fail "Unsupported audit tag [BB_DYNAMICS-WAIVER:<id>] found in source ($WAIVER_TAG_COUNT occurrence(s)) — this toolkit does not support line-level exceptions. Remove every such tag, and either migrate the underlying call-sites to Dynamics APIs or have the developer defer the entire owning domain in bootstrap.json deferredDomains[]. Locate occurrences via: grep -rn '[BB_DYNAMICS-WAIVER:' $COMMENT_AUDIT_TARGETS"
else
    check_pass "No unsupported audit tag variants present in source"
fi

check_pass "No keyword-based sensitive logging scan — review log payloads manually during security review"
echo ""
