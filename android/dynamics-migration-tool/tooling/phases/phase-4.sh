# BlackBerry Dynamics Migration — validator phase 4
#
# Sourced by tooling/validate.sh once should_run_phase "4" passes.
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
    # Phase 4: File Storage
    # ========================================
    echo "Phase 4: File Storage"
    echo "-----------------------------------------"

GD_FILE_CALLSITE_SCAN_PY="$SCRIPT_DIR/lib/gd-file-callsite-scan.py"
GD_LISTFILES_GUARD_SCAN_PY="$SCRIPT_DIR/lib/gd-listfiles-guard-scan.py"
GD_FS_IMPORTS=$(grep -rnE "import[[:space:]]+com\.good\.gd\.file\.(GDFileSystem|FileInputStream|FileOutputStream)" "$SRC_DIR_MM/" 2>/dev/null \
    | wc -l | tr -d ' ')
GD_FS_CALL_HITS=$(python3 "$GD_FILE_CALLSITE_SCAN_PY" --source-root "$SRC_DIR_MM" --mode real 2>/dev/null | strip_audit_noise || true)
GD_FS_CALLS=$(printf '%s\n' "$GD_FS_CALL_HITS" | count_hits_for_domain "secureFileStorage")
GD_FS_HALLUCINATION_HITS=$(python3 "$GD_FILE_CALLSITE_SCAN_PY" --source-root "$SRC_DIR_MM" --mode hallucination 2>/dev/null | strip_audit_noise || true)
GD_FS_HALLUCINATION_COUNT=$(printf '%s\n' "$GD_FS_HALLUCINATION_HITS" | count_hits_for_domain "secureFileStorage")
STD_FS=$(grep -rnE "context\.openFile|Context\.openFile|getContext\(\)\.openFile" "$SRC_DIR_MM/" 2>/dev/null \
    | strip_audit_noise \
    | count_hits_for_domain "secureFileStorage")
# java.io streams vs com.good.gd.file streams: optional (java.io.)? matched
# unqualified "FileInputStream" when com.good.gd.file.* was imported.
# Emit grep-compatible path:line:text lines and count each hit. The
# toolkit has no line-level suppression mechanism, so every hit counts.
STD_FILE_STREAMS="$(python3 - "$SRC_DIR_MM" <<'PY' | count_hits_for_domain "secureFileStorage"
import os
import re
import sys

src_root = sys.argv[1]
java_io_ctor = re.compile(r"(?:new\s+)?java\.io\.File(Input|Output)Stream\s*\(")
gd_ctor = re.compile(r"(?:new\s+)?com\.good\.gd\.file\.File(Input|Output)Stream\s*\(")
short_ctor = re.compile(r"(?<![\w.])(?:new\s+)?File(Input|Output)Stream\s*\(")
import_java_io_star = re.compile(r"^\s*import\s+java\.io\.\*\s*;?", re.MULTILINE)
import_java_fis = re.compile(r"^\s*import\s+java\.io\.FileInputStream\s*;?", re.MULTILINE)
import_java_fos = re.compile(r"^\s*import\s+java\.io\.FileOutputStream\s*;?", re.MULTILINE)
import_gd_fis = re.compile(r"^\s*import\s+com\.good\.gd\.file\.FileInputStream\s*;?", re.MULTILINE)
import_gd_fos = re.compile(r"^\s*import\s+com\.good\.gd\.file\.FileOutputStream\s*;?", re.MULTILINE)


def comment_only_line(line: str) -> bool:
    s = line.lstrip()
    if not s:
        return True
    if s.startswith("//"):
        return True
    if s.startswith("*") or s.startswith("/*"):
        return True
    return False


def line_counts_as_java_io_stream_violation(line: str, whole_file: str) -> bool:
    if comment_only_line(line):
        return False
    if gd_ctor.search(line):
        return False
    if java_io_ctor.search(line):
        return True
    m = short_ctor.search(line)
    if not m:
        return False
    kind = m.group(1)
    j_star = bool(import_java_io_star.search(whole_file))
    j_fis = bool(import_java_fis.search(whole_file))
    j_fos = bool(import_java_fos.search(whole_file))
    g_fis = bool(import_gd_fis.search(whole_file))
    g_fos = bool(import_gd_fos.search(whole_file))
    if kind == "Input":
        if g_fis and not j_fis and not j_star:
            return False
        return True
    if kind == "Output":
        if g_fos and not j_fos and not j_star:
            return False
        return True
    return False


def main() -> None:
    cwd = os.getcwd()
    for dirpath, _, files in os.walk(src_root):
        for fn in files:
            if not fn.endswith((".java", ".kt")):
                continue
            path = os.path.normpath(os.path.join(dirpath, fn))
            try:
                rel = os.path.relpath(path, cwd)
            except ValueError:
                rel = path
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
            except OSError:
                continue
            for lineno, line in enumerate(text.splitlines(), start=1):
                if not line_counts_as_java_io_stream_violation(line, text):
                    continue
                print(f"{rel}:{lineno}:{line}")


if __name__ == "__main__":
    main()
PY
)"

# Direct java.io.File construction (excludes legitimate cache dir usage and
# comment-only lines).
# Cache paths (getCacheDir / externalCacheDir) are allowed because Android
# guarantees they live inside the app sandbox already; the Dynamics container
# does not re-secure them but they're not the migration target.
#
# Import-aware: unqualified `new File(...)` is only flagged when the file
# imports java.io.File (or java.io.*). If the file imports
# com.good.gd.file.File and does NOT also import java.io.File, every
# unqualified `new File(...)` resolves to the GD-backed type and is NOT a
# violation. Fully-qualified `new java.io.File(...)` is always flagged.
DIRECT_FILE_COUNT="$(python3 - "$SRC_DIR_MM" <<'PY' | count_hits_for_domain "secureFileStorage"
import os
import re
import sys

src_root = sys.argv[1]

# Fully-qualified java.io.File construction — always a violation.
java_io_ctor   = re.compile(r"(?:new\s+)?java\.io\.File\s*\(")
# Unqualified File(...) — violation only when java.io.File is in scope.
short_ctor     = re.compile(r"(?<![\w.])(?:new\s+)?File\s*\(")

import_gd_file      = re.compile(r"^\s*import\s+com\.good\.gd\.file\.File\s*;?",  re.MULTILINE)
import_java_io_file = re.compile(r"^\s*import\s+java\.io\.File\s*;?",              re.MULTILINE)
import_java_io_star = re.compile(r"^\s*import\s+java\.io\.\*\s*;?",               re.MULTILINE)
cache_path     = re.compile(r"getCacheDir|getExternalCacheDir|externalCacheDir|cacheDir")


def comment_only(line: str) -> bool:
    s = line.lstrip()
    return (not s) or s.startswith("//") or s.startswith("*") or s.startswith("/*")


cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith((".java", ".kt")):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue

        has_gd_file  = bool(import_gd_file.search(text))
        has_java_io  = bool(import_java_io_file.search(text)) or bool(import_java_io_star.search(text))

        for lineno, line in enumerate(text.splitlines(), start=1):
            if comment_only(line):
                continue
            if cache_path.search(line):
                continue
            # Fully-qualified java.io.File: always a violation regardless of imports.
            if java_io_ctor.search(line):
                print(f"{rel}:{lineno}:{line}")
                continue
            # Unqualified File(): only a violation when java.io.File is imported.
            # If the file imports com.good.gd.file.File exclusively, the call site
            # resolves to the Dynamics-backed type — skip it.
            if short_ctor.search(line):
                if has_gd_file and not has_java_io:
                    continue
                print(f"{rel}:{lineno}:{line}")
PY
)"

# File.createTempFile is never safe in a Dynamics-migrated app — it writes
# plaintext to the app data directory outside the secure container and was
# the gap that Secure Camera's first migration pass missed entirely.
# This check is intentionally non-waivable.
TEMP_FILE_COUNT=$(grep -rnE "File\.createTempFile[[:space:]]*\(" "$SRC_DIR_MM/" 2>/dev/null \
    | grep -vE ":[[:space:]]*[/*]" \
    | wc -l | tr -d ' ')

# GD stream constructors MUST use container-relative paths. Passing Android
# absolute paths (/data/..., filesDir/cacheDir-derived paths, or
# File#getAbsolutePath()) causes runtime FileNotFoundException in the GD layer.
# This check is intentionally non-waivable.
GD_ABS_PATH_STREAM_HITS=$(python3 "$GD_FILE_CALLSITE_SCAN_PY" --source-root "$SRC_DIR_MM" --mode abs-paths 2>/dev/null | strip_audit_noise || true)
GD_ABS_PATH_STREAMS=$(printf '%s\n' "$GD_ABS_PATH_STREAM_HITS" | count_hits_for_domain "secureFileStorage")

# Detect Glide/Picasso/Coil style native File/path loading patterns that
# bypass secure-container readers for container-backed files. This check is
# waivable only through the owning secureFileStorage domain deferral.
GLIDE_NATIVE_PATH_LOADS="$(python3 - "$SRC_DIR_MM" <<'PY' | count_hits_for_domain "secureFileStorage"
import os
import re
import sys

src_root = sys.argv[1]
load_pattern = re.compile(r"Glide\.with\([^)]*\)(?:.|\n){0,400}?\.load\((.*?)\)", re.MULTILINE)
bad_load_arg = re.compile(r"new\s+File\s*\(|getCacheDir\s*\(|getFilesDir\s*\(|getExternalCacheDir\s*\(|externalCacheDir|/data/user/|getAbsolutePath\s*\(")

cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith((".java", ".kt")):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            text = open(path, "r", encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for m in load_pattern.finditer(text):
            arg = m.group(1)
            if not bad_load_arg.search(arg):
                continue
            line_no = text.count("\n", 0, m.start()) + 1
            line = text.splitlines()[line_no - 1] if line_no - 1 < len(text.splitlines()) else "Glide.load(...)"
            print(f"{rel}:{line_no}:{line}")
PY
)"
[ "$GD_FS_IMPORTS" -gt 0 ] && check_pass "Dynamics secure file APIs imported ($GD_FS_IMPORTS)" || check_warn "Dynamics secure file APIs not found (GDFileSystem / com.good.gd.file.* — may not apply)"
[ "$GD_FS_CALLS" -gt 0 ] && check_pass "Dynamics secure file APIs invoked at call-sites ($GD_FS_CALLS)" || check_warn "No Dynamics secure file API call-sites found (imports alone are scaffolding)"
if [ "${GD_FS_HALLUCINATION_COUNT:-0}" -gt 0 ]; then
    _set_violation_context "secureFileStorage" "4" \
        "Replace hallucinated GDFileSystem static helpers with com.good.gd.file.File instance methods for mkdirs/exists/delete/list, and keep GDFileSystem only for openFileInput/openFileOutput/openRandomAccessFile." \
        "$GD_FS_HALLUCINATION_HITS"
    check_fail "Hallucinated GDFileSystem static helper usage detected ($GD_FS_HALLUCINATION_COUNT location(s)) — GDFileSystem.mkdirs/exists/delete/renameTo/list/listFiles/listDir are not public Dynamics APIs and do not count as a migration. Use com.good.gd.file.File instance methods instead (see steering/40-secure-file-storage.md §4)."
else
    check_pass "No hallucinated GDFileSystem static helper usage detected"
fi
if [ "$GD_FS_IMPORTS" -gt 0 ] && [ "$GD_FS_CALLS" -eq 0 ]; then
    fail_or_defer "secureFileStorage" "Dynamics file imports exist but no GDFileSystem/com.good.gd.file call-sites were found — scaffolding-only migration detected. Replace native file operations with real GDFileSystem/FileInputStream/FileOutputStream calls."
fi
if [ "$STD_FS" -gt 0 ]; then
    _CURRENT_PHASE="4"
    fail_or_defer "secureFileStorage" "Standard file I/O still present ($STD_FS) — re-run prompts 05a/05b/05c (filesystem migration split)" \
        "Replace context.openFileInput/openFileOutput with GDFileSystem.openFileInput/openFileOutput (catalog rows fs-java-001/002)"
else
    check_pass "Standard file I/O removed"
fi
if [ "$STD_FILE_STREAMS" -gt 0 ]; then
    _CURRENT_PHASE="4"
    fail_or_defer "secureFileStorage" "java.io.FileInputStream/FileOutputStream constructor usage still present ($STD_FILE_STREAMS) — these bypass the Dynamics secure container" \
        "Replace new java.io.FileInputStream(path) with new com.good.gd.file.FileInputStream(path) and new java.io.FileOutputStream(path) with new com.good.gd.file.FileOutputStream(path) (catalog rows fs-java-003/004)"
else
    check_pass "java.io.FileInputStream/FileOutputStream constructor usage removed"
fi
if [ "$DIRECT_FILE_COUNT" -gt 0 ]; then
    _CURRENT_PHASE="4"
    fail_or_defer "secureFileStorage" "Direct java.io.File construction in $DIRECT_FILE_COUNT location(s) outside cache paths — bypasses the Dynamics secure container. Re-run prompts 05a/05b/05c to complete the migration, or have the developer defer the entire 'secureFileStorage' domain in bootstrap.json deferredDomains[]." \
        "Replace new java.io.File(path) with new com.good.gd.file.File(path) and update import to com.good.gd.file.File (catalog row fs-java-005)"
else
    check_pass "No direct java.io.File construction in non-cache paths"
fi
# ---------------------------------------------------------------
# External storage surface — SECURITY-CRITICAL, non-waivable.
#
# Writes (and most reads) of application data to external/shared
# storage bypass the Dynamics secure container entirely. The data
# is unencrypted, included in device backups, visible to any app
# with READ_EXTERNAL_STORAGE / MANAGE_EXTERNAL_STORAGE, accessible
# over USB / file manager, and NOT wiped when the Dynamics
# container is remotely wiped. This breaks the core Dynamics
# data-at-rest contract.
#
# Therefore this check uses `security_blocker` (always hard-fail)
# and is routed through the `externalStorage` domain, which is
# registered as non-waivable in validate.sh and rejected from
# `deferredDomains[]` by Phase 0. It is intentionally **not**
# downgraded when `secureFileStorage` is deferred — a developer
# may legitimately defer secureFileStorage if their app stores no
# sensitive data, but the moment external-storage APIs appear at
# call-sites the migration is incomplete and requires manual
# intervention before production use.
#
# The migration agent must:
#   1. Migrate the call-site to com.good.gd.file.* (container
#      paths) where the data is application-owned; OR
#   2. Remove the external-storage path entirely (e.g. delete
#      "Save to SD card" / "Export to public Downloads" features
#      that are not part of an explicit, user-initiated, audited
#      export boundary); OR
#   3. If the feature may remain, block it first and carry the
#      decision in the plan/report until the developer explicitly
#      approves an allowed Dynamics-controlled workflow. Do not
#      silently preserve outbound export just because the pre-
#      migration app had one.
#
# Deferral is NEVER acceptable for these findings.
# ---------------------------------------------------------------

# NOTE: All four sub-scans below pipe through `strip_pure_comments`
# (not `strip_audit_noise`). The `[BB_DYNAMICS-MIGRATION]` marker is
# audit-only and must NOT be able to silence a security blocker.
# Annotating an external-storage line with the marker was the exact
# workaround that allowed MediaStore / public-storage writes to ship
# under a "deferred / export boundary" label in 0.3.0 — that
# suppression path is now closed for the externalStorage domain.

# (a) High-level Android external-storage APIs — both writes and
# reads count because reads of application data from public storage
# imply that data was, or will be, written outside the container.
EXTERNAL_STORAGE_HIGHLEVEL_HITS=$(grep -rnE \
    "Environment\.getExternalStorage(Directory|PublicDirectory|State)|getExternalFilesDir|getExternalFilesDirs|getExternalCacheDir|getExternalMediaDirs|\bexternalMediaDirs\b|Environment\.DIRECTORY_(DOWNLOADS|PICTURES|DOCUMENTS|MOVIES|MUSIC|DCIM|PODCASTS|RINGTONES|ALARMS|NOTIFICATIONS|AUDIOBOOKS)" \
    "$SRC_DIR_MM/" 2>/dev/null | strip_pure_comments | count_hits_for_domain "externalStorage")

# (b) MediaStore writes / inserts into shared collections. Reads of
# MediaStore (e.g. picking a user-selected image to ingest into the
# container) are not flagged here; writes/updates/deletes against
# shared collections are.
EXTERNAL_STORAGE_MEDIASTORE_WRITES=$(grep -rnE \
    "MediaStore\.(Images|Video|Audio|Downloads|Files|Documents)\.(EXTERNAL_CONTENT_URI|Media\.EXTERNAL_CONTENT_URI)|getContentResolver\s*\(\s*\)\s*\.(insert|update|delete)\s*\([^)]*MediaStore|MediaStore\.createWriteRequest|MediaStore\.createDeleteRequest|MediaStore\.createTrashRequest|MediaScannerConnection" \
    "$SRC_DIR_MM/" 2>/dev/null | strip_pure_comments | count_hits_for_domain "externalStorage")

# (b2) ContentResolver.openOutputStream against public media/output URIs.
# This catches the common "insert into MediaStore, then stream bytes to the
# returned public Uri" pattern and caller-provided capture output Uri writes.
EXTERNAL_STORAGE_PUBLIC_OUTPUT_STREAMS="$(python3 - "$SRC_DIR_MM" <<'PY' | count_hits_for_domain "externalStorage"
import os
import re
import sys

src_root = sys.argv[1]
open_output = re.compile(r'openOutputStream\s*\(')
public_uri = re.compile(
    r'MediaStore\.(Images|Video|Audio|Downloads|Files|Documents)\.(EXTERNAL_CONTENT_URI|Media\.EXTERNAL_CONTENT_URI)|'
    r'ACTION_CREATE_DOCUMENT|ACTION_OPEN_DOCUMENT_TREE|DocumentFile\.fromTreeUri|'
    r'MediaStore\.EXTRA_OUTPUT|EXTRA_OUTPUT|content://media/'
)

def comment_only(line: str) -> bool:
    s = line.lstrip()
    return (not s) or s.startswith("//") or s.startswith("*") or s.startswith("/*")

cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith((".java", ".kt")):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            text = open(path, "r", encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if "openOutputStream" not in text:
            continue
        lines = text.splitlines()
        for lineno, line in enumerate(lines, start=1):
            if comment_only(line) or not open_output.search(line):
                continue
            start = max(0, lineno - 6)
            end = min(len(lines), lineno + 5)
            window = "\n".join(lines[start:end])
            if public_uri.search(window):
                print(f"{rel}:{lineno}:{line.rstrip()}")
PY
)"

# (c) Raw file paths targeting external / shared / removable storage.
# These slip past API-level detection because they construct a
# java.io.File or pass a string path directly to an InputStream
# constructor, native code, or a third-party library.
EXTERNAL_STORAGE_RAW_PATHS=$(grep -rnE \
    "[\"']/(sdcard|storage/emulated|storage/self|mnt/sdcard|mnt/media_rw|external_sd)|[\"']/storage/[A-Za-z0-9_-]+/(Download|Downloads|Pictures|Documents|DCIM|Movies|Music)" \
    "$SRC_DIR_MM/" 2>/dev/null | strip_pure_comments | count_hits_for_domain "externalStorage")

# (c2) Download-to-public-storage flows. These often survive as
# "save file" or "download attachment" code even after the main file
# store migrates, but they still write protected bytes outside the
# Dynamics container.
EXTERNAL_STORAGE_DOWNLOAD_MANAGER=$(grep -rnE \
    "DownloadManager|setDestinationInExternalPublicDir|setDestinationUri|Request\s*\([^)]*\)\s*\.\s*setDestination" \
    "$SRC_DIR_MM/" 2>/dev/null | strip_pure_comments | count_hits_for_domain "externalStorage")

# (d) Storage Access Framework document-tree usage — picking a user
# directory and then writing application data into it leaves the
# secure container in the same way a public Downloads write does.
EXTERNAL_STORAGE_SAF_TREE=$(grep -rnE \
    "ACTION_OPEN_DOCUMENT_TREE|DocumentFile\.fromTreeUri|DocumentsContract\.buildChildDocumentsUriUsingTree|DocumentsContract\.createDocument|takePersistableUriPermission" \
    "$SRC_DIR_MM/" 2>/dev/null | strip_pure_comments | count_hits_for_domain "externalStorage")

# (d2) One-shot SAF document pickers — user can import/export vault or backup
# bytes outside the Dynamics container via ContentResolver streams.
# Tree URIs are covered by (d); this catches ACTION_OPEN_DOCUMENT and
# ACTION_CREATE_DOCUMENT without _TREE suffix (catalog fs-java-ext-003/005).
EXTERNAL_STORAGE_SAF_ONESHOT="$(python3 - "$SRC_DIR_MM" <<'PY' | count_hits_for_domain "externalStorage"
import os
import re
import sys

src_root = sys.argv[1]
patterns = (
    re.compile(r"\bACTION_CREATE_DOCUMENT\b"),
    re.compile(r"\bACTION_OPEN_DOCUMENT\b(?!_TREE)"),
    re.compile(r"\bIntent\.ACTION_CREATE_DOCUMENT\b"),
    re.compile(r"\bIntent\.ACTION_OPEN_DOCUMENT\b(?!_TREE)"),
)

def comment_only(line: str) -> bool:
    s = line.lstrip()
    return (not s) or s.startswith("//") or s.startswith("*") or s.startswith("/*")

cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith((".java", ".kt")):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if comment_only(line):
                continue
            for pat in patterns:
                if pat.search(line):
                    print(f"{rel}:{lineno}:{line.rstrip()}")
                    break
PY
)"

# (e) Permissions that imply an unmigrated external-storage
# expectation. These do not by themselves write data, but in
# combination with the above signal that the developer still expects
# external storage to be available. Recorded as a warning so the
# migration report can surface a manifest cleanup item even when
# call-sites are clean.
EXTERNAL_STORAGE_MANIFEST_PERMS=$(grep -rnE \
    "android\.permission\.(WRITE_EXTERNAL_STORAGE|MANAGE_EXTERNAL_STORAGE|ACCESS_MEDIA_LOCATION)" \
    "$SRC_DIR_MM/../" 2>/dev/null | strip_audit_noise | count_hits_for_domain "externalStorage")

EXTERNAL_STORAGE_API_SURFACE=$(( \
    EXTERNAL_STORAGE_HIGHLEVEL_HITS \
    + EXTERNAL_STORAGE_MEDIASTORE_WRITES \
    + EXTERNAL_STORAGE_PUBLIC_OUTPUT_STREAMS \
    + EXTERNAL_STORAGE_RAW_PATHS \
    + EXTERNAL_STORAGE_DOWNLOAD_MANAGER \
    + EXTERNAL_STORAGE_SAF_TREE \
    + EXTERNAL_STORAGE_SAF_ONESHOT ))

if [ "$EXTERNAL_STORAGE_API_SURFACE" -gt 0 ]; then
    security_blocker "externalStorage" "api-surface" "$EXTERNAL_STORAGE_API_SURFACE" \
        "External storage / MediaStore / shared-storage API surface detected ($EXTERNAL_STORAGE_API_SURFACE hit(s): \
highLevelApis=$EXTERNAL_STORAGE_HIGHLEVEL_HITS mediaStoreWrites=$EXTERNAL_STORAGE_MEDIASTORE_WRITES publicOutputStreams=$EXTERNAL_STORAGE_PUBLIC_OUTPUT_STREAMS rawPaths=$EXTERNAL_STORAGE_RAW_PATHS downloadManager=$EXTERNAL_STORAGE_DOWNLOAD_MANAGER safDocTree=$EXTERNAL_STORAGE_SAF_TREE safOneShot=$EXTERNAL_STORAGE_SAF_ONESHOT). \
Application data written to these locations leaves the Dynamics secure container: it is unencrypted at rest, included in device backups, accessible to any app with READ_EXTERNAL_STORAGE / MANAGE_EXTERNAL_STORAGE, visible over USB, and is NOT remotely wipeable. \
This violates the BlackBerry Dynamics secure-container contract and is a SECURITY BLOCKER for production. \
Deferral is NOT permitted (the externalStorage domain is non-waivable). \
Required action: keep protected bytes inside com.good.gd.file.* container paths, remove the external/public-storage feature, or block the capability until the developer explicitly approves a documented Dynamics-controlled workflow. \
Do NOT treat MediaStore / DownloadManager / generic public save as a successful migration target. \
Any user-visible export/download capability that remains blocked or needs redesign must be recorded in egressFeatureDecisions[] and manualTodos[] before production use."
else
    check_pass "No external storage / MediaStore / shared-storage API surface detected"
fi
if [ "$EXTERNAL_STORAGE_MANIFEST_PERMS" -gt 0 ]; then
    check_warn "AndroidManifest still declares external-storage permissions ($EXTERNAL_STORAGE_MANIFEST_PERMS) — once all external-storage call-sites are removed, drop WRITE_EXTERNAL_STORAGE / MANAGE_EXTERNAL_STORAGE / ACCESS_MEDIA_LOCATION from the manifest to reduce the attack surface and pass UEM hardening review"
fi

BACKUP_EGRESS_SURFACE_HITS=$(grep -rnE \
    "BackupAgent|BackupAgentHelper|BackupManager|onBackup\s*\(|onRestore\s*\(|android:fullBackupContent|android:dataExtractionRules|backup_rules\.xml" \
    "$SRC_DIR_MM/../" 2>/dev/null | strip_audit_noise | count_hits_for_domain "secureFileStorage")
if [ "${BACKUP_EGRESS_SURFACE_HITS:-0}" -gt 0 ]; then
    check_warn "Backup/restore surface still present ($BACKUP_EGRESS_SURFACE_HITS) — remove Android backup rules/agents and unmanaged backup/export UI when protected data can leave the Dynamics container; record the feature outcome in egressFeatureDecisions[] and the report"
else
    check_pass "No Android backup/restore egress surface detected"
fi

CAPTURE_INTENT_OUTPUT_FLOW=$(grep -rnE \
    "ACTION_IMAGE_CAPTURE|ACTION_VIDEO_CAPTURE|IMAGE_CAPTURE_SECURE|MediaStore\.EXTRA_OUTPUT|EXTRA_OUTPUT|getParcelableExtra\s*\([^)]*EXTRA_OUTPUT|putExtra\s*\([^)]*EXTRA_OUTPUT" \
    "$SRC_DIR_MM/" 2>/dev/null | strip_pure_comments | count_hits_for_domain "externalStorage")

CAPTURE_INTENT_MANIFEST_SURFACE=$(python3 - "$MM_IN_SCOPE_MANIFESTS" <<'PY'
import re
import sys

manifest_paths = [p for p in (sys.argv[1] if len(sys.argv) > 1 else "").split() if p]
count = 0
action_pat = re.compile(r"android:name\s*=\s*\"(?:android\.media\.action\.)?(IMAGE_CAPTURE_SECURE|IMAGE_CAPTURE|VIDEO_CAPTURE)\"")
exported_false = re.compile(r"android:exported\s*=\s*\"false\"")

for manifest_path in manifest_paths:
    try:
        text = open(manifest_path, "r", encoding="utf-8", errors="ignore").read()
    except OSError:
        continue
    for tag_name in ("activity", "activity-alias"):
        blocks = re.findall(r"<" + tag_name + r"\b.*?(?:/>|</" + tag_name + r">)", text, flags=re.I | re.S)
        for block in blocks:
            if not action_pat.search(block):
                continue
            if exported_false.search(block):
                continue
            count += 1
print(count)
PY
)

CAPTURE_OUTPUT_SURFACE=$((CAPTURE_INTENT_OUTPUT_FLOW + CAPTURE_INTENT_MANIFEST_SURFACE))
if [ "$CAPTURE_OUTPUT_SURFACE" -gt 0 ]; then
    security_blocker "externalStorage" "capture-output-uri-surface" "$CAPTURE_OUTPUT_SURFACE" \
        "Android capture intent or caller-supplied output-URI surface remains ($CAPTURE_OUTPUT_SURFACE hit(s): code=$CAPTURE_INTENT_OUTPUT_FLOW manifest=$CAPTURE_INTENT_MANIFEST_SURFACE). \
General-purpose ACTION_IMAGE_CAPTURE / ACTION_VIDEO_CAPTURE / IMAGE_CAPTURE_SECURE or MediaStore.EXTRA_OUTPUT flows can route app-owned media to unmanaged callers or public output Uris outside the Dynamics container. \
Required action: disable or narrow exported capture intent behavior, reject caller supplied output Uris, and keep capture in managed in-app flows backed by Dynamics secure storage. \
If the product must remain a general-purpose camera provider for unmanaged callers, mark the feature manual intervention and the migration no-go before production use."
else
    check_pass "No exported capture intent or caller-supplied output-URI surface detected"
fi

PRIVATE_SANDBOX_STAGING_HITS="$(python3 - "$SRC_DIR_MM" <<'PY' | count_hits_for_domain "secureFileStorage"
import os
import re
import sys

src_root = sys.argv[1]
path_terms = re.compile(r'getCacheDir|getFilesDir|\bcacheDir\b|\bfilesDir\b')
writer_terms = re.compile(
    r'FileOutputStream|openFileOutput|openOutputStream|Bitmap\.compress|MediaRecorder|'
    r'ImageCapture\.OutputFileOptions\.Builder|java\.io\.File\s*\('
)

def comment_only(line: str) -> bool:
    s = line.lstrip()
    return (not s) or s.startswith("//") or s.startswith("*") or s.startswith("/*")

cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith((".java", ".kt")):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            text = open(path, "r", encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        lines = text.splitlines()
        for lineno, line in enumerate(lines, start=1):
            if comment_only(line):
                continue
            if not path_terms.search(line):
                continue
            start = max(0, lineno - 4)
            end = min(len(lines), lineno + 4)
            window_lines = [l for l in lines[start:end] if not comment_only(l)]
            window = "\n".join(window_lines)
            if writer_terms.search(window):
                print(f"{rel}:{lineno}:{line.rstrip()}")
PY
)"
if [ "${PRIVATE_SANDBOX_STAGING_HITS:-0}" -gt 0 ]; then
    fail_or_defer "secureFileStorage" "Android filesDir/cacheDir staging remains ($PRIVATE_SANDBOX_STAGING_HITS) — writes rooted in the normal Android filesystem remain outside the Dynamics container. Persist through container-relative GD paths instead of filesDir/cacheDir staging."
else
    check_pass "No filesDir/cacheDir write staging patterns detected"
fi

# -----------------------------------------------------------------------
# 4N. SAF Directional Classification Scanner
#
# Extends the flat externalStorage blocker (above) with directional
# classification required by steering/44-saf-trust-boundary.md.
# Detects:
#   - ActivityResultContracts (OpenDocument, CreateDocument, GetContent,
#     OpenDocumentTree, OpenMultipleDocuments, GetMultipleContents)
#   - ACTION_GET_CONTENT / ACTION_PICK as inbound import vectors
#   - URI permission grants (FLAG_GRANT_READ/WRITE_URI_PERMISSION)
#   - ClipData.newUri for content URI sharing
#   - Persisted content:// URIs in databases/prefs
#
# Each finding is classified: SAF_INBOUND_IMPORT, SAF_OUTBOUND_EXPORT,
# SAF_EXTERNAL_PRIMARY_STORAGE, SAF_URI_SHARING, SAF_PLAINTEXT_STAGING
#
# Inbound findings emit warnings (require secure-copy migration).
# Outbound findings route through security_blocker with surface
# "saf-outbound-export" or "saf-uri-sharing".
# -----------------------------------------------------------------------

echo ""
echo "Phase 4N: SAF Directional Classification"
echo "-----------------------------------------"

SAF_PLAN_STATE_FILE="dynamics-migration-tool/output/migration-plan-state.json"
if [ -f "output/migration-plan-state.json" ]; then
    SAF_PLAN_STATE_FILE="output/migration-plan-state.json"
fi

SAF_DIRECTIONAL_RESULTS=$(python3 - "$SRC_DIR_MM" "$SAF_PLAN_STATE_FILE" <<'PY'
import json
import os
import re
import sys

src_root = sys.argv[1]
plan_state_path = sys.argv[2] if len(sys.argv) > 2 else ""


def approved_outbound_decision_count(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            plan_state = json.load(f)
    except Exception:
        return 0
    count = 0
    for disp in plan_state.get("dispositions") or []:
        if not isinstance(disp, dict):
            continue
        if disp.get("domain") != "secureFileStorage":
            continue
        if disp.get("status") != "migrated":
            continue
        decision = disp.get("safDecision")
        if not isinstance(decision, dict):
            continue
        if decision.get("classification") != "SAF_OUTBOUND_EXPORT":
            continue
        if decision.get("migrationDecision") != "ALLOW_WITH_DLP_ENFORCEMENT":
            continue
        if decision.get("developerDecision") != "ALLOW_WITH_DLP_ENFORCEMENT":
            continue
        if decision.get("runtimeDlpEnforced") is not True:
            continue
        if not decision.get("developerApprovalRequested"):
            continue
        count += 1
    return count


approved_outbound_decisions = approved_outbound_decision_count(plan_state_path)
approved_outbound_remaining = approved_outbound_decisions

# Classification patterns
outbound_intents = re.compile(
    r'\bACTION_CREATE_DOCUMENT\b|'
    r'\bActivityResultContracts\s*\.\s*CreateDocument\b'
)
inbound_intents = re.compile(
    r'\bACTION_OPEN_DOCUMENT\b(?!_TREE)|'
    r'\bACTION_GET_CONTENT\b|'
    r'\bACTION_PICK\b|'
    r'\bActivityResultContracts\s*\.\s*OpenDocument\b|'
    r'\bActivityResultContracts\s*\.\s*OpenMultipleDocuments\b|'
    r'\bActivityResultContracts\s*\.\s*GetContent\b|'
    r'\bActivityResultContracts\s*\.\s*GetMultipleContents\b'
)
tree_intents = re.compile(
    r'\bACTION_OPEN_DOCUMENT_TREE\b|'
    r'\bActivityResultContracts\s*\.\s*OpenDocumentTree\b'
)
uri_grant_flags = re.compile(
    r'\bFLAG_GRANT_READ_URI_PERMISSION\b|'
    r'\bFLAG_GRANT_WRITE_URI_PERMISSION\b'
)
# A FLAG_GRANT_*_URI_PERMISSION constant is only a DLP concern when it is used
# to GRANT access (addFlags/setFlags/grantUriPermission/putExtra/intent.flags=).
# Reading the same constants to RELEASE persisted permissions is the correct
# migration-time cleanup action and must not be flagged.
grant_context = re.compile(
    r'\baddFlags\s*\([^)]*FLAG_GRANT_|'
    r'\bsetFlags\s*\([^)]*FLAG_GRANT_|'
    r'\bgrantUriPermission\s*\(|'
    r'\bputExtra\s*\([^)]*FLAG_GRANT_|'
    r'\.\s*flags\s*=\s*[^=].*FLAG_GRANT_'
)
grant_cleanup = re.compile(
    r'\breleasePersistableUriPermission\b|'
    r'\bclearPersistedUriPermissions\b|'
    r'\btakePersistableUriPermission\b|'
    r'\brevokeUriPermission\b'
)
file_provider_uri = re.compile(r'\bFileProvider\s*\.\s*getUriForFile\b')
clipdata_new_uri = re.compile(r'\bClipData\s*\.\s*newUri\b')
extra_stream = re.compile(r'\bEXTRA_STREAM\b')
set_clip_data = re.compile(r'\bsetClipData\s*\(')
set_or_construct_intent_uri = re.compile(
    r'\bsetData\s*\(|'
    r'\bsetDataAndType\s*\(|'
    r'\.\s*data\s*=|'
    r'\bIntent\s*\([^,]+,'
)
content_uri_literal = re.compile(
    r'"content://[^"]*"|'
    r'Uri\.parse\s*\(\s*"content://'
)
uri_var_assignment = re.compile(
    r'\b(?:val|var|final\s+\w+\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'
    r'(?:.*FileProvider\s*\.\s*getUriForFile|.*Uri\.parse\s*\(\s*"content://)'
)
clipdata_var_assignment = re.compile(
    r'\b(?:val|var|final\s+\w+\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*.*ClipData\s*\.\s*newUri'
)
persisted_uri = re.compile(
    r'takePersistableUriPermission|'
    r'"content://[^"]*"|'
    r'Uri\.parse\s*\(\s*"content://'
)

# DLP enforcement pattern — approved outbound exports must check
# Dynamics outbound DLP policy BEFORE launching the picker. A file
# containing both an outbound intent AND a DLP policy check is
# treated as an approved DLP-gated export (not an unapproved blocker).
dlp_enforcement = re.compile(
    r'getApplicationPolicy\s*\(\s*\)|'
    r'preventDataLeakageOut|'
    r'preventDataLeakage'
)

counts = {
    "inbound": 0,
    "outbound": 0,
    "outbound_unapproved": 0,
    "outbound_dlp_gated": 0,
    "tree_primary": 0,
    "uri_sharing": 0,
    "uri_grants": 0,
    "contracts_inbound": 0,
    "contracts_outbound": 0,
    "approved_outbound_decisions": approved_outbound_decisions,
}


def is_comment(line):
    s = line.lstrip()
    return (not s) or s.startswith("//") or s.startswith("*") or s.startswith("/*")


def line_uses_any_var(line, names):
    return any(re.search(r'\b' + re.escape(name) + r'\b', line) for name in names)


for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith((".java", ".kt")):
            continue
        path = os.path.join(dirpath, fn)
        try:
            text = open(path, "r", encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if "/test/" in path or "/androidTest/" in path:
            continue
        file_has_outbound = False
        file_has_dlp = False
        file_outbound_count = 0
        file_contracts_outbound = 0
        uri_vars = set()
        clipdata_vars = set()
        for lineno, line in enumerate(text.splitlines(), start=1):
            if is_comment(line):
                continue
            uri_match = uri_var_assignment.search(line)
            if uri_match:
                uri_vars.add(uri_match.group(1))
            clip_match = clipdata_var_assignment.search(line)
            if clip_match:
                clipdata_vars.add(clip_match.group(1))
            if outbound_intents.search(line):
                file_has_outbound = True
                file_outbound_count += 1
                if "ActivityResultContracts" in line:
                    file_contracts_outbound += 1
            if inbound_intents.search(line):
                counts["inbound"] += 1
                if "ActivityResultContracts" in line:
                    counts["contracts_inbound"] += 1
            if tree_intents.search(line):
                counts["tree_primary"] += 1
            if (uri_grant_flags.search(line)
                    and grant_context.search(line)
                    and not grant_cleanup.search(line)):
                counts["uri_grants"] += 1
            uri_sharing_hit = False
            if file_provider_uri.search(line):
                uri_sharing_hit = True
            if clipdata_new_uri.search(line):
                uri_sharing_hit = True
            if extra_stream.search(line):
                uri_sharing_hit = True
            if set_clip_data.search(line) and (
                clipdata_new_uri.search(line) or line_uses_any_var(line, clipdata_vars)
            ):
                uri_sharing_hit = True
            if set_or_construct_intent_uri.search(line) and (
                content_uri_literal.search(line) or line_uses_any_var(line, uri_vars)
            ):
                uri_sharing_hit = True
            if uri_sharing_hit:
                counts["uri_sharing"] += 1
            if dlp_enforcement.search(line):
                file_has_dlp = True
        if file_has_outbound:
            counts["outbound"] += file_outbound_count
            counts["contracts_outbound"] += file_contracts_outbound
            if file_has_dlp and approved_outbound_remaining > 0:
                gated = min(file_outbound_count, approved_outbound_remaining)
                counts["outbound_dlp_gated"] += gated
                approved_outbound_remaining -= gated
                if gated < file_outbound_count:
                    counts["outbound_unapproved"] += file_outbound_count - gated
            else:
                counts["outbound_unapproved"] += file_outbound_count

for key, val in counts.items():
    print(f"{key}|{val}")
PY
)

SAF_DIR_INBOUND=0
SAF_DIR_OUTBOUND=0
SAF_DIR_OUTBOUND_UNAPPROVED=0
SAF_DIR_OUTBOUND_DLP_GATED=0
SAF_DIR_TREE_PRIMARY=0
SAF_DIR_URI_SHARING=0
SAF_DIR_URI_GRANTS=0
SAF_DIR_CONTRACTS_IN=0
SAF_DIR_CONTRACTS_OUT=0
SAF_DIR_APPROVED_DECISIONS=0

while IFS='|' read -r key value; do
    [ -z "$key" ] && continue
    case "$key" in
        inbound) SAF_DIR_INBOUND="${value:-0}" ;;
        outbound) SAF_DIR_OUTBOUND="${value:-0}" ;;
        outbound_unapproved) SAF_DIR_OUTBOUND_UNAPPROVED="${value:-0}" ;;
        outbound_dlp_gated) SAF_DIR_OUTBOUND_DLP_GATED="${value:-0}" ;;
        tree_primary) SAF_DIR_TREE_PRIMARY="${value:-0}" ;;
        uri_sharing) SAF_DIR_URI_SHARING="${value:-0}" ;;
        uri_grants) SAF_DIR_URI_GRANTS="${value:-0}" ;;
        contracts_inbound) SAF_DIR_CONTRACTS_IN="${value:-0}" ;;
        contracts_outbound) SAF_DIR_CONTRACTS_OUT="${value:-0}" ;;
        approved_outbound_decisions) SAF_DIR_APPROVED_DECISIONS="${value:-0}" ;;
    esac
done <<EOF
$SAF_DIRECTIONAL_RESULTS
EOF

if [ "$SAF_DIR_INBOUND" -gt 0 ]; then
    check_warn "SAF inbound import patterns detected ($SAF_DIR_INBOUND, including $SAF_DIR_CONTRACTS_IN ActivityResultContracts) — requires secure-copy migration into Dynamics container (see steering/44-saf-trust-boundary.md §1a, catalog row saf-java-inbound-001)"
else
    check_pass "No SAF inbound import patterns detected"
fi

# Unapproved outbound: any SAF outbound export pattern in a file that
# does NOT contain a Dynamics outbound DLP policy check. This is a
# security blocker — the export code exists without DLP enforcement.
if [ "$SAF_DIR_OUTBOUND_UNAPPROVED" -gt 0 ]; then
    security_blocker "externalStorage" "saf-outbound-export" "$SAF_DIR_OUTBOUND_UNAPPROVED" \
        "Unapproved SAF outbound export patterns detected ($SAF_DIR_OUTBOUND_UNAPPROVED of $SAF_DIR_OUTBOUND total, including $SAF_DIR_CONTRACTS_OUT ActivityResultContracts). \
Data from the Dynamics secure container may be written to an external document provider via ACTION_CREATE_DOCUMENT or equivalent WITHOUT both runtime DLP enforcement and a structured developer approval record. \
Default migration decision: BLOCKED_PENDING_DEVELOPER_APPROVAL. \
The migration agent must DELETE the outbound SAF code (not just disable the UI), and record the blocked capability with status 'removed' in dispositions[]. \
Only after explicit developer approval (ALLOW_WITH_DLP_ENFORCEMENT persisted in dispositions[].safDecision with runtimeDlpEnforced=true) may the export be re-implemented with runtime DLP enforcement. \
See steering/44-saf-trust-boundary.md §1b and catalog row saf-java-outbound-001."
elif [ "$SAF_DIR_OUTBOUND_DLP_GATED" -gt 0 ]; then
    check_pass "SAF outbound export patterns detected ($SAF_DIR_OUTBOUND_DLP_GATED) — all are DLP-gated with structured developer approval records ($SAF_DIR_APPROVED_DECISIONS approval decision(s))"
else
    check_pass "No SAF outbound export patterns requiring developer approval detected"
fi

if [ "$SAF_DIR_URI_SHARING" -gt 0 ] || [ "$SAF_DIR_URI_GRANTS" -gt 0 ]; then
    SAF_URI_TOTAL=$((SAF_DIR_URI_SHARING + SAF_DIR_URI_GRANTS))
    security_blocker "externalStorage" "saf-uri-sharing" "$SAF_URI_TOTAL" \
        "SAF URI sharing / permission grant patterns detected ($SAF_URI_TOTAL: uriSharing=$SAF_DIR_URI_SHARING uriGrants=$SAF_DIR_URI_GRANTS). \
URI payloads and permission grants transfer data access to external components outside the Dynamics container. \
Write grants are especially dangerous — an external component may modify data consumed by the Dynamics application. \
Default migration decision: BLOCKED_PENDING_DEVELOPER_APPROVAL. \
Blocking requires removal of: the external intent launch, all EXTRA_STREAM values, Intent.data, ClipData, URI permission flags, temporary FileProvider files, and any async preparation job used only by the share flow. Disabling the visible Share button alone does NOT close the finding. \
See steering/44-saf-trust-boundary.md §1d and §4b."
else
    check_pass "No SAF URI sharing / permission grant patterns detected"
fi

if [ "$SAF_DIR_TREE_PRIMARY" -gt 0 ]; then
    security_blocker "externalStorage" "saf-external-primary-storage" "$SAF_DIR_TREE_PRIMARY" \
        "SAF external primary storage patterns detected ($SAF_DIR_TREE_PRIMARY). \
The application uses ACTION_OPEN_DOCUMENT_TREE or ActivityResultContracts.OpenDocumentTree, indicating \
a persisted external directory may serve as canonical data store. Persisted URI permission is NOT equivalent to \
Dynamics secure storage. Enterprise data must be moved to the container. \
See steering/44-saf-trust-boundary.md §1c and catalog row saf-java-primary-storage-001."
else
    check_pass "No SAF external primary storage patterns detected"
fi

echo ""

SHARED_PREFS_RUNTIME_USAGE="$(python3 - "$SRC_DIR_MM" <<'PY' | count_hits_for_domain "secureFileStorage"
import os
import re
import sys

src_root = sys.argv[1]

pref_factory = re.compile(
    r"getSharedPreferences\s*\(|"
    r"PreferenceManager\.getDefaultSharedPreferences\s*\(|"
    r"EncryptedSharedPreferences"
)
pref_accessor = re.compile(
    r'\.(?:edit|getAll|getString|getInt|getLong|getBoolean|getFloat|getStringSet|contains|'
    r'remove|clear|putString|putInt|putLong|putBoolean|putFloat|putStringSet|apply|commit)\s*\('
)
pref_context = re.compile(
    r'\bSharedPreferences\b|'
    r'getSharedPreferences\s*\(|'
    r'PreferenceManager\.getDefaultSharedPreferences\s*\(|'
    r'EncryptedSharedPreferences'
)
migration_terms = re.compile(r"(?i)\b(migration|migrate|migrated|upgrade|legacy|backfill)\b")
secure_terms = re.compile(
    r"(?i)\b("
    r"securePrefs|SecurePreferencesHelper|SecureFileIO|secure storage|"
    r"GDFileSystem|com\.good\.gd\.file|fileStore|openFileInput|openFileOutput"
    r")\b"
)
cleanup_terms = re.compile(r"(?i)\b(remove|clear|delete)\s*\(")
authorized_terms = re.compile(r"(?i)\bonAuthorized\b")


def is_comment(line: str) -> bool:
    stripped = line.lstrip()
    return (not stripped) or stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*")


def explicit_migration_context(window: str) -> bool:
    return (
        migration_terms.search(window)
        and secure_terms.search(window)
        and (cleanup_terms.search(window) or authorized_terms.search(window))
    )


cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith((".java", ".kt")):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            text = open(path, "r", encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        lines = text.splitlines()
        for lineno, line in enumerate(lines, start=1):
            if is_comment(line):
                continue
            if not pref_factory.search(line) and not pref_accessor.search(line):
                continue
            start = max(0, lineno - 4)
            end = min(len(lines), lineno + 3)
            window_lines = [l for l in lines[start:end] if not is_comment(l)]
            window = "\n".join(window_lines)
            if not pref_context.search(window):
                continue
            if explicit_migration_context(window):
                continue
            print(f"{rel}:{lineno}:{line.rstrip()}")
PY
)"
if [ "${SHARED_PREFS_RUNTIME_USAGE:-0}" -gt 0 ]; then
    _CURRENT_PHASE="4"
    fail_or_defer "secureFileStorage" "SharedPreferences runtime usage still present (${SHARED_PREFS_RUNTIME_USAGE}) — steady-state preference persistence remains outside the Dynamics container. SharedPreferences access is allowed only inside an explicit one-time migration helper that copies legacy values into secure storage and removes them." \
        "Replace steady-state SharedPreferences persistence with SecurePreferencesHelper backed by com.good.gd.file.FileOutputStream/FileInputStream. Keep legacy SharedPreferences reads/writes only inside the explicit one-time migration helper after onAuthorized()."
else
    check_pass "No SharedPreferences runtime usage detected outside explicit migration helpers"
fi

if [ "$TEMP_FILE_COUNT" -gt 0 ]; then
    check_fail "File.createTempFile() detected in $TEMP_FILE_COUNT location(s) — non-waivable: writes plaintext outside the secure container. Use in-memory capture (`ImageCapture.OnImageCapturedCallback`) or a true Dynamics container staging flow."
else
    check_pass "No plaintext File.createTempFile usage"
fi
if [ "${GD_ABS_PATH_STREAMS:-0}" -gt 0 ]; then
    check_fail "GD FileInputStream/FileOutputStream uses Android absolute/cache/files-dir paths in $GD_ABS_PATH_STREAMS location(s) — non-waivable: use container-relative paths only (e.g., media/photos/..., thumbs/...)"
else
    check_pass "No GD stream constructors with Android absolute/cache/files-dir path arguments"
fi
GD_STREAM_FOLLOWON=$(python3 - "$SRC_DIR_MM" <<'PY'
import os
import re
import sys

src_root = sys.argv[1]
gd_fis = re.compile(r"^\s*import\s+com\.good\.gd\.file\.FileInputStream", re.MULTILINE)
gd_fos = re.compile(r"^\s*import\s+com\.good\.gd\.file\.FileOutputStream", re.MULTILINE)
patterns = (
    re.compile(r"\.getChannel\s*\("),
    re.compile(r"\.transferFrom\s*\("),
    re.compile(r"\.transferTo\s*\("),
    re.compile(r"BitmapFactory\.decodeFile\s*\("),
)
count = 0
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith((".java", ".kt")):
            continue
        path = os.path.join(dirpath, fn)
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if not (gd_fis.search(text) or gd_fos.search(text)):
            continue
        for pat in patterns:
            count += len(pat.findall(text))
print(count)
PY
)
if [ "${GD_STREAM_FOLLOWON:-0}" -gt 0 ]; then
    fail_or_defer "secureFileStorage" "GD FileInputStream/FileOutputStream follow-on API misuse in $GD_STREAM_FOLLOWON location(s) — .getChannel(), transferFrom/transferTo, or BitmapFactory.decodeFile on GD streams/paths are unsupported. Use byte[]/InputStream patterns (see steering/40-secure-file-storage.md)."
else
    check_pass "No GD stream FileChannel/decodeFile follow-on anti-patterns detected"
fi

# -----------------------------------------------------------------------
# 4J. Unguarded .listFiles() / .list() on com.good.gd.file.File.
#     Unlike java.io.File.listFiles() (returns null for non-existent dirs),
#     com.good.gd.file.File.listFiles() throws NPE internally in the
#     native layer (FileImpl.cwgjn) when the directory does not exist.
#     The Kotlin ?. safe-call operator does NOT protect against this
#     because the exception is thrown INSIDE listFiles(), not as a null
#     return value.
#
#     This check finds .listFiles() and .list() calls on receivers that can
#     be structurally tied back to com.good.gd.file.File (direct constructor
#     calls, typed variables, or constructor-backed assignments). This avoids
#     false positives on unrelated receivers such as DocumentFile in utility
#     files that also import GD file APIs.
#     See steering/40-secure-file-storage.md §10 "Known Pitfalls".
# -----------------------------------------------------------------------
GD_LISTFILES_SCAN=$(python3 "$GD_LISTFILES_GUARD_SCAN_PY" --source-root "$SRC_DIR_MM" 2>/dev/null || true)
GD_LISTFILES_UNGUARDED=$(printf '%s\n' "$GD_LISTFILES_SCAN" | sed -n '1p')
GD_LISTFILES_UNGUARDED_FILES=$(printf '%s\n' "$GD_LISTFILES_SCAN" | sed -n '2p')
GD_LISTFILES_UNGUARDED=${GD_LISTFILES_UNGUARDED:-0}
if [ "$GD_LISTFILES_UNGUARDED" -gt 0 ]; then
    fail_or_defer "secureFileStorage" "[RUNTIME-NPE][secureFileStorage/listFiles-unguarded] GD File.listFiles()/list() called without exists() guard in $GD_LISTFILES_UNGUARDED location(s) — com.good.gd.file.File.listFiles() throws NPE internally (in the native layer) for non-existent directories, unlike java.io.File which returns null. The Kotlin ?. safe-call does NOT protect against this. Always guard: if (!dir.exists()) return before calling listFiles()/list(). See steering/40-secure-file-storage.md §10." \
        "Add an exists()/isDirectory() guard before every com.good.gd.file.File.listFiles()/list() call. Safe patterns: if (!dir.exists()) return; or val children = if (dir.exists()) dir.listFiles() else null." \
        "$GD_LISTFILES_UNGUARDED_FILES"
else
    check_pass "No unguarded GD File.listFiles()/list() calls detected (exists() guard present or not applicable)"
fi

if [ "${GLIDE_NATIVE_PATH_LOADS:-0}" -gt 0 ]; then
    fail_or_defer "secureFileStorage" "Glide .load(...) uses native File/absolute/cache/files-dir path patterns in $GLIDE_NATIVE_PATH_LOADS location(s) — for container-backed files use secure-container readers (InputStream/byte[]) instead of Android filesystem paths"
else
    check_pass "No Glide native File/absolute/cache/files-dir path loading patterns detected"
fi
# Generic writer->reader closure check:
# if secure container path domains are detected in Dynamics write call-sites,
# fail when those same domains also appear with cache/files-dir path creation
# and third-party/native file readers (often split across different files).
#
# TODO(api-anchored-detection): this remains a best-effort token-matching
# heuristic over path literals. It is intentionally NOT used to infer data
# sensitivity, but it still uses lexical domain matching to spot partial
# reader-side migrations that span files/modules. A future structural rewrite
# should anchor this on explicit path/reader call-site linkage instead.
SECURE_PATH_TOKENS=""
PARTIAL_MIGRATION_DOMAIN_HITS=0
PARTIAL_MIGRATION_DOMAIN_DETAILS=""
if [ "$GD_FS_CALLS" -gt 0 ]; then
    GD_CALL_FILES=$(python3 "$GD_FILE_CALLSITE_SCAN_PY" --source-root "$SRC_DIR_MM" --mode files 2>/dev/null || true)
    if [ -n "$GD_CALL_FILES" ]; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            LITERALS=$(grep -oE "\"[A-Za-z0-9_.-]{3,}(/[A-Za-z0-9_.-]+)?\"" "$f" 2>/dev/null \
                | sed -E 's/^"//; s/"$//' || true)
            if [ -n "$LITERALS" ]; then
                while IFS= read -r literal; do
                    [ -z "$literal" ] && continue
                    token="${literal%%/*}"
                    case "$token" in
                        image|video|audio|text|application|http|https|content|file|android|drawable|layout|string|color|mipmap)
                            continue
                            ;;
                    esac
                    SECURE_PATH_TOKENS="${SECURE_PATH_TOKENS}${token}"$'\n'
                done <<EOF
$LITERALS
EOF
            fi
        done <<EOF
$GD_CALL_FILES
EOF
    fi

    SECURE_PATH_TOKENS=$(printf "%s" "$SECURE_PATH_TOKENS" | sed '/^$/d' | sort -u || true)
    CACHE_PATH_FILES=""
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if file_has_noncomment_ere_match "$f" "getCacheDir|getExternalCacheDir|externalCacheDir|getFilesDir"; then
            CACHE_PATH_FILES="${CACHE_PATH_FILES}${f}"$'\n'
        fi
    done <<EOF
$(grep -rlE "getCacheDir|getExternalCacheDir|externalCacheDir|getFilesDir" "$SRC_DIR_MM/" 2>/dev/null || true)
EOF
    FILE_READER_FILES=""
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if file_has_noncomment_ere_match "$f" "Glide\.with|Picasso\.|Coil|BitmapFactory\.decodeFile|decodeFile\(|openInputStream\(|new[[:space:]]+(java\.io\.)?File(Input|Output)Stream[[:space:]]*\("; then
            FILE_READER_FILES="${FILE_READER_FILES}${f}"$'\n'
        fi
    done <<EOF
$(grep -rlE "Glide\.with|Picasso\.|Coil|BitmapFactory\.decodeFile|decodeFile\(|openInputStream\(|new[[:space:]]+(java\.io\.)?File(Input|Output)Stream[[:space:]]*\(" "$SRC_DIR_MM/" 2>/dev/null || true)
EOF

    if [ -n "$SECURE_PATH_TOKENS" ] && [ -n "$CACHE_PATH_FILES" ] && [ -n "$FILE_READER_FILES" ]; then
        while IFS= read -r token; do
            [ -z "$token" ] && continue
            safe_token=$(printf '%s' "$token" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g')
            CACHE_TOKEN_FILES=0
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                tokpat="\"${safe_token}([/\"\\\\]|$)"
                file_has_noncomment_ere_match "$f" "$tokpat" || continue
                CACHE_TOKEN_FILES=$((CACHE_TOKEN_FILES + 1))
            done <<EOF
$CACHE_PATH_FILES
EOF

            READER_TOKEN_FILES=0
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                tokpat="\"${safe_token}([/\"\\\\]|$)"
                file_has_noncomment_ere_match "$f" "$tokpat" || continue
                READER_TOKEN_FILES=$((READER_TOKEN_FILES + 1))
            done <<EOF
$FILE_READER_FILES
EOF

            if [ "$CACHE_TOKEN_FILES" -gt 0 ] && [ "$READER_TOKEN_FILES" -gt 0 ]; then
                PARTIAL_MIGRATION_DOMAIN_HITS=$((PARTIAL_MIGRATION_DOMAIN_HITS + 1))
                PARTIAL_MIGRATION_DOMAIN_DETAILS="${PARTIAL_MIGRATION_DOMAIN_DETAILS}${token}(cache=${CACHE_TOKEN_FILES},readers=${READER_TOKEN_FILES}) "
            fi
        done <<EOF
$SECURE_PATH_TOKENS
EOF
    fi
fi

if [ "$GD_FS_CALLS" -gt 0 ] && [ "$PARTIAL_MIGRATION_DOMAIN_HITS" -gt 0 ]; then
    fail_or_defer "secureFileStorage" "Potential writer-migrated/reader-not-migrated pattern detected for secure path domain(s): $PARTIAL_MIGRATION_DOMAIN_DETAILS. Dynamics secure file writes coexist with cache/files-dir reader paths for the same domain(s). Complete reader-side migration to secure APIs (byte[]/InputStream/custom loader). If the reader path cannot be migrated, the developer must defer the entire 'secureFileStorage' domain in bootstrap.json deferredDomains[]."
else
    check_pass "No generic writer->reader path-domain mismatch detected alongside Dynamics file I/O (or Dynamics I/O not used)"
fi

# Native (NDK / C / C++) file I/O detection. Direct-replacement coverage
# extends to native source under app control: standard C/POSIX file
# calls bypass the Dynamics container entirely if not replaced with the
# matching `GD_*` / `GD_UNISTD_*` calls from
# `steering/14-api-provenance-and-replacement-catalog.md` and
# `steering/46-native-ndk-direct-replacement.md`. Routed through
# `fail_or_defer "secureFileStorage"` so the deferral semantics already
# applied to Java/Kotlin secureFileStorage call sites also apply here.
NATIVE_FILE_HITS=0
NATIVE_SO_HITS=0
NATIVE_JNI_LOAD_HITS=0
NATIVE_BUILD_SIGNALS=0
NATIVE_SOURCE_PRESENT=0
OPAQUE_BINARY_DEP_HITS=0
NATIVE_FILE_HIT_MODULES=""
NATIVE_SO_HIT_MODULES=""
OPAQUE_BINARY_DEP_HIT_MODULES=""
# Iterate every in-scope module (primary + libraryModulesInScope[]).
# Each module contributes to four aggregates: NATIVE_FILE_HITS,
# NATIVE_SO_HITS, NATIVE_BUILD_SIGNALS, and NATIVE_SOURCE_PRESENT
# (the boolean "any in-repo native source anywhere?" used to gate the
# opaque-loadLibrary warning at the bottom of this phase).
# shellcheck disable=SC2086
for MP in $MM_IN_SCOPE_MODULE_PATHS; do
    [ -z "$MP" ] && continue
    MP_SRC="$MP/src"
    if [ -d "$MP_SRC" ]; then
        MP_FILE_HITS=$(python3 "$NATIVE_SCAN_PY" "$MP_SRC" file 2>/dev/null || echo 0)
        MP_FILE_HITS=${MP_FILE_HITS:-0}
        if [ "$MP_FILE_HITS" -gt 0 ]; then
            NATIVE_FILE_HITS=$((NATIVE_FILE_HITS + MP_FILE_HITS))
            NATIVE_FILE_HIT_MODULES="$NATIVE_FILE_HIT_MODULES $MP:$MP_FILE_HITS"
        fi
        # "Any in-repo native source?" — presence of any .c/.cc/.cpp/.cxx/.h/.hpp
        # under $MP/src, excluding test source sets. Cheap shell-level check.
        if find "$MP_SRC" -type f \( -name "*.c" -o -name "*.cc" -o -name "*.cpp" \
            -o -name "*.cxx" -o -name "*.h" -o -name "*.hpp" \) \
            -not -path "*/src/test/*" -not -path "*/src/androidTest/*" \
            2>/dev/null | head -1 | grep -q .; then
            NATIVE_SOURCE_PRESENT=1
        fi
        # Prebuilt .so under any source set's jniLibs/ (typically
        # src/main/jniLibs/<abi>/lib*.so, but flavors also have jniLibs/).
        MP_SO_HITS=$(find "$MP_SRC" -type d -name "jniLibs" 2>/dev/null \
            | while read -r d; do find "$d" -type f -name "*.so" 2>/dev/null; done \
            | wc -l | tr -d ' ')
        MP_SO_HITS=${MP_SO_HITS:-0}
        if [ "$MP_SO_HITS" -gt 0 ]; then
            NATIVE_SO_HITS=$((NATIVE_SO_HITS + MP_SO_HITS))
            NATIVE_SO_HIT_MODULES="$NATIVE_SO_HIT_MODULES $MP:$MP_SO_HITS"
        fi
    fi

    # Build-config signals per module: CMakeLists.txt, Android.mk,
    # Application.mk, or externalNativeBuild/ndkBuild in the module's
    # build.gradle[.kts].
    for f in "$MP/CMakeLists.txt" "$MP/src/main/cpp/CMakeLists.txt"; do
        [ -f "$f" ] && NATIVE_BUILD_SIGNALS=$((NATIVE_BUILD_SIGNALS + 1))
    done
    for f in "$MP/src/main/jni/Android.mk" "$MP/src/main/jni/Application.mk" \
             "$MP/Android.mk" "$MP/Application.mk"; do
        [ -f "$f" ] && NATIVE_BUILD_SIGNALS=$((NATIVE_BUILD_SIGNALS + 1))
    done
    for bf in "$MP/build.gradle" "$MP/build.gradle.kts"; do
        if [ -f "$bf" ]; then
            # BSD `grep -c` returns 0 on the stream but exit code 1 when
            # there are zero matches; pinning to a single integer via the
            # second grep + wc keeps the arithmetic safe under `set -e`-ish
            # shells and avoids `0\n0` collisions in `$(... || echo 0)`.
            EXT_NATIVE=$(grep -E "externalNativeBuild|ndkBuild|cmake[[:space:]]*\{" "$bf" 2>/dev/null | wc -l | tr -d ' ')
            NATIVE_BUILD_SIGNALS=$((NATIVE_BUILD_SIGNALS + ${EXT_NATIVE:-0}))
            # Opaque binary dependency hints: local AAR/JAR wiring and flatDir/fileTree based
            # dependencies are typically closed-source and out of automatic migration scope.
            MP_OPAQUE_DECLS=$(grep -E "flatDir[[:space:]]*\{|fileTree[[:space:]]*\(|files[[:space:]]*\(|name[[:space:]]*:[[:space:]]*['\"][^'\"]+['\"][[:space:]]*,[[:space:]]*ext[[:space:]]*:[[:space:]]*['\"](aar|jar)['\"]" "$bf" 2>/dev/null | wc -l | tr -d ' ')
            MP_OPAQUE_DECLS=${MP_OPAQUE_DECLS:-0}
            if [ "$MP_OPAQUE_DECLS" -gt 0 ]; then
                OPAQUE_BINARY_DEP_HITS=$((OPAQUE_BINARY_DEP_HITS + MP_OPAQUE_DECLS))
                OPAQUE_BINARY_DEP_HIT_MODULES="$OPAQUE_BINARY_DEP_HIT_MODULES $MP:$MP_OPAQUE_DECLS"
            fi
        fi
    done
    if [ -d "$MP/libs" ]; then
        MP_OPAQUE_LIB_FILES=$(find "$MP/libs" -type f \( -name "*.aar" -o -name "*.jar" \) 2>/dev/null | wc -l | tr -d ' ')
        MP_OPAQUE_LIB_FILES=${MP_OPAQUE_LIB_FILES:-0}
        if [ "$MP_OPAQUE_LIB_FILES" -gt 0 ]; then
            OPAQUE_BINARY_DEP_HITS=$((OPAQUE_BINARY_DEP_HITS + MP_OPAQUE_LIB_FILES))
            OPAQUE_BINARY_DEP_HIT_MODULES="$OPAQUE_BINARY_DEP_HIT_MODULES $MP:$MP_OPAQUE_LIB_FILES"
        fi
    fi
done

# JNI System.loadLibrary / System.load — scan Java/Kotlin across the
# full in-scope source-root set, not just the primary module: a library
# module can be the one that pulls in an opaque prebuilt .so.
NATIVE_JNI_LOAD_HITS=0
# shellcheck disable=SC2086
if [ -n "$MM_IN_SCOPE_SOURCE_ROOTS" ]; then
    NATIVE_JNI_LOAD_HITS=$(grep -rnE "System\.(loadLibrary|load)\s*\(" $MM_IN_SCOPE_SOURCE_ROOTS 2>/dev/null \
        | strip_audit_noise \
        | count_hits_for_domain "secureFileStorage")
fi

if [ "${NATIVE_FILE_HITS:-0}" -gt 0 ]; then
    NATIVE_FILE_DETAIL="$(echo "$NATIVE_FILE_HIT_MODULES" | sed -e 's/^ //' -e 's/ /, /g')"
    _CURRENT_PHASE="4"
    fail_or_defer "secureFileStorage" "Native (C/C++) standard file / POSIX storage calls detected in app-controlled native source ($NATIVE_FILE_HITS hit(s) across in-scope modules: ${NATIVE_FILE_DETAIL}) — these bypass the Dynamics container. Replace with GD_*/GD_UNISTD_* equivalents per steering/14-api-provenance-and-replacement-catalog.md and steering/40-secure-file-storage.md §8, or defer secureFileStorage in bootstrap.json deferredDomains[]." \
        "Replace fopen() with GD_fopen(), open() with GD_UNISTD_open(), fclose() with GD_fclose(), read/write with GD_UNISTD_read/GD_UNISTD_write. Add #include <GD_C_FileSystem.h> and link gd_runtime. See steering/46-native-ndk-direct-replacement.md."
elif [ "${NATIVE_SOURCE_PRESENT:-0}" -eq 1 ] && [ "${NATIVE_BUILD_SIGNALS:-0}" -gt 0 ]; then
    check_pass "No standard C/POSIX file calls detected in app-controlled native source (in-scope modules)"
fi

if [ "${NATIVE_SO_HITS:-0}" -gt 0 ]; then
    NATIVE_SO_DETAIL="$(echo "$NATIVE_SO_HIT_MODULES" | sed -e 's/^ //' -e 's/ /, /g')"
    _CURRENT_DOMAIN="secureFileStorage"
    _CURRENT_PHASE="4"
    check_warn "Prebuilt native .so libraries present in jniLibs/ ($NATIVE_SO_HITS file(s) across: ${NATIVE_SO_DETAIL}) — the validator cannot prove safety from binaries. Add a non-blocking manualTodo per steering/46-native-ndk-direct-replacement.md naming each library, owning module, and the reason source-level proof is unavailable. If evidence shows the underlying flow violates a non-waivable storage/networking rule, set blocking=true."
fi

# Opaque-loadLibrary warning: loadLibrary detected somewhere in the
# in-scope source roots AND prebuilt .so artifacts exist AND no
# in-repo native source was found in any in-scope module.
if [ "${NATIVE_JNI_LOAD_HITS:-0}" -gt 0 ] \
   && [ "${NATIVE_SO_HITS:-0}" -gt 0 ] \
   && [ "${NATIVE_FILE_HITS:-0}" -eq 0 ] \
   && [ "${NATIVE_SOURCE_PRESENT:-0}" -eq 0 ]; then
    _CURRENT_DOMAIN="secureFileStorage"
    _CURRENT_PHASE="4"
    check_warn "JNI System.loadLibrary detected ($NATIVE_JNI_LOAD_HITS) loading prebuilt .so libraries without in-repo source (across in-scope modules) — treat as opaque native code per steering/46-native-ndk-direct-replacement.md"
fi

if [ "${OPAQUE_BINARY_DEP_HITS:-0}" -gt 0 ]; then
    OPAQUE_BINARY_DEP_DETAIL="$(echo "$OPAQUE_BINARY_DEP_HIT_MODULES" | sed -e 's/^ //' -e 's/ /, /g')"
    _CURRENT_DOMAIN="secureFileStorage"
    _CURRENT_PHASE="4"
    check_warn "Opaque binary dependency artifacts detected (${OPAQUE_BINARY_DEP_HITS} hint(s) across modules: ${OPAQUE_BINARY_DEP_DETAIL}) — closed-source SDK internals are out of automatic migration scope. Add non-blocking manualTodos[] entries with owner, evidence, and proof actions (vendor attestation/source audit/runtime monitoring). Escalate to blocking=true only when evidence shows a non-waivable storage/networking rule violation."
fi

# ========================================================================
# Phase 4: Stream-layer closure (steering/40-secure-file-storage.md §5)
# ------------------------------------------------------------------------
# Scope: files in ${in_scope_main_src} that ALSO import com.good.gd.file.*
# (the secure-storage surface is in scope for them). This avoids false
# positives in modules that opt the domain out entirely. Each detector
# prints "<file>:<line>:<api>:<message>" lines and they are counted via
# count_hits_for_domain "secureFileStorage" so deferral semantics apply.
#
# Each detector is a FAIL (routed via fail_or_defer) — see steering/40a
# for the full anti-pattern list and canonical replacements.
# ========================================================================

STREAM_LAYER_DETAIL=""
STREAM_LAYER_HITS_TOTAL=0

# Helper: produce raw "path:line:matched" lines for a regex, restricted to
# files importing com.good.gd.file.*  (and excluding comment-only lines /
# the SecureFileIO template itself).
__stream_layer_scan() {
    local regex="$1"
    local label="$2"
    python3 - "$SRC_DIR_MM" "$regex" "$label" <<'PY' 2>/dev/null
import os
import re
import sys

src_root = sys.argv[1]
pattern = re.compile(sys.argv[2])
label = sys.argv[3]
gd_import = re.compile(r"^\s*import\s+com\.good\.gd\.file\.", re.MULTILINE)

# Lines where a kotlin.io / java.io call happens against an in-line GD
# stream (e.g. `FileInputStream("x").use { it.readBytes() }`) read the
# secure container correctly — the .readText / .readBytes / .bufferedReader
# is on the GD InputStream, not on a File receiver. Skip such lines for
# the kotlin.io family. This avoids false positives on the canonical
# pattern that 40a actually recommends.
gd_inline_stream = re.compile(
    r"com\.good\.gd\.file\.File(Input|Output)Stream\s*\(|"
    r"\bFileInputStream\s*\(|"
    r"\bFileOutputStream\s*\(|"
    r"GDFileSystem\.openFileInput\s*\(|"
    r"GDFileSystem\.openFileOutput\s*\(|"
    r"SecureFileIO\.")
KOTLIN_IO_LABELS = {"kotlin.io-text-bytes", "kotlin.io-accessor"}

def is_comment(line: str) -> bool:
    s = line.lstrip()
    return (not s) or s.startswith("//") or s.startswith("*") or s.startswith("/*")

cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith((".java", ".kt")):
            continue
        # Skip the toolkit's own SecureFileIO template if it landed in src.
        if fn in ("SecureFileIO.kt", "SecureFileIO.java"):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        if not gd_import.search(text):
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if is_comment(line):
                continue
            if pattern.search(line):
                if label in KOTLIN_IO_LABELS and gd_inline_stream.search(line):
                    continue
                print(f"{rel}:{lineno}:{label}:{line.strip()}")
PY
}

__stream_layer_accumulate() {
    local label="$1"
    local hits
    hits=$(echo "$2" | sed '/^$/d' | wc -l | tr -d ' ')
    if [ "${hits:-0}" -gt 0 ]; then
        STREAM_LAYER_HITS_TOTAL=$((STREAM_LAYER_HITS_TOTAL + hits))
        STREAM_LAYER_DETAIL="${STREAM_LAYER_DETAIL}${label}=${hits} "
    fi
}

# 4A. kotlin.io text/bytes/line/copy/tree extensions on any File receiver.
SL_KIO_TEXT=$(__stream_layer_scan \
    '\.(writeText|readText|appendText|writeBytes|readBytes|appendBytes|forEachLine|readLines|useLines|copyTo|copyRecursively|deleteRecursively)\s*\(' \
    'kotlin.io-text-bytes')
__stream_layer_accumulate "kotlinIoTextBytes" "$SL_KIO_TEXT"

# 4B. kotlin.io stream/reader/writer accessors on any File receiver.
SL_KIO_ACCESS=$(__stream_layer_scan \
    '\.(bufferedReader|bufferedWriter|printWriter|inputStream|outputStream)\s*\(\s*\)' \
    'kotlin.io-accessor')
__stream_layer_accumulate "kotlinIoAccessor" "$SL_KIO_ACCESS"

# 4C. JDK NIO file helpers (Files.* convenience methods).
SL_NIO_FILES=$(__stream_layer_scan \
    'java\.nio\.file\.Files\.(readAllBytes|write|newInputStream|newOutputStream|newBufferedReader|newBufferedWriter|lines|readString|writeString)\b' \
    'java.nio.file.Files')
__stream_layer_accumulate "javaNioFiles" "$SL_NIO_FILES"

# 4D. Reader/Writer/PrintWriter/Scanner/RandomAccessFile over a File.
SL_READER_WRITER=$(__stream_layer_scan \
    'new\s+(FileReader|FileWriter|PrintWriter|Scanner|RandomAccessFile)\s*\(' \
    'jdk-reader-writer')
__stream_layer_accumulate "jdkReaderWriter" "$SL_READER_WRITER"

# 4E. Image decode by path.
SL_BITMAP_DECODE=$(__stream_layer_scan \
    'BitmapFactory\.decodeFile\s*\(' \
    'BitmapFactory.decodeFile')
__stream_layer_accumulate "bitmapDecodeFile" "$SL_BITMAP_DECODE"

# 4F. Bitmap compress into a java.io.FileOutputStream sink.
SL_BITMAP_COMPRESS=$(__stream_layer_scan \
    '\.compress\s*\([^)]*new\s+java\.io\.FileOutputStream' \
    'Bitmap.compress->java.io.FileOutputStream')
__stream_layer_accumulate "bitmapCompressJavaIo" "$SL_BITMAP_COMPRESS"

# 4G. com.good.gd.file.File seeded from Android sandbox roots.
#     Matches both Java (`new com.good.gd.file.File(...)`) and Kotlin
#     (`com.good.gd.file.File(...)` or aliased `GDFile(...)`) forms when
#     the constructor argument references getFilesDir/getCacheDir/etc.
SL_GD_FILE_SANDBOX=$(__stream_layer_scan \
    '(new\s+com\.good\.gd\.file\.File|com\.good\.gd\.file\.File|GDFile)\s*\(\s*[^)]*\b(getFilesDir|getCacheDir|filesDir|cacheDir)\b' \
    'GD File seeded from Android sandbox')
__stream_layer_accumulate "gdFileFromSandbox" "$SL_GD_FILE_SANDBOX"

# -----------------------------------------------------------------------
# 4H. Library-consumed File arguments — hidden java.io sites.
#     These are library APIs that accept a java.io.File (or path string)
#     and construct a java.io stream internally. The Dynamics container is
#     bypassed regardless of the argument's static type.
#
#     Overlaps with existing rules (intentionally NOT re-detected here):
#       - 4A catches ObjectInputStream/ObjectOutputStream over raw
#         java.io.FileInputStream / FileOutputStream, as well as
#         Properties.load/store over raw java.io streams.
#       - 4D catches new RandomAccessFile(File|String, String).
#       - The existing Glide/Picasso/Coil path-load rule catches image
#         loader File/path loads.
#     These are not duplicated under 4H to avoid double-counting.
#
#     See steering/40-secure-file-storage.md §5c "Library-consumed File
#     arguments are hidden java.io sites" for the full catalog.
# -----------------------------------------------------------------------

# 4H.camerax — ImageCapture.OutputFileOptions.Builder(File)
# Filter: drop matches where the captured argument identifier contains
# "stream" (any case) — those are the safe OutputStream overload.
SL_4H_CAMERAX=$(python3 - "$SRC_DIR_MM" <<'PY' 2>/dev/null
import os, re, sys

src_root = sys.argv[1]
pattern = re.compile(r'ImageCapture\.OutputFileOptions\.Builder\s*\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\)')
gd_import = re.compile(r'^\s*import\s+com\.good\.gd\.file\.', re.MULTILINE)

def is_comment(line):
    s = line.lstrip()
    return (not s) or s.startswith('//') or s.startswith('*') or s.startswith('/*')

cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith(('.java', '.kt')):
            continue
        if fn in ('SecureFileIO.kt', 'SecureFileIO.java'):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        if not gd_import.search(text):
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if is_comment(line):
                continue
            m = pattern.search(line)
            if m:
                arg = m.group(1)
                if 'stream' in arg.lower():
                    continue
                print(f'{rel}:{lineno}:camerax-output-file-builder:{line.strip()}')
PY
)
__stream_layer_accumulate "camerax-output-file-builder" "$SL_4H_CAMERAX"

# 4H.mediamuxer — new MediaMuxer(path|file, format)
# Filter: drop matches where the first argument identifier contains
# "fd", "descriptor", or starts with "Fd"/"FD" (FileDescriptor overload).
SL_4H_MEDIAMUXER=$(python3 - "$SRC_DIR_MM" <<'PY' 2>/dev/null
import os, re, sys

src_root = sys.argv[1]
pattern = re.compile(r'new\s+MediaMuxer\s*\(\s*([^,)]+)\s*,')
gd_import = re.compile(r'^\s*import\s+com\.good\.gd\.file\.', re.MULTILINE)
fd_filter = re.compile(r'(?i)\bfd\b|descriptor|^Fd|^FD')

def is_comment(line):
    s = line.lstrip()
    return (not s) or s.startswith('//') or s.startswith('*') or s.startswith('/*')

cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith(('.java', '.kt')):
            continue
        if fn in ('SecureFileIO.kt', 'SecureFileIO.java'):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        if not gd_import.search(text):
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if is_comment(line):
                continue
            m = pattern.search(line)
            if m:
                arg = m.group(1).strip()
                if fd_filter.search(arg):
                    continue
                print(f'{rel}:{lineno}:mediamuxer-file-constructor:{line.strip()}')
PY
)
__stream_layer_accumulate "mediamuxer-file-constructor" "$SL_4H_MEDIAMUXER"

# 4H.mediarecorder — MediaRecorder.setOutputFile/setNextOutputFile(path|file)
# Filter: drop matches where the argument contains fd/descriptor or a bare int.
SL_4H_MEDIARECORDER=$(python3 - "$SRC_DIR_MM" <<'PY' 2>/dev/null
import os, re, sys

src_root = sys.argv[1]
pattern = re.compile(r'\.set(?:Next)?OutputFile\s*\(\s*([^,)]+)')
gd_import = re.compile(r'^\s*import\s+com\.good\.gd\.file\.', re.MULTILINE)
fd_filter = re.compile(r'(?i)\bfd\b|descriptor|parcelFileDescriptor|fileDescriptor')
int_literal = re.compile(r'^\s*[0-9]+\s*$')

def is_comment(line):
    s = line.lstrip()
    return (not s) or s.startswith('//') or s.startswith('*') or s.startswith('/*')

cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith(('.java', '.kt')):
            continue
        if fn in ('SecureFileIO.kt', 'SecureFileIO.java'):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        if not gd_import.search(text):
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if is_comment(line):
                continue
            m = pattern.search(line)
            if not m:
                continue
            arg = m.group(1).strip()
            if fd_filter.search(arg) or int_literal.match(arg):
                continue
            print(f'{rel}:{lineno}:mediarecorder-file-output:{line.strip()}')
PY
)
__stream_layer_accumulate "mediarecorder-file-output" "$SL_4H_MEDIARECORDER"

# 4H.zipfile — new ZipFile(File|String)
# Import-gated: only fires when java.util.zip.ZipFile is in the file's
# import set (avoids false positives from unrelated classes named ZipFile).
SL_4H_ZIPFILE=$(python3 - "$SRC_DIR_MM" <<'PY' 2>/dev/null
import os, re, sys

src_root = sys.argv[1]
fq_pattern = re.compile(r'new\s+java\.util\.zip\.ZipFile\s*\(')
short_pattern = re.compile(r'new\s+ZipFile\s*\(')
zip_import = re.compile(r'^\s*import\s+java\.util\.zip\.ZipFile\b', re.MULTILINE)
gd_import = re.compile(r'^\s*import\s+com\.good\.gd\.file\.', re.MULTILINE)

def is_comment(line):
    s = line.lstrip()
    return (not s) or s.startswith('//') or s.startswith('*') or s.startswith('/*')

cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith(('.java', '.kt')):
            continue
        if fn in ('SecureFileIO.kt', 'SecureFileIO.java'):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        if not gd_import.search(text):
            continue
        has_zip_import = zip_import.search(text)
        for lineno, line in enumerate(text.splitlines(), start=1):
            if is_comment(line):
                continue
            if fq_pattern.search(line):
                print(f'{rel}:{lineno}:zipfile-file-constructor:{line.strip()}')
            elif has_zip_import and short_pattern.search(line):
                print(f'{rel}:{lineno}:zipfile-file-constructor:{line.strip()}')
PY
)
__stream_layer_accumulate "zipfile-file-constructor" "$SL_4H_ZIPFILE"

# 4H.exifinterface — new ExifInterface(File|String)
# Import-gated: only fires when androidx.exifinterface.media.ExifInterface
# is in the file's import set.
# Filter: drop matches where the captured argument identifier contains
# "stream" or "inputstream" (any case) — those are the safe InputStream
# overload.
SL_4H_EXIFINTERFACE=$(python3 - "$SRC_DIR_MM" <<'PY' 2>/dev/null
import os, re, sys

src_root = sys.argv[1]
pattern = re.compile(r'new\s+ExifInterface\s*\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\)')
exif_import = re.compile(r'^\s*import\s+androidx\.exifinterface\.media\.ExifInterface\b', re.MULTILINE)
gd_import = re.compile(r'^\s*import\s+com\.good\.gd\.file\.', re.MULTILINE)

def is_comment(line):
    s = line.lstrip()
    return (not s) or s.startswith('//') or s.startswith('*') or s.startswith('/*')

cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith(('.java', '.kt')):
            continue
        if fn in ('SecureFileIO.kt', 'SecureFileIO.java'):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        if not gd_import.search(text):
            continue
        if not exif_import.search(text):
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if is_comment(line):
                continue
            m = pattern.search(line)
            if m:
                arg = m.group(1)
                if 'stream' in arg.lower() or 'inputstream' in arg.lower():
                    continue
                print(f'{rel}:{lineno}:exifinterface-file-constructor:{line.strip()}')
PY
)
__stream_layer_accumulate "exifinterface-file-constructor" "$SL_4H_EXIFINTERFACE"

# 4H.pdfrenderer — ParcelFileDescriptor.open(File, mode) used by PdfRenderer
# Import-gated: only fires when android.graphics.pdf.PdfRenderer is in
# the file's import set (scopes to PDF use).
# Filter: drop matches where the first argument contains "stream".
SL_4H_PDFRENDERER=$(python3 - "$SRC_DIR_MM" <<'PY' 2>/dev/null
import os, re, sys

src_root = sys.argv[1]
pattern = re.compile(r'ParcelFileDescriptor\.open\s*\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*,')
pdf_import = re.compile(r'^\s*import\s+android\.graphics\.pdf\.PdfRenderer\b', re.MULTILINE)
gd_import = re.compile(r'^\s*import\s+com\.good\.gd\.file\.', re.MULTILINE)

def is_comment(line):
    s = line.lstrip()
    return (not s) or s.startswith('//') or s.startswith('*') or s.startswith('/*')

cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith(('.java', '.kt')):
            continue
        if fn in ('SecureFileIO.kt', 'SecureFileIO.java'):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        if not gd_import.search(text):
            continue
        if not pdf_import.search(text):
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if is_comment(line):
                continue
            m = pattern.search(line)
            if m:
                arg = m.group(1)
                if 'stream' in arg.lower():
                    continue
                print(f'{rel}:{lineno}:pdfrenderer-file-backed-pfd:{line.strip()}')
PY
)
__stream_layer_accumulate "pdfrenderer-file-backed-pfd" "$SL_4H_PDFRENDERER"

# -----------------------------------------------------------------------
# 4I. FD-based media writer with sandbox-sourced descriptor provenance.
#     The 4H scanners above let FD-based MediaMuxer / MediaRecorder calls
#     pass because they assume the descriptor comes from a GD-backed
#     source. This second-pass check detects files where both conditions
#     are true:
#       (a) an FD-accepting media writer call is present (MediaMuxer(fd,
#           ...) or MediaRecorder.setOutputFile(fd)), AND
#       (b) the same file derives a FileDescriptor or path from sandbox
#           sources (getFilesDir, getCacheDir, openFileOutput,
#           createTempFile, ParcelFileDescriptor.open).
#     When both are present the FD is likely sandbox-sourced and the
#     media bytes reside outside the Dynamics container during staging.
#     Routed through fail_or_defer "secureFileStorage".
# -----------------------------------------------------------------------
SL_4I_FD_SANDBOX=$(python3 - "$SRC_DIR_MM" <<'PY' 2>/dev/null
import os, re, sys

src_root = sys.argv[1]
gd_import = re.compile(r'^\s*import\s+com\.good\.gd\.file\.', re.MULTILINE)

fd_media_writer = re.compile(
    r'new\s+MediaMuxer\s*\(\s*[^,)]*\b(?:fd|fileDescriptor|descriptor)\b|'
    r'\.set(?:Next)?OutputFile\s*\(\s*[^,)]*\b(?:fd|fileDescriptor|descriptor)\b',
    re.IGNORECASE
)
sandbox_fd_source = re.compile(
    r'getFilesDir\s*\(|getCacheDir\s*\(|'
    r'openFileOutput\s*\(|createTempFile\s*\(|'
    r'ParcelFileDescriptor\.open\s*\('
)

def is_comment(line):
    s = line.lstrip()
    return (not s) or s.startswith('//') or s.startswith('*') or s.startswith('/*')

cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith(('.java', '.kt')):
            continue
        if fn in ('SecureFileIO.kt', 'SecureFileIO.java'):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        if not gd_import.search(text):
            continue
        has_fd_writer = False
        has_sandbox_source = False
        fd_writer_lines = []
        for lineno, line in enumerate(text.splitlines(), start=1):
            if is_comment(line):
                continue
            if fd_media_writer.search(line):
                has_fd_writer = True
                fd_writer_lines.append((lineno, line.strip()))
            if sandbox_fd_source.search(line):
                has_sandbox_source = True
        if has_fd_writer and has_sandbox_source:
            for lineno, line_text in fd_writer_lines:
                print(f'{rel}:{lineno}:fd-media-sandbox-provenance:{line_text}')
PY
)
__stream_layer_accumulate "fd-media-sandbox-provenance" "$SL_4I_FD_SANDBOX"

STREAM_LAYER_DETAILS_BUFFER=$(printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s" \
    "$SL_KIO_TEXT" "$SL_KIO_ACCESS" "$SL_NIO_FILES" \
    "$SL_READER_WRITER" "$SL_BITMAP_DECODE" "$SL_BITMAP_COMPRESS" \
    "$SL_GD_FILE_SANDBOX" \
    "$SL_4H_CAMERAX" "$SL_4H_MEDIAMUXER" "$SL_4H_MEDIARECORDER" "$SL_4H_ZIPFILE" \
    "$SL_4H_EXIFINTERFACE" "$SL_4H_PDFRENDERER" "$SL_4I_FD_SANDBOX" | sed '/^$/d')

STREAM_LAYER_HITS=$(echo "$STREAM_LAYER_DETAILS_BUFFER" \
    | count_hits_for_domain "secureFileStorage")

if [ "${STREAM_LAYER_HITS:-0}" -gt 0 ]; then
    STREAM_LAYER_FIRST=$(echo "$STREAM_LAYER_DETAILS_BUFFER" | head -5 \
        | awk -F: '{ printf "    %s:%s [%s]\n", $1, $2, $3 }')
    _CURRENT_PHASE="4"
    fail_or_defer "secureFileStorage" "Stream-layer closure failure in $STREAM_LAYER_HITS location(s) [${STREAM_LAYER_DETAIL}] — files importing com.good.gd.file.* still route I/O through Kotlin File extensions (including copy/delete recursion), java.nio.file helpers, FileReader/FileWriter family, BitmapFactory.decodeFile, sandbox-seeded GD File constructors, library-consumed File args (CameraX / MediaMuxer / MediaRecorder / ZipFile / ExifInterface / PdfRenderer), or sandbox-sourced FD media provenance. Calls may compile on com.good.gd.file.File but remain unresolved until replaced with GD streams, GDFileSystem, or SecureFileIO. Native media writers that still require path or file based output must be treated as manual intervention, not sandbox staging — filesDir/cacheDir staging is not an accepted default migration outcome. See steering/40-secure-file-storage.md §5 and §7 for canonical replacements and FD-only decision tree. First sites:
${STREAM_LAYER_FIRST}" \
        "Replace File.readText/readBytes/writeText with com.good.gd.file.FileInputStream + manual read. Replace FileReader/FileWriter with GD stream equivalents. Replace BitmapFactory.decodeFile(path) with BitmapFactory.decodeStream(new com.good.gd.file.FileInputStream(containerPath)). See steering/40-secure-file-storage.md §5."
else
    check_pass "Stream-layer closure clean (no Kotlin File extensions, java.nio.file helpers, FileReader/decodeFile, library-consumed File patterns [4A-4H including 4H.camerax, 4H.mediamuxer, 4H.mediarecorder, 4H.zipfile, 4H.exifinterface, 4H.pdfrenderer], or sandbox-sourced FD media provenance [4I] in files importing com.good.gd.file.*)"
fi

# -----------------------------------------------------------------------
# 4K. Uri.EMPTY / Uri.parse("") in persistent data stores.
#     When a save path is removed without implementing the container-side
#     equivalent, the migration often stores Uri.EMPTY or Uri.parse("") as
#     a placeholder reference. These URIs will never resolve to a file and
#     indicate a broken save round-trip — the user's data is written to the
#     container but unreachable because the stored reference is empty.
#
#     Scoped to files that also reference DataStore, Room, SharedPreferences,
#     or other persistence APIs — raw Uri.EMPTY in a ViewModel that never
#     persists it is not flagged.
#
#     See steering/40-secure-file-storage.md §7a "Secure Container Save
#     Pattern" for the full write-read round-trip guidance.
# -----------------------------------------------------------------------
URI_EMPTY_PERSISTENT_HITS=$(python3 - "$SRC_DIR_MM" <<'PY' 2>/dev/null
import os
import re
import sys

src_root = sys.argv[1]

uri_empty = re.compile(
    r'\bUri\.EMPTY\b|'
    r'Uri\.parse\s*\(\s*""\s*\)|'
    r'Uri\.parse\s*\(\s*"\\s*"\s*\)'
)
persistence_api = re.compile(
    r'DataStore|dataStore|'
    r'SharedPreferences|sharedPreferences|getSharedPreferences|'
    r'@Insert|@Update|@Query|@Entity|@Dao|Room\.|'
    r'\.edit\s*\(\s*\)|putString|putInt|'
    r'preferences\s*\[|'
    r'ProtoDataStore|proto\s*\{|'
    r'\.updateData\s*\{|'
    r'\.emit\s*\(|MutableStateFlow|'
    r'writeToParcel|Parcelable'
)


def is_comment(line):
    s = line.lstrip()
    return (not s) or s.startswith('//') or s.startswith('*') or s.startswith('/*')


cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith(('.java', '.kt')):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        if not uri_empty.search(text):
            continue
        if not persistence_api.search(text):
            continue
        lines = text.splitlines()
        for lineno, line in enumerate(lines, start=1):
            if is_comment(line):
                continue
            if not uri_empty.search(line):
                continue
            start = max(0, lineno - 4)
            end = min(len(lines), lineno + 4)
            window = '\n'.join(lines[start:end])
            if persistence_api.search(window):
                print(f'{rel}:{lineno}:{line.rstrip()}')
PY
)
URI_EMPTY_PERSISTENT_HITS=${URI_EMPTY_PERSISTENT_HITS:-0}
if [ "$URI_EMPTY_PERSISTENT_HITS" -gt 0 ]; then
    _CURRENT_PHASE="4"
    fail_or_defer "secureFileStorage" "Uri.EMPTY or Uri.parse(\"\") stored in persistent data (${URI_EMPTY_PERSISTENT_HITS} location(s)) — this is a broken save round-trip indicator. When external storage write paths are removed, the stored file reference must be replaced with a valid container file:// URI, not an empty placeholder. Files saved with Uri.EMPTY are unreachable by the application. See steering/40-secure-file-storage.md §7a." \
        "Replace Uri.EMPTY with the container-relative path string (e.g. \"saved-documents/report.pdf\") stored directly in the data model. Do NOT construct file:// URIs from GD container paths — they are virtual and will not resolve. Retrieve files via com.good.gd.file.FileInputStream(path). See steering/40-secure-file-storage.md §7a 'Secure Container Save Pattern'."
else
    check_pass "No Uri.EMPTY/Uri.parse(\"\") in persistent data stores (save round-trip references intact)"
fi

# -----------------------------------------------------------------------
# 4M. DocumentFile.fromFile() with GD container paths.
#     DocumentFile.fromFile(gdFile) produces a file:// URI from the
#     GDFile's absolutePath. GD container-relative paths (e.g. "/logs",
#     "/attachments") are virtual — they do not exist on the real Android
#     filesystem. The resulting URI (file:///logs) is invalid for
#     ContentResolver operations: DocumentFile.createFile() returns null
#     or throws, ContentResolver.openOutputStream() throws
#     FileNotFoundException. This compiles cleanly and crashes at runtime.
#
#     Scoped to files importing com.good.gd.file.* — if the file does not
#     use GD file APIs, DocumentFile.fromFile is not a container-path
#     issue. FAILURE — the pattern is always invalid on container paths.
#
#     See steering/40-secure-file-storage.md §10.
# -----------------------------------------------------------------------
DOCFILE_FROM_FILE_GD_HITS=$(python3 - "$SRC_DIR_MM" <<'PY' 2>/dev/null
import os
import re
import sys

src_root = sys.argv[1]
gd_import = re.compile(r"^\s*import\s+com\.good\.gd\.file\.", re.MULTILINE)
docfile_from_file = re.compile(r"DocumentFile\.fromFile\s*\(")


def is_comment(line):
    s = line.lstrip()
    return (not s) or s.startswith("//") or s.startswith("*") or s.startswith("/*")


cwd = os.getcwd()
for dirpath, _, files in os.walk(src_root):
    for fn in files:
        if not fn.endswith((".java", ".kt")):
            continue
        if fn in ("SecureFileIO.kt", "SecureFileIO.java"):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        try:
            rel = os.path.relpath(path, cwd)
        except ValueError:
            rel = path
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        if not gd_import.search(text):
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if is_comment(line):
                continue
            if docfile_from_file.search(line):
                print(f"{rel}:{lineno}:{line.rstrip()}")
PY
)
DOCFILE_FROM_FILE_GD_COUNT=$(echo "$DOCFILE_FROM_FILE_GD_HITS" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "${DOCFILE_FROM_FILE_GD_COUNT:-0}" -gt 0 ]; then
    _CURRENT_PHASE="4"
    fail_or_defer "secureFileStorage" "[FS-DOCFILE-001] DocumentFile.fromFile() used in ${DOCFILE_FROM_FILE_GD_COUNT} file(s) importing com.good.gd.file.* — DocumentFile.fromFile() produces a file:// URI from the GDFile absolutePath. GD container-relative paths are virtual and do not exist on the real Android filesystem; the resulting URI is always invalid for ContentResolver operations. Replace DocumentFile-based I/O with direct GD FileInputStream/FileOutputStream. See steering/40-secure-file-storage.md §10." \
        "Replace DocumentFile.fromFile(gdFile) with direct GD stream access: new com.good.gd.file.FileOutputStream(path) / new com.good.gd.file.FileInputStream(path). Do not wrap GD files with DocumentFile."
else
    check_pass "No DocumentFile.fromFile() usage in files importing com.good.gd.file.* (FS-DOCFILE-001)"
fi

echo ""
