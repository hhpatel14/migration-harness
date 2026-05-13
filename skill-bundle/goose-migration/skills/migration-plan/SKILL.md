---
name: migration-plan
description: >
  Sub-skill of migration-harness. Reads a project and a goal statement, then produces
  PLAN.md in the repo root. The plan is specific to THIS project — real file paths,
  real dependencies, real layer ordering. Does NOT execute any changes.
  Output is always PLAN.md and nothing else.
---

# Planner Sub-Skill

Reads the project, understands the goal, writes `PLAN.md`.
Does NOT modify any source files — planning only.

---

## Phase 1 — Understand the Goal

Parse the goal statement to extract:

- **What** needs to change (e.g. javax → jakarta, Python 2 → 3, .NET Framework → .NET 8)
- **Scope** — all files? specific layers? specific patterns?
- **Target state** — what does "done" look like?
- **Constraints** — anything to preserve, avoid, or be careful about?

---

## Phase 2 — Discover the Project

**If detect.json and file tree are provided in your context, skip this phase.**
Those are already collected — do NOT re-run discovery commands.

If NOT provided, run discovery commands. Read structure and metadata ONLY — no
file contents yet. Adapt commands to the detected project type.

```bash
# Project type detection
ls -la
cat pom.xml | grep -E "<packaging>|<parent>|<artifactId>" | head -10
cat package.json 2>/dev/null | head -20
cat *.csproj 2>/dev/null | head -20
cat requirements.txt 2>/dev/null | head -20

# Source file inventory
find . -type f -name "*.java" -o -name "*.cs" -o -name "*.py" | grep -v test | sort
find . -type f | grep test | sort

# Pattern scan (grep counts, not content)
grep -rl "javax\."     src 2>/dev/null | wc -l
grep -rl "@Stateless"  src 2>/dev/null | wc -l
grep -rl "@MessageDriven" src 2>/dev/null | wc -l
```

---

## Phase 3 — Identify What Needs Changing

Scan for patterns relevant to the goal. Still no full file reads — grep only.

Build a mental model:
- Which files are affected?
- What is the dependency order? (which files depend on which?)
- What are the hardest changes? (flag them)
- What can be done mechanically vs needs reasoning?

---

## Phase 4 — Read Selectively (max 5 files)

For files that need complex changes (e.g. MDB conversion, JNDI removal,
lifecycle listener replacement, DI container changes), read them NOW.

**Rules:**
- Read ONE file at a time
- Read ONLY files you need to understand to write accurate plan instructions
- Do NOT read files that only need mechanical import changes
- Maximum 5 file reads — if uncertain, mark the step ⚠️ and move on

---

## Phase 5 — Write PLAN.md

Write `PLAN.md` to the project root. Use this exact structure:

```markdown
# PLAN.md

## Goal
<restate the goal in one sentence>

## Project Summary
- Type: <Maven/Node/Python/.NET/etc>
- Files affected: <N>
- Estimated complexity: <Low/Medium/High>
- Hardest steps: <list the 1-3 most complex items>

## Steps

### Step 1: <title>
- File: <exact path from repo root>
- Action: <CREATE | MODIFY | DELETE>
- What to do: <specific instructions for this file>
- Why: <reason — what pattern is being changed>
- Depends on: <step numbers this must come after, or "none">
- Verify: <how to know this step is done correctly>

### Step 2: <title>
...

## Verification
<exact command(s) to run after all steps are done>

## Notes
<gotchas, special cases, decisions made>
```

### Rules for writing steps:

1. **One file per step** — never combine two files in one step
2. **Exact paths** — use real paths from discovery, not placeholders
3. **Dependency order** — steps that others depend on come first
4. **Layer order** — build config → app config → utils → persistence → models → services → REST/controllers → tests → cleanup/deletions
5. **Hard steps flagged** — add `⚠️ COMPLEX:` prefix to title for MDB, JNDI, architecture changes, lifecycle listeners
6. **DELETE steps last** — after all modifications are done
7. **Test files last** — after source files they test are migrated

### Step detail levels:

**Mechanical** (simple import swaps):
```markdown
### Step 5: Migrate Order.java imports
- File: src/main/java/com/example/model/Order.java
- Action: MODIFY
- What to do: Replace all `javax.persistence.*` → `jakarta.persistence.*`
- Why: Quarkus 3 uses Jakarta EE namespace
- Depends on: Step 1
- Verify: No `javax.` imports remain in file
```

**Complex** (structural changes — describe before/after pattern):
```markdown
### Step 14: ⚠️ COMPLEX — Convert OrderServiceMDB to Reactive
- File: src/main/java/com/example/service/OrderServiceMDB.java
- Action: MODIFY
- What to do:
    - Remove @MessageDriven, ActivationConfigProperty, implements MessageListener
    - Add @ApplicationScoped
    - Replace onMessage(Message msg) with @Incoming("orders") onMessage(String body)
    - Remove javax.jms.* imports, add org.eclipse.microprofile.reactive.messaging.*
    - Also update application.properties: add mp.messaging.incoming.orders.connector=smallrye-amqp
- Why: JMS/MDB not supported in Quarkus — replaced by SmallRye Reactive Messaging
- Depends on: Step 1 (pom needs smallrye-amqp extension), Step 2 (application.properties)
- Verify: No javax.jms imports, @Incoming annotation present, channel name matches config
```

---

## Phase 6 — Handoff

After writing PLAN.md, report:

```
✅ PLAN.md written
   Steps: <N>  |  Complex: <X>  |  Files affected: <Y>
```

Do not proceed further. The harness handles the approval gate.
