# BlackBerry Dynamics Migration — validator phase 12
#
# Sourced by tooling/validate.sh once should_run_phase "12" passes.
# WI-02: FCM FirebaseMessagingService handlers must gate on container
# authorization or Background Authorize handshake markers.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2086,SC2046,SC2016

    # ========================================
    # Phase 12: Push / FCM authorization gate
    # ========================================
    echo "Phase 12: Push / FCM authorization gate"
    echo "-----------------------------------------"

PUSH_FCM_SCAN="$SCRIPT_DIR/lib/push-fcm-gate-scan.py"
if [ ! -f "$PUSH_FCM_SCAN" ]; then
    check_fail "push-fcm-gate-scan.py missing — cannot run Phase 12 (WI-02)"
else
    PUSH_SCAN_ROOTS=()
    if [ -n "$MM_IN_SCOPE_SOURCE_ROOTS" ]; then
        while IFS= read -r _root; do
            [ -n "$_root" ] && PUSH_SCAN_ROOTS+=("$_root")
        done <<EOF
$MM_IN_SCOPE_SOURCE_ROOTS
EOF
    fi
    if [ "${#PUSH_SCAN_ROOTS[@]}" -eq 0 ] && [ -n "$SRC_DIR_MM" ]; then
        PUSH_SCAN_ROOTS=("$SRC_DIR_MM")
    fi
  if [ "${#PUSH_SCAN_ROOTS[@]}" -eq 0 ]; then
        check_warn "No in-scope source roots — Phase 12 FCM gate skipped"
    else
        PUSH_FCM_RESULT="$(python3 "$PUSH_FCM_SCAN" "${PUSH_SCAN_ROOTS[@]}" 2>/dev/null || echo OK)"
        case "${PUSH_FCM_RESULT%%|*}" in
            UNGATED)
                check_fail "FCM handler missing authorization guard (isContainerAuthorized / Background Authorize) — re-run prompt 11 (WI-02). Files: ${PUSH_FCM_RESULT#*|}"
                ;;
            OK)
                check_pass "FCM push handlers: authorization gate present or no FirebaseMessagingService handlers (WI-02)"
                ;;
            *)
                check_warn "Phase 12 FCM scan returned unexpected result: $PUSH_FCM_RESULT"
                ;;
        esac
    fi
fi

# Hard fails: deprecated/stale Push Channel registration APIs.
if [ -n "$MM_IN_SCOPE_SOURCE_ROOTS" ] || [ -n "$SRC_DIR_MM" ]; then
    PUSH_CH_SCAN_ROOTS=("${PUSH_SCAN_ROOTS[@]}")
    if [ "${#PUSH_CH_SCAN_ROOTS[@]}" -gt 0 ]; then
        PUSH_LISTENER_HITS=$(count_noncomment_ere_hits '(^[[:space:]]*import[[:space:]]+com\.good\.gd\.push\.PushChannelListener|[[:space:]:,({]PushChannelListener[[:space:];,){])' "${PUSH_CH_SCAN_ROOTS[@]}")
        if [ "${PUSH_LISTENER_HITS:-0}" -gt 0 ]; then
            check_fail "Deprecated PushChannelListener usage detected ($PUSH_LISTENER_HITS) — replace with PushChannel.prepareIntentFilter() + GDAndroid.getInstance().registerReceiver(...) and PushChannel intent helper dispatch."
        else
            check_pass "No deprecated PushChannelListener usage detected"
        fi

        GD_LOCAL_BROADCAST_HITS=$(count_noncomment_ere_hits 'GDLocalBroadcastManager|com\.good\.gd\.GDLocalBroadcastManager' "${PUSH_CH_SCAN_ROOTS[@]}")
        if [ "${GD_LOCAL_BROADCAST_HITS:-0}" -gt 0 ]; then
            check_fail "GDLocalBroadcastManager usage detected ($GD_LOCAL_BROADCAST_HITS) — this is not the current Push Channel registration target. Use GDAndroid.getInstance().registerReceiver(...) with PushChannel.prepareIntentFilter()."
        else
            check_pass "No GDLocalBroadcastManager usage detected"
        fi

        # Advisory: PushChannel.connect() in Activity onCreate before auth patterns.
        PREAUTH_PUSH_CONNECT="$(python3 - "${PUSH_CH_SCAN_ROOTS[@]}" <<'PY' 2>/dev/null || true
import os, re, sys

roots = sys.argv[1:]
oncreate = re.compile(r"\b(?:protected\s+)?void\s+onCreate\s*\(|override\s+fun\s+onCreate\s*\(")
connect = re.compile(r"\bPushChannel\b.*\.connect\s*\(|\bnew\s+PushChannel\s*\(")
auth = re.compile(r"isContainerAuthorized|runOnAuthorized|onAuthorized")

hits = []
for root in roots:
    if not os.path.isdir(root):
        continue
    for dp, _, files in os.walk(root):
        for fn in files:
            if not fn.endswith((".java", ".kt")):
                continue
            path = os.path.join(dp, fn)
            try:
                text = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            if "PushChannel" not in text or not connect.search(text):
                continue
            if not oncreate.search(text):
                continue
            if auth.search(text):
                continue
            hits.append(os.path.relpath(path, root))
if hits:
    print(";".join(sorted(set(hits))))
PY
)"
        if [ -n "$PREAUTH_PUSH_CONNECT" ]; then
            check_warn "PushChannel.connect() may run from Activity before auth — connect from onAuthorized/runOnAuthorized (WI-02). Files: $PREAUTH_PUSH_CONNECT"
        fi
    fi
fi
