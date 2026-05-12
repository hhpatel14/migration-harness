# migration-harness

A CLI tool that drives `goose` through a 5-step code migration pipeline:
**detect → plan → execute → verify → fix-loop**. Each step is a separate,
stateless `goose run` invocation. Migration expertise lives in the bundled
skill files; per-run state lives on disk.

---

## Architecture

```
migration-harness  (bash CLI)               ←  orchestration, gates, resume
    │
    ├── lib/                                ←  one bash file per step
    │     step-detect.sh                        pure bash, no LLM
    │     step-plan.sh                          renders recipe dynamically
    │     step-execute.sh                       loops over plan items
    │     step-verify.sh                        single goose call
    │     step-fix-loop.sh                      bounded verify/fix iterations
    │     common.sh                             shared helpers, goose_run()
    │
    ├── recipes/                            ←  static goose recipe files
    │     execute.yaml                          one file per migration item
    │     verify.yaml                           build + test check
    │     fix.yaml                              fix one compiler error
    │     (no plan.yaml — rendered dynamically, see below)
    │
    └── skill-bundle/goose-migration/       ←  migration expertise
          SKILL.md                              umbrella skill
          skills/migration-plan/SKILL.md        planner skill (how to plan)
          skills/javaee-quarkus/SKILL.md        Java EE execution rules
          skills/python2-to-python3/SKILL.md    Python 2→3 execution rules
          references/javaee-quarkus.md          transformation patterns
          references/migration-phases.md        general migration phases

State on disk:
  ~/.migration-harness/config               ←  model, provider, limits
  ~/.migration-harness/runs/<id>/           ←  per-run artifacts + logs
  <repo>/PLAN.md                            ←  human-readable migration plan
  <repo>/.goosehints                        ←  guidance for execution steps
```

---

## Install

```bash
./install.sh
```

This:
1. Verifies `goose`, `jq`, `git` are present.
2. Copies payload to `~/.migration-harness/install/`.
3. Symlinks `~/.local/bin/migration-harness` → the command.
4. Installs the skill bundle to `~/.config/goose/skills/goose-migration/`.

Make sure `~/.local/bin` is in your `PATH`.

## First-time configuration

```bash
migration-harness init
```

Auto-detects provider and model from your goose config (`~/.config/goose/config.yaml`).
Falls back to interactive prompts if not found.

Saved to `~/.migration-harness/config`.

---

## Usage

```bash
migration-harness /path/to/your/app "Migrate this Java EE app to Quarkus 3"
```

---

## Pipeline Overview

| # | Step | Who does the work | LLM? | Output |
|---|------|-------------------|------|--------|
| 1 | **Detect** | bash script | No | `detect.json` |
| 2 | **Plan** | goose (dynamic recipe) | Yes | `PLAN.md` + `plan.json` |
| 3 | **Execute** | goose (per item) | Yes | modified source files |
| 4 | **Verify** | goose | Yes | build/test results |
| 5 | **Fix-loop** | goose (bounded) | Yes | error fixes |

---

## Step 1 — Detect (pure bash, zero tokens)

**File:** `lib/step-detect.sh`

This step runs entirely in bash — no goose, no LLM, no tokens spent.
It inspects the repo structure to figure out what kind of project it is.

### What it does

```
1a. Check manifest files      → does pom.xml / package.json / pyproject.toml / etc. exist?
1b. Count source files         → how many .java / .py / .js / .ts files?
1c. Scan for migration patterns → grep counts only (not file content):
      - javax imports, @Stateless/@Stateful/@EJB, @MessageDriven
      - Python 2 print statements, xrange()
      - React class components
1d. Write detect.json
```

### What bash does vs what goose does

| Bash does | Goose does |
|-----------|------------|
| `find` to count files by extension | Nothing — goose is not invoked |
| `grep -rl` to count patterns | Nothing |
| `jq -n` to write structured JSON | Nothing |

### Output: `detect.json`

```json
{
  "repo": "/path/to/project",
  "manifests": { "pom_xml": true, "package_json": false, ... },
  "files": { "java": 30, "python": 1, "javascript": 1001, ... },
  "patterns": { "javax_imports": 24, "ejb_files": 6, "mdb_files": 1, ... }
}
```

### What the user sees

```
── Step 1/5 — Detect ──
ℹ Step 1/5: detecting project structure
ℹ   1a. checking manifest files (pom.xml, package.json, etc.)...
✓   1a. manifests: pom=true pkg=false pyproj=false req=false setup=false
ℹ   1b. counting source files...
✓   1b. files: java=30 python=1 js=1001 ts=1
ℹ   1c. scanning for migration patterns (javax, EJB, MDB, py2, react)...
✓   1c. patterns: javax=24 ejb=6 mdb=1 weblogic=6 ...
ℹ   1d. writing detect.json...
✓ Step 1/5 complete → detect.json
```

### Why pure bash?

Counting files and grepping for patterns costs zero tokens. The LLM doesn't
need to waste turns on `find ... | wc -l` — bash does it in milliseconds.

---

## Step 2 — Plan (dynamic recipe, goose decides what to read)

**File:** `lib/step-plan.sh`

This is the most complex step. It has **no static recipe file** — the recipe
is rendered dynamically at runtime with the planner skill baked into the
instructions. Goose gets the developer extension so it can read files from
the repo as needed.

### What the recipe contains

The recipe is generated by `_render_plan_recipe()` and written to
`$RUN_DIR/plan-recipe.yaml`. It contains:

```
┌─────────────────────────────────────────────────────┐
│  instructions:                                       │
│    ┌─ PLANNER SKILL ──────────────────────────────┐ │
│    │  skills/migration-plan/SKILL.md (full text)   │ │  ← hardcoded: always loaded
│    └──────────────────────────────────────────────┘ │
│    ┌─ PRE-GATHERED CONTEXT ───────────────────────┐ │
│    │  detect.json (from step 1)                    │ │  ← pre-fed: already collected
│    │  file tree (source + config filenames only)   │ │  ← pre-fed: just a listing
│    │  available references (filenames only):       │ │  ← listed, NOT content
│    │    - javaee-quarkus.md                        │ │
│    │    - migration-phases.md                      │ │
│    └──────────────────────────────────────────────┘ │
│    YOUR JOB:                                         │
│    1. Read the pre-gathered context                  │
│    2. Pick and read relevant reference file(s)       │  ← goose decides
│    3. Read complex source files (MDBs, JNDI, etc.)  │  ← goose decides
│    4. Read relevant config files                     │  ← goose decides
│    5. Write PLAN.md                                  │
│                                                      │
│  extensions: [developer]                             │  ← goose has shell/cat/write
│  prompt: "Repo: ... Migration request: ..."          │
│  response: { json_schema: ... }                      │
└─────────────────────────────────────────────────────┘
```

### What's hardcoded vs what goose decides

| Hardcoded (pre-fed) | Goose decides at runtime |
|----------------------|--------------------------|
| Planner skill (always loaded) | Which reference to read (`javaee-quarkus.md`? `migration-phases.md`? none?) |
| detect.json (file counts, patterns) | Which build manifest to read (`pom.xml`? `package.json`? `build.gradle`?) |
| File tree (names only, no content) | Which config files to read (`persistence.xml`? `web.xml`? `application.yml`?) |
| Available reference filenames | Which source files to read (MDBs, JNDI lookups, complex patterns) |
| — | What the migration plan should look like |

### Why this split?

- **detect.json and file tree** are cheap metadata already collected in step 1.
  Pre-feeding them saves 2-3 tool calls (goose doesn't run `find` and `grep` again).
- **Build manifests, config files, references, source files** are NOT pre-fed
  because goose should decide what's relevant. A Spring Boot → Quarkus migration
  reads different files than a Python 2 → 3 migration.
- **The planner skill** is always loaded because it defines *how* to plan
  (layer ordering, phase structure, PLAN.md format). It's the method, not the content.

### Sub-steps in detail

```
2a. Pre-gather context
    Bash collects detect.json + file tree + reference filenames into a text blob.
    This is baked into the rendered recipe so goose has it on turn 1.

2b. Load planner skill
    Bash reads skills/migration-plan/SKILL.md and indents it into the recipe
    instructions block.

2c. Render recipe
    _render_plan_recipe() generates plan-recipe.yaml in $RUN_DIR.
    No static recipes/plan.yaml exists — it's always dynamic.

2d. Run goose (the LLM step)
    goose_run() invokes goose in background with live progress monitoring.
    Goose typically makes 5-10 tool calls:
      - cat javaee-quarkus.md         (picks the relevant reference)
      - cat pom.xml                   (reads the build manifest)
      - cat persistence.xml           (reads config it needs)
      - cat OrderServiceMDB.java      (reads a complex source file)
      - cat InventoryNotificationMDB.java  (another complex file)
      - write PLAN.md                 (the output)
      - recipe__final_output          (structured JSON confirmation)

    Live progress shows each tool call as it happens:
      ↳ shell: cat .../OrderServiceMDB.java
      ↳ thinking...
      ↳ write: /path/to/PLAN.md

2e. Validate PLAN.md
    Checks that PLAN.md was written and counts steps.

2f. Parse PLAN.md → plan.json
    _plan_md_to_json() converts the human-readable PLAN.md into structured
    JSON for step 3 (execute). Handles multiple formats:
      Format A: "### Step 1: Title\n- File: path\n- Action: MODIFY"
      Format B: "1. `path`\n   - description..."
      Format C: "29. **DELETE:** `path`"

2g. Human approval gate
    Shows PLAN.md and asks: Approve and execute? [y/edit/N]
    "edit" opens in $EDITOR, re-parses after save.

2h. Write .goosehints
    Generates <repo>/.goosehints with token discipline rules, migration
    order, and a checklist for the execution steps.
```

### What the user sees

```
── Step 2/5 — Plan (human approval gate) ──
ℹ Step 2/5: generating migration plan
ℹ   2a. gathering project context (detect results, file tree, manifests, configs)...
✓   2a. gathered 45 lines (3KB) of project context
ℹ   2b. loading planner skill and migration references...
✓   2b. loaded planner skill + 2 reference doc(s)
ℹ   2c. building plan recipe...
✓   2c. recipe ready (12KB — skill + context baked in)
ℹ   2d. running goose planner (reads complex files, writes PLAN.md)...
ℹ        this is the LLM step — may take 30-90s depending on model
       ↳ thinking...
       ↳ shell: cat references/javaee-quarkus.md
       ↳ shell: cat pom.xml
       ↳ shell: cat src/.../OrderServiceMDB.java
       ↳ thinking...
       ↳ write: /path/to/coolstore/PLAN.md
       ↳ finalizing output...
✓   2e. PLAN.md written — 34 steps (4 complex)
ℹ   2f. parsing PLAN.md → plan.json for downstream steps...
✓   2f. parsed 34 items from PLAN.md

══════════════════ PLAN ══════════════════
# PLAN.md
## Goal
Migrate coolstore from Java EE 7 to Quarkus 3
...
══════════════════════════════════════════

Approve and execute? [y/edit/N]:
```

### Turn limits

Plan step is capped at **15 turns**. With pre-gathered context, goose
typically finishes in 5-8 turns. The cap prevents runaway sessions.

---

## Steps 3–5 (brief)

### Step 3 — Execute (`recipes/execute.yaml`)

Loops over each item in `plan.json`. For each item, invokes goose with
the execute recipe (max 10 turns). Supports resume — already-completed
items are skipped.

### Step 4 — Verify (`recipes/verify.yaml`)

Single goose invocation (max 5 turns). Runs the build, reports pass/fail,
test counts, and up to 10 errors.

### Step 5 — Fix-loop (`recipes/fix.yaml`)

Bounded loop (default max 3 iterations). Each iteration: verify the build,
fix the first error, repeat. Stops when build is clean or max iterations hit.

---

## Other commands

```bash
migration-harness status    # summarize the last run
migration-harness resume    # resume the last run (skips completed items)
migration-harness step detect /path/to/app          # run one step
migration-harness step plan /path/to/app "..."      # run one step
```

---

## Why per-step invocations?

Each step is its own `goose run` process. This gives you:

- **Bounded token budget per step.** Step N doesn't inherit step 1's context.
- **Crash resilience.** If step 3 dies on item 17, only that item failed.
  Re-run with `resume`.
- **Cheaper detection.** Step 1 is pure bash — zero tokens spent on counting
  files. Only reasoning steps invoke the model.
- **Inspectable artifacts.** Every step writes JSON to
  `~/.migration-harness/runs/<id>/`. You can diff, replay, audit.

---

## Extending

### New migration type (e.g. Rails 5 → 7)

1. Add `skill-bundle/goose-migration/references/rails5-to-7.md` with patterns.
2. Add `skill-bundle/goose-migration/skills/rails5-to-7/SKILL.md` with rules.
3. Update the umbrella `SKILL.md` routing table.
4. Reinstall (`./install.sh`).
5. No recipe changes needed — goose picks the reference automatically.

### New step (e.g. backup before execute)

1. Add `recipes/backup.yaml`.
2. Add `lib/step-backup.sh` and source it from `bin/migration-harness`.
3. Insert into `cmd_run` between phases.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `credit balance too low` / API errors | Check provider billing. The harness now detects and reports this. |
| Skill doesn't auto-load | Verify `~/.config/goose/skills/goose-migration/SKILL.md` exists |
| `Model not found` | Run `goose configure`, then `migration-harness init` |
| Fix-loop hits max iterations | Read `verify-N.json` and `fix-N.json` in `~/.migration-harness/runs/<id>/` |
| Wrong provider | Run `migration-harness init` — it auto-detects from goose config |
