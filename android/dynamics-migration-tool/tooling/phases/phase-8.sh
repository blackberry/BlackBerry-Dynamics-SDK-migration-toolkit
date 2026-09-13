# BlackBerry Dynamics Migration — validator phase 8
#
# Sourced by tooling/validate.sh once should_run_phase "8" passes.
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
    # Phase 8: UI Widgets
    # ========================================
    echo "Phase 8: UI Widgets"
    echo "-----------------------------------------"

# Build a space-separated list of layout dirs across every in-scope
# source set. Falls back to the legacy app/src/main/res/layout/ when
# the resource list is empty (e.g. the project keeps layouts in a
# non-default location).
GD_WIDGET_PATHS="$SRC_DIR_MM/"
for res in $MM_IN_SCOPE_RES_DIRS; do
    for layout_dir in "$res"/layout*; do
        [ -d "$layout_dir" ] && GD_WIDGET_PATHS="$GD_WIDGET_PATHS $layout_dir/"
    done
done
# shellcheck disable=SC2086
GD_ET=$(count_noncomment_ere_hits "GDEditText" $GD_WIDGET_PATHS)
# shellcheck disable=SC2086
GD_TV=$(count_noncomment_ere_hits "GDTextView" $GD_WIDGET_PATHS)

[ "$GD_ET" -gt 0 ] && check_pass "GDEditText used ($GD_ET)" || check_pass "GDEditText not found (not applicable in this app)"
[ "$GD_TV" -gt 0 ] && check_pass "GDTextView used ($GD_TV)" || check_pass "GDTextView not found (not applicable in this app)"

# Lane-aware UI surface scan (catalog-backed)
UI_WIDGET_LANE="explicit_gd_widgets"
UI_SURFACE_SCAN="$SCRIPT_DIR/lib/ui-surface-scan.py"
if [ -f "$UI_SURFACE_SCAN" ]; then
    UI_SCAN_ROOTS=()
    if [ -n "$MM_IN_SCOPE_SOURCE_ROOTS" ]; then
        while IFS= read -r _sroot; do
            [ -n "$_sroot" ] && UI_SCAN_ROOTS+=("$_sroot")
        done <<EOF
$MM_IN_SCOPE_SOURCE_ROOTS
EOF
    fi
    if [ "${#UI_SCAN_ROOTS[@]}" -eq 0 ] && [ -n "$SRC_DIR_MM" ]; then
        UI_SCAN_ROOTS+=("$SRC_DIR_MM")
    fi
    if [ "${#UI_SCAN_ROOTS[@]}" -eq 0 ]; then
        check_warn "No in-scope source roots — ui-surface-scan skipped"
    else
        export MM_IN_SCOPE_RES_DIRS
        UI_SCAN_RESULT="$(python3 "$UI_SURFACE_SCAN" "${UI_SCAN_ROOTS[@]}" 2>/dev/null || true)"
        _ui_scan_entry() {
            local key="$1"
            printf "%s\n" "$UI_SCAN_RESULT" | awk -F= -v k="$key" '$1==k{print $2; exit}'
        }
        _ui_scan_handle() {
            local key="$1" domain="$2" label="$3"
            local entry status detail
            entry="$(_ui_scan_entry "$key")"
            [ -z "$entry" ] && { check_warn "$label scan returned no result"; return; }
            status="${entry%%|*}"
            detail="${entry#*|}"
            [ "$entry" = "$status" ] && detail=""
            case "$status" in
                FAIL)
                    fail_or_defer "$domain" "$label failed${detail:+: $detail}"
                    ;;
                PASS)
                    check_pass "$label passed${detail:+: $detail}"
                    ;;
                NA)
                    check_pass "$label not applicable"
                    ;;
                *)
                    check_warn "$label returned unexpected status: ${entry}"
                    ;;
            esac
            if [ "$key" = "UI_LANE" ] && [ "$status" = "PASS" ] && [ -n "$detail" ]; then
                UI_WIDGET_LANE="$detail"
            fi
        }

        _ui_scan_handle "UI_LANE" "secureUiWidgets" "UI lane consistency"
        # Always honor the scanner's effective lane, including mixed-lane FAIL
        # (inflater is present; leftover standard tags must not be treated as Lane B remnants).
        _UI_EFFECTIVE_LANE="$(_ui_scan_entry UI_EFFECTIVE_LANE)"
        if [ -n "$_UI_EFFECTIVE_LANE" ] && [ "$_UI_EFFECTIVE_LANE" != "NA" ]; then
            UI_WIDGET_LANE="$_UI_EFFECTIVE_LANE"
        fi
        _ui_scan_handle "UI_BIND_001" "secureUiWidgets" "UI binding compatibility"
        _ui_scan_handle "UI_CHILD_001" "secureUiWidgets" "UI mixed-sibling child cast safety"
        _ui_scan_handle "UI_CUSTOM_001" "secureUiWidgets" "UI custom-tag migration safety"
        _ui_scan_handle "UI_PROG_001" "secureUiWidgets" "Programmatic widget migration coverage"
        _ui_scan_handle "UI_SEARCH_001" "secureUiWidgets" "SearchView lane compatibility"
        _ui_scan_handle "UI_TIN_001" "secureUiWidgets" "TextInputEditText migration coverage"
        _ui_scan_handle "UI_REMOTE_001" "secureUiWidgets" "RemoteViews GD widget safety"
        _ui_scan_handle "UI_DRAG_001" "secureClipboard" "Secure drag/drop clipboard routing"
    fi
else
    check_warn "ui-surface-scan.py missing — lane-aware UI checks skipped"
fi

# Direct-replacement widget family coverage. Explicit lane requires
# standard/AppCompat remnants to be removed. In AppCompat inflater lane,
# those remnants are expected and scanner checks enforce consistency.
WIDGET_FAMILY_SPECS=(
    # gd_class|xml_tags|fqn_imports|binding_tokens
    # XML-only remnants for EditText/TextView (imports of android.widget.* remain
    # valid Lane B bind types).
    "GDEditText|EditText||EditText"
    "GDTextView|TextView,com.google.android.material.textview.MaterialTextView||TextView"
    "GDAutoCompleteTextView|AutoCompleteTextView|android.widget.AutoCompleteTextView|AutoCompleteTextView"
    "GDMultiAutoCompleteTextView|MultiAutoCompleteTextView|android.widget.MultiAutoCompleteTextView|MultiAutoCompleteTextView"
    "GDSearchView|SearchView|android.widget.SearchView,androidx.appcompat.widget.SearchView|SearchView"
    "GDAppCompatEditText|androidx.appcompat.widget.AppCompatEditText|androidx.appcompat.widget.AppCompatEditText|AppCompatEditText"
    "GDAppCompatTextView|androidx.appcompat.widget.AppCompatTextView|androidx.appcompat.widget.AppCompatTextView|AppCompatTextView"
    "GDAppCompatCheckedTextView|CheckedTextView,android.widget.CheckedTextView,androidx.appcompat.widget.AppCompatCheckedTextView|androidx.appcompat.widget.AppCompatCheckedTextView|AppCompatCheckedTextView"
    "GDAppCompatAutoCompleteTextView|androidx.appcompat.widget.AppCompatAutoCompleteTextView|androidx.appcompat.widget.AppCompatAutoCompleteTextView|AppCompatAutoCompleteTextView"
    "GDAppCompatMultiAutoCompleteTextView|androidx.appcompat.widget.AppCompatMultiAutoCompleteTextView|androidx.appcompat.widget.AppCompatMultiAutoCompleteTextView|AppCompatMultiAutoCompleteTextView"
    "GDAppCompatSearchView|androidx.appcompat.widget.SearchView|androidx.appcompat.widget.SearchView|SearchView"
    "GDTextInputEditText|com.google.android.material.textfield.TextInputEditText|com.google.android.material.textfield.TextInputEditText|TextInputEditText"
)

_widget_count_token() {
    local token="$1"
    # shellcheck disable=SC2086
    count_noncomment_ere_hits "$token" $GD_WIDGET_PATHS
}

WIDGET_FAMILY_REMAINING_TOTAL=0
for spec in "${WIDGET_FAMILY_SPECS[@]}"; do
    GD_CLASS="${spec%%|*}"
    rest="${spec#*|}"
    XML_TAGS="${rest%%|*}"
    rest="${rest#*|}"
    FQN_IMPORTS="${rest%%|*}"
    BINDING_TOKEN="${rest##*|}"

    # shellcheck disable=SC2086
    GD_HITS=$(count_noncomment_ere_hits "com\\.good\\.gd\\.widget\\.${GD_CLASS}" $GD_WIDGET_PATHS)

    XML_HITS=0
    for tag in ${XML_TAGS//,/ }; do
        H=$(_widget_count_token "<${tag}[[:space:]/>]" || true)
        XML_HITS=$((XML_HITS + ${H:-0}))
    done

    IMPORT_HITS=0
    for fqn in ${FQN_IMPORTS//,/ }; do
        H=$(_widget_count_token "import[[:space:]]+${fqn//./\\.}\b" || true)
        IMPORT_HITS=$((IMPORT_HITS + ${H:-0}))
    done

    REMAINING=$((XML_HITS + IMPORT_HITS))
    WIDGET_FAMILY_REMAINING_TOTAL=$((WIDGET_FAMILY_REMAINING_TOTAL + REMAINING))

    if [ "$UI_WIDGET_LANE" = "appcompat_inflater" ]; then
        if [ "$REMAINING" -gt 0 ]; then
            check_pass "Widget family (inflater lane): $BINDING_TOKEN standard/AppCompat remnants expected ($REMAINING: xml=$XML_HITS, imports=$IMPORT_HITS)"
        else
            check_pass "Widget family (inflater lane): $BINDING_TOKEN not present"
        fi
        continue
    fi

    if [ "$GD_HITS" -gt 0 ]; then
        if [ "$REMAINING" -gt 0 ]; then
            fail_or_defer "secureUiWidgets" "Direct-replacement widget family: $GD_CLASS is in use ($GD_HITS) but standard equivalents still remain ($REMAINING: xml=$XML_HITS, imports=$IMPORT_HITS) — classify call sites and finish migration or defer secureUiWidgets."
        else
            check_pass "Widget family: $GD_CLASS used ($GD_HITS); no standard remnants"
        fi
    else
        if [ "$REMAINING" -gt 0 ]; then
            fail_or_defer "secureUiWidgets" "Direct-replacement widget family: standard $BINDING_TOKEN still present ($REMAINING: xml=$XML_HITS, imports=$IMPORT_HITS) and no com.good.gd.widget.$GD_CLASS usage — classify call sites and migrate (prompt 09 / steering 45) or defer secureUiWidgets in bootstrap.json"
        else
            check_pass "Widget family: $GD_CLASS not applicable in this app"
        fi
    fi
done

if [ "$UI_WIDGET_LANE" != "appcompat_inflater" ] && [ "$WIDGET_FAMILY_REMAINING_TOTAL" -eq 0 ]; then
    check_pass "Direct-replacement widget family fully covered (no standard/AppCompat/Material remnants)"
fi

# MaterialTextView binding mismatch remains a hard runtime crash in explicit lane.
if [ "$UI_WIDGET_LANE" != "appcompat_inflater" ] && [ "$GD_TV" -gt 0 ]; then
    MAT_TV_BINDINGS=$(count_noncomment_ere_hits "import[[:space:]]+com\\.google\\.android\\.material\\.textview\\.MaterialTextView|\\bMaterialTextView[[:space:]]+[A-Za-z_][A-Za-z0-9_]*\\b|\\([[:space:]]*MaterialTextView[[:space:]]*\\)" "$SRC_DIR_MM/")
    if [ "${MAT_TV_BINDINGS:-0}" -gt 0 ]; then
        fail_or_defer "secureUiWidgets" "MaterialTextView references remain ($MAT_TV_BINDINGS) while layouts use GDTextView — runtime ClassCastException; replace migrated bindings."
    else
        check_pass "No MaterialTextView vs GDTextView binding mismatch"
    fi
fi

# Legacy GDWebView detection. GDWebView is deprecated; BBWebView is the
# only supported migration target (prompt 07 + steering 50). Any
# reference to com.good.gd.widget.GDWebView — in code or layouts — is a
# migration defect and is treated as invalid. Routed through the
# `webview` domain so the same deferral semantics apply as other webview
# checks (the domain is not in the non-waivable list).
LEGACY_GDWEBVIEW=$(count_noncomment_ere_hits "com\\.good\\.gd\\.widget\\.GDWebView|<com\\.good\\.gd\\.widget\\.GDWebView" "$SRC_DIR_MM/" $GD_WIDGET_PATHS)
if [ "${LEGACY_GDWEBVIEW:-0}" -gt 0 ]; then
    fail_or_defer "webview" "Legacy com.good.gd.widget.GDWebView usage detected ($LEGACY_GDWEBVIEW) — GDWebView is deprecated and is not a supported migration target. Migrate to com.blackberry.bbwebview.BBWebView (prompt 07 / steering 50-webview-bbwebview.md)."
else
    check_pass "No legacy com.good.gd.widget.GDWebView usage detected"
fi

# Clipboard DLP enforcement
GD_CLIP=$(count_noncomment_ere_hits "com\\.good\\.gd\\.content\\.ClipboardManager" "$SRC_DIR_MM/")
STD_CLIP=$(count_noncomment_ere_hits "android\\.content\\.ClipboardManager" "$SRC_DIR_MM/")

[ "$STD_CLIP" -gt 0 ] && check_fail "Standard ClipboardManager still present ($STD_CLIP) — DLP policies bypassed — re-run prompt 09 (UI widgets, clipboard section)" || check_pass "Standard ClipboardManager removed"
[ "$GD_CLIP" -gt 0 ] && check_pass "Dynamics secure ClipboardManager used ($GD_CLIP)" || check_pass "Dynamics ClipboardManager not found (not applicable: no clipboard usage)"

CLIPBOARD_SERVICE_HITS=$(count_noncomment_ere_hits "CLIPBOARD_SERVICE|getSystemService[[:space:]]*\\([[:space:]]*Context\\.CLIPBOARD_SERVICE" "$SRC_DIR_MM/")
if [ "${CLIPBOARD_SERVICE_HITS:-0}" -gt 0 ]; then
    check_fail "System clipboard service acquisition still present ($CLIPBOARD_SERVICE_HITS) — use com.good.gd.content.ClipboardManager.getInstance(context) or GDClipboardAdapter for Compose — re-run prompt 09"
else
    check_pass "No CLIPBOARD_SERVICE system clipboard acquisition detected"
fi

COMPOSE_CLIP_SCAN="$SCRIPT_DIR/lib/compose-clipboard-scan.py"
COMPOSE_CLIPBOARD_UNMANAGED=0
if [ -f "$COMPOSE_CLIP_SCAN" ]; then
    CLIP_SCAN_ROOTS=()
    if [ -n "$MM_IN_SCOPE_SOURCE_ROOTS" ]; then
        while IFS= read -r _croot; do
            [ -n "$_croot" ] && CLIP_SCAN_ROOTS+=("$_croot")
        done <<EOF
$MM_IN_SCOPE_SOURCE_ROOTS
EOF
    fi
    if [ "${#CLIP_SCAN_ROOTS[@]}" -eq 0 ] && [ -n "$SRC_DIR_MM" ]; then
        CLIP_SCAN_ROOTS=("$SRC_DIR_MM")
    fi
    if [ "${#CLIP_SCAN_ROOTS[@]}" -eq 0 ]; then
        check_warn "No in-scope source roots — Compose clipboard scan skipped"
    else
        COMPOSE_CLIP_RESULT="$(python3 "$COMPOSE_CLIP_SCAN" "${CLIP_SCAN_ROOTS[@]}" 2>/dev/null || echo OK)"
        case "${COMPOSE_CLIP_RESULT%%|*}" in
            UNMANAGED)
                COMPOSE_CLIPBOARD_UNMANAGED="${COMPOSE_CLIP_RESULT#*|}"
                COMPOSE_CLIPBOARD_UNMANAGED="${COMPOSE_CLIPBOARD_UNMANAGED%%|*}"
                [ -z "$COMPOSE_CLIPBOARD_UNMANAGED" ] && COMPOSE_CLIPBOARD_UNMANAGED=1
                check_fail "Unmanaged Jetpack Compose clipboard API(s) remain ($COMPOSE_CLIPBOARD_UNMANAGED) — migrate to GDClipboardAdapter (templates/clipboard/GDClipboardAdapter.kt) or record manualTodos with appropriate severity/blocking — re-run prompt 09"
                ;;
            OK)
                check_pass "No unmanaged Jetpack Compose clipboard APIs detected"
                ;;
            *)
                check_warn "Compose clipboard scan returned unexpected result: $COMPOSE_CLIP_RESULT"
                ;;
        esac
    fi
else
    check_warn "compose-clipboard-scan.py missing — Compose clipboard check skipped"
fi

# Custom EditText/TextView subclasses must extend GD equivalents for system copy/paste DLP
CUSTOM_ET=$(grep -rn "AppCompatEditText" "$SRC_DIR_MM/" 2>/dev/null \
    | grep "class " \
    | grep -v "GDAppCompatEditText" \
    | strip_audit_noise \
    | count_hits_for_domain "secureUiWidgets")
CUSTOM_TV=$(grep -rn "AppCompatTextView" "$SRC_DIR_MM/" 2>/dev/null \
    | grep "class " \
    | grep -v "GDAppCompatTextView" \
    | strip_audit_noise \
    | count_hits_for_domain "secureUiWidgets")

[ "$CUSTOM_ET" -gt 0 ] && check_fail "Custom EditText subclasses still extend AppCompatEditText ($CUSTOM_ET) — system copy/paste bypasses DLP — re-run prompt 09 (UI widgets, section 5b)" || check_pass "No custom EditText subclasses extending AppCompatEditText"
[ "$CUSTOM_TV" -gt 0 ] && check_fail "Custom TextView subclasses still extend AppCompatTextView ($CUSTOM_TV) — system copy/paste bypasses DLP — re-run prompt 09 (UI widgets, section 5b)" || check_pass "No custom TextView subclasses extending AppCompatTextView"

# Custom subclasses extending the rest of the direct-replacement widget
# family. Each entry maps the standard/AppCompat base to the GD class
# that the developer must use as the parent class instead.
WIDGET_BASE_PAIRS=(
    "AppCompatCheckedTextView|GDAppCompatCheckedTextView"
    "AppCompatAutoCompleteTextView|GDAppCompatAutoCompleteTextView"
    "AppCompatMultiAutoCompleteTextView|GDAppCompatMultiAutoCompleteTextView"
    # SearchView base: AppCompat (androidx.appcompat.widget.SearchView) is
    # the modern parent; we accept either GDAppCompatSearchView or
    # GDSearchView as the GD parent class.
    "AppCompatSearchView|GDAppCompatSearchView"
    # Standard android.widget bases (less common as direct parents, but
    # still real in legacy code).
    "AutoCompleteTextView|GDAutoCompleteTextView"
    "MultiAutoCompleteTextView|GDMultiAutoCompleteTextView"
    "TextInputEditText|GDTextInputEditText"
)
for pair in "${WIDGET_BASE_PAIRS[@]}"; do
    BASE_CLASS="${pair%%|*}"
    GD_PARENT="${pair##*|}"
    # AppCompatEditText and AppCompatTextView are handled by the existing
    # CUSTOM_ET / CUSTOM_TV checks above; skip them here to avoid duplicate
    # reporting. We also need to skip false positives where the class line
    # actually extends the GD equivalent (e.g. GDAppCompatCheckedTextView
    # contains "AppCompatCheckedTextView" as a substring).
    HITS=$(grep -rnE "class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\([^)]*\))?[[:space:]]*(:|extends)[[:space:]]+(androidx\.appcompat\.widget\.|android\.widget\.)?${BASE_CLASS}\b" "$SRC_DIR_MM/" 2>/dev/null \
        | grep -v "${GD_PARENT}" \
        | strip_audit_noise \
        | count_hits_for_domain "secureUiWidgets")
    if [ "${HITS:-0}" -gt 0 ]; then
        fail_or_defer "secureUiWidgets" "Custom widget subclasses still extend ${BASE_CLASS} ($HITS) — system copy/paste bypasses DLP for this widget family. Change the root parent class to com.good.gd.widget.${GD_PARENT} (prompt 09 section 5b / steering 45)"
    else
        check_pass "No custom widget subclasses extending ${BASE_CLASS}"
    fi
done
TIMBER_LOG_COUNT=$(count_noncomment_ere_hits "Timber\\.(d|v|i|w|e)\\(|Napier\\.(d|v|i|w|e)\\(" "$SRC_DIR_MM/")
[ "$TIMBER_LOG_COUNT" -gt 0 ] && check_warn "Custom logging framework calls detected ($TIMBER_LOG_COUNT) — ensure sensitive data is never logged" || check_pass "No Timber/Napier logging calls detected"

STATIC_TEXT_RUNTIME_SET=$(count_noncomment_ere_hits "findViewById\\(R\\.id\\.[A-Za-z0-9_]+\\).*setText\\(" "$SRC_DIR_MM/")
[ "$STATIC_TEXT_RUNTIME_SET" -gt 0 ] && check_warn "Runtime setText on direct view bindings detected ($STATIC_TEXT_RUNTIME_SET) — verify static-label classifications" || check_pass "No obvious static-label runtime setText patterns detected"

# HR-0-4: broad DLP/output surfaces are non-blocking manual interventions by
# default unless they overlap an existing non-waivable rule. We detect them
# here and require prompt 10 to carry them into manualTodos[].
DLP_NOTIFICATION_SURFACE_HITS=$(count_noncomment_ere_hits "NotificationCompat\\.Builder|Notification\\.Builder|setContentText\\(|setStyle\\(" "$SRC_DIR_MM/")
DLP_PRINT_SURFACE_HITS=$(count_noncomment_ere_hits "PrintManager|PrintDocumentAdapter|createPrintDocumentAdapter|\\.print\\(" "$SRC_DIR_MM/")
DLP_SCREENSHOT_SURFACE_HITS=$(count_noncomment_ere_hits "clearFlags\\([^)]*FLAG_SECURE|MediaProjection|PixelCopy|setRecentsScreenshotEnabled|onProvideAssistData" "$SRC_DIR_MM/")
DLP_AUTOFILL_SURFACE_HITS=$(count_noncomment_ere_hits "AutofillManager|importantForAutofill|setAutofillHints|getAutofillType" "$SRC_DIR_MM/")
DLP_ACCESSIBILITY_SURFACE_HITS=$(count_noncomment_ere_hits "AccessibilityManager|AccessibilityService|sendAccessibilityEvent|setAccessibilityDelegate|TYPE_VIEW_TEXT_CHANGED" "$SRC_DIR_MM/")
DLP_IME_SURFACE_HITS=$(count_noncomment_ere_hits "InputMethodManager|EditorInfo\\.IME_|setImeOptions|onCreateInputConnection|InputConnection" "$SRC_DIR_MM/")
DLP_EXTERNAL_BROWSER_SURFACE_HITS=$(count_noncomment_ere_hits "CustomTabsIntent|androidx\\.browser\\.customtabs|Intent\\.ACTION_VIEW|setPackage\\(\"com\\.android\\.chrome\"\\)" "$SRC_DIR_MM/")
DLP_RICH_CLIPBOARD_URI_SURFACE_HITS=$(count_noncomment_ere_hits "ClipData\\.newUri|setPrimaryClip\\(|ClipData\\.Item\\([^)]*Uri" "$SRC_DIR_MM/")
DLP_DRAGDROP_SURFACE_HITS=$(count_noncomment_ere_hits "startDragAndDrop|startDrag\\(|OnDragListener|DragEvent|requestDragAndDropPermissions" "$SRC_DIR_MM/")

if [ "${DLP_PRINT_SURFACE_HITS:-0}" -gt 0 ]; then
    check_warn "Android printing surface detected ($DLP_PRINT_SURFACE_HITS) — remove unmanaged PrintManager/PrintDocumentAdapter usage unless an explicitly approved Dynamics-compatible secure printing workflow exists; report the feature outcome in egressFeatureDecisions[]/manualTodos[]"
fi
if [ "${DLP_RICH_CLIPBOARD_URI_SURFACE_HITS:-0}" -gt 0 ]; then
    check_warn "Rich clipboard URI/content transfer surface detected ($DLP_RICH_CLIPBOARD_URI_SURFACE_HITS) — remove unmanaged ClipData URI export or replace with a documented Dynamics-controlled boundary; do not preserve URI-bearing clipboard flows by default"
fi
if [ "${DLP_DRAGDROP_SURFACE_HITS:-0}" -gt 0 ]; then
    check_warn "Cross-app drag/drop surface detected ($DLP_DRAGDROP_SURFACE_HITS) — remove or block protected-content drag/drop paths unless a specific Dynamics-safe workflow is approved; record the feature outcome in egressFeatureDecisions[]/manualTodos[]"
fi

DLP_SURFACE_TOTAL=$((DLP_NOTIFICATION_SURFACE_HITS + DLP_PRINT_SURFACE_HITS + DLP_SCREENSHOT_SURFACE_HITS + DLP_AUTOFILL_SURFACE_HITS + DLP_ACCESSIBILITY_SURFACE_HITS + DLP_IME_SURFACE_HITS + DLP_EXTERNAL_BROWSER_SURFACE_HITS + DLP_RICH_CLIPBOARD_URI_SURFACE_HITS + DLP_DRAGDROP_SURFACE_HITS))
if [ "${DLP_SURFACE_TOTAL:-0}" -gt 0 ]; then
    check_warn "Broad DLP/output surfaces detected (notifications=$DLP_NOTIFICATION_SURFACE_HITS, print=$DLP_PRINT_SURFACE_HITS, screenshot=$DLP_SCREENSHOT_SURFACE_HITS, autofill=$DLP_AUTOFILL_SURFACE_HITS, accessibility=$DLP_ACCESSIBILITY_SURFACE_HITS, ime=$DLP_IME_SURFACE_HITS, externalBrowser=$DLP_EXTERNAL_BROWSER_SURFACE_HITS, richClipboardUri=$DLP_RICH_CLIPBOARD_URI_SURFACE_HITS, dragDrop=$DLP_DRAGDROP_SURFACE_HITS) — prompt 10 must record explicit egress outcomes and developer-owned manualTodos[]; escalate to blocking only when overlapping existing non-waivable rules."
else
    check_pass "No broad DLP/output manual-intervention surfaces detected"
fi

echo ""
