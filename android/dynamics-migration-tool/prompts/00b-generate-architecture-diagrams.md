# Task: Generate Architectural Diagrams for Dynamics Migration

## Execution Order

Run immediately after `00-analyze-app.md`. Do NOT modify any source code.

Output: `dynamics-migration-tool/output/architecture-diagrams.md`

**IMPORTANT — File Write Method**: Use a **full-file overwrite** (not a
patch or append) to create the output file. In AI IDEs, use the
Write/CreateFile tool — do NOT use StrReplace or patch-based tools. If
the file already exists from a previous run, the full-file write will
correctly replace it.

---

## Why This Step Exists

Import-swapping is mechanical. The hard part is understanding the
transitive dependency chains that lead to secure API calls during early
initialization. Crashes come from ViewModel `init {}` blocks that open
databases, Fragments that observe uninitialized LiveData, BroadcastReceivers
triggered before unlock, and utility functions called from constructors.
A flat API inventory does not reveal these chains. The diagrams below do.

**Room LiveData trap**: Room LiveData queries fire on `arch_disk_io`
background threads immediately when observed, even if `observe()` is
called in `onCreate()`. The crash happens on a background thread, not
on the line where `observe()` is called.

**This output is consumed by**:
- Prompt 03 (auth initialization) — identifies main Activity startup restructuring
- Prompt 03b (deferral audit) — primary input, maps every pre-auth chain to a deferral pattern
- Prompt 04 (secure SQL) — identifies which DB access points need deferral
- Prompt 05a/05b/05c/05z (secure filesystem split flow) — identifies which file I/O, reader, and native-media paths need deferral
- Prompt 10 (migration report) — risk heatmap feeds into report risk assessments

If this output is incomplete, downstream prompts will miss pre-auth chains
and the migrated app will crash at runtime.

---

# STRICT OUTPUT CONTRACT

The output file MUST contain these sections in order:

0. Application Architecture Overview (Mermaid — component diagram)
1. Data Flow Diagrams (Mermaid — one per distinct flow)
2. Storage Classification Map (Tables)
3. Network Classification Map (Table)
4. Lifecycle Dependency Map (Text Tree + Summary Table + Mermaid)
5. Secure API Call Graph (Mermaid — bottom-up, split by domain)
6. Authorization Boundary (Mermaid diagram + structured prose)
7. Migration Risk Heatmap (Table)
8. Migration API Replacement Map (Mermaid + Table)

Rules:
- No prose explanations outside section headers and structured annotations
- Only structured output (tables, trees, Mermaid, blockquote annotations, lists)
- If information is unknown, write: `UNKNOWN — requires manual review`

---

# STYLING AND PRESENTATION RULES

## Tone

Professional, no emoji or unicode pictographs anywhere in the output.
Use plain-text prefixes and Mermaid color styling to convey meaning.

## Node Label Conventions

Use plain-text prefixes instead of emoji markers:

| Prefix | Meaning | classDef name |
|--------|---------|---------------|
| `SECURE:` | Requires Dynamics API replacement | `secure` |
| `RISK:` | Executes before onAuthorized, potential crash | `risk` |
| `LIB:` | Third-party library in the data path | `lib` |
| *(no prefix)* | Standard application code | varies by role |

## Mandatory classDef Palette

Every Mermaid diagram MUST define its applicable classes from this
palette. Use `classDef` (not per-node `style` directives) for
consistency across all diagrams. Only use per-node `style` for
subgraph background coloring.

```
classDef lifecycle fill:#3498db,color:#fff,stroke:#2980b9
classDef userAction fill:#2ecc71,color:#fff,stroke:#27ae60
classDef secure fill:#e74c3c,color:#fff,stroke:#c0392b
classDef io fill:#e67e22,color:#fff,stroke:#d35400
classDef risk fill:#f39c12,color:#fff,stroke:#d35400
classDef ui fill:#95a5a6,color:#fff,stroke:#7f8c8d
classDef authGate fill:#27ae60,color:#fff,stroke:#1e8449,stroke-width:3px
classDef appNode fill:#8e44ad,color:#fff,stroke:#6c3483
classDef actNode fill:#2c3e50,color:#fff,stroke:#1a252f
```

Role assignment:
- **lifecycle** (blue): Android lifecycle entry points — onCreate, onCreateView, onResume
- **userAction** (green): User-triggered events — button clicks, menu selections
- **secure** (red): Nodes touching secure APIs — label with `SECURE:` prefix
- **io** (orange): I/O operations, intermediary method calls
- **risk** (amber): Pre-auth execution risk — label with `RISK:` prefix
- **ui** (gray): UI updates — setText, setChecked, adapter notify
- **authGate** (green, thick border): The `onAuthorized()` boundary node
- **appNode** (purple): Application class
- **actNode** (dark): Activity-level nodes

---

# 0. Application Architecture Overview (MANDATORY MERMAID)

Produce a `graph TD` component diagram that shows the full app structure
at a glance: Application class, Activity/navigation layer, Fragments or
screens, and the data layer each connects to.

### Format Requirements

- Use `graph TD` (top-down)
- Four subgraphs: **Application**, **Activity/Navigation**,
  **Fragments/Screens**, **Data Layer**
- Color-code by role using `classDef`: `appClass` (purple) for
  Application, `activity` (dark) for Activity/navigation, `fragment`
  (blue) for Fragments/screens, `data` (teal) for data layer
- Database nodes should use cylinder shape `[("label")]`
- Connect Application to Activity with labeled edges showing init calls
  (`applicationInit`, `setGDStateListener`)
- Connect Activity to Fragments/screens with navigation edges
- Connect Fragments to Data Layer with labeled edges showing the
  **post-migration** Dynamics API used (e.g., `GDFileSystem`,
  `GDHttpClient`, `GD SQLiteOpenHelper`)

### Example

```mermaid
graph TD
    subgraph Application
        APP["MyApplication<br/><i>GDStateListener</i>"]
    end

    subgraph "MainActivity"
        MA["MainActivity<br/><i>AppCompatActivity</i>"]
        NAV["NavController"]
    end

    subgraph "Screens"
        S1["HomeFragment<br/>Secure File I/O"]
        S2["DataFragment<br/>Secure SQLite"]
    end

    subgraph "Data Layer"
        DB[("app.db<br/><i>SQLiteOpenHelper</i>")]
        FS[("documents/<br/><i>File I/O</i>")]
    end

    APP -->|"applicationInit + setGDStateListener"| MA
    MA -->|"activityInit(this)"| NAV
    NAV --> S1 & S2
    S1 ---|"GDFileSystem"| FS
    S2 ---|"GD SQLiteOpenHelper"| DB

    classDef appClass fill:#8e44ad,color:#fff,stroke:#6c3483
    classDef activity fill:#2c3e50,color:#fff,stroke:#1a252f
    classDef fragment fill:#2980b9,color:#fff,stroke:#1f6da0
    classDef data fill:#16a085,color:#fff,stroke:#0e6655

    class APP appClass
    class MA,NAV activity
    class S1,S2 fragment
    class DB,FS data
```

---

# 1. Data Flow Diagrams (MANDATORY MERMAID)

For EACH distinct data flow in the app, produce one Mermaid `flowchart LR`.

### Format Requirements

- Use `flowchart LR` (left-to-right)
- One Mermaid block per distinct flow — do not collapse multiple flows
- Use `Class.method` naming for all nodes
- Apply `classDef` classes to every node based on its role (lifecycle,
  userAction, secure, io, risk, ui)
- Mark every node that touches a secure API with the `SECURE:` text
  prefix and the `secure` class
- Mark every third-party library node with the `LIB:` text prefix
- Mark every node that runs before authorization with the `RISK:` text
  prefix and the `risk` class
- Use dashed edges (`-.->`) for system-triggered or asynchronous paths

### Per-Flow Annotations (below each Mermaid block)

After each diagram, add annotations as a blockquote with two mandatory
lines and one optional line:
- **Dynamics impact:** which nodes require Dynamics API replacement
- **Third-party:** libraries in the path and container compatibility
  (can it read from the secure container directly, or does it need a
  workaround like byte-array loading?)
- **Risk:** *(optional — include only if pre-auth execution is possible)*

### Example

```mermaid
flowchart LR
    A["CameraFragment<br/>onViewCreated"]:::lifecycle
    B["capturePhoto.onClick"]:::userAction
    C["CapturePhotoUseCase"]:::io
    D["SECURE:<br/>SecureFileStore.openForWrite"]:::secure
    E["SECURE:<br/>Room.insert()"]:::secure
    F["LiveData emit"]:::io
    G["LIB: Glide<br/>loads thumbnail"]:::lib

    A --> B --> C --> D --> E --> F --> G

    classDef lifecycle fill:#3498db,color:#fff,stroke:#2980b9
    classDef userAction fill:#2ecc71,color:#fff,stroke:#27ae60
    classDef secure fill:#e74c3c,color:#fff,stroke:#c0392b
    classDef io fill:#e67e22,color:#fff,stroke:#d35400
    classDef lib fill:#9b59b6,color:#fff,stroke:#7d3c98
```

> **Dynamics impact:** SecureFileStore write (to GDFileSystem), Room insert (to GD secure SQLite)
> **Third-party:** Glide cannot load from GD secure container — needs byte[] workaround

---

# 2. Storage Classification Map (TABLES ONLY)

Produce four sub-tables. Every storage location in the app must appear
in exactly one table. No missing categories.

## Databases

| Name | Technology | Sensitivity | Pre-Auth? | Migration Target |
|------|-----------|-------------|-----------|-----------------|

## File Storage

| Path | Operation | Sensitivity | Pre-Auth? | Migration Target |
|------|-----------|-------------|-----------|-----------------|

## SharedPreferences / DataStore

If entries exist:

| Name | Sensitivity | Pre-Auth? | Migration Target |
|------|-------------|-----------|-----------------|

If none detected, use a single-row status table:

| Status |
|--------|
| None detected — no migration required |

## Cache / Temp Files

If entries exist:

| Path Pattern | Sensitivity | Pre-Auth? | Migration Target |
|-------------|-------------|-----------|-----------------|

If none detected:

| Status |
|--------|
| None detected — no leakage risk |

Column rules:
- `Pre-Auth?` must be YES or NO, optionally with a brief qualifier
  (e.g., "NO — button-triggered")
- `Sensitivity` must be one of: Sensitive, Semi-sensitive, Non-sensitive, Transient
- `Migration Target` must name the specific Dynamics API or state
  "Keep native" with justification

---

# 3. Network Classification Map (TABLE ONLY)

| Component | Technology | Endpoint | Trigger | Pre-Auth? | Migration Target |
|-----------|-----------|----------|---------|-----------|-----------------|

Column rules:
- `Trigger` must be one of: Startup, System-triggered, User-triggered, Background worker
- `Pre-Auth?` must be YES or NO

---

# 4. Lifecycle Dependency Map (CRITICAL — MOST IMPORTANT SECTION)

This section prevents the majority of runtime crashes. It is the primary
input for Prompt 03b (authorization deferral audit).

## A. Startup Chain Trace (TEXT TREE)

For EVERY component that accesses a secure API, trace the complete call
chain back to the Android lifecycle event that triggers it.

Format:
```
[Lifecycle Event]
  > Class.method()
    > Class.method()
      > SECURE API: description
```

Rules:
- Do NOT stop tracing at ViewModel level — trace through to the actual secure API call
- Do NOT stop at "calls database" — name the specific method
- Trace transitive calls fully (if A calls B calls C calls secure API, show all three)
- Include every distinct chain — if the same secure API is reached via two different
  lifecycle paths, show both chains

**Condensed pattern rule**: If multiple components follow an identical
startup pattern (e.g., several Fragments that only inflate layouts and
register click listeners with no secure API access), describe the common
pattern once and list the components that follow it. Then trace only the
**exceptions** — components whose startup chains differ or access secure
APIs — in full detail.

**Pay special attention to:**
- ViewModel `init {}` blocks — #1 source of missed pre-auth secure API access
- Room LiveData queries — fire on background threads immediately when observed
- Utility functions that do file I/O — may be called transitively from constructors
- WorkManager workers — may be triggered by the system before authorization
- Constructor side effects — `new SomeClass()` that calls `mkdirs()` or opens DB

## B. Summary Table

| Trigger | Component | Secure API | Pre-Auth? | Deferral |
|---------|-----------|-----------|-----------|----------|

Column rules:
- `Deferral` must reference a specific pattern from
  `21-authorization-deferral-patterns.md` (e.g., "Pattern 2: ViewModel
  deferral") or state `None needed` if post-auth only
- Every row in this table must correspond to at least one chain in section A

## C. Lifecycle Flowchart (MANDATORY MERMAID)

Use `flowchart TD`. Structure as three connected elements:
1. Subgraph `"Pre-Authorization — Unsafe Zone"` — everything that runs
   before onAuthorized()
2. A standalone `onAuthorized()` gate node styled with `authGate`
3. Subgraph `"Post-Authorization — Safe Zone"` — everything that runs
   after onAuthorized()

Connected as: `PRE --> AUTH --> POST`

Apply `classDef` classes from the mandatory palette:
- `appNode` for Application class
- `actNode` for Activity-level nodes
- `safeFragment` (use `lifecycle` color) for fragments with no pre-auth risk
- `secureNode` (use `secure` color) for secure API nodes in post-auth zone
- `policyNode` (use `risk` color) for policy/config-related nodes
- `authGate` for the onAuthorized boundary

### Template (adapt to actual app)

```mermaid
flowchart TD
    subgraph PRE["Pre-Authorization — Unsafe Zone"]
        A["Application.onCreate<br/><i>GDAndroid.applicationInit</i>"]:::appNode
        B["MainActivity.onCreate<br/><i>activityInit(this)</i>"]:::actNode
        C["Fragment.onCreateView<br/><i>UI setup only</i>"]:::safeFragment
        A --> B --> C
    end

    AUTH["onAuthorized fires<br/><i>Container unlocked</i>"]:::authGate

    subgraph POST["Post-Authorization — Safe Zone"]
        D["User interacts with UI"]:::userNode
        E["SECURE: Database access"]:::secureNode
        D --> E
    end

    PRE --> AUTH --> POST

    classDef appNode fill:#8e44ad,color:#fff,stroke:#6c3483
    classDef actNode fill:#2c3e50,color:#fff,stroke:#1a252f
    classDef safeFragment fill:#3498db,color:#fff,stroke:#2980b9
    classDef authGate fill:#27ae60,color:#fff,stroke:#1e8449,stroke-width:3px
    classDef userNode fill:#2ecc71,color:#fff,stroke:#27ae60
    classDef secureNode fill:#e74c3c,color:#fff,stroke:#c0392b
```

---

# 5. Secure API Call Graph (MANDATORY MERMAID — BOTTOM-UP, BY DOMAIN)

This is a separate set of diagrams from section 4C. They trace in REVERSE:

`Secure API --> Immediate Caller --> Transitive Caller --> ... --> Trigger`

Purpose: Forces bottom-up traversal to catch chains that top-down tracing misses.
If a secure API is reachable from multiple lifecycle events, show all paths.

### Format Requirements

- Split into sub-diagrams by domain: **Storage APIs**, **Network APIs**,
  **Policy API**, and any other applicable domain (WebView, ICC, etc.)
- Use `flowchart RL` (right-to-left) for bottom-up readability
- Each sub-diagram must have its own `classDef` declarations
- Every secure API call from the Prompt 00 inventory MUST appear in at
  least one sub-diagram
- If a secure API is only reachable post-auth (user-triggered), still
  include it but connect to a terminal node like
  `"User click — post-auth only"` styled with `auth` class
- If a chain reaches a pre-auth trigger, connect to a terminal node
  styled with `risk` class

### Example

```mermaid
flowchart RL
    A["SECURE: Room DB query"]:::secure --> B["AppDatabase.getInstance"]:::io
    B --> C["CameraFragment<br/>.initDependencies"]:::io
    C --> D["CameraFragment<br/>.onViewCreated"]:::risk

    classDef secure fill:#e74c3c,color:#fff,stroke:#c0392b
    classDef io fill:#e67e22,color:#fff,stroke:#d35400
    classDef risk fill:#f39c12,color:#fff,stroke:#d35400
```

---

# 6. Authorization Boundary (MERMAID + STRUCTURED PROSE)

Produce a `flowchart LR` with three connected elements:
- Subgraph `ABOVE Auth Boundary` listing pre-auth components
- A central `onAuthorized()` gate node styled with `authGate`
- Subgraph `BELOW Auth Boundary` listing post-auth components

Connected as: `ABOVE --> GATE --> BELOW`

Mark any pre-auth component that accesses a secure API with the `risk`
class.

### Example

```mermaid
flowchart LR
    subgraph ABOVE["ABOVE Auth Boundary<br/><i>Runs before onAuthorized</i>"]
        A1["Application.onCreate"]
        A2["MainActivity.onCreate"]
        A3["Fragment.onCreateView"]
        A4["RISK: BroadcastReceiver<br/>.onReceive()"]:::risk
    end

    GATE["onAuthorized()"]:::authGate

    subgraph BELOW["BELOW Auth Boundary<br/><i>Runs after onAuthorized</i>"]
        B1["File save/load<br/><i>button click</i>"]
        B2["SQL save/load<br/><i>button click</i>"]
    end

    ABOVE --> GATE --> BELOW

    classDef risk fill:#f39c12,color:#fff,stroke:#d35400
    classDef authGate fill:#27ae60,color:#fff,stroke:#1e8449,stroke-width:3px
```

Below the diagram, provide structured prose in three groups:

**Above boundary (safe — no secure API access):**
- List components with brief description

**Above boundary (risk — potential pre-auth API access):**
- List components, describe the risk, and state mitigation

**Below boundary (all post-auth):**
- List components with the Dynamics API each uses

---

# 7. Migration Risk Heatmap (TABLE)

| Component | Storage | Network | Lifecycle | Pre-Auth? | Overall | Deferral Required |
|-----------|:-------:|:-------:|:---------:|:---------:|:-------:|-------------------|

Column rules:
- Risk levels: HIGH, MED, LOW, or — (not applicable)
- `Pre-Auth?` must be YES or NO
- `Overall` = highest of the three individual risks, bolded
- `Deferral Required` must reference `21-authorization-deferral-patterns.md`
  or state `None — post-auth only`

Risk assignment guidance:
- HIGH: Pre-auth secure API access, or complex migration (Room bridge, streaming decrypt)
- MED: Post-auth secure API access with API shape change, or constructor side effects
- LOW: Post-auth with drop-in replacement, or no secure API involvement

Below the table, include a one-line legend:

> **Legend:** HIGH = pre-auth secure API or complex migration | MED = API shape change or post-auth with refactoring | LOW = drop-in replacement or no secure API

---

# 8. Migration API Replacement Map (MANDATORY MERMAID + TABLE)

Produce a `flowchart LR` with two subgraphs showing the before/after
API mapping:

- Subgraph `BEFORE["Standard Android APIs"]` with
  `style BEFORE fill:#fdf2f2,stroke:#e74c3c`
- Subgraph `AFTER["Dynamics Secure APIs"]` with
  `style AFTER fill:#f0fdf0,stroke:#27ae60`

Connect each original API to its replacement with a labeled edge
describing the change type (e.g., `import swap`, `API refactor`,
`widget swap`, `constructor change`, `API + callback change`).

Below the diagram, add a summary table:

| Original API | Dynamics API | Risk | Change Type |
|-------------|-------------|:----:|------------|

Column rules:
- `Risk` must be HIGH, MED, or LOW
- `Change Type` must be a short description (import swap, API shape
  change, constructor to method, etc.)

---

# GLOBAL DIAGRAM RULES

- All Mermaid diagrams must be syntactically valid (compilable)
- No duplicate node IDs within a single diagram
- Use consistent `Class.method` naming across all diagrams
- Use text prefixes (`SECURE:`, `RISK:`, `LIB:`) — no emoji or unicode
  pictographs anywhere in the output
- Use `classDef` for all node styling — do not use per-node `style`
  directives (except for subgraph background styling via
  `style SUBGRAPH_ID fill:...`)
- Direction: `LR` for data flows and replacement maps, `RL` for call
  graphs, `TD` for lifecycle and architecture overview diagrams
- Color semantics: red = secure API, green = post-auth safe / auth gate,
  orange/amber = I/O or pre-auth risk, blue = lifecycle, gray = UI,
  purple = application class, dark = activity

---

# INTERNAL VALIDATION CHECKLIST (MANDATORY)

Before finalizing output, verify:

- [ ] Section 0 (Architecture Overview) is present with component diagram
- [ ] Every secure API from the Prompt 00 inventory appears in the Lifecycle Dependency Map (section 4)
- [ ] Every secure API from the Prompt 00 inventory appears in the Secure API Call Graph (section 5)
- [ ] Every row in the Summary Table (4B) has a corresponding chain in the Text Tree (4A)
- [ ] Every storage entry has `Pre-Auth?` filled (YES or NO)
- [ ] Every network entry has `Trigger` filled
- [ ] SharedPreferences / DataStore entries are classified (not omitted)
- [ ] All Mermaid blocks are syntactically valid
- [ ] No missing deferral patterns in Summary Table (4B) and Heatmap (7)
- [ ] Room LiveData observation points are flagged if observed in onCreate/onViewCreated
- [ ] No prose paragraphs outside section headers and annotations
- [ ] classDef declarations present in all Mermaid diagrams
- [ ] No emoji or unicode pictographs anywhere in the output
- [ ] Section 8 (API Replacement Map) is present with before/after diagram and table
- [ ] Pre-Authorization and Post-Authorization subgraphs are connected through authGate node (section 4C)
- [ ] Call graph (section 5) is split by domain, not a single monolithic diagram

If any check fails: correct before output.

---

# CRITICAL FAILURE CONDITIONS

The following are considered incorrect output and must be fixed:

- Emoji or unicode pictographs used anywhere (use text prefixes instead)
- Per-node `style` directives instead of `classDef` classes
- Narrative explanation paragraphs outside section headers
- Arrow chains described in prose instead of Mermaid blocks
- Lifecycle tracing that stops at ViewModel level without reaching the secure API
- Missing Architecture Overview (section 0) or API Replacement Map (section 8)
- Missing Secure API Call Graph (section 5)
- Missing `Pre-Auth?` flags in Storage/Network tables
- Secure API from Prompt 00 inventory not appearing in sections 4 and 5
- Deferral pattern column left blank (must be a pattern reference or "None needed")
- Call graph produced as a single monolithic diagram instead of per-domain splits
- Pre-auth and post-auth subgraphs not connected through authGate node
- Tables with more than 7 columns (reduce to essential columns, use footnotes for details)

If unsure about any data point: `UNKNOWN — requires manual review`

---

## Record execution

After diagrams are written, append the execution record:

```bash
bash dynamics-migration-tool/tooling/record-prompt-execution.sh \
    --prompt-id 00b \
    --status completed \
    --files-touched dynamics-migration-tool/output/architecture-diagrams.md
```
