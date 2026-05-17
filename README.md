# migration-harness

A CLI tool that drives `goose` through a 5-step code migration pipeline:
**detect → plan → execute → verify → fix-loop**. Each step is a separate
`goose run` invocation (mostly stateless except verify which supports resumption).
Migration expertise lives in the bundled skill files; per-run state lives on disk.

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
    ├── graph.json                          ←  code graph from graphify
    ├── GRAPH_REPORT.md                     ←  graph analysis summary
    ├── plan.json                           ←  structured migration plan
    ├── execution-log.md                    ←  lessons learned + errors per step
    ├── verification-report.md              ←  build status + auto-fix attempts
    └── fix-loop-report.md                  ←  fix iteration history
  <repo>/PLAN.md                            ←  human-readable migration plan
  <repo>/execution-log.md                   ←  execution progress (copied from run dir)
  <repo>/verification-report.md             ←  verification results (copied from run dir)
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
| 1 | **Detect** | graphify (Python AST) | No | `graph.json` + `GRAPH_REPORT.md` |
| 2 | **Plan** | goose (dynamic recipe) | Yes | `PLAN.md` + `plan.json` (tracks which reference used) |
| 3 | **Execute** | goose (per item) | Yes | modified source files + `execution-log.md` |
| 4 | **Verify** | goose (auto-fix 0-3 attempts) | Yes | `verification-report.md` (interactive resumption up to 140 turns) |
| 5 | **Fix-loop** | goose (conditional) | Yes | `fix-loop-report.md` (only runs if verify build failed) |

---

## Step 1 — Detect (graphify AST analysis, zero LLM tokens)

**File:** `lib/step-detect.sh`

This step uses **graphify** (Python-based AST analysis) — no goose, no LLM, no tokens spent.
It builds a complete code graph showing nodes (classes/functions), edges (dependencies),
and communities (related code clusters).

### What it does

```
1a. Check manifest files      → does pom.xml / package.json / pyproject.toml / etc. exist?
1b. Build code graph           → AST extraction, dependency edges, community detection
1c. Analyze file types         → extract counts from graph nodes
1d. Write detect.json          → structured metadata for planning
```

### Graphify vs Traditional Grep

| Traditional grep approach | Graphify approach |
|---------------------------|-------------------|
| Pattern matching on text | AST-based parsing |
| No relationships | Full dependency graph |
| No architecture insight | Community detection (clusters) |
| Fragile (misses obfuscated code) | Robust (parses syntax) |

### Output artifacts

**`graph.json`**:
```json
{
  "nodes": [
    {
      "id": "OrderService.placeOrder",
      "type": "method",
      "source_file": "services/OrderService.java",
      "degree": 23
    }
  ],
  "links": [
    {"source": "OrderService.placeOrder", "target": "InventoryService.reserve"}
  ],
  "communities": [
    {"id": 1, "nodes": ["OrderService", "InventoryService", ...]}
  ]
}
```

**`GRAPH_REPORT.md`**: Human-readable summary of architecture (communities, god nodes, key dependencies)

**`detect.json`**: Metadata summary
```json
{
  "repo": "/path/to/project",
  "manifests": { "pom_xml": true, "package_json": false, ... },
  "files": { "java": 30, "python": 1, "javascript": 1001, ... },
  "graph": { "nodes": 245, "edges": 687, "communities": 12, "god_nodes": 3 },
  "graph_file": "graph.json"
}
```

### What the user sees

```
── Step 1/5 — Detect ──
ℹ Step 1/5: detecting project structure
ℹ   1a. checking manifest files...
✓   1a. manifests: pom=true pkg=false pyproj=false req=false setup=false
ℹ   1b. building code graph (AST extraction, edges, communities)...
ℹ        this may take 10-30s for large codebases (parallelized across 12 workers)...
       Analyzing repository...
       Found 245 nodes, 687 edges
       Detected 12 communities
✓   1b. graph: 245 nodes, 687 edges, 12 communities (3 high-degree nodes)
ℹ   1c. analyzing file types from graph...
✓   1c. files: java=30 py=1 js=1001 ts=1
✓ Step 1/5 complete → detect.json + graph.json (245 nodes, 12 communities)

Graph outputs available in ~/.migration-harness/runs/<id>/:
  - graph.json         (full graph structure for planning)
  - GRAPH_REPORT.md    (human-readable summary)
```

### Why graphify?

- **Zero LLM tokens**: All analysis is Python-based AST parsing
- **Structured understanding**: Graph gives the planner architectural insights
- **Community detection**: Identifies related code clusters for phased migration
- **Dependency awareness**: Knows which files depend on which (execution ordering)
- **God node detection**: Highlights high-degree nodes needing special attention

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

2e2. Track which reference was used
    Extracts `reference_used` from goose response to prove which migration
    reference file the LLM actually read (e.g., "javaee-quarkus.md" vs "none").
    Displays: "✓ 2e2. reference used: javaee-quarkus.md"

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

### Turn limits and session management

| Step | Initial Turns | Max Total | Session Type | Resumable? |
|------|---------------|-----------|--------------|------------|
| **Plan** | 15 | 15 | Ephemeral (`--no-session`) | No |
| **Execute** (per item) | 10 | 10 | Ephemeral (`--no-session`) | No |
| **Verify** | 50 | 140 | Persistent (auto-deleted) | **Yes** (interactive) |
| **Fix** (per error) | 8 | 8 | Ephemeral (`--no-session`) | No |

**Why verify is different:**
- Complex migrations can have 28+ compilation errors
- Auto-fix needs: read errors → read files → fix files → re-compile → repeat (3x)
- Can easily need 80-100 turns for complex cases
- Interactive resumption lets user control token spend
- All other steps are bounded by design (small focused tasks)

---

## Step 3 — Execute (per-item execution with lessons learned)

**File:** `lib/step-execute.sh`  
**Recipe:** `recipes/execute.yaml`

Loops over each item in `plan.json`. For each item, invokes goose with
the execute recipe (max 10 turns). Supports resume — already-completed
items are skipped.

### What's new

- **Reads PLAN.md for context**: Each execution gets the full Goal and Project Summary
  to understand the migration intent (not just isolated file changes)
- **Creates execution-log.md**: Tracks lessons learned and errors for each step:
  - **Lessons**: What patterns worked, what to watch out for
  - **Errors**: Syntax errors, compilation issues encountered during execution
  - Used by verification step to understand what execution attempted

### Output: `execution-log.md`

```markdown
# Execution Log

**Migration:** javaee-quarkus
**Started:** 2026-05-17 10:23:15

---

## Step #1: MODIFY - src/main/java/services/OrderService.java

**Status:** ok
**Files touched:** OrderService.java, pom.xml

**Lesson learned:**
Changed `javax.ejb.Stateless` to `jakarta.enterprise.context.ApplicationScoped`.
Also needed to add `quarkus-arc` dependency to pom.xml for CDI support.

---

## Step #2: MODIFY - src/main/resources/META-INF/persistence.xml

**Status:** ok
**Files touched:** persistence.xml

**Lesson learned:**
Quarkus auto-configures datasources. Removed explicit DataSource JNDI lookups.

**Errors:**
Initial attempt had syntax error in application.properties (missing =).
Fixed by correcting property format.

---
```

### Why execution-log.md matters

When verification finds compilation errors, it reads `execution-log.md` to understand:
- What changes were attempted
- What patterns were already tried
- What known issues execution ran into
This context helps verification auto-fix intelligently instead of blindly re-attempting
the same failed approaches.

---

## Step 4 — Verify (auto-fix with interactive resumption)

**File:** `lib/step-verify.sh`  
**Recipe:** `recipes/verify.yaml`

Runs build/tests and **auto-fixes compilation errors** (up to 3 fix iterations).
Uses **interactive session resumption** for complex migrations that need >50 turns.

### What it does

**Phase 1 — Read verification steps:**
1. Reads `PLAN.md` → locates "## Verification" section
2. This section contains build commands (e.g., `mvn compile`, `dotnet build`)

**Phase 2 — Run verification:**
3. Executes the verification commands
4. Captures build status, test results, compilation errors

**Phase 3 — Auto-fix (0-3 iterations):**
5. If compilation **fails**:
   - Reads `execution-log.md` to understand what execution attempted
   - Identifies root cause of failures
   - Makes targeted fixes to resolve compilation errors
   - Re-runs verification
   - Repeats up to **3 times total**
6. If still failing after 3 attempts → documents remaining errors

### Interactive session resumption

**The problem**: Complex migrations (e.g., .NET with 28+ errors) can need 80-100 turns
to complete auto-fix. If goose hits the 50-turn limit, you get **zero output** even
though it made progress.

**The solution**: 
- Starts with **50 turns** (initial budget)
- If incomplete, asks user: `"Continue with more turns? [Y/n]"`
- If yes, prompts: `"How many more turns to add? [default: 30, max: 90]"`
- Resumes **same session** with additional turns (preserves all context)
- Max total: **140 turns**
- Auto-cleanup: Session deleted when done (success or failure)

### Example flow

```
ℹ   running goose session 'verify-1234567890' (turns: 50 / 140)...
[... goose runs verification, fixes 15/28 errors ...]
⚠   session incomplete (used 50 turns so far)
Continue with more turns? [Y/n]: y

How many more turns to add? [default: 30, max: 90]: 40

ℹ   running goose session 'verify-1234567890' (turns: 90 / 140)...
[... goose continues from where it left off, fixes remaining errors ...]
✓   session completed successfully
```

### Output: `verification-report.md`

```markdown
# Verification Report

**Migration:** dotnet-upgrade
**Timestamp:** 2026-05-17 10:45:32

## Build Status

- ✅ Compilation: **SUCCESS**
- Tests: 45/50 passed

## Auto-Fix Attempts

- Fix iterations: 2
- Fixes applied: Fixed missing `using` statements in 3 controllers, updated NuGet packages

## Summary

Build successful after 2 auto-fix iterations. 5 tests still failing (require manual review).
```

### What the user sees

```
── Step 4/5 — Verify ──
ℹ Step 4/5: verifying build + tests (migration: javaee-quarkus)
ℹ   invoking goose — running verification with auto-fix (up to 3 attempts)...
ℹ   this may take 2-5 minutes depending on project size...
ℹ   session will ask for more turns if needed (max total: 140)
ℹ        running goose session 'verify-1778991023-7963' (turns: 50 / 140)...
       ↳ shell: cat PLAN.md
       ↳ shell: mvn compile
       ↳ thinking...
       ↳ shell: cat src/main/java/OrderService.java
       ↳ edit: fixing import statement
       ↳ shell: mvn compile
       ↳ thinking...
ℹ   fix attempts: 2
ℹ   fixes: Fixed missing jakarta.inject imports, updated EJB annotations
✓   build: OK | tests: 45/50 passed | errors: 0
ℹ   verification report: ~/.migration-harness/runs/<id>/verification-report.md
```

### Session management

**Only verify uses persistent sessions** (all other steps use `--no-session`):
- **Detect**: No goose (Python graphify)
- **Plan**: Ephemeral session (`--no-session`)
- **Execute** (per item): Ephemeral session (`--no-session`)
- **Verify**: Persistent session (for resumption), **auto-deleted after completion**
- **Fix-loop** (per fix): Ephemeral session (`--no-session`)

**Net result**: Zero sessions accumulate on disk.

---

## Step 5 — Fix-loop (conditional, only if verify fails)

**File:** `lib/step-fix-loop.sh`  
**Recipe:** `recipes/fix.yaml`

Bounded loop (default max 3 iterations) that **only runs if Step 4 verification failed**.

### Conditional execution

```bash
# Check build status from verification-report.md
if build_ok == true:
  ✓ "build status: SUCCESS (from verification report)"
  ✓ "fix loop not needed — skipping"
  return success

# Only run if build failed
⚠ "build status: FAILED (from verification report)"
ℹ "starting fix loop (max 3 iterations)..."
```

### What it does (if build failed)

Each iteration:
1. Re-runs verification (creates `verify-fix-N.json`)
2. If build clean → success, write `fix-loop-report.md`, done
3. If errors remain:
   - Reads `verification-report.md` for full error context
   - Picks first error
   - Invokes goose with `fix.yaml` (max 8 turns) to fix **one error**
   - Repeats

### Output: `fix-loop-report.md`

**Success case:**
```markdown
# Fix Loop Report

**Migration:** javaee-quarkus
**Status:** ✅ **SUCCESS**
**Iterations:** 2

## Fixes Applied

### Iteration 1

- **File:** OrderService.java
- **Summary:** Fixed missing @Inject annotation on InventoryService dependency

### Iteration 2

- **File:** pom.xml
- **Summary:** Added missing quarkus-hibernate-orm dependency

## Result

All compilation errors resolved. Build is now successful.
```

**Max iterations case:**
```markdown
# Fix Loop Report

**Migration:** dotnet-upgrade
**Iterations:** 3
**Status:** Manual intervention needed (max iterations reached)

## Attempted Fixes

### Iteration 1
- **File:** HomeController.cs
- **Summary:** Fixed missing using statement for AspNetCore.Mvc

### Iteration 2
- **File:** Startup.cs
- **Summary:** Updated middleware configuration for .NET 6

### Iteration 3
- **File:** appsettings.json
- **Summary:** Fixed connection string format

## Next Steps

Manual intervention is required. Review the remaining errors in verification-report.md
```

### Why fix-loop after verify auto-fix?

**Verify auto-fix** (Step 4):
- Fixes **obvious patterns** in one smart session (has full context)
- Fast (2-5 minutes)
- Catches 60-80% of errors

**Fix-loop** (Step 5):
- Handles **remaining tricky errors** one at a time
- Slower (focused, isolated fixes)
- Needed only if verify couldn't finish the job

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

Each step is its own `goose run` process (except verify which uses resumable sessions). This gives you:

- **Bounded token budget per step.** Step N doesn't inherit step 1's context.
- **Crash resilience.** If step 3 dies on item 17, only that item failed.
  Re-run with `resume`.
- **Zero-token detection.** Step 1 uses graphify (Python AST) — zero LLM tokens
  spent on structural analysis. Only reasoning steps invoke the model.
- **Interactive resumption.** Verify can continue with more turns if needed (up to 140 total),
  preserving all context without restarting from scratch.
- **Inspectable artifacts.** Every step writes structured logs to
  `~/.migration-harness/runs/<id>/`. You can diff, replay, audit.
- **Context accumulation.** `execution-log.md` captures lessons from execution,
  `verification-report.md` shows auto-fix attempts — each step builds on the previous.

---

## Artifacts and Logs

Each migration run creates structured artifacts in `~/.migration-harness/runs/<id>/`:

| File | Created by | Purpose |
|------|-----------|---------|
| `detect.json` | Step 1 | Project metadata (manifests, file counts, graph stats) |
| `graph.json` | Step 1 | Full code graph (nodes, edges, communities) |
| `GRAPH_REPORT.md` | Step 1 | Human-readable graph analysis |
| `plan-recipe.yaml` | Step 2 | Dynamically rendered recipe for planning |
| `plan.json` | Step 2 | Structured migration plan (parsed from PLAN.md) |
| `PLAN.md` | Step 2 | Human-readable migration plan (copied to repo) |
| `execution-log.md` | Step 3 | Lessons learned + errors per execution step |
| `item-N.json` | Step 3 | Per-item execution results |
| `verification-report.md` | Step 4 | Build status, auto-fix attempts, remaining errors |
| `verify.json` | Step 4 | Structured verification results |
| `verify-fix-N.json` | Step 5 | Re-verification results per fix iteration |
| `fix-N.json` | Step 5 | Per-fix results |
| `fix-loop-report.md` | Step 5 | Fix iteration history and final status |
| `logs/*.json` | All steps | Raw goose session transcripts |

**Copied to repo root:**
- `PLAN.md` — migration plan
- `execution-log.md` — execution progress
- `verification-report.md` — verification results
- `fix-loop-report.md` — fix history (if applicable)

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
| `verify produced no output` | Verification hit turn limit without completing. Re-run verify step — it will ask to continue with more turns (up to 140 total). |
| `goose produced no log output` | Goose command failed immediately. Check goose version supports `--name` flag (`goose run --help`). Ensure goose is properly configured. |
| `session incomplete (used N turns)` | Normal for complex migrations. Answer `y` to continue, specify how many more turns to add (default 30). |
| `credit balance too low` / API errors | Check provider billing. The harness detects and reports this. |
| Skill doesn't auto-load | Verify `~/.config/goose/skills/goose-migration/SKILL.md` exists |
| `Model not found` | Run `goose configure`, then `migration-harness init` |
| Fix-loop hits max iterations | Read `verification-report.md` and `fix-loop-report.md` for attempted fixes. May need manual intervention. |
| Wrong provider | Run `migration-harness init` — it auto-detects from goose config |
| Graphify fails | Ensure `pip install graphifyy` or check Python version (needs 3.8+) |
| Verification auto-fix too aggressive | It only auto-fixes compilation errors, not logic bugs. Check `verification-report.md` for what was changed. |
| Sessions accumulating | Only verify creates sessions, and they're auto-deleted after completion. Check `goose session list` if concerned. |
