#!/bin/bash

# BlackBerry Dynamics Migration Tool — Orchestration Script
#
# This script guides a developer through the complete migration of an
# Android app to BlackBerry Dynamics. It verifies the project structure,
# optionally installs steering files for Kiro, and provides the migration
# prompt to paste into your AI agent.
#
# Usage:
#   ./dynamics-migration-tool/tooling/migrate.sh [OPTIONS]
#
# Options:
#   --agent kiro     Install steering files into .kiro/steering/
#   --agent cursor   Install rules into .cursor/rules/
#   --agent codex    Install Codex project instructions into AGENTS.md
#   --agent generic  Print instructions for any AI agent (default)
#   --dry-run        Show what would be done without making changes
#   --list-prompts   Show all migration prompts with file paths
#   --with-diagrams  Include optional prompt 00b in suggested run order
#   --help           Show this help message

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

AGENT="generic"
DRY_RUN=false
LIST_PROMPTS=false
WITH_DIAGRAMS=false
RESUME_MODE=false
PRINT_KICKSTART=false
APP_MODULE_OVERRIDE=""
# shellcheck source=lib/toolkit-version.sh
. "$SCRIPT_DIR/lib/toolkit-version.sh"
toolkit_version_load "$TOOL_DIR"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --agent)
            AGENT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --list-prompts)
            LIST_PROMPTS=true
            shift
            ;;
        --with-diagrams)
            WITH_DIAGRAMS=true
            shift
            ;;
        --resume)
            RESUME_MODE=true
            shift
            ;;
        --print-kickstart)
            PRINT_KICKSTART=true
            shift
            ;;
        --app-module)
            APP_MODULE_OVERRIDE="$2"
            shift 2
            ;;
        --app-module=*)
            APP_MODULE_OVERRIDE="${1#--app-module=}"
            shift
            ;;
        --help)
            echo "Usage: ./dynamics-migration-tool/tooling/migrate.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --agent kiro      Install steering files into .kiro/steering/"
            echo "  --agent cursor    Install rules into .cursor/rules/"
            echo "  --agent codex     Install Codex instructions into AGENTS.md"
            echo "  --agent generic   Print instructions for any AI agent (default)"
            echo "  --dry-run         Show what would be done without making changes"
            echo "  --list-prompts    Show all migration prompts with file paths"
            echo "  --with-diagrams   Include optional prompt 00b in suggested run order"
            echo "  --resume          Resume from last completed prompt (reads bootstrap.json)"
            echo "  --print-kickstart Print only the pasteable kickoff prompt and exit"
            echo "  --app-module <n>  Select primary application module by repo-relative"
            echo "                    path (e.g. 'app-primary'). Required for"
            echo "                    multi-application projects with no canonical"
            echo "                    'app/' module; passed through to bootstrap.sh."
            echo "  --version         Show toolkit version"
            echo "  --help            Show this help message"
            echo ""
            echo "Prompts (use --list-prompts to see full paths):"
            echo "  00pre Bootstrap (STOP — asks for GDApplicationID + permissions confirm; probes env/network/SDK)"
            echo "  00    Analyze app (no code changes — produces migration plan)"
            echo "  00b   OPTIONAL: Generate architecture diagrams (no code changes)"
            echo "  01    Gradle integration (SDK dependency, minSdk, Maven repo)"
            echo "  02    Create settings.json (writes UEM values captured in 00pre)"
            echo "  03    Add Dynamics authorization (Application class, GDStateListener, manifest)"
            echo "  03b   Authorization deferral audit (ViewModels, Fragments, widgets)"
            echo "  04    Secure SQLite (android.database.sqlite → com.good.gd.database.sqlite)"
            echo "  05a   Secure filesystem core I/O (writers/readers)"
            echo "  05b   Secure filesystem UI reader closure"
            echo "  05z   Secure filesystem SharedPreferences + closure"
            echo "  06    Secure networking (HttpURLConnection → GDHttpClient, Socket → GDSocket)"
            echo "  07    WebView → BBWebView (if applicable)"
            echo "  08    ICC / TransferFileService (if applicable)"
            echo "  09    Migrate sensitive UI widgets (EditText → GDEditText)"
            echo "  11    Push channel / FCM hardening (if applicable)"
            echo "  03c   Background Authorize hardening (if applicable)"
            echo "  10    Generate migration report (dynamics-migration-tool/output/)"
            echo "  12    OPTIONAL: Migration run retrospective (after 10; asks developer first)"
            exit 0
            ;;
        --version)
            toolkit_version_print
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage"
            exit 1
            ;;
    esac
done

case "$AGENT" in
    kiro|cursor|codex|generic)
        ;;
    *)
        echo "Unknown agent: $AGENT"
        echo "Supported agents: kiro, cursor, codex, generic"
        exit 1
        ;;
esac

PROMPT_ORDER_DEFAULT="00pre, 00, 01, 02, 03, 03b, 04, 05a, 05b, 05c, 05z, 06, 07, 08, 09, 11, 03c, 10"
PROMPT_ORDER_WITH_DIAGRAMS="00pre, 00, 00b, 01, 02, 03, 03b, 04, 05a, 05b, 05c, 05z, 06, 07, 08, 09, 11, 03c, 10"
if [ "$WITH_DIAGRAMS" = true ]; then
    PROMPT_ORDER="$PROMPT_ORDER_WITH_DIAGRAMS"
    POST_ANALYZE_NOTE="After prompt 00, run 00b-generate-architecture-diagrams.md (optional diagnostics enabled by --with-diagrams), then proceed through each applicable prompt sequentially."
else
    PROMPT_ORDER="$PROMPT_ORDER_DEFAULT"
    POST_ANALYZE_NOTE="After prompt 00, proceed through each applicable prompt sequentially. Prompt 00b (architecture diagrams) is optional and can be run manually at any point after prompt 00."
fi

RESUME_NOTE=""
if [ "$RESUME_MODE" = true ]; then
    BOOTSTRAP_FILE="$TOOL_DIR/output/bootstrap.json"
    if [ ! -f "$BOOTSTRAP_FILE" ]; then
        echo "❌ --resume requires bootstrap.json at $BOOTSTRAP_FILE"
        echo "   Run prompt 00pre first to initialize the migration."
        exit 1
    fi

    RESUME_INFO=$(python3 - "$BOOTSTRAP_FILE" "$PROMPT_ORDER" <<'PY'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

canonical_str = sys.argv[2]
canonical = [p.strip() for p in canonical_str.split(",")]

executed = {}
for ep in data.get("executedPrompts", []):
    pid = ep.get("promptId", "")
    executed[pid] = ep.get("status", "unknown")

completed = []
failed = []
resume_from = None
remaining = []

for pid in canonical:
    status = executed.get(pid)
    if status == "completed" or status == "skipped":
        completed.append(pid)
    elif status in ("failed", "aborted"):
        failed.append(pid)
        if resume_from is None:
            resume_from = pid
        remaining.append(pid)
    else:
        if resume_from is None:
            resume_from = pid
        remaining.append(pid)

if resume_from is None:
    print("ALL_DONE")
else:
    remaining_str = ", ".join(remaining)
    completed_str = ", ".join(completed) if completed else "none"
    failed_str = ", ".join(failed) if failed else "none"
    print(f"{resume_from}|||{remaining_str}|||{completed_str}|||{failed_str}")
PY
    )

    if [ "$RESUME_INFO" = "ALL_DONE" ]; then
        echo ""
        echo "✅ All prompts are already completed. Nothing to resume."
        echo "   Run validate.sh for a final check, or prompt 12 for a retrospective."
        exit 0
    fi

    RESUME_FROM="${RESUME_INFO%%|||*}"
    RESUME_REST="${RESUME_INFO#*|||}"
    REMAINING_PROMPTS="${RESUME_REST%%|||*}"
    RESUME_REST2="${RESUME_REST#*|||}"
    COMPLETED_PROMPTS="${RESUME_REST2%%|||*}"
    FAILED_PROMPTS="${RESUME_REST2##*|||}"

    PROMPT_ORDER="$REMAINING_PROMPTS"

    if [ "$PRINT_KICKSTART" = false ]; then
        echo ""
        echo "╔══════════════════════════════════════════════╗"
        echo "║      Resuming Migration                      ║"
        echo "╚══════════════════════════════════════════════╝"
        echo ""
        echo "  Completed: $COMPLETED_PROMPTS"
        if [ "$FAILED_PROMPTS" != "none" ]; then
            echo "  Failed:    $FAILED_PROMPTS"
        fi
        echo "  Resuming:  $RESUME_FROM"
        echo "  Remaining: $REMAINING_PROMPTS"
        echo ""
    fi

    RESUME_NOTE="RESUME CONTEXT: This is a resumed migration. Prompts already completed: $COMPLETED_PROMPTS. Resume from prompt $RESUME_FROM. The remaining prompts to execute are: $REMAINING_PROMPTS. Read bootstrap.json for the full migration state. Do NOT re-run completed prompts."
fi

POST_REPORT_NOTE="After prompt 10 completes successfully, offer prompt 12-generate-migration-retrospective.md: ask whether to generate the optional migration retrospective (migration-retrospective.md). Run prompt 12 only if the developer opts in."

IMPL_FIRST_NOTE="CRITICAL - Implementation Contract:
- You are the migration developer. Implement the Dynamics migration; do not only report findings and stop.
- When validation reports remaining findings (java.io.File construction, SharedPreferences, external storage, native file I/O), fix them using the documented replacements in the prompt steering and API catalog.
- Use exact API names from prompt templates and steering/14-api-provenance-and-replacement-catalog.md. Do not substitute similar-sounding APIs.
- Replace java.io.File with com.good.gd.file.File where secure storage is required. Implement SecurePreferencesHelper for SharedPreferences runtime usage. Remove or replace external storage writes with container-backed flows.
- Never replace a removed API with a no-op stub (Toast-only body, @Suppress(\"UNUSED_PARAMETER\")) while leaving the calling UI intact. That is a silent functional regression, not a migration.
- If a method still has callers, implement the secure replacement (for example ICC TransferFile for ACTION_VIEW) or remove the UI elements that call it.
- Preserve the full round trip when replacing external storage writes: write location, retrieval URI/path, read-back logic, and UI strings must all update together.
- GD file APIs are not behavioral drop-ins for java.io. Read each prompt's steering pitfalls before migrating, for example guard listFiles()/list() with exists().
- If a single waivable call site has no feasible automated fix, record it in manualTodos and continue to the next domain. Do not convert non-waivable domains or validator security blockers into manualTodos; fix them or stop for a developer security decision where the prompt explicitly permits it."

CLOSURE_NOTE="Closure Ledger Contract:
- For prompts 04, 05z, 06, 08, and 09, enumerate every call site from migration-analysis.json before editing.
- Write final dispositions[] entries in dynamics-migration-tool/output/migration-plan-state.json only after the corresponding call site is actually migrated or removed.
- Prompt 10 checks those entries as the final closure gate. If final closure rejects a removed disposition because the method still has callers, reclassify as migrated and implement the secure replacement.
- Do not edit bootstrap.json deferredDomains[] - only the developer may add deferrals."

RECOVERY_NOTE="Validation and Recorder Recovery:
- If validate.sh or record-prompt-execution.sh fails, fix the underlying source, generated artifact, or closure-ledger evidence and rerun the same validation/recorder command.
- When stuck, run dynamics-migration-tool/tooling/progress.sh, then repair the owning prompt/domain. Do not thrash prompt 10 or re-run unrelated prompts to clear a gate.
- If the recorder/validator prints ESCALATION REQUIRED (exit code 3), STOP and ask the developer. Do not keep retrying the same failure.
- Optional bounded repair for controlled prompts (01,02,03,03b,04,05a,05b,05c,05z,06,07,08,09,11,03c): bash dynamics-migration-tool/tooling/repair-orchestrator.sh --prompt-id <id>, obey exit 0/1/3, and read steering/96-repair-loop-conduct.md. Prompt 10 stays recorder-owned.
- Do not patch bootstrap.json.executedPrompts[], bootstrap.json.deferredDomains[], migration-plan-state.json, or validator output by hand to bypass a gate."

if [ -n "$RESUME_NOTE" ]; then
    IMPL_FIRST_NOTE="$IMPL_FIRST_NOTE

$RESUME_NOTE"
fi

print_kickstart_body() {
    case "$AGENT" in
        kiro)
            echo "Read the migration prompts in dynamics-migration-tool/prompts/ and execute them in order ($PROMPT_ORDER) against this project."
            echo "For each prompt, also read its referenced steering files in dynamics-migration-tool/steering/ - especially 03-implementation-first-conduct.md, 14-api-provenance-and-replacement-catalog.md, and 96-repair-loop-conduct.md (optional bounded repair lane)."
            ;;
        cursor)
            echo "Read the migration prompts in @dynamics-migration-tool/prompts and execute them in order ($PROMPT_ORDER) against this project."
            echo "For each prompt, also read its referenced steering files in @dynamics-migration-tool/steering — especially 03-implementation-first-conduct.md, 14-api-provenance-and-replacement-catalog.md, and 96-repair-loop-conduct.md (optional bounded repair lane)."
            ;;
        codex)
            echo "Read AGENTS.md and follow the BlackBerry Dynamics Migration Tool Instructions section."
            echo ""
            echo "Then read the migration prompts in dynamics-migration-tool/prompts/ and execute them in order ($PROMPT_ORDER) against this project."
            echo "For each prompt, also read its referenced steering files in dynamics-migration-tool/steering/ - especially 03-implementation-first-conduct.md, 14-api-provenance-and-replacement-catalog.md, and 96-repair-loop-conduct.md (optional bounded repair lane)."
            ;;
        generic)
            echo "Read the migration prompts in dynamics-migration-tool/prompts/ and execute them in order ($PROMPT_ORDER) against this project."
            echo "For each prompt, also read its referenced steering files in dynamics-migration-tool/steering/ - especially 03-implementation-first-conduct.md, 14-api-provenance-and-replacement-catalog.md, and 96-repair-loop-conduct.md (optional bounded repair lane)."
            ;;
    esac
    echo ""
    echo "$IMPL_FIRST_NOTE"
    echo ""
    echo "$CLOSURE_NOTE"
    echo ""
    echo "$RECOVERY_NOTE"
    echo ""
    echo "Start with 00pre-bootstrap.md (IDE permissions, GDApplicationID/Version, attestations, backup branch, SDK probes). Do not proceed until it writes dynamics-migration-tool/output/bootstrap.json with sdkProbe.dynamicsSdkResolvedVersion populated."
    echo ""
    echo "Then run 00-analyze-app.md - read all source files, produce the migration plan including the binding executionPlan[], and show it to me. Do not make source changes until I review the plan and confirm you should proceed. $POST_ANALYZE_NOTE Each prompt MUST end by calling dynamics-migration-tool/tooling/record-prompt-execution.sh so the executedPrompts[] audit in bootstrap.json stays current."
    echo ""
    echo "Acceptance Contract: after prompts 00pre-09, 11, and 03c are complete, run prompt 10. It hard-gates executionPlan[] against executedPrompts[] and deferredDomains[] in bootstrap.json; if any applicable domain lacks both a completed prompt and a developer deferral, it aborts and names the prompts to re-run. Only after the gate passes does it write migration-report.json. The recorder call runs the full validation sweep and refreshes the report's validation fields."
    echo ""
    echo "$POST_REPORT_NOTE"
}

if [ "$PRINT_KICKSTART" = true ]; then
    print_kickstart_body
    exit 0
fi

write_codex_agents_section() {
    local agents_file="$PROJECT_ROOT/AGENTS.md"
    local tmp_file
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/dynamics-agents.XXXXXX")"

    if [ -f "$agents_file" ]; then
        awk '
            /^<!-- BEGIN BB_DYNAMICS_MIGRATION_CODEX -->$/ { skip = 1; next }
            /^<!-- END BB_DYNAMICS_MIGRATION_CODEX -->$/ { skip = 0; next }
            skip != 1 { print }
        ' "$agents_file" > "$tmp_file"
        if [ -s "$tmp_file" ] && [ "$(tail -c 1 "$tmp_file" 2>/dev/null)" != "" ]; then
            printf "\n" >> "$tmp_file"
        fi
        printf "\n" >> "$tmp_file"
    fi

    cat >> "$tmp_file" <<'EOF'
<!-- BEGIN BB_DYNAMICS_MIGRATION_CODEX -->
# BlackBerry Dynamics Migration Tool Instructions

Use these instructions when running the Android Dynamics migration in this
repository.

## Required Context

Before editing source, read:
- `dynamics-migration-tool/steering/00-context.md`
- `dynamics-migration-tool/steering/06-inline-migration-comments.md`
- the prompt file currently being executed from `dynamics-migration-tool/prompts/`
- every steering file named by that prompt

Do not invent Dynamics APIs. Use only APIs documented in
`dynamics-migration-tool/steering/14-api-provenance-and-replacement-catalog.md`
and public BlackBerry Dynamics SDK documentation.

## Prompt Order

Execute prompts in this exact default order:
`00pre`, `00`, `01`, `02`, `03`, `03b`, `04`, `05a`, `05b`, `05c`, `05z`,
`06`, `07`, `08`, `09`, `11`, `03c`, `10`.

Optional after prompt 10:
- `12` (`12-generate-migration-retrospective.md`) — asks the developer
  whether to generate `output/migration-retrospective.md`; no source changes.

Optional diagnostics:
- `00b` (`00b-generate-architecture-diagrams.md`) is optional and may be
  run manually after `00`, or included automatically by running
  `migrate.sh --with-diagrams`.

Start with `dynamics-migration-tool/prompts/00pre-bootstrap.md`. Do not proceed
past 00pre until `dynamics-migration-tool/output/bootstrap.json` exists and
`sdkProbe.dynamicsSdkResolvedVersion` is populated.

At the end of every prompt, run
`dynamics-migration-tool/tooling/record-prompt-execution.sh` with the prompt's
id so `bootstrap.json.executedPrompts[]` stays current. Do not edit
`executedPrompts[]` directly.

## Implementation-First Principle (CRITICAL)

You are the migration developer. Your job is to IMPLEMENT the Dynamics
migration, not to flag findings and stop. When the validator reports
remaining findings (external storage, java.io.File construction,
SharedPreferences, native file I/O), your response is to FIX them using
the documented replacements in the API catalog and steering files.

- Replace `java.io.File` with `com.good.gd.file.File`.
- Replace `java.io.FileInputStream/FileOutputStream` with
  `com.good.gd.file.FileInputStream/FileOutputStream`.
- Replace external storage APIs with container-relative paths or
  remove the public-storage feature.
- Implement `SecurePreferencesHelper` for SharedPreferences runtime usage.
- Replace native POSIX file I/O with `GD_fopen`/`GD_UNISTD_open`.

Do NOT stop and report "this needs product/security decisions" for
findings that have documented replacements. Only pause for genuine
ambiguity (e.g., two viable redesigns with different UX trade-offs).

If a single call site has no feasible fix, record it in manualTodos
and CONTINUE to the next domain. Do not abandon the migration.

## Migration Rules

- Preserve every `[BB_DYNAMICS-MIGRATION]` inline audit comment.
- Do not edit `bootstrap.json.deferredDomains[]`; only the developer may add
  deferrals.
- Prompt 03 uses `bootstrap.json.processModel`: `main` Activities require
  `activityInit()`, and `auxiliary` Activities must not call it.
- Prompt 08 must not stage secure attachments outside the Dynamics container.
- Prompt 10 must not write `migration-report.json` until its execution-plan
  gate passes.

## Validation

After prompt 10, run:
- `dynamics-migration-tool/tooling/validate.sh`

When the validator reports failures, FIX the underlying code and re-run
the relevant prompt. Do not report the failure as a blocker — implement
the fix.

When stuck: run `dynamics-migration-tool/tooling/progress.sh`, repair the
owning prompt/domain, and do not thrash prompt 10. On
`ESCALATION REQUIRED` (exit 3), stop and ask the developer. Optional
bounded repair for controlled prompts:
`bash dynamics-migration-tool/tooling/repair-orchestrator.sh --prompt-id <id>`
(see `steering/96-repair-loop-conduct.md`). Prompt 10 remains recorder-owned.
<!-- END BB_DYNAMICS_MIGRATION_CODEX -->
EOF

    mv "$tmp_file" "$agents_file"
}

echo "========================================="
echo "BlackBerry Dynamics Migration Tool"
echo "========================================="
echo ""
echo "Toolkit Version: $TOOL_VERSION"
echo "Supported Dynamics SDK: $SUPPORTED_SDK_VERSION"
echo "Project: $PROJECT_ROOT"
echo "Agent:   $AGENT"
echo "00b diagrams: $([ "$WITH_DIAGRAMS" = true ] && echo "enabled (opt-in path)" || echo "optional/manual (default path)")"
echo ""

# =========================================
# Step 1: Verify project structure
# =========================================
echo "Step 1: Checking project structure..."
echo "-----------------------------------------"

ERRORS=0

# Resolve the primary app module via the module map. If the bootstrap
# has already run, output/module-map.json exists and is authoritative;
# otherwise the accessor library synthesizes a single-module fallback
# (which fails loudly only if there is no app/ directory either).
. "$SCRIPT_DIR/lib/module-map.sh"

cd "$PROJECT_ROOT"

# For multi-app projects with no map yet, suggest running bootstrap
# (which is the part of the toolkit that resolves --app-module).
if [ ! -f "$(mm_module_map_path)" ]; then
    if [ ! -f "$PROJECT_ROOT/app/build.gradle" ] && [ ! -f "$PROJECT_ROOT/app/build.gradle.kts" ]; then
        # No map AND no app/ directory: this is a multi-module project
        # that hasn't had bootstrap run yet. Tell the user how to proceed.
        SETTINGS_FILE=""
        for cand in settings.gradle.kts settings.gradle; do
            [ -f "$PROJECT_ROOT/$cand" ] && SETTINGS_FILE="$cand" && break
        done
        if [ -n "$SETTINGS_FILE" ]; then
            echo "❌ No 'app/' module and no module map yet."
            echo "   This appears to be a multi-module project. Run the bootstrap"
            echo "   first to discover the project shape:"
            echo ""
            echo "     bash dynamics-migration-tool/tooling/bootstrap.sh probe ${APP_MODULE_OVERRIDE:+--app-module $APP_MODULE_OVERRIDE}"
            echo ""
            echo "   For projects with multiple application modules, supply"
            echo "   --app-module <name> on that command line."
            exit 1
        fi
        echo "❌ No app/build.gradle found — is this an Android project?"
        exit 1
    fi
fi

if ! mm_load 2>/dev/null; then
    echo "❌ Could not establish project shape — neither output/module-map.json"
    echo "   nor a recognizable app/ directory was found."
    exit 1
fi

PRIMARY_PATH="$(mm_primary_path)"
PRIMARY_BUILD="$(mm_primary_build_file)"

if [ ! -f "$PROJECT_ROOT/$PRIMARY_BUILD" ]; then
    echo "❌ Primary app module build file missing: $PRIMARY_BUILD"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ Android app module found at $PRIMARY_PATH"
fi

if [ ! -f "$PROJECT_ROOT/build.gradle" ] && [ ! -f "$PROJECT_ROOT/build.gradle.kts" ]; then
    echo "❌ No root build.gradle found"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ Root build.gradle found"
fi

# Source root presence: as long as at least one in-scope module has a
# java/ or kotlin/ source root, we're good. Single-module fallback always
# yields app/src/main/java when present.
SOURCE_ROOT_FOUND=false
while IFS= read -r root; do
    [ -z "$root" ] && continue
    if [ -d "$PROJECT_ROOT/$root" ]; then
        SOURCE_ROOT_FOUND=true
        break
    fi
done <<EOF
$(mm_in_scope_source_roots 2>/dev/null)
EOF

if [ "$SOURCE_ROOT_FOUND" = "true" ]; then
    echo "✅ Source directory found"
else
    echo "❌ No source directory found under $PRIMARY_PATH/src/*/java or .../kotlin"
    ERRORS=$((ERRORS + 1))
fi

# Manifest presence: at least one of the in-scope manifests must exist.
MANIFEST_FOUND=false
while IFS= read -r mf; do
    [ -z "$mf" ] && continue
    if [ -f "$PROJECT_ROOT/$mf" ]; then
        MANIFEST_FOUND=true
        break
    fi
done <<EOF
$(mm_in_scope_manifests 2>/dev/null)
EOF

if [ "$MANIFEST_FOUND" = "true" ]; then
    echo "✅ AndroidManifest.xml found"
else
    echo "❌ No AndroidManifest.xml found in any in-scope source set"
    ERRORS=$((ERRORS + 1))
fi

if [ $ERRORS -gt 0 ]; then
    echo ""
    echo "❌ Project structure check failed ($ERRORS errors)"
    echo "   Make sure you run this from your Android project root."
    exit 1
fi

# Capture the pre-migration baseline (git HEAD + timestamp) once for optional
# change-driven validation diagnostics. Idempotent: only initializes if no
# checkpoint exists, so re-running migrate.sh mid-migration never resets the
# baseline. Best effort — diagnostics degrade safely if absent.
CHANGED_FILES_SH="$SCRIPT_DIR/lib/changed-files.sh"
VALIDATION_CHECKPOINT="$TOOL_DIR/output/.validation-checkpoint.json"
if [ "$DRY_RUN" = false ] && [ -f "$CHANGED_FILES_SH" ] && [ ! -f "$VALIDATION_CHECKPOINT" ]; then
    (cd "$PROJECT_ROOT" && bash "$CHANGED_FILES_SH" baseline-write) >/dev/null 2>&1 || true
fi

echo ""

# =========================================
# Step 2: Check for existing Dynamics integration
# =========================================
echo "Step 2: Checking for existing Dynamics integration..."
echo "-----------------------------------------"

ALREADY_MIGRATED=false

# Scan every in-scope source root (primary + libraries) for existing
# Dynamics API usage. Single-module projects still see only one root
# (app/src/main/java) and the message is identical to the old check.
while IFS= read -r root; do
    [ -z "$root" ] && continue
    [ ! -d "$PROJECT_ROOT/$root" ] && continue
    if grep -rq "com.good.gd" "$PROJECT_ROOT/$root" 2>/dev/null; then
        ALREADY_MIGRATED=true
        break
    fi
done <<EOF
$(mm_in_scope_source_roots 2>/dev/null)
EOF

if [ "$ALREADY_MIGRATED" = true ]; then
    echo "⚠️  Dynamics APIs already detected in source code."
    echo "   This project may already be partially migrated."
    echo "   The migration prompts will still work — the AI agent will skip what's done."
fi

# settings.json check: look at every target the module map requests.
SJSON_FOUND=false
while IFS= read -r tgt; do
    [ -z "$tgt" ] && continue
    if [ -f "$PROJECT_ROOT/$tgt" ]; then
        SJSON_FOUND=true
        break
    fi
done <<EOF
$(mm_settings_json_targets 2>/dev/null)
EOF
if [ "$SJSON_FOUND" = true ]; then
    echo "⚠️  settings.json already exists — will be preserved."
fi

# Dynamics SDK dependency check: scan the primary build file plus, if
# applicable, the convention plugin source file the primary consumes.
SDK_DEP_FOUND=false
if grep -q "blackberrydynamics" "$PROJECT_ROOT/$PRIMARY_BUILD" 2>/dev/null; then
    SDK_DEP_FOUND=true
fi
CP_FILE="$(mm_convention_plugin_for "$PRIMARY_PATH" 2>/dev/null || echo "")"
if [ "$SDK_DEP_FOUND" = false ] && [ -n "$CP_FILE" ] && [ -f "$PROJECT_ROOT/$CP_FILE" ]; then
    if grep -q "blackberrydynamics" "$PROJECT_ROOT/$CP_FILE" 2>/dev/null; then
        SDK_DEP_FOUND=true
    fi
fi
if [ "$SDK_DEP_FOUND" = true ]; then
    echo "⚠️  Dynamics SDK dependency already present in build.gradle."
fi

if [ "$ALREADY_MIGRATED" = false ]; then
    echo "✅ No existing Dynamics integration detected — clean project."
fi

echo ""

# =========================================
# Step 3: Install steering files (Kiro/Cursor/Codex) or print instructions
# =========================================
if [ "$AGENT" = "kiro" ]; then
    echo "Step 3: Installing steering files for Kiro..."
    echo "-----------------------------------------"

    if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] Would create .kiro/steering/"
        echo "  [dry-run] Would copy steering files"
    else
        mkdir -p "$PROJECT_ROOT/.kiro/steering"
        cp "$TOOL_DIR/steering/"*.md "$PROJECT_ROOT/.kiro/steering/"
        echo "✅ Steering files installed to .kiro/steering/"
        echo "   Kiro will automatically use these as context."
    fi
    echo ""
elif [ "$AGENT" = "cursor" ]; then
    echo "Step 3: Installing rules for Cursor..."
    echo "-----------------------------------------"

    if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] Would create .cursor/rules/"
        echo "  [dry-run] Would copy steering files as Cursor rules"
    else
        mkdir -p "$PROJECT_ROOT/.cursor/rules"
        cp "$TOOL_DIR/steering/"*.md "$PROJECT_ROOT/.cursor/rules/"
        echo "✅ Steering files installed to .cursor/rules/"
        echo "   Cursor will automatically use these as context."
    fi
    echo ""
elif [ "$AGENT" = "codex" ]; then
    echo "Step 3: Installing project instructions for Codex..."
    echo "-----------------------------------------"

    if [ "$DRY_RUN" = true ]; then
        echo "  [dry-run] Would create or update AGENTS.md"
        echo "  [dry-run] Would add a BlackBerry Dynamics migration section"
    else
        write_codex_agents_section
        echo "✅ Codex instructions installed to AGENTS.md"
        echo "   Codex will read this project instruction file before starting work."
    fi
    echo ""
fi

# =========================================
# Prompt definitions
# =========================================

PROMPT_FILES=(
    "00pre-bootstrap.md"
    "00-analyze-app.md"
    "00b-generate-architecture-diagrams.md"
    "01-gradle-integration.md"
    "02-create-settings-json.md"
    "03-add-dynamics-auth.md"
    "03b-authorization-deferral-audit.md"
    "04-sqlite-migrate-to-secure-sql.md"
    "05a-filesystem-core-io-migration.md"
    "05b-filesystem-ui-reader-closure.md"
    "05z-filesystem-sharedprefs-and-closure.md"
    "06-secure-networking-audit-and-migrate.md"
    "07-webview-migrate-to-bbwebview.md"
    "08-icc-add-transferfileservice.md"
    "09-migrate-ui-widgets.md"
    "11-push-channel.md"
    "03c-background-authorize.md"
    "10-generate-migration-report.md"
    "12-generate-migration-retrospective.md"
)

PROMPT_LABELS=(
    "Bootstrap (STOP — asks for GDApplicationID, permissions confirmation, probes env/network/SDK)"
    "Analyze App (no code changes — produces migration plan)"
    "Generate Architecture Diagrams (OPTIONAL diagnostics; no code changes)"
    "Gradle Integration (SDK dependency, minSdk, Maven repo)"
    "Create settings.json (writes UEM values captured in 00pre)"
    "Add Dynamics Authorization (Application class, GDStateListener, manifest)"
    "Authorization Deferral Audit (ViewModels, Fragments, widgets, receivers)"
    "Secure SQLite (database migration)"
    "Secure Filesystem 05a (core file I/O migration)"
    "Secure Filesystem 05b (UI/consumer reader closure)"
    "Secure Filesystem 05z (SharedPreferences + final closure)"
    "Secure Networking (HTTP + Socket migration)"
    "WebView → BBWebView (if applicable)"
    "ICC / TransferFileService (if applicable)"
    "Migrate Covered Text/Search UI Widgets (EditText/TextView/... → com.good.gd.widget.*)"
    "Push Channel / FCM hardening (if applicable)"
    "Background Authorize hardening (if applicable)"
    "Generate Migration Report (dynamics-migration-tool/output/)"
    "Generate Migration Retrospective (OPTIONAL; after 10; asks developer first)"
)

PROMPT_NUMS=(
    "00pre"
    "00"
    "00b"
    "01"
    "02"
    "03"
    "03b"
    "04"
    "05a"
    "05b"
    "05z"
    "06"
    "07"
    "08"
    "09"
    "11"
    "03c"
    "10"
    "12"
)

PROMPT_REQUIRED=(
    "OPTIONAL"
    "REQUIRED"
    "REQUIRED"
    "REQUIRED"
    "REQUIRED"
    "REQUIRED"
    "REQUIRED"
    "if applicable"
    "if applicable"
    "if applicable"
    "if applicable"
    "if applicable"
    "if applicable"
    "if applicable"
    "if applicable"
    "if applicable"
    "if applicable"
    "REQUIRED"
    "OPTIONAL"
)

# =========================================
# Agent-specific instructions
# =========================================
if [ "$AGENT" = "kiro" ]; then
    echo "========================================="
    echo "Next Step: Paste This Into Kiro"
    echo "========================================="
    echo ""
    echo "Open this project in Kiro and paste the following into chat."
    echo "Copy everything between the --- lines:"
    echo ""
    echo "---"
    echo ""
    print_kickstart_body
    echo ""
    echo "---"
    echo ""
    echo "Kiro handles the rest. The 00pre bootstrap is the only step that"
    echo "asks for GDApplicationID/Version and confirms IDE permissions —"
    echo "everything afterwards reads from output/bootstrap.json. Prompt 10's"
    echo "hard gate refuses to write a report if any applicable domain has"
    echo "neither a completed prompt nor a developer-signed-off deferral."
    echo ""
elif [ "$AGENT" = "cursor" ]; then
    echo "========================================="
    echo "Next Step: Paste This Into Cursor"
    echo "========================================="
    echo ""
    echo "Open this project in Cursor and start a new Agent chat."
    echo "Copy everything between the --- lines:"
    echo ""
    echo "---"
    echo ""
    print_kickstart_body
    echo ""
    echo "---"
    echo ""
    echo "Cursor handles the rest. The 00pre bootstrap is the only step that"
    echo "asks for GDApplicationID/Version and confirms IDE permissions —"
    echo "everything afterwards reads from output/bootstrap.json. Prompt 10's"
    echo "hard gate refuses to write a report if any applicable domain has"
    echo "neither a completed prompt nor a developer-signed-off deferral."
    echo ""
elif [ "$AGENT" = "codex" ]; then
    echo "========================================="
    echo "Next Step: Paste This Into Codex"
    echo "========================================="
    echo ""
    echo "Open this project in Codex. AGENTS.md now points Codex at the"
    echo "migration prompts and steering files for this repository."
    echo "Copy everything between the --- lines:"
    echo ""
    echo "---"
    echo ""
    print_kickstart_body
    echo ""
    echo "---"
    echo ""
    echo "Codex handles the rest. The 00pre bootstrap is the only step that"
    echo "asks for GDApplicationID/Version and confirms permissions —"
    echo "everything afterwards reads from output/bootstrap.json. Prompt 10's"
    echo "hard gate refuses to write a report if any applicable domain has"
    echo "neither a completed prompt nor a developer-signed-off deferral."
    echo ""
elif [ "$AGENT" = "generic" ]; then
    echo "========================================="
    echo "Migration Prompts — Execute in Order"
    echo "========================================="
    echo ""
    echo "Open your AI agent and work through these prompts one at a time."
    echo "The 00pre-bootstrap step asks for UEM entitlement values"
    echo "(GDApplicationID and GDApplicationVersion from your administrator), not the app's package/versionName."
    echo ""
    echo "$IMPL_FIRST_NOTE"
    echo ""
    echo "$CLOSURE_NOTE"
    echo ""

    for i in "${!PROMPT_FILES[@]}"; do
        PROMPT_FILE="${PROMPT_FILES[$i]}"
        PROMPT_LABEL="${PROMPT_LABELS[$i]}"
        PROMPT_NUM="${PROMPT_NUMS[$i]}"
        PROMPT_REQ="${PROMPT_REQUIRED[$i]}"
        PROMPT_PATH="$TOOL_DIR/prompts/$PROMPT_FILE"

        printf "  %3s. [%-13s] %s\n" "$PROMPT_NUM" "$PROMPT_REQ" "$PROMPT_LABEL"
        echo "       → $PROMPT_PATH"
        echo ""
    done

    echo "Before running prompts, provide these files as context:"
    echo ""
    echo "  1. $TOOL_DIR/steering/00-context.md  (core principles)"
    echo "  2. $TOOL_DIR/steering/03-implementation-first-conduct.md  (implement first, do not stop at findings)"
    echo "  3. $TOOL_DIR/steering/14-api-provenance-and-replacement-catalog.md  (exact API names and replacements)"
    echo "  4. $TOOL_DIR/steering/06-inline-migration-comments.md  (comment rules)"
    echo "  5. The steering file matching each prompt:"
    echo ""
    echo "     Prompt 00pre → steering/02-bootstrap-schema.md"
    echo "     Prompt 00    → No extra steering needed (analysis only)"
    echo "     Prompt 00b   → No extra steering needed (optional diagnostics only)"
    echo "     Prompt 01    → steering/10-gradle-integration.md"
    echo "     Prompt 02    → steering/11-settings-json-reference.md"
    echo "     Prompt 03    → steering/10-gradle-integration.md + steering/20-auth-initialization.md"
    echo "     Prompt 03b   → steering/21-authorization-deferral-patterns.md"
    echo "     Prompt 04    → steering/41-secure-storage-sql.md"
    echo "     Prompt 05a   → steering/40-secure-file-storage.md"
    echo "     Prompt 05b   → steering/40-secure-file-storage.md"
    echo "     Prompt 05z   → steering/40-secure-file-storage.md"
    echo "     Prompt 06    → steering/30-secure-networking.md"
    echo "     Prompt 07    → steering/50-webview-bbwebview.md"
    echo "     Prompt 08    → steering/60-icc-transferfileservice.md"
    echo "     Prompt 09    → steering/45-secure-ui-widgets.md"
    echo "     Prompt 11    → steering/78-push-channel.md"
    echo "     Prompt 03c   → steering/70-background-authorize.md"
    echo "     Prompt 10    → steering/80-migration-report-schema.md"
    echo "     Prompt 12    → No extra steering needed (optional retrospective after 10)"
    echo ""
    echo "$POST_REPORT_NOTE"
    echo ""
fi

# =========================================
# Information checklist
# =========================================
echo "========================================="
echo "Before You Start — Have This Ready"
echo "========================================="
echo ""
echo "  [ ] Developer confirms app builds cleanly before migration"
echo "  [ ] IDE permissions enabled (file read/write, shell exec, full network)"
echo "  [ ] GDApplicationID    — from your UEM administrator"
echo "  [ ] GDApplicationVersion — from your UEM administrator"
echo "  [ ] UEM server address — for testing authorization"
echo "  [ ] Test user credentials — for activation testing"
echo "  [ ] Optional diagnostics (if needed): ./dynamics-migration-tool/tooling/validate.sh --preflight"
echo ""
echo "  The bootstrap (00pre) is the single human stop. It asks you to"
echo "  confirm IDE permissions and capture GDApplicationID/Version once."
echo "  Network access is REQUIRED — the Dynamics SDK is downloaded from"
echo "  the BlackBerry Maven repository during bootstrap."
echo ""

# =========================================
# Post-migration
# =========================================
echo "========================================="
echo "After Migration"
echo "========================================="
echo ""
echo "Validate your migration:"
echo "  ./dynamics-migration-tool/tooling/validate.sh"
echo ""
echo "Optional migration retrospective (after prompt 10):"
echo "  Run prompts/12-generate-migration-retrospective.md — the agent will"
echo "  ask whether to write output/migration-retrospective.md."
echo ""
PRIMARY_APK_GLOB="$(mm_primary_apk_glob 2>/dev/null || echo 'app/build/outputs/apk/**/*.apk')"
echo "Optional non-blocking emulator/device probe + APK install (Phase A):"
echo "  bash ./dynamics-migration-tool/tooling/emulator-probs.sh --apk-glob \"$PRIMARY_APK_GLOB\""
echo "  If no known emulator/device is found, it tries to auto-start the first local AVD."
echo "  If no AVD/device becomes available, migration still continues and you'll"
echo "  be asked to test the resulting APK manually."
echo ""
echo "Maintainer-only diagnostics (optional):"
echo "  see dynamics-migration-tool/_maintainer/README.md"
echo ""
echo "Find all migration changes:"
# Build a space-separated list of every in-scope module path so the
# audit-comment recap covers libraries too on multi-module projects.
GREP_TARGETS="$(mm_in_scope_module_paths 2>/dev/null | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')"
[ -z "$GREP_TARGETS" ] && GREP_TARGETS="$PRIMARY_PATH"
echo "  grep -rn \"[BB_DYNAMICS-MIGRATION]\" $GREP_TARGETS"
echo ""

# =========================================
# Optional: list prompts (--list-prompts or generic agent)
# =========================================
if [ "$LIST_PROMPTS" = true ]; then
    echo "========================================="
    echo "Prompt Reference (for manual execution)"
    echo "========================================="
    echo ""
    echo "Use these if you prefer to run prompts one at a time"
    echo "instead of letting the agent handle them automatically."
    echo ""

    for i in "${!PROMPT_FILES[@]}"; do
        PROMPT_FILE="${PROMPT_FILES[$i]}"
        PROMPT_LABEL="${PROMPT_LABELS[$i]}"
        PROMPT_NUM="${PROMPT_NUMS[$i]}"
        PROMPT_REQ="${PROMPT_REQUIRED[$i]}"
        PROMPT_PATH="$TOOL_DIR/prompts/$PROMPT_FILE"

        printf "  %3s. [%-13s] %s\n" "$PROMPT_NUM" "$PROMPT_REQ" "$PROMPT_LABEL"
        echo "       → $PROMPT_PATH"
        echo ""
    done
fi

echo "========================================="
