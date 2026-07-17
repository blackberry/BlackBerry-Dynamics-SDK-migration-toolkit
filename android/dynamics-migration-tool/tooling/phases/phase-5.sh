# BlackBerry Dynamics Migration — validator phase 5
#
# Sourced by tooling/validate.sh once should_run_phase "5" passes.
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
    # Phase 5: SQL Database
    # ========================================
    echo "Phase 5: SQL Database"
    echo "-----------------------------------------"

GD_SQL_IMPORTS=$(grep -rnE "import[[:space:]]+com\.good\.gd\.database\.sqlite\." "$SRC_DIR_MM/" 2>/dev/null | wc -l | tr -d ' ')
# Use ERE (-E): BSD grep BRE does not treat + as "one or more", so -rl alone
# would never match "import ... +" patterns on macOS.
GD_SQL_IMPORT_FILES="$(grep -Erl "import[[:space:]]+com\.good\.gd\.database\.sqlite\." "$SRC_DIR_MM/" 2>/dev/null || true)"
GD_SQL_USAGE_FILES=0
if [ -n "$GD_SQL_IMPORT_FILES" ]; then
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        FILE_USAGE=$(grep -nE "SQLite(OpenHelper|Database)" "$f" 2>/dev/null \
            | grep -vE "^[0-9]+:[[:space:]]*import " \
            | wc -l | tr -d ' ')
        if [ "$FILE_USAGE" -gt 0 ]; then
            GD_SQL_USAGE_FILES=$((GD_SQL_USAGE_FILES + 1))
        fi
    done <<EOF
$GD_SQL_IMPORT_FILES
EOF
fi
# Exclude: exception classes (no Dynamics equivalent), bridge adapter files (intentionally use Android types),
# external database access for backup import (reads standard SQLite files, not the app's own database),
# and the SQLiteDatabase import used solely for opening external backup files
STD_SQL=$(grep -rn "android.database.sqlite" "$SRC_DIR_MM/" 2>/dev/null \
    | strip_audit_noise \
    | grep -v "SQLiteTransactionListener" \
    | grep -v "SQLiteBlobTooBigException" \
    | grep -v "SQLiteConstraintException" \
    | grep -v "GDSupportSQLite" \
    | grep -v "SQLiteDatabase\.openDatabase" \
    | grep -v "import android.database.sqlite.SQLiteDatabase$" \
    | count_hits_for_domain "secureSql")

# Room (androidx.room.*) detection. Room is implemented on top of
# SupportSQLiteOpenHelper; without a Dynamics-backed bridge factory it
# stores data in plaintext in the app data directory. This is the gap
# Secure Camera's first migration pass missed entirely.
ROOM_FILES=$(grep -rl "androidx\.room\." "$SRC_DIR_MM/" 2>/dev/null || true)
ROOM_FILE_COUNT=0
if [ -n "$ROOM_FILES" ]; then
    ROOM_FILE_COUNT=$(echo "$ROOM_FILES" | grep -c . || true)
fi

# A bridge factory is a SupportSQLiteOpenHelper.Factory implementation
# that delegates to com.good.gd.database.sqlite.* (i.e. the Dynamics
# secure SQLite). Steering 41-secure-storage-sql.md describes the pattern.
BRIDGE_FACTORY_FILES=0
BRIDGE_FACTORY_LIST=$(grep -rl "SupportSQLiteOpenHelper" "$SRC_DIR_MM/" 2>/dev/null || true)
ROOM_DELEGATE_FACTORY_FILES=0
if [ -n "$BRIDGE_FACTORY_LIST" ]; then
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if grep -q "com\.good\.gd\.database\.sqlite" "$f" 2>/dev/null; then
            BRIDGE_FACTORY_FILES=$((BRIDGE_FACTORY_FILES + 1))
        fi
        if file_has_noncomment_ere_match "$f" "FrameworkSQLiteOpenHelperFactory"; then
            ROOM_DELEGATE_FACTORY_FILES=$((ROOM_DELEGATE_FACTORY_FILES + 1))
        fi
    done <<< "$BRIDGE_FACTORY_LIST"
fi
[ "$GD_SQL_IMPORTS" -gt 0 ] && check_pass "Dynamics SQLite imports present ($GD_SQL_IMPORTS)" || check_warn "Dynamics SQLite not found (may not apply)"
if [ "$GD_SQL_IMPORTS" -gt 0 ] && [ "$GD_SQL_USAGE_FILES" -eq 0 ]; then
    fail_or_defer "secureSql" "Dynamics SQLite imports were found but no non-import SQLiteOpenHelper/SQLiteDatabase usage exists — scaffolding-only migration detected"
elif [ "$GD_SQL_USAGE_FILES" -gt 0 ]; then
    check_pass "Dynamics SQLite classes used beyond imports ($GD_SQL_USAGE_FILES file(s))"
fi
if [ "$STD_SQL" -gt 0 ]; then
    fail_or_defer "secureSql" "Standard SQLite still present ($STD_SQL) — re-run prompt 04 (SQL migration)"
else
    check_pass "Standard SQLite removed"
fi

if [ "$ROOM_FILE_COUNT" -gt 0 ]; then
    if [ "$BRIDGE_FACTORY_FILES" -gt 0 ]; then
        check_pass "Room (androidx.room) wired through Dynamics bridge factory ($BRIDGE_FACTORY_FILES bridge file(s) backing $ROOM_FILE_COUNT Room file(s))"
        if [ "$ROOM_DELEGATE_FACTORY_FILES" -gt 0 ]; then
            fail_or_defer "secureSql" "SupportSQLiteOpenHelper bridge file(s) still reference FrameworkSQLiteOpenHelperFactory ($ROOM_DELEGATE_FACTORY_FILES file(s)) — this is scaffolding and keeps Room on standard SQLite"
        fi
    else
        fail_or_defer "secureSql" "Room (androidx.room) used in $ROOM_FILE_COUNT file(s) WITHOUT a Dynamics bridge factory — database is in plaintext outside the secure container. Implement SupportSQLiteOpenHelper.Factory backed by com.good.gd.database.sqlite.* (see steering/41-secure-storage-sql.md, 'Room Bridge' section)."
    fi
else
    check_pass "No Room (androidx.room) usage detected"
fi
echo ""
