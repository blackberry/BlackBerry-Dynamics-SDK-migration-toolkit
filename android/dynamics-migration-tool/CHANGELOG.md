# Changelog — BlackBerry Dynamics Migration Tool (Android)

All notable changes that are part of public Android toolkit releases are
documented in this file. Versioning follows
[Semantic Versioning](https://semver.org/). Pre-release suffixes
(`-beta.N`) track beta releases; the toolkit has not yet reached `1.0.0`.

The toolkit has not been GA released; schema and CLI behavior may change
between pre-release cuts. Run each toolkit version end-to-end against a
fresh project and avoid mid-run upgrades.

---

## [0.1.0-beta.1] — 2026-07-14

First public Android beta. Lockstep toolkit version with iOS
(`0.1.0-beta.1`). Targets Dynamics SDK **15.0** (`15.0.8513.64`).

### Added

- Pre-auth SecurePreferences / GD-file lifecycle gate **AUTH-PREF-001**
  (Phase 11 + `auth-startup-scan.py`) with fail/pass fixtures for Activity
  helper chains and chained `SecurePreferencesHelper` I/O before
  `onAuthorized()`.
- Deferred Activity UI lifecycle gate **AUTH-UI-004** (Pattern 14): fail
  when fields assigned in `initializeAuthorizedUi` / `setupNavigation` /
  `onDynamicsAuthorized` are used from lifecycle **or menu** callbacks
  (`onResume`/`onCreateOptionsMenu`/…) without a ready/null/`isInitialized`
  guard (two-phase auth + Toolbar/NavController cold-start crash class).
  Steering + prompts `03`/`03b`/`10` updated; fail/pass fixtures in
  `tooling/fixtures/auth-startup/`.
- **PROC-AUX-001** elevated from Phase-3 warning to **failure**, with 2-hop
  helper reachability (aux crash-handler → shared log helper → file/dir
  helper → GD File) so auxiliary processes cannot silently keep GD I/O.
- Report normalizer aliases `manualTodos[].priority` → `severity` when the
  value is already `P0|P1|P2|P3` (drops `priority` for
  `additionalProperties: false`); report-contract emits an explicit hint
  for analysis-vocab `priority` values.
- Kickoff / recovery guidance: `progress.sh` when stuck, fix owning prompt
  (do not thrash prompt `10`), stop on `ESCALATION REQUIRED`, optional
  `repair-orchestrator.sh` for controlled prompts, and
  `96-repair-loop-conduct.md` in the kickoff “especially read” list.
- Human-facing **When stuck** section in `MIGRATION_INSTRUCTIONS.md`.

### Included capability snapshot

- Prompt pipeline `00pre` → `10` (optional `00b`, `12`) with recorder
  `requires[]` gating, module/process model, Background Authorize (`03c`),
  and report schema **v2.1.0**.
- Bounded loop-state telemetry, optional repair orchestrator, reviewer
  lane, runtime-evidence contract, improvement backlog, and release
  assessment (maturing / optional; validators remain authoritative).
