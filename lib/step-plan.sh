#!/usr/bin/env bash
# lib/step-plan.sh — invokes plan recipe, applies human approval gate.
set -euo pipefail

step_plan() {
  local repo="$1"
  local request="$2"
  local out="$RUN_DIR/plan-goose-output.json"
  local plan_md="$repo/PLAN.md"

  info "Step 2/5: generating migration plan"

  # ── 2a. Pre-gather project context ──
  info "  2a. gathering project context (detect results, file tree, manifests, configs)..."
  local skill_dir="$MH_INSTALL_DIR/skill-bundle/goose-migration"
  local context_file="$RUN_DIR/plan-context.txt"
  _pregather_context "$repo" "$skill_dir" > "$context_file"
  local context_lines context_kb
  context_lines=$(wc -l < "$context_file" | tr -d ' ')
  context_kb=$(( $(wc -c < "$context_file" | tr -d ' ') / 1024 ))
  ok "  2a. gathered ${context_lines} lines (${context_kb}KB) of project context"

  # ── 2b. Load planner skill + migration references ──
  info "  2b. loading planner skill and migration references..."
  local ref_count=0
  if [[ -d "$skill_dir/references" ]]; then
    ref_count=$(find "$skill_dir/references" -name "*.md" | wc -l | tr -d ' ')
  fi
  ok "  2b. loaded planner skill + ${ref_count} reference doc(s)"

  # ── 2c. Render recipe ──
  info "  2c. building plan recipe..."
  local rendered_recipe="$RUN_DIR/plan-recipe.yaml"
  _render_plan_recipe "$repo" "$request" "$context_file" > "$rendered_recipe"
  local recipe_kb
  recipe_kb=$(( $(wc -c < "$rendered_recipe" | tr -d ' ') / 1024 ))
  ok "  2c. recipe ready (${recipe_kb}KB — skill + context + references baked in)"

  # ── 2d. Run goose (the LLM call) ──
  info "  2d. running goose planner (reads complex files, writes PLAN.md)..."
  info "       this is the LLM step — may take 30-90s depending on model"

  goose_run "$rendered_recipe" --max-turns 15 \
    > "$out" || true

  # ── 2e. Validate PLAN.md ──
  if [[ -s "$plan_md" ]]; then
    local step_count complex_count
    step_count=$(grep -c '^### Step' "$plan_md" 2>/dev/null || echo 0)
    complex_count=$(grep -c '⚠️' "$plan_md" 2>/dev/null || echo 0)
    cp "$plan_md" "$RUN_DIR/PLAN.md"
    ok "  2e. PLAN.md written — ${step_count} steps (${complex_count} complex)"
  else
    fatal "plan failed — PLAN.md not written; see $RUN_DIR/logs/"
  fi

  # ── 2f. Parse PLAN.md → plan.json ──
  info "  2f. parsing PLAN.md → plan.json for downstream steps..."
  _plan_md_to_json "$plan_md" > "$RUN_DIR/plan.json"
  local item_count
  item_count=$(jq '.items | length' "$RUN_DIR/plan.json")
  ok "  2f. parsed ${item_count} items from PLAN.md"

  # ── 2g. Human approval gate ──
  echo
  printf "${C_BOLD}══════════════════ PLAN ══════════════════${C_X}\n" >&2
  cat "$plan_md" >&2
  printf "${C_BOLD}══════════════════════════════════════════${C_X}\n\n" >&2

  read -rp "Approve and execute? [y/edit/N]: " approval
  case "$approval" in
    y|Y|yes)
      ok "  2g. plan approved"
      ;;
    edit|e)
      "${EDITOR:-vi}" "$plan_md"
      cp "$plan_md" "$RUN_DIR/PLAN.md"
      _plan_md_to_json "$plan_md" > "$RUN_DIR/plan.json"
      ok "  2g. plan edited and re-parsed"
      ;;
    *)
      info "  2g. aborted by user"
      exit 0
      ;;
  esac

  # ── 2h. Write .goosehints ──
  info "  2h. writing .goosehints for execution steps..."
  write_hints "$repo" "$RUN_DIR/plan.json" "$request"
  ok "  2h. .goosehints written"

  ok "Step 2/5 complete"
}

# ── Render recipe with planner skill + pre-gathered context inlined ──
_render_plan_recipe() {
  local repo="$1"
  local request="$2"
  local context_file="$3"
  local skill_dir="$MH_INSTALL_DIR/skill-bundle/goose-migration"

  # Load planner skill
  local planner_skill=""
  if [[ -f "$skill_dir/skills/migration-plan/SKILL.md" ]]; then
    planner_skill=$(sed 's/^/    /' "$skill_dir/skills/migration-plan/SKILL.md")
  fi

  # Indent context for YAML block scalar
  local indented_context
  indented_context=$(sed 's/^/    /' "$context_file")

  cat <<RECIPE_EOF
version: "1.0.0"
title: "Migration plan"
description: "Generate PLAN.md using the planner skill."

settings:
  temperature: 1

extensions:
  - type: builtin
    name: developer
    timeout: 600
    bundled: true

instructions: |
  You are the planner sub-skill. Your ONLY job is to produce PLAN.md in the
  repo root. Do NOT modify any source files.

  === PLANNER SKILL ===
$planner_skill
  === END PLANNER SKILL ===

  === PRE-GATHERED CONTEXT ===
  Everything below was already collected — do NOT re-read these files or
  re-run discovery commands. This includes: detect.json, file tree,
  build manifests, config files, and ALL migration reference docs.
$indented_context
  === END PRE-GATHERED CONTEXT ===

  EFFICIENCY RULES:
  - All discovery data and references are above. Do NOT re-read them.
  - Use developer tools ONLY to read source files you need for complex
    steps (MDBs, JNDI lookups, architecture changes). Do NOT read files
    that only need mechanical import swaps.
  - Write PLAN.md to $repo/PLAN.md when done.

prompt: |
  Repo:              $repo
  Migration request: $request

  Follow the planner skill phases. All discovery data and references are
  already in your instructions. Read only complex source files you need,
  then write PLAN.md.

response:
  json_schema:
    type: object
    required: [plan_written, step_count]
    properties:
      plan_written: { type: boolean }
      step_count:   { type: integer }
      complex_count: { type: integer }
      summary:      { type: string }
RECIPE_EOF
}

# ── Pre-gather context that goose would otherwise fetch via tool calls ──
_pregather_context() {
  local repo="$1"
  local skill_dir="$2"

  echo "=== DETECTION SUMMARY ==="
  cat "$RUN_DIR/detect.json"
  echo ""

  echo "=== FILE TREE (source + config only) ==="
  find "$repo" -type f \
    \( -name "*.java" -o -name "*.py" -o -name "*.xml" -o -name "*.yaml" \
       -o -name "*.yml" -o -name "*.properties" -o -name "*.sql" \
       -o -name "*.json" -o -name "*.toml" -o -name "*.gradle" \
       -o -name "*.kt" -o -name "*.groovy" -o -name "Dockerfile" \) \
    -not -path "*/target/*" -not -path "*/node_modules/*" \
    -not -path "*/.git/*" -not -path "*/.vscode/*" \
    -not -path "*/bower_components/*" -not -path "*/.metadata/*" \
    | sed "s|^$repo/||" | sort
  echo ""

  # Build manifests
  for f in pom.xml package.json pyproject.toml requirements.txt build.gradle; do
    if [[ -f "$repo/$f" ]]; then
      echo "=== $f ==="
      cat "$repo/$f"
      echo ""
    fi
  done

  # Config files
  for f in \
    src/main/resources/META-INF/persistence.xml \
    src/main/resources/META-INF/beans.xml \
    src/main/webapp/WEB-INF/web.xml \
    src/main/webapp/WEB-INF/weblogic.xml \
    src/main/resources/application.properties \
    src/main/resources/application.yml \
  ; do
    if [[ -f "$repo/$f" ]]; then
      echo "=== $f ==="
      cat "$repo/$f"
      echo ""
    fi
  done

  # ALL migration references — goose picks what's relevant from context
  if [[ -d "$skill_dir/references" ]]; then
    echo "=== MIGRATION REFERENCES ==="
    for ref in "$skill_dir/references/"*.md; do
      [[ -f "$ref" ]] || continue
      echo "--- $(basename "$ref") ---"
      cat "$ref"
      echo ""
    done
  fi
}

# ── Parse PLAN.md into plan.json for downstream step_execute/step_verify ──
_plan_md_to_json() {
  local plan_md="$1"

  python3 - "$plan_md" <<'PYEOF'
import re, json, sys

plan_md = sys.argv[1]
with open(plan_md) as f:
    content = f.read()

# Extract goal
goal_match = re.search(r'## Goal\s*\n(.+?)(?=\n##|\Z)', content, re.DOTALL)
goal = goal_match.group(1).strip() if goal_match else ''

# Extract steps
items = []
step_pattern = re.compile(
    r'### Step (\d+):\s*(.*?)(?:\s*✅.*)?\n(.*?)(?=### Step \d+|## Verification|## Notes|\Z)',
    re.DOTALL
)
for m in step_pattern.finditer(content):
    n = int(m.group(1))
    title = m.group(2).strip()
    body = m.group(3)

    file_m = re.search(r'- File:\s*(.+)', body)
    action_m = re.search(r'- Action:\s*(\w+)', body)
    path = file_m.group(1).strip() if file_m else ''
    action = action_m.group(1).strip().lower() if action_m else 'migrate'

    action_map = {'modify': 'migrate', 'create': 'create', 'delete': 'delete'}
    action = action_map.get(action, action)

    risk = 'high' if '⚠️' in title or 'COMPLEX' in title else 'low'

    layer = 'unknown'
    if 'pom.xml' in path or 'package.json' in path or 'build.gradle' in path:
        layer = 'build'
    elif 'application.properties' in path or 'persistence.xml' in path or 'web.xml' in path:
        layer = 'config'
    elif '/model/' in path or '/domain/' in path or '/entity/' in path:
        layer = 'model'
    elif '/service/' in path:
        layer = 'service'
    elif '/rest/' in path or '/controller/' in path or '/api/' in path:
        layer = 'api'
    elif '/utils/' in path or '/util/' in path or '/helper/' in path:
        layer = 'util'
    elif '/persistence/' in path or '/repository/' in path:
        layer = 'persistence'

    items.append({
        'n': n, 'path': path, 'action': action,
        'layer': layer, 'risk': risk, 'notes': title
    })

# Detect migration type from goal
mt = 'custom'
if re.search(r'quarkus|java.?ee|jakarta', goal, re.I):
    mt = 'java-ee-to-quarkus'
elif re.search(r'python.?[23]', goal, re.I):
    mt = 'python2-to-python3'
elif re.search(r'react|hooks', goal, re.I):
    mt = 'react-class-to-hooks'

plan = {
    'migration_type': mt,
    'source_stack': goal,
    'target_stack': goal,
    'items': items
}
print(json.dumps(plan))
PYEOF
}

write_hints() {
  local repo="$1"
  local plan="$2"
  local request="$3"
  local hints="$repo/.goosehints"

  {
    echo "# AUTO-GENERATED by migration-harness"
    echo "# $(date) | request: $request"
    echo ""
    echo "## TOKEN DISCIPLINE"
    echo "- Read ONE file at a time"
    echo "- After writing each file: STOP"
    echo "- Do NOT re-read migrated files"
    echo "- Do NOT compile unless explicitly asked"
    echo ""
    echo "## Migration"
    jq -r '"- Source: \(.source_stack)\n- Target: \(.target_stack)\n- Type:   \(.migration_type)"' "$plan"
    echo ""
    echo "## Order"
    jq -r '.items[] | "\(.n). [\(.action)] \(.path)  — \(.notes)"' "$plan"
    echo ""
    echo "## Checklist"
    jq -r '.items[] | "- [ ] \(.n). \(.path)"' "$plan"
  } > "$hints"

  ok "  wrote $hints"
}
