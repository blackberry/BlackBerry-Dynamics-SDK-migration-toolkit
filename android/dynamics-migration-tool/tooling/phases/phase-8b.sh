# BlackBerry Dynamics Migration — validator phase 8b
#
# Sourced by tooling/validate.sh once should_run_phase "8b" passes.
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
    # Phase 8b: ICC / Secure Sharing
    # ========================================
    echo "Phase 8b: ICC / Secure Sharing (Data Leakage Audit)"
    echo "-----------------------------------------"

# Check for generic Android sharing that leaks data outside Dynamics container
GENERIC_SEND=$(grep -rnE "ACTION_SEND([[:space:]]|$)|ACTION_SEND_MULTIPLE([[:space:]]|$)" "$SRC_DIR_MM/" 2>/dev/null \
    | strip_audit_noise \
    | grep -v "test/" \
    | grep -v "ACTION_SENDTO" \
    | count_hits_for_domain "icc")
GENERIC_CHOOSER=$(grep -rn "Intent\.createChooser\|ShareCompat" "$SRC_DIR_MM/" 2>/dev/null \
    | strip_audit_noise \
    | grep -v "test/" \
    | count_hits_for_domain "icc")
GENERIC_FILEPROVIDER=$(grep -rn "FileProvider\.getUriForFile" "$SRC_DIR_MM/" 2>/dev/null \
    | strip_audit_noise \
    | grep -v "test/" \
    | count_hits_for_domain "icc")

GENERIC_SHARE_TOTAL=$((GENERIC_SEND + GENERIC_CHOOSER + GENERIC_FILEPROVIDER))

if [ "$GENERIC_SHARE_TOTAL" -gt 0 ]; then
    fail_or_defer "icc" "Generic Android sharing still present ($GENERIC_SHARE_TOTAL occurrences) — unmanaged share/open/export paths are not valid Dynamics end states. Replace with ICC TransferFile using runtime provider discovery/chooser and remove unmanaged fallback routes. Re-run prompt 08."
    [ "$GENERIC_SEND" -gt 0 ] && echo "    - ACTION_SEND/ACTION_SEND_MULTIPLE: $GENERIC_SEND"
    [ "$GENERIC_CHOOSER" -gt 0 ] && echo "    - Intent.createChooser/ShareCompat: $GENERIC_CHOOSER"
    [ "$GENERIC_FILEPROVIDER" -gt 0 ] && echo "    - FileProvider.getUriForFile: $GENERIC_FILEPROVIDER"
else
    check_pass "No generic Android sharing found (no DLP leakage via ACTION_SEND/FileProvider)"
fi

# FileProvider manifest/resource hygiene after ICC migration.
# This scan uses multiline parsing so it catches provider/meta-data attributes
# even when AndroidManifest.xml splits them across several lines.
FILEPROVIDER_DECL=0
FILEPROVIDER_PATHS_META=0
FILEPROVIDER_AUTHORITIES_APPID=0
FILEPROVIDER_RESOURCE_REFS=0
FILEPROVIDER_RESOURCE_MISSING=0
FILEPROVIDER_PATH_FILES=0
FP_TAG_FILES_PATH=0
FP_TAG_CACHE_PATH=0
FP_TAG_EXTERNAL_PATH=0
FP_TAG_EXTERNAL_FILES_PATH=0
FP_TAG_EXTERNAL_CACHE_PATH=0
FP_TAG_ROOT_PATH=0
FILEPROVIDER_PATH_FILE_LIST=""

FILEPROVIDER_AUDIT=$(python3 - "$MM_IN_SCOPE_MANIFESTS" "$MM_IN_SCOPE_RES_DIRS" <<'PY'
import os
import re
import sys

manifest_paths = [p for p in (sys.argv[1] if len(sys.argv) > 1 else "").split() if p]
res_dirs = [p for p in (sys.argv[2] if len(sys.argv) > 2 else "").split() if p]

provider_decl = 0
paths_meta = 0
authorities_appid = 0
resource_refs = set()
resource_files = {}

tag_names = (
    "files-path",
    "cache-path",
    "external-path",
    "external-files-path",
    "external-cache-path",
    "root-path",
)
tag_counts = {k: 0 for k in tag_names}
path_files = set()

for manifest_path in manifest_paths:
    try:
        text = open(manifest_path, "r", encoding="utf-8", errors="ignore").read()
    except OSError:
        continue
    provider_blocks = re.findall(r"<provider\b.*?(?:/>|</provider>)", text, flags=re.I | re.S)
    for block in provider_blocks:
        if not re.search(r"androidx\.core\.content\.FileProvider|android\.support\.v4\.content\.FileProvider", block):
            continue
        provider_decl += 1
        auth_match = re.search(r'android:authorities\s*=\s*"([^"]+)"', block)
        if auth_match:
            authority = auth_match.group(1)
            if (
                "${applicationId}" in authority
                or ".provider" in authority
                or "fileprovider" in authority.lower()
            ):
                authorities_appid += 1
        for meta_match in re.finditer(r"<meta-data\b[^>]*>", block, flags=re.I | re.S):
            meta_tag = meta_match.group(0)
            if not re.search(r'android:name\s*=\s*"android\.support\.FILE_PROVIDER_PATHS"', meta_tag):
                continue
            paths_meta += 1
            resource_match = re.search(r'android:resource\s*=\s*"@xml/([^"]+)"', meta_tag)
            if resource_match:
                resource_refs.add(resource_match.group(1) + ".xml")

for res_dir in res_dirs:
    xml_dir = os.path.join(res_dir, "xml")
    if not os.path.isdir(xml_dir):
        continue
    try:
        names = sorted(os.listdir(xml_dir))
    except OSError:
        continue
    for name in names:
        if not name.endswith(".xml"):
            continue
        path = os.path.join(xml_dir, name)
        resource_files.setdefault(name, []).append(path)
        try:
            text = open(path, "r", encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        has_path_tag = False
        for tag in tag_names:
            hits = len(re.findall(r"<\s*" + re.escape(tag) + r"\b", text))
            if hits:
                tag_counts[tag] += hits
                has_path_tag = True
        if has_path_tag or re.search(r"(file_paths|provider_paths)", name):
            path_files.add(path)

resource_missing = 0
for ref in resource_refs:
    if ref not in resource_files:
        resource_missing += 1

print(f"DECL|{provider_decl}")
print(f"META|{paths_meta}")
print(f"AUTH_APPID|{authorities_appid}")
print(f"RESOURCE_REFS|{len(resource_refs)}")
print(f"RESOURCE_MISSING|{resource_missing}")
print(f"PATH_FILES|{len(path_files)}")
print(f"TAG_files-path|{tag_counts['files-path']}")
print(f"TAG_cache-path|{tag_counts['cache-path']}")
print(f"TAG_external-path|{tag_counts['external-path']}")
print(f"TAG_external-files-path|{tag_counts['external-files-path']}")
print(f"TAG_external-cache-path|{tag_counts['external-cache-path']}")
print(f"TAG_root-path|{tag_counts['root-path']}")
print("PATH_FILE_LIST|" + ";".join(sorted(path_files)))
PY
)
while IFS='|' read -r key value; do
    [ -z "$key" ] && continue
    case "$key" in
        DECL) FILEPROVIDER_DECL="${value:-0}" ;;
        META) FILEPROVIDER_PATHS_META="${value:-0}" ;;
        AUTH_APPID) FILEPROVIDER_AUTHORITIES_APPID="${value:-0}" ;;
        RESOURCE_REFS) FILEPROVIDER_RESOURCE_REFS="${value:-0}" ;;
        RESOURCE_MISSING) FILEPROVIDER_RESOURCE_MISSING="${value:-0}" ;;
        PATH_FILES) FILEPROVIDER_PATH_FILES="${value:-0}" ;;
        TAG_files-path) FP_TAG_FILES_PATH="${value:-0}" ;;
        TAG_cache-path) FP_TAG_CACHE_PATH="${value:-0}" ;;
        TAG_external-path) FP_TAG_EXTERNAL_PATH="${value:-0}" ;;
        TAG_external-files-path) FP_TAG_EXTERNAL_FILES_PATH="${value:-0}" ;;
        TAG_external-cache-path) FP_TAG_EXTERNAL_CACHE_PATH="${value:-0}" ;;
        TAG_root-path) FP_TAG_ROOT_PATH="${value:-0}" ;;
        PATH_FILE_LIST) FILEPROVIDER_PATH_FILE_LIST="${value:-}" ;;
    esac
done <<EOF
$FILEPROVIDER_AUDIT
EOF

if [ "$FILEPROVIDER_DECL" -gt 0 ]; then
    check_warn "FileProvider declaration(s) detected in manifest ($FILEPROVIDER_DECL) — run post-ICC cleanup audit"
    [ "$FILEPROVIDER_PATHS_META" -gt 0 ] \
        && check_warn "FileProvider meta-data android.support.FILE_PROVIDER_PATHS detected ($FILEPROVIDER_PATHS_META)" \
        || check_warn "FileProvider declaration found without FILE_PROVIDER_PATHS meta-data — verify provider is intentional"
    [ "$FILEPROVIDER_AUTHORITIES_APPID" -gt 0 ] \
        && check_warn "FileProvider authorities use applicationId/provider-style namespace ($FILEPROVIDER_AUTHORITIES_APPID) — verify this component is still required"
else
    check_pass "No FileProvider provider declaration found in primary manifests"
fi

if [ "$FILEPROVIDER_RESOURCE_REFS" -gt 0 ] && [ "$FILEPROVIDER_RESOURCE_MISSING" -gt 0 ]; then
    check_fail "FileProvider FILE_PROVIDER_PATHS meta-data references missing @xml resources ($FILEPROVIDER_RESOURCE_MISSING of $FILEPROVIDER_RESOURCE_REFS) — fix manifest/resource mismatch"
fi

if [ "$GENERIC_FILEPROVIDER" -eq 0 ] && [ "$FILEPROVIDER_DECL" -gt 0 ]; then
    fail_or_defer "icc" "Stale FileProvider manifest surface remains ($FILEPROVIDER_DECL declaration(s)) after FileProvider.getUriForFile removal — remove provider/meta-data + path resource or document justified non-sharing use in report blockingItems"
fi

if [ "$FILEPROVIDER_DECL" -eq 0 ] && [ "$GENERIC_FILEPROVIDER" -eq 0 ] && [ "$FILEPROVIDER_PATH_FILES" -gt 0 ]; then
    fail_or_defer "icc" "Stale FileProvider path resource(s) remain ($FILEPROVIDER_PATH_FILES file(s): ${FILEPROVIDER_PATH_FILE_LIST:-unknown}) after ICC migration — delete res/xml/file_paths.xml (or equivalent) when FileProvider is removed"
fi

FILESYSTEM_PATH_TAG_TOTAL=$((FP_TAG_FILES_PATH + FP_TAG_CACHE_PATH))
if [ "$FILESYSTEM_PATH_TAG_TOTAL" -gt 0 ] && [ "$GENERIC_FILEPROVIDER" -eq 0 ]; then
    check_warn "FileProvider paths still expose files/cache roots ($FILESYSTEM_PATH_TAG_TOTAL) — DLP review required (document exposed paths and non-sharing justification)"
fi

[ "$FP_TAG_EXTERNAL_PATH" -gt 0 ] && security_blocker "externalStorage" "fileprovider-external-path" "$FP_TAG_EXTERNAL_PATH" "FileProvider path resource exposes <external-path> entries. Hard fail for Dynamics migration unless the retained provider is explicitly proven not to carry app data and is justified in the report."
[ "$FP_TAG_EXTERNAL_FILES_PATH" -gt 0 ] && security_blocker "externalStorage" "fileprovider-external-files-path" "$FP_TAG_EXTERNAL_FILES_PATH" "FileProvider path resource exposes <external-files-path> entries. Hard fail for Dynamics migration unless the retained provider is explicitly proven not to carry app data and is justified in the report."
[ "$FP_TAG_EXTERNAL_CACHE_PATH" -gt 0 ] && security_blocker "externalStorage" "fileprovider-external-cache-path" "$FP_TAG_EXTERNAL_CACHE_PATH" "FileProvider path resource exposes <external-cache-path> entries. Hard fail for Dynamics migration unless the retained provider is explicitly proven not to carry app data and is justified in the report."
[ "$FP_TAG_ROOT_PATH" -gt 0 ] && security_blocker "externalStorage" "fileprovider-root-path" "$FP_TAG_ROOT_PATH" "FileProvider path resource exposes <root-path> entries. Hard fail for Dynamics migration unless the retained provider is explicitly proven not to carry app data and is justified in the report."

# -----------------------------------------------------------------------
# 8b-SAF: URI-sharing and content-URI egress detection
#
# Detects patterns where content URIs carrying Dynamics data are shared
# with external components via Intent extras, ClipData, or URI grants.
# These represent data transfer outside the secure container and default
# to BLOCKED_PENDING_DEVELOPER_APPROVAL per steering/44-saf-trust-boundary.md.
# -----------------------------------------------------------------------

SAF_URI_EGRESS_RESULTS=$(python3 - "$SRC_DIR_MM" <<'PY'
import os
import re
import sys

root = sys.argv[1]

flag_grant = re.compile(
    r'\bFLAG_GRANT_READ_URI_PERMISSION\b|'
    r'\bFLAG_GRANT_WRITE_URI_PERMISSION\b'
)
clipdata_uri = re.compile(r'\bClipData\s*\.\s*newUri\b')
extra_stream = re.compile(r'\bEXTRA_STREAM\b')
intent_setdata = re.compile(r'\bsetData\s*\(|\bsetDataAndType\s*\(|\bsetClipData\s*\(')
content_uri_literal = re.compile(r'"content://[^"]*"')

gd_import = re.compile(r'^\s*import\s+com\.good\.gd\.', re.MULTILINE)
icc_safe = re.compile(r'GDServiceClient|sendTo\s*\(|TransferFile|GDService')


def is_comment(line):
    s = line.lstrip()
    return (not s) or s.startswith("//") or s.startswith("*") or s.startswith("/*")


grant_count = 0
clipdata_count = 0
extra_stream_count = 0
intent_uri_count = 0
content_literal_count = 0
files_with_unsafe_grants = 0

for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        if not (name.endswith(".kt") or name.endswith(".java")):
            continue
        path = os.path.join(dirpath, name)
        if "/test/" in path or "/androidTest/" in path:
            continue
        try:
            text = open(path, "r", encoding="utf-8", errors="ignore").read()
        except Exception:
            continue
        if icc_safe.search(text):
            continue
        file_has_grant = False
        for lineno, line in enumerate(text.splitlines(), start=1):
            if is_comment(line):
                continue
            if flag_grant.search(line):
                grant_count += 1
                file_has_grant = True
            if clipdata_uri.search(line):
                clipdata_count += 1
            if extra_stream.search(line) and not icc_safe.search(line):
                extra_stream_count += 1
            if intent_setdata.search(line) and content_uri_literal.search(line):
                intent_uri_count += 1
            if content_uri_literal.search(line) and gd_import.search(text):
                content_literal_count += 1
        if file_has_grant:
            files_with_unsafe_grants += 1

total = grant_count + clipdata_count + intent_uri_count
print(f"grant|{grant_count}")
print(f"clipdata|{clipdata_count}")
print(f"extra_stream|{extra_stream_count}")
print(f"intent_uri|{intent_uri_count}")
print(f"content_literal|{content_literal_count}")
print(f"files_with_grants|{files_with_unsafe_grants}")
print(f"total|{total}")
PY
)

SAF_EGRESS_GRANT=0
SAF_EGRESS_CLIPDATA=0
SAF_EGRESS_EXTRA_STREAM=0
SAF_EGRESS_INTENT_URI=0
SAF_EGRESS_TOTAL=0
SAF_EGRESS_FILES=0

while IFS='|' read -r key value; do
    [ -z "$key" ] && continue
    case "$key" in
        grant) SAF_EGRESS_GRANT="${value:-0}" ;;
        clipdata) SAF_EGRESS_CLIPDATA="${value:-0}" ;;
        extra_stream) SAF_EGRESS_EXTRA_STREAM="${value:-0}" ;;
        intent_uri) SAF_EGRESS_INTENT_URI="${value:-0}" ;;
        files_with_grants) SAF_EGRESS_FILES="${value:-0}" ;;
        total) SAF_EGRESS_TOTAL="${value:-0}" ;;
    esac
done <<EOF
$SAF_URI_EGRESS_RESULTS
EOF

if [ "$SAF_EGRESS_TOTAL" -gt 0 ]; then
    fail_or_defer "icc" "Content URI egress patterns detected outside ICC ($SAF_EGRESS_TOTAL: uriGrants=$SAF_EGRESS_GRANT clipDataUri=$SAF_EGRESS_CLIPDATA intentSetData=$SAF_EGRESS_INTENT_URI in $SAF_EGRESS_FILES file(s)) — URI permission grants or content:// sharing with external components bypasses Dynamics DLP. Default outcome for share/open flows is ICC replacement with runtime provider discovery; otherwise strip/block unmanaged paths. See steering/44-saf-trust-boundary.md §1d."
else
    check_pass "No content URI egress patterns outside ICC detected (FLAG_GRANT_*_URI_PERMISSION / ClipData.newUri / setData with content://)"
fi

# Provider chooser bypass: direct providers.first()/index shortcuts near ICC share logic
ICC_PROVIDER_SHORTCUTS=$(grep -rnE "providers[[:space:]]*\\.[[:space:]]*first\\(|providers[[:space:]]*\\[[[:space:]]*0[[:space:]]*\\]|providers[[:space:]]*\\.[[:space:]]*get[[:space:]]*\\([[:space:]]*0[[:space:]]*\\)" "$SRC_DIR_MM/" 2>/dev/null \
    | strip_audit_noise \
    | grep -v "test/" \
    | count_hits_for_domain "icc")
[ "$ICC_PROVIDER_SHORTCUTS" -gt 0 ] \
    && fail_or_defer "icc" "ICC provider chooser bypass detected ($ICC_PROVIDER_SHORTCUTS) — replace providers.first/index shortcuts with a user chooser in prompt 08" \
    || check_pass "No ICC provider chooser bypass shortcuts detected"

# No-op ICC replacement detection. Catches the anti-pattern where an agent
# replaces an ACTION_VIEW / ACTION_SEND method body with a Toast-only stub
# while leaving active callers intact — a silent functional regression that
# compiles cleanly and passes all other checks. Scans methods that combine:
#   - @Suppress("UNUSED_PARAMETER")
#   - Toast.makeText(...) as the only visible action
#   - no GDServiceClient.sendTo / TransferFile / file I/O replacement
#   - a [BB_DYNAMICS-MIGRATION] comment mentioning "removed"
NOOP_ICC_REPLACEMENT_PY="$VALIDATE_TMPDIR/noop_icc_scan.py"
cat > "$NOOP_ICC_REPLACEMENT_PY" <<'PY'
import os
import re
import sys

root = sys.argv[1]
noop_files = []

suppress_unused = re.compile(r'@Suppress\s*\(\s*"UNUSED_PARAMETER"\s*\)')
toast_pattern = re.compile(r'Toast\s*\.\s*makeText\s*\(')
migration_removed = re.compile(r'\[BB_DYNAMICS-MIGRATION\].*\b(removed|no-op|noop|stub)\b', re.IGNORECASE)
icc_or_file_io = re.compile(
    r'GDServiceClient\s*\.\s*sendTo|'
    r'sendFiles\s*\(|'
    r'transferFile|TransferFile|'
    r'com\.good\.gd\.file\.|'
    r'GDFileSystem|'
    r'FileInputStream|FileOutputStream|'
    r'startActivity\s*\(|'
    r'startActivityForResult\s*\('
)
fun_sig = re.compile(
    r'(private|internal|public|protected)?\s*(fun|void|private\s+void|static\s+void)\s+'
    r'([A-Za-z_][A-Za-z0-9_]*)\s*\('
)

def scan_file(path, relpath):
    try:
        text = open(path, "r", encoding="utf-8", errors="ignore").read()
    except Exception:
        return
    if not suppress_unused.search(text):
        return
    if not toast_pattern.search(text):
        return
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if not suppress_unused.search(line):
            i += 1
            continue
        # Found @Suppress("UNUSED_PARAMETER") — look for the function below
        fn_start = None
        fn_name = ""
        for j in range(i, min(i + 5, len(lines))):
            m = fun_sig.search(lines[j])
            if m:
                fn_start = j
                fn_name = m.group(3)
                break
        if fn_start is None:
            i += 1
            continue
        # Extract the function body (heuristic: brace-balanced block)
        brace_depth = 0
        fn_body_lines = []
        started = False
        for k in range(fn_start, min(fn_start + 60, len(lines))):
            ln = lines[k]
            for ch in ln:
                if ch == '{':
                    brace_depth += 1
                    started = True
                elif ch == '}':
                    brace_depth -= 1
            fn_body_lines.append(ln)
            if started and brace_depth <= 0:
                break
        fn_body = "\n".join(fn_body_lines)
        has_toast = bool(toast_pattern.search(fn_body))
        has_icc = bool(icc_or_file_io.search(fn_body))
        has_migration_removed = bool(migration_removed.search(fn_body))
        if has_toast and not has_icc:
            noop_files.append(f"{relpath}:{fn_start + 1}:{fn_name}")
        i = fn_start + len(fn_body_lines)

for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        if not (name.endswith(".kt") or name.endswith(".java")):
            continue
        path = os.path.join(dirpath, name)
        relpath = os.path.relpath(path, os.path.dirname(root))
        scan_file(path, relpath)

print(len(noop_files))
for f in noop_files:
    print(f)
PY
NOOP_ICC_REPLACEMENTS=$(python3 "$NOOP_ICC_REPLACEMENT_PY" "$SRC_DIR_MM" 2>/dev/null | head -1)
NOOP_ICC_REPLACEMENTS="${NOOP_ICC_REPLACEMENTS:-0}"
if [ "$NOOP_ICC_REPLACEMENTS" -gt 0 ]; then
    NOOP_DETAILS=$(python3 "$NOOP_ICC_REPLACEMENT_PY" "$SRC_DIR_MM" 2>/dev/null | tail -n +2 | head -5)
    _set_violation_context "icc" "8b" \
        "Replace the no-op Toast stub with ICC TransferFile (GDServiceClient.sendTo) or an in-app secure viewer. If the feature is truly dead, remove the calling UI elements too." \
        "$(echo "$NOOP_DETAILS" | tr '\n' ',')"
    fail_or_defer "icc" "No-op ICC replacement detected ($NOOP_ICC_REPLACEMENTS method(s)) — @Suppress(\"UNUSED_PARAMETER\") + Toast-only stub with no ICC/file-I/O replacement. This is a silent functional regression: the method's callers still exist but the feature does nothing. Replace with ICC TransferFile or remove the calling UI elements (prompt 08 / steering 60 §7)."
    while IFS= read -r _noop_detail; do
        [ -n "$_noop_detail" ] && echo "    - $_noop_detail"
    done <<EOF
$NOOP_DETAILS
EOF
else
    check_pass "No no-op ICC replacement stubs detected (no @Suppress(\"UNUSED_PARAMETER\") + Toast-only methods)"
fi

# Check for AppKinetics ICC integration (TransferFile service)
ICC_WIRING_AUDIT=$(python3 - "$SRC_DIR_MM" <<'PY' 2>/dev/null
import os
import re
import sys

root = sys.argv[1]

send_to = re.compile(r'\bGDServiceClient\s*\.\s*sendTo\s*\(')
discovery = re.compile(r'\bgetServiceProvidersFor\s*\(')
client_reg = re.compile(r'\bGDServiceClient\s*\.\s*setServiceClientListener\s*\(')
service_reg = re.compile(r'\bGDService\s*\.\s*setServiceListener\s*\(')
client_listener = re.compile(r'\bGDServiceClientListener\b')
provider_markers = re.compile(
    r'\bGDServiceListener\b|'
    r'\bGDService\s*\.\s*replyTo\s*\(|'
    r'onReceiveMessage\s*\([^)]*\bservice\b[^)]*\bversion\b[^)]*\bmethod\b',
    re.S,
)
background_markers = re.compile(
    r'\bExecutor(Service)?\b|'
    r'\bExecutors\s*\.|'
    r'\.execute\s*\(|'
    r'\bDispatchers\s*\.\s*IO\b|'
    r'\bwithContext\s*\(\s*Dispatchers\s*\.\s*IO\b|'
    r'\bCoroutineScope\b|'
    r'\.launch\s*\(|'
    r'\bThread\s*\(|'
    r'\bHandlerThread\b|'
    r'\bWorkManager\b|'
    r'\bListenableWorker\b|'
    r'\bSchedulers\s*\.\s*io\b|'
    r'\bAsyncTask\b|'
    r'\bdoInBackground\b|'
    r'\bsuspend\s+fun\b'
)
ui_markers = re.compile(
    r'\b(onCreate|onActivityResult|onClick|setOnClickListener|onBindViewHolder)\b|'
    r'@Composable|'
    r'\bextends\s+(Activity|Fragment)\b|'
    r':\s*(AppCompatActivity|Activity|Fragment)\b'
)


def active_text(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    lines = []
    for line in text.splitlines():
        stripped = line.lstrip()
        if not stripped or stripped.startswith('//') or stripped.startswith('*'):
            continue
        if stripped.startswith('import '):
            continue
        lines.append(line)
    return '\n'.join(lines)


counts = {
    'sendTo': 0,
    'discovery': 0,
    'clientReg': 0,
    'serviceReg': 0,
    'clientListener': 0,
    'providerCode': 0,
    'backgroundEvidence': 0,
    'uiThreadRisk': 0,
}
ui_details = []

for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        if not (name.endswith('.kt') or name.endswith('.java')):
            continue
        path = os.path.join(dirpath, name)
        if '/test/' in path or '/androidTest/' in path:
            continue
        try:
            raw = open(path, 'r', encoding='utf-8', errors='ignore').read()
        except OSError:
            continue
        text = active_text(raw)
        if not text:
            continue

        file_send = len(send_to.findall(text))
        file_discovery = len(discovery.findall(text))
        file_client_reg = len(client_reg.findall(text))
        file_service_reg = len(service_reg.findall(text))
        file_client_listener = len(client_listener.findall(text))
        file_provider_code = 1 if provider_markers.search(text) else 0
        file_background = 1 if file_send and background_markers.search(text) else 0

        counts['sendTo'] += file_send
        counts['discovery'] += file_discovery
        counts['clientReg'] += file_client_reg
        counts['serviceReg'] += file_service_reg
        counts['clientListener'] += file_client_listener
        counts['providerCode'] += file_provider_code
        counts['backgroundEvidence'] += file_background

        if not file_send:
            continue
        lines = text.splitlines()
        file_ui_context = bool(ui_markers.search(text))
        for index, line in enumerate(lines):
            if not send_to.search(line):
                continue
            window = '\n'.join(lines[max(0, index - 20): index + 3])
            if background_markers.search(window):
                continue
            if file_ui_context or ui_markers.search(window):
                counts['uiThreadRisk'] += 1
                if len(ui_details) < 5:
                    rel = os.path.relpath(path, root)
                    ui_details.append(f'{rel}:{index + 1}')

for key, value in counts.items():
    print(f'{key}|{value}')
print('uiThreadRiskDetails|' + ','.join(ui_details))
PY
) || ICC_WIRING_AUDIT=""

ICC_SENDTO=0
ICC_DISCOVERY=0
ICC_CLIENT_LISTENER_REG=0
ICC_SERVICE_LISTENER_REG=0
ICC_CLIENT_LISTENER=0
ICC_PROVIDER_CODE=0
ICC_BACKGROUND_EVIDENCE=0
ICC_UI_THREAD_RISK=0
ICC_UI_THREAD_RISK_DETAILS=""

while IFS='|' read -r key value; do
    [ -z "$key" ] && continue
    case "$key" in
        sendTo) ICC_SENDTO="${value:-0}" ;;
        discovery) ICC_DISCOVERY="${value:-0}" ;;
        clientReg) ICC_CLIENT_LISTENER_REG="${value:-0}" ;;
        serviceReg) ICC_SERVICE_LISTENER_REG="${value:-0}" ;;
        clientListener) ICC_CLIENT_LISTENER="${value:-0}" ;;
        providerCode) ICC_PROVIDER_CODE="${value:-0}" ;;
        backgroundEvidence) ICC_BACKGROUND_EVIDENCE="${value:-0}" ;;
        uiThreadRisk) ICC_UI_THREAD_RISK="${value:-0}" ;;
        uiThreadRiskDetails) ICC_UI_THREAD_RISK_DETAILS="${value:-}" ;;
    esac
done <<EOF
$ICC_WIRING_AUDIT
EOF

ICC_LISTENER_REG=$((ICC_CLIENT_LISTENER_REG + ICC_SERVICE_LISTENER_REG))
ICC_LISTENER=$((ICC_CLIENT_LISTENER + ICC_PROVIDER_CODE))
ICC_TOTAL=$((ICC_SENDTO + ICC_DISCOVERY + ICC_LISTENER + ICC_LISTENER_REG))

# Distinguish file/content URI egress from benign web-link ACTION_VIEW usage.
BAD_ACTION_VIEW=$(grep -rnE "ACTION_VIEW" "$SRC_DIR_MM/" 2>/dev/null \
    | strip_audit_noise \
    | grep -E "content://|file://|FileProvider|setDataAndType|application/pdf|EXTRA_STREAM" \
    | wc -l | tr -d ' ')
[ "$BAD_ACTION_VIEW" -gt 0 ] && check_warn "ACTION_VIEW file/content-uri patterns detected ($BAD_ACTION_VIEW) — verify this is not unmanaged file egress" || check_pass "No obvious file/content-uri ACTION_VIEW egress patterns detected"

SECURE_MEDIA_NATIVE_VIEWER_EGRESS=$(python3 - "$SRC_DIR_MM" <<'PY'
import os
import re
import sys

root = sys.argv[1]
action_pat = re.compile(r'\b(ACTION_VIEW|MediaStore\.ACTION_REVIEW|CATEGORY_APP_GALLERY)\b')
secure_import = re.compile(r'^\s*import\s+com\.good\.gd\.file\.', re.MULTILINE)
secure_storage_api = re.compile(
    r'com\.good\.gd\.file\.|'
    r'GDFileSystem'
)
egress_terms = re.compile(
    r'content://|file://|'
    r'FileProvider\.getUriForFile|'
    r'ClipData\s*\.\s*newUri|'
    r'setData\s*\(|setDataAndType|setClipData\s*\(|'
    r'EXTRA_STREAM|'
    r'image/\*|video/\*|application/pdf'
)

def is_comment(line: str) -> bool:
    s = line.lstrip()
    return (not s) or s.startswith("//") or s.startswith("*") or s.startswith("/*")

count = 0
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        if not (name.endswith(".kt") or name.endswith(".java")):
            continue
        path = os.path.join(dirpath, name)
        try:
            text = open(path, "r", encoding="utf-8", errors="ignore").read()
        except Exception:
            continue
        if not action_pat.search(text):
            continue
        secure_file = bool(secure_import.search(text)) or bool(secure_storage_api.search(text))
        if not secure_file:
            continue
        has_native_viewer = False
        for line in text.splitlines():
            if is_comment(line):
                continue
            if action_pat.search(line):
                has_native_viewer = True
                break
        if not has_native_viewer:
            continue
        for line in text.splitlines():
            if is_comment(line):
                continue
            if egress_terms.search(line):
                count += 1
print(count)
PY
)
[ "$SECURE_MEDIA_NATIVE_VIEWER_EGRESS" -gt 0 ] \
    && fail_or_defer "icc" "Native gallery/viewer invocation for secure-container-owned media detected ($SECURE_MEDIA_NATIVE_VIEWER_EGRESS) — block ACTION_VIEW / ACTION_REVIEW / CATEGORY_APP_GALLERY for secure media, replace with an in-app secure viewer/gallery or Dynamics ICC. End-user confirmation is not a waiver for unmanaged egress." \
    || check_pass "No native gallery/viewer invocation detected for secure-container-owned media"

# Heuristic warning: sendTo wiring present, but attachment path origin appears rooted
# in Android filesystem APIs without obvious GD container or staging indicators.
ICC_PATH_ORIGIN_WARN=$(python3 - "$SRC_DIR_MM" <<'PY'
import os
import re
import sys

root = sys.argv[1]
suspect = 0
for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        if not (name.endswith(".kt") or name.endswith(".java")):
            continue
        path = os.path.join(dirpath, name)
        try:
            text = open(path, "r", encoding="utf-8", errors="ignore").read()
        except Exception:
            continue
        if "GDServiceClient.sendTo" not in text and "sendTo(" not in text and "sendFiles(" not in text:
            continue
        has_android_origin = bool(re.search(r"cacheDir|getCacheDir|getFilesDir|java\.io\.File\(|\.absolutePath", text))
        has_gd_origin = bool(re.search(r"com\.good\.gd\.file|GDFileSystem|gdPaths|containerPaths", text))
        has_staging = bool(
            re.search(r"stageFilesInGDContainer|ICC_STAGING_DIR", text)
            or (
                re.search(r"java\.io\.FileInputStream", text)
                and re.search(r"com\.good\.gd\.file\.FileOutputStream", text)
                and re.search(r"sendTo\(|sendFiles\(", text)
            )
        )
        if has_staging:
            suspect += 1
        elif has_android_origin and not has_gd_origin:
            suspect += 1
print(suspect)
PY
)
[ "$ICC_PATH_ORIGIN_WARN" -gt 0 ] \
    && fail_or_defer "icc" "ICC sandbox staging or path-origin risk in $ICC_PATH_ORIGIN_WARN file(s) — attachments must use in-container paths only; complete secureFileStorage before ICC (steering/60-icc-transferfileservice.md)" \
    || check_pass "No ICC sandbox-staging or path-origin risk patterns detected"

if [ "$ICC_TOTAL" -gt 0 ]; then
    check_pass "AppKinetics ICC TransferFile integration found ($ICC_TOTAL references)"
    [ "$ICC_SENDTO" -gt 0 ] && check_pass "GDServiceClient.sendTo() used for file transfer" || check_warn "GDServiceClient.sendTo() not found (may not send files)"

    if [ "$ICC_SENDTO" -gt 0 ]; then
        [ "$ICC_DISCOVERY" -gt 0 ] \
            && check_pass "getServiceProvidersFor() used for runtime service discovery" \
            || fail_or_defer "icc" "GDServiceClient.sendTo() is present but getServiceProvidersFor() is missing — prompt 08 must use runtime Dynamics provider discovery before sending"

        [ "$ICC_CLIENT_LISTENER_REG" -gt 0 ] \
            && check_pass "GDServiceClient.setServiceClientListener() registered for sender responses" \
            || fail_or_defer "icc" "GDServiceClient.sendTo() is present but GDServiceClient.setServiceClientListener() is missing — register a client listener for responses, errors, and progress callbacks"

        [ "$ICC_BACKGROUND_EVIDENCE" -gt 0 ] \
            && check_pass "Background-dispatch evidence found for GDServiceClient.sendTo()" \
            || fail_or_defer "icc" "GDServiceClient.sendTo() found without background-dispatch evidence — dispatch transfers through an Executor, coroutine Dispatchers.IO path, worker thread, or equivalent non-UI execution path"

        if [ "$ICC_UI_THREAD_RISK" -gt 0 ]; then
            _set_violation_context "icc" "8b" \
                "Move GDServiceClient.sendTo() behind an Executor/coroutine/worker thread and marshal only UI feedback back to the main thread." \
                "$ICC_UI_THREAD_RISK_DETAILS"
            check_warn "Potential UI-thread GDServiceClient.sendTo() call(s) detected ($ICC_UI_THREAD_RISK) — add explicit background dispatch. Examples: ${ICC_UI_THREAD_RISK_DETAILS:-unknown}"
        else
            check_pass "No obvious UI-thread GDServiceClient.sendTo() call sites detected"
        fi
    else
        [ "$ICC_DISCOVERY" -gt 0 ] && check_warn "getServiceProvidersFor() found without GDServiceClient.sendTo() — verify prompt 08 migration is complete"
        [ "$ICC_CLIENT_LISTENER_REG" -gt 0 ] && check_warn "GDServiceClient.setServiceClientListener() found without GDServiceClient.sendTo() — verify sender flow is complete"
    fi

    if [ "$ICC_PROVIDER_CODE" -gt 0 ]; then
        [ "$ICC_SERVICE_LISTENER_REG" -gt 0 ] \
            && check_pass "GDService.setServiceListener() registered for provider/receiver code" \
            || fail_or_defer "icc" "ICC provider/receiver code is present but GDService.setServiceListener() is missing — register the service listener or remove the unused provider code"
    else
        [ "$ICC_SERVICE_LISTENER_REG" -gt 0 ] \
            && check_warn "GDService.setServiceListener() registered but no provider/receiver code was detected — verify this is intentional" \
            || check_pass "No ICC provider/receiver code detected (GDService.setServiceListener not required)"
    fi
else
    if [ "$GENERIC_SHARE_TOTAL" -gt 0 ]; then
        check_fail "No AppKinetics ICC integration found but generic sharing exists — must migrate to ICC"
    else
        check_pass "No AppKinetics ICC integration found (not applicable: no share/export flows)"
    fi
fi

COMPOSE_ICC_SCAN="$SCRIPT_DIR/lib/compose-icc-chooser-scan.py"
COMPOSE_ICC_VIEW_CHOOSER=0
if [ -f "$COMPOSE_ICC_SCAN" ]; then
    ICC_SCAN_ROOTS=()
    if [ -n "$MM_IN_SCOPE_SOURCE_ROOTS" ]; then
        while IFS= read -r _iroot; do
            [ -n "$_iroot" ] && ICC_SCAN_ROOTS+=("$_iroot")
        done <<EOF
$MM_IN_SCOPE_SOURCE_ROOTS
EOF
    fi
    if [ "${#ICC_SCAN_ROOTS[@]}" -eq 0 ] && [ -n "$SRC_DIR_MM" ]; then
        ICC_SCAN_ROOTS=("$SRC_DIR_MM")
    fi
    if [ "${#ICC_SCAN_ROOTS[@]}" -eq 0 ]; then
        check_warn "No in-scope source roots — Compose ICC chooser scan skipped"
    else
        COMPOSE_ICC_RESULT="$(python3 "$COMPOSE_ICC_SCAN" "${ICC_SCAN_ROOTS[@]}" 2>/dev/null || echo OK)"
        case "${COMPOSE_ICC_RESULT%%|*}" in
            UNMANAGED)
                COMPOSE_ICC_VIEW_CHOOSER="${COMPOSE_ICC_RESULT#*|}"
                COMPOSE_ICC_VIEW_CHOOSER="${COMPOSE_ICC_VIEW_CHOOSER%%|*}"
                [ -z "$COMPOSE_ICC_VIEW_CHOOSER" ] && COMPOSE_ICC_VIEW_CHOOSER=1
                check_fail "Unmanaged Compose ICC chooser pattern(s) remain ($COMPOSE_ICC_VIEW_CHOOSER) — use GDICCProviderShareDialog (templates/icc/GDICCProviderShareDialog.kt) instead of MaterialAlertDialogBuilder/showShareChooser in @Composable screens — re-run prompt 08"
                ;;
            OK)
                check_pass "No unmanaged Compose ICC View-system chooser patterns detected"
                ;;
            *)
                check_warn "Compose ICC chooser scan returned unexpected result: $COMPOSE_ICC_RESULT"
                ;;
        esac
    fi
else
    check_warn "compose-icc-chooser-scan.py missing — Compose ICC chooser check skipped"
fi
echo ""
