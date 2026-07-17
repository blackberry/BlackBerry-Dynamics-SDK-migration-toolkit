# BlackBerry Dynamics Migration — validator phase 6b
#
# Sourced by tooling/validate.sh once should_run_phase "6b" passes.
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
    # Phase 6b: WebView Hardening
    # ========================================
    echo "Phase 6b: WebView Hardening"
    echo "-----------------------------------------"
WEBVIEW_JS_INTERFACE=$(count_noncomment_ere_hits "addJavascriptInterface" "$SRC_DIR_MM/")
WEBVIEW_UNSAFE_SETTINGS=$(count_noncomment_ere_hits "setAllowFileAccess[[:space:]]*\\([[:space:]]*true[[:space:]]*\\)|setAllowContentAccess[[:space:]]*\\([[:space:]]*true[[:space:]]*\\)|setAllowFileAccessFromFileURLs[[:space:]]*\\([[:space:]]*true[[:space:]]*\\)|setAllowUniversalAccessFromFileURLs[[:space:]]*\\([[:space:]]*true[[:space:]]*\\)|setMixedContentMode[[:space:]]*\\([[:space:]]*[^)]*MIXED_CONTENT_ALWAYS_ALLOW" "$SRC_DIR_MM/")
STD_WEBVIEW=$(count_noncomment_ere_hits "android\\.webkit\\.WebView|<WebView[[:space:]/>]|<android\\.webkit\\.WebView[[:space:]/>]" "$SRC_DIR_MM/")
BB_WEBVIEW=$(count_noncomment_ere_hits "com\\.blackberry\\.bbwebview\\.BBWebView|<com\\.blackberry\\.bbwebview\\.BBWebView[[:space:]/>]" "$SRC_DIR_MM/")
[ "$WEBVIEW_JS_INTERFACE" -gt 0 ] && check_fail "addJavascriptInterface usage detected ($WEBVIEW_JS_INTERFACE) — remove the JS bridge entirely. If the bridge is unavoidable, the developer must defer the entire 'webview' domain in bootstrap.json deferredDomains[]." || check_pass "No addJavascriptInterface usage detected"
[ "$WEBVIEW_UNSAFE_SETTINGS" -gt 0 ] && check_fail "Unsafe WebView settings enabled ($WEBVIEW_UNSAFE_SETTINGS) — remove true-enabled file/content access and mixed-content always-allow" || check_pass "No unsafe WebView settings enabled"
if [ "$STD_WEBVIEW" -gt 0 ]; then
    fail_or_defer "webview" "Standard android.webkit.WebView usage remains ($STD_WEBVIEW) — migrate to BBWebView per prompt 07 / steering 50"
else
    if [ "$BB_WEBVIEW" -gt 0 ]; then
        check_pass "BBWebView usage detected with no standard WebView remnants"
    else
        check_pass "No WebView usage detected (not applicable)"
    fi
fi
echo ""
