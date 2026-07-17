# BlackBerry Dynamics Migration — validator phase 6
#
# Sourced by tooling/validate.sh once should_run_phase "6" passes.
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
    # Phase 6: Networking
    # ========================================
    echo "Phase 6: Networking"
    echo "-----------------------------------------"

GD_HTTP=$(count_noncomment_ere_hits "GDHttpClient" "$SRC_DIR_MM/")
GD_SOCK=$(count_noncomment_ere_hits "GDSocket" "$SRC_DIR_MM/")
STD_HTTP=$(count_noncomment_ere_hits "HttpURLConnection|openConnection[[:space:]]*\\(" "$SRC_DIR_MM/")
STD_SOCK=$(count_noncomment_ere_hits "java\\.net\\.Socket|new[[:space:]]+Socket[[:space:]]*\\(" "$SRC_DIR_MM/")
BAD_HTTP_IMPORTS=$(count_noncomment_ere_hits "import[[:space:]]+org\\.apache\\.http" "$SRC_DIR_MM/")
BAD_GDSOCKET_IMPORTS=$(count_noncomment_ere_hits "import[[:space:]]+com\\.good\\.gd\\.net\\.ssl\\.GDSocket" "$SRC_DIR_MM/")
BAD_SOCKET_DISCONNECT=$(count_noncomment_ere_hits "socket[[:space:]]*\\.[[:space:]]*disconnect[[:space:]]*\\(" "$SRC_DIR_MM/")

if [ "$GD_HTTP" -gt 0 ]; then
    check_pass "GDHttpClient used ($GD_HTTP)"
elif [ "$STD_HTTP" -eq 0 ]; then
    check_pass "Networking not applicable for URL transports — no HttpURLConnection/openConnection surfaces found"
else
    check_warn "GDHttpClient not found while standard URL transport surfaces still exist"
fi
if [ "$STD_HTTP" -gt 0 ]; then
    fail_or_defer "secureNetworking" "Standard URL networking still present ($STD_HTTP) — HttpURLConnection/URL.openConnection must migrate to Dynamics networking (re-run prompt 06)"
else
    check_pass "Standard URL networking removed (HttpURLConnection/openConnection)"
fi
if [ "$GD_SOCK" -gt 0 ]; then
    check_pass "GDSocket used ($GD_SOCK)"
elif [ "$STD_SOCK" -eq 0 ]; then
    check_pass "Networking not applicable for socket transports — no java.net.Socket surfaces found"
else
    check_warn "GDSocket not found while standard socket surfaces still exist"
fi
if [ "$STD_SOCK" -gt 0 ]; then
    fail_or_defer "secureNetworking" "java.net.Socket still present ($STD_SOCK) — re-run prompt 06 (networking migration)"
else
    check_pass "java.net.Socket removed"
fi
[ "$BAD_HTTP_IMPORTS" -gt 0 ] && check_fail "Wrong Apache import path detected ($BAD_HTTP_IMPORTS) — use com.good.gd.apache.http.*, not org.apache.http.*"
[ "$BAD_GDSOCKET_IMPORTS" -gt 0 ] && check_fail "Wrong GDSocket import path detected ($BAD_GDSOCKET_IMPORTS) — use com.good.gd.net.GDSocket"
[ "$BAD_SOCKET_DISCONNECT" -gt 0 ] && check_fail "socket.disconnect() detected ($BAD_SOCKET_DISCONNECT) — use socket.close()"

# OkHttp / Retrofit detection. OkHttp clients without BBCustomInterceptor
# (or BBCookieJar) bypass Dynamics container policy entirely — TLS pinning,
# proxy enforcement, certificate trust store, and DLP all skipped. This is
# the gap Secure Camera's first migration pass missed.
OKHTTP_FILE_COUNT=$(count_files_with_noncomment_ere_match "okhttp3\\." "$SRC_DIR_MM/")
RETROFIT_FILE_COUNT=$(count_files_with_noncomment_ere_match "retrofit2\\." "$SRC_DIR_MM/")
INTERCEPTOR_COUNT=$(count_files_with_noncomment_ere_match "BBCustomInterceptor|BBCookieJar" "$SRC_DIR_MM/")

if [ "$OKHTTP_FILE_COUNT" -gt 0 ]; then
    if [ "$INTERCEPTOR_COUNT" -gt 0 ]; then
        check_pass "OkHttp present with Dynamics interceptor wired ($OKHTTP_FILE_COUNT OkHttp file(s); $INTERCEPTOR_COUNT interceptor file(s))"
    else
        fail_or_defer "secureNetworking" "OkHttp (okhttp3.*) used in $OKHTTP_FILE_COUNT file(s) WITHOUT BBCustomInterceptor or BBCookieJar — traffic bypasses Dynamics container policy (no TLS pinning, no proxy, no DLP). Re-run prompt 06 with the OkHttp interceptor pattern from steering/30-secure-networking.md."
    fi
else
    check_pass "No OkHttp (okhttp3.*) usage detected"
fi

if [ "$RETROFIT_FILE_COUNT" -gt 0 ]; then
    if [ "$INTERCEPTOR_COUNT" -gt 0 ]; then
        check_pass "Retrofit present and uses interceptor-wired OkHttp underneath ($RETROFIT_FILE_COUNT Retrofit file(s))"
    else
        fail_or_defer "secureNetworking" "Retrofit (retrofit2.*) used in $RETROFIT_FILE_COUNT file(s) but no Dynamics interceptor on the underlying OkHttp client — traffic bypasses container policy. See steering/30-secure-networking.md (Retrofit / OkHttp pattern)."
    fi
else
    check_pass "No Retrofit (retrofit2.*) usage detected"
fi

# HR-0-3: unsupported / unproven networking surfaces.
# Source-level stacks below are unsupported unless explicitly proven to route
# through supported Dynamics paths (GDHttpClient, GDSocket, or interceptor-wired
# OkHttp/Retrofit). Presence without proof is a blocking networking finding.
KTOR_HITS=$(count_noncomment_ere_hits "io\\.ktor\\.|HttpClient[[:space:]]*\\([[:space:]]*[A-Za-z0-9_.]*CIO|CIOEngineConfig" "$SRC_DIR_MM/")
CRONET_HITS=$(count_noncomment_ere_hits "org\\.chromium\\.net\\.|CronetEngine|CronetProvider|UrlRequest\\.Builder" "$SRC_DIR_MM/")
GRPC_HITS=$(count_noncomment_ere_hits "io\\.grpc\\.|ManagedChannelBuilder|OkHttpChannelBuilder|AndroidChannelBuilder|Grpc\\.newChannelBuilder" "$SRC_DIR_MM/")
DOWNLOAD_MANAGER_HITS=$(count_noncomment_ere_hits "android\\.app\\.DownloadManager|DownloadManager\\.(Request|Query)|DOWNLOAD_SERVICE" "$SRC_DIR_MM/")
WEBSOCKET_LIB_HITS=$(count_noncomment_ere_hits "org\\.java_websocket|nv\\.websocket\\.client|okhttp3\\.WebSocket|newWebSocket[[:space:]]*\\(|WebSocketClient[[:space:]]*\\(" "$SRC_DIR_MM/")
DATAGRAM_SSL_SOCKET_HITS=$(count_noncomment_ere_hits "java\\.net\\.DatagramSocket|new[[:space:]]+DatagramSocket[[:space:]]*\\(|javax\\.net\\.ssl\\.SSLSocket|new[[:space:]]+SSLSocket[[:space:]]*\\(" "$SRC_DIR_MM/")

UNSUPPORTED_NET_BLOCKERS=$((KTOR_HITS + CRONET_HITS + GRPC_HITS + DOWNLOAD_MANAGER_HITS + WEBSOCKET_LIB_HITS + DATAGRAM_SSL_SOCKET_HITS))

# Dependency-level signals catch dependency-owned/generated client stacks that
# may not leave obvious call sites in app-controlled source.
UNSUPPORTED_NET_DEP_HINTS=$(count_noncomment_ere_hits "io\\.ktor:|org\\.chromium\\.net:cronet|io\\.grpc:|org\\.java-websocket:|com\\.neovisionaries:nv-websocket-client|com\\.squareup\\.okhttp3:okhttp-ws" "$MM_GRADLE_FILES" "$PROJECT_DIR/build.gradle" "$PROJECT_DIR/build.gradle.kts" "$PROJECT_DIR/settings.gradle" "$PROJECT_DIR/settings.gradle.kts" "$PROJECT_DIR/gradle/libs.versions.toml" "$PROJECT_DIR/libs.versions.toml")

if [ "$UNSUPPORTED_NET_BLOCKERS" -gt 0 ] || [ "$UNSUPPORTED_NET_DEP_HINTS" -gt 0 ]; then
    _CURRENT_DOMAIN="secureNetworking"
    _CURRENT_FIX="Manual intervention required: replace unsupported transports with GDHttpClient, GDSocket, or interceptor-wired OkHttp/Retrofit; otherwise keep recommendation no-go with manualTodos[].blocking=true."
    check_fail "Unsupported/unproven networking surfaces detected (ktor=$KTOR_HITS, cronet=$CRONET_HITS, grpc=$GRPC_HITS, downloadManager=$DOWNLOAD_MANAGER_HITS, websocketLib=$WEBSOCKET_LIB_HITS, datagramOrSslSocket=$DATAGRAM_SSL_SOCKET_HITS, dependencyHints=$UNSUPPORTED_NET_DEP_HINTS). Manual intervention required before secureNetworking can be closed."
else
    check_pass "No unsupported/unproven networking stacks detected (Ktor/Cronet/gRPC/DownloadManager/WebSocket libs/DatagramSocket/SSLSocket/dependency-owned hints)"
fi

TRANSPORT_TRUST_BYPASS_HITS=$(count_noncomment_ere_hits "disableHostVerification[[:space:]]*\\(|disablePeerVerification[[:space:]]*\\(|trustAllCerts|ALLOW_ALL_HOSTNAME_VERIFIER|DO_NOT_VERIFY" "$SRC_DIR_MM/")
if [ "$TRANSPORT_TRUST_BYPASS_HITS" -gt 0 ]; then
    check_fail "Explicit TLS/trust bypass APIs detected ($TRANSPORT_TRUST_BYPASS_HITS) — remove disableHostVerification/disablePeerVerification and trust-all patterns"
else
    check_pass "No explicit TLS/trust bypass API usage detected"
fi

TRANSPORT_CUSTOM_TLS_PRIMITIVE_HITS=$(count_noncomment_ere_hits "X509TrustManager|HostnameVerifier|setHostnameVerifier[[:space:]]*\\(|sslSocketFactory[[:space:]]*\\(|SSLSocketFactory|CertificatePinner|checkServerTrusted" "$SRC_DIR_MM/")
if [ "$TRANSPORT_CUSTOM_TLS_PRIMITIVE_HITS" -gt 0 ]; then
    check_warn "Custom TLS primitives detected ($TRANSPORT_CUSTOM_TLS_PRIMITIVE_HITS) — verify these are not bypasses and are compatible with Dynamics-managed transport"
else
    check_pass "No custom TLS primitive patterns detected"
fi

OKHTTP_ORDER_ISSUES=$(python3 - "$SRC_DIR_MM" <<'INNERPY'
import os,re,sys
src=sys.argv[1]
issue=0

def strip_comments_and_strings(text):
    out = []
    i = 0
    n = len(text)
    state = "code"
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state == "code":
            if ch == "/" and nxt == "/":
                state = "line_comment"
                i += 2
                continue
            if ch == "/" and nxt == "*":
                state = "block_comment"
                i += 2
                continue
            if ch == '"' and text[i:i+3] == '"""':
                state = "triple_double"
                i += 3
                out.append("   ")
                continue
            if ch == "'":
                state = "single_quote"
                out.append(" ")
                i += 1
                continue
            if ch == '"':
                state = "double_quote"
                out.append(" ")
                i += 1
                continue
            out.append(ch)
            i += 1
            continue
        if state == "line_comment":
            if ch == "\n":
                out.append("\n")
                state = "code"
            i += 1
            continue
        if state == "block_comment":
            if ch == "*" and nxt == "/":
                state = "code"
                i += 2
            else:
                i += 1
            continue
        if state == "single_quote":
            if ch == "\\":
                i += 2
                continue
            if ch == "'":
                state = "code"
            i += 1
            continue
        if state == "double_quote":
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                state = "code"
            i += 1
            continue
        if state == "triple_double":
            if text[i:i+3] == '"""':
                state = "code"
                i += 3
            else:
                i += 1
            continue
    return "".join(out)

for dp,_,fs in os.walk(src):
    for fn in fs:
        if not fn.endswith((".java",".kt")):
            continue
        p=os.path.join(dp,fn)
        t=open(p,encoding="utf-8",errors="ignore").read()
        t = strip_comments_and_strings(t)
        if "OkHttpClient" not in t or "BBCustomInterceptor" not in t:
            continue
        for m in re.finditer(r"OkHttpClient(?:\.Builder|\(\)\.newBuilder\(\)|\.Builder\(\))(?:.|\n){0,1200}?\.build\(\)", t):
            blk=m.group(0)
            adds = re.findall(r"addInterceptor\s*\(([^)]*)\)", blk)
            if not adds:
                continue
            bb_indices = [i for i,a in enumerate(adds) if ("BBCustomInterceptor" in a or "bbCustomInterceptor" in a)]
            if not bb_indices:
                continue
            if max(bb_indices) != len(adds) - 1:
                issue += 1
print(issue)
INNERPY
)
if [ "${OKHTTP_ORDER_ISSUES:-0}" -gt 0 ]; then
    check_fail "OkHttp BBCustomInterceptor ordering appears incorrect in $OKHTTP_ORDER_ISSUES builder block(s) — BB interceptor must be last"
else
    check_pass "No obvious OkHttp interceptor-ordering defects detected"
fi

OKHTTP_BB_NETWORK_INTERCEPTOR=$(count_noncomment_ere_hits "addNetworkInterceptor[[:space:]]*\\(([^)]*BBCustomInterceptor|[^)]*bbCustomInterceptor)" "$SRC_DIR_MM/")
if [ "${OKHTTP_BB_NETWORK_INTERCEPTOR:-0}" -gt 0 ]; then
    check_fail "BBCustomInterceptor used as network interceptor ($OKHTTP_BB_NETWORK_INTERCEPTOR) — use addInterceptor(...) only"
else
    check_pass "No BBCustomInterceptor network-interceptor misuse detected"
fi

OKHTTP_PROXY_OVERRIDE_WITH_BB=$(python3 - "$SRC_DIR_MM" <<'INNERPY'
import os,re,sys
src=sys.argv[1]
hits=0

def strip_comments_and_strings(text):
    out = []
    i = 0
    n = len(text)
    state = "code"
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state == "code":
            if ch == "/" and nxt == "/":
                state = "line_comment"
                i += 2
                continue
            if ch == "/" and nxt == "*":
                state = "block_comment"
                i += 2
                continue
            if ch == '"' and text[i:i+3] == '"""':
                state = "triple_double"
                i += 3
                out.append("   ")
                continue
            if ch == "'":
                state = "single_quote"
                out.append(" ")
                i += 1
                continue
            if ch == '"':
                state = "double_quote"
                out.append(" ")
                i += 1
                continue
            out.append(ch)
            i += 1
            continue
        if state == "line_comment":
            if ch == "\n":
                out.append("\n")
                state = "code"
            i += 1
            continue
        if state == "block_comment":
            if ch == "*" and nxt == "/":
                state = "code"
                i += 2
            else:
                i += 1
            continue
        if state == "single_quote":
            if ch == "\\":
                i += 2
                continue
            if ch == "'":
                state = "code"
            i += 1
            continue
        if state == "double_quote":
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                state = "code"
            i += 1
            continue
        if state == "triple_double":
            if text[i:i+3] == '"""':
                state = "code"
                i += 3
            else:
                i += 1
            continue
    return "".join(out)

for dp,_,fs in os.walk(src):
    for fn in fs:
        if not fn.endswith((".java",".kt")):
            continue
        p=os.path.join(dp,fn)
        t=open(p,encoding="utf-8",errors="ignore").read()
        t = strip_comments_and_strings(t)
        if "OkHttpClient" not in t or "BBCustomInterceptor" not in t:
            continue
        for m in re.finditer(r"OkHttpClient(?:\.Builder|\(\)\.newBuilder\(\)|\.Builder\(\))(?:.|\n){0,1200}?\.build\(\)", t):
            blk = m.group(0)
            if ".proxy(" in blk:
                hits += 1
print(hits)
INNERPY
)
if [ "${OKHTTP_PROXY_OVERRIDE_WITH_BB:-0}" -gt 0 ]; then
    check_warn "OkHttp .proxy(...) used in BBCustomInterceptor-wired builder block(s) ($OKHTTP_PROXY_OVERRIDE_WITH_BB) — unsupported with Dynamics transport; prefer UEM proxy policy"
else
    check_pass "No OkHttp .proxy(...) override found in BBCustomInterceptor-wired builders"
fi

# Native (NDK / C / C++) BSD socket detection. Direct-replacement
# coverage in app-controlled native source. Routed through
# `fail_or_defer "secureNetworking"` so the deferral semantics already
# applied to Java/Kotlin secureNetworking call sites also apply here.
NATIVE_SOCK_HITS=0
NATIVE_SOCK_HIT_MODULES=""
# Iterate every in-scope module (primary + libraryModulesInScope[]).
# shellcheck disable=SC2086
for MP in $MM_IN_SCOPE_MODULE_PATHS; do
    [ -z "$MP" ] && continue
    MP_SRC="$MP/src"
    [ -d "$MP_SRC" ] || continue
    MP_SOCK_HITS=$(python3 "$NATIVE_SCAN_PY" "$MP_SRC" sock 2>/dev/null || echo 0)
    MP_SOCK_HITS=${MP_SOCK_HITS:-0}
    if [ "$MP_SOCK_HITS" -gt 0 ]; then
        NATIVE_SOCK_HITS=$((NATIVE_SOCK_HITS + MP_SOCK_HITS))
        NATIVE_SOCK_HIT_MODULES="$NATIVE_SOCK_HIT_MODULES $MP:$MP_SOCK_HITS"
    fi
done

if [ "${NATIVE_SOCK_HITS:-0}" -gt 0 ]; then
    NATIVE_SOCK_DETAIL="$(echo "$NATIVE_SOCK_HIT_MODULES" | sed -e 's/^ //' -e 's/ /, /g')"
    fail_or_defer "secureNetworking" "Native (C/C++) BSD socket / name-resolution calls detected in app-controlled native source ($NATIVE_SOCK_HITS hit(s) across in-scope modules: ${NATIVE_SOCK_DETAIL}) — these bypass the Dynamics transport. Replace with GD_socket/GD_connect/GD_send/GD_recv/GD_getaddrinfo (and similar) per steering/14-api-provenance-and-replacement-catalog.md and steering/46-native-ndk-direct-replacement.md, or defer secureNetworking in bootstrap.json deferredDomains[]."
elif [ "${NATIVE_SOURCE_PRESENT:-0}" -eq 1 ] && [ "${NATIVE_BUILD_SIGNALS:-0}" -gt 0 ]; then
    check_pass "No standard C/POSIX BSD socket calls detected in app-controlled native source (in-scope modules)"
fi

if [ "${NATIVE_SO_HITS:-0}" -gt 0 ] && [ "${NATIVE_SOCK_HITS:-0}" -eq 0 ]; then
    check_warn "Prebuilt native .so libraries present ($NATIVE_SO_HITS file(s) across in-scope modules) — if any of them open sockets, secureNetworking cannot be auto-closed. Add a manualTodo per steering/46-native-ndk-direct-replacement.md."
fi

echo ""
