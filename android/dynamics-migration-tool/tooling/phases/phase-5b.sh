# BlackBerry Dynamics Migration — validator phase 5b
#
# Sourced by tooling/validate.sh once should_run_phase "5b" passes.
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
    # Phase 5b: Redundant Crypto
    # ========================================
    echo "Phase 5b: Redundant Crypto"
    echo "-----------------------------------------"

REDUNDANT_CRYPTO=$(grep -rnE "javax\.crypto\.Cipher|CipherInputStream|CipherOutputStream|EncryptedSharedPreferences|EncryptedFile|MasterKey|Aead|StreamingAead|KeyGenParameterSpec" "$SRC_DIR/" 2>/dev/null | strip_audit_noise | count_hits_for_domain "redundantCrypto")
if [ "$REDUNDANT_CRYPTO" -gt 0 ]; then
    check_warn "Redundant app-level crypto patterns detected ($REDUNDANT_CRYPTO) — classify as remove-now / temporary-pass-through / business-required and document rationale + cleanup in migration report"
else
    check_pass "No redundant app-level crypto patterns detected"
fi
echo ""
