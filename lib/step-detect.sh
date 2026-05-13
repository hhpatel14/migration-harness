#!/usr/bin/env bash
# lib/step-detect.sh — structural inspection of the repo. No goose, no tokens.
set -euo pipefail

step_detect() {
  local repo="$1"
  local out="$RUN_DIR/detect.json"

  info "Step 1/5: detecting project structure"

  # ── 1a. Check manifest files ──
  info "  1a. checking manifest files (pom.xml, package.json, etc.)..."
  local has_pom=false has_pkg=false has_pyproj=false has_reqtxt=false has_setup=false
  [[ -f "$repo/pom.xml" ]]          && has_pom=true
  [[ -f "$repo/package.json" ]]     && has_pkg=true
  [[ -f "$repo/pyproject.toml" ]]   && has_pyproj=true
  [[ -f "$repo/requirements.txt" ]] && has_reqtxt=true
  [[ -f "$repo/setup.py" ]]         && has_setup=true
  ok "  1a. manifests: pom=$has_pom pkg=$has_pkg pyproj=$has_pyproj req=$has_reqtxt setup=$has_setup"

  # ── 1b. Count source files by language ──
  info "  1b. counting source files..."
  local java_files py_files js_files ts_files cs_files go_files rb_files rs_files
  java_files=$(find "$repo" -name "*.java" -not -path "*/target/*" 2>/dev/null | wc -l | tr -d ' ')
  py_files=$(find "$repo" -name "*.py" -not -path "*/.venv/*" -not -path "*/venv/*" 2>/dev/null | wc -l | tr -d ' ')
  js_files=$(find "$repo" \( -name "*.js" -o -name "*.jsx" \) -not -path "*/node_modules/*" 2>/dev/null | wc -l | tr -d ' ')
  ts_files=$(find "$repo" \( -name "*.ts" -o -name "*.tsx" \) -not -path "*/node_modules/*" 2>/dev/null | wc -l | tr -d ' ')
  cs_files=$(find "$repo" -name "*.cs" -not -path "*/bin/*" -not -path "*/obj/*" 2>/dev/null | wc -l | tr -d ' ')
  go_files=$(find "$repo" -name "*.go" -not -path "*/vendor/*" 2>/dev/null | wc -l | tr -d ' ')
  rb_files=$(find "$repo" -name "*.rb" 2>/dev/null | wc -l | tr -d ' ')
  rs_files=$(find "$repo" -name "*.rs" -not -path "*/target/*" 2>/dev/null | wc -l | tr -d ' ')
  ok "  1b. files: java=$java_files python=$py_files js=$js_files ts=$ts_files cs=$cs_files go=$go_files ruby=$rb_files rust=$rs_files"

  # ── 1c. Detect migration-relevant patterns ──
  info "  1c. scanning for migration patterns (javax, EJB, MDB, py2, react)..."
  local javax_count=0 ejb_count=0 mdb_count=0 weblogic_count=0
  local py2_print=0 py2_xrange=0
  local react_class=0

  if [[ "$has_pom" == true ]] && [[ -d "$repo/src" ]]; then
    javax_count=$({ grep -rl "javax\." "$repo/src" 2>/dev/null || true; } | wc -l | tr -d ' ')
    ejb_count=$({ grep -rl "@Stateless\|@Stateful\|@EJB" "$repo/src" 2>/dev/null || true; } | wc -l | tr -d ' ')
    mdb_count=$({ grep -rl "@MessageDriven" "$repo/src" 2>/dev/null || true; } | wc -l | tr -d ' ')
    weblogic_count=$(find "$repo/src" -path "*/weblogic/*" 2>/dev/null | wc -l | tr -d ' ')
  fi

  if (( py_files > 0 )); then
    py2_print=$({ grep -rE '^[[:space:]]*print[[:space:]]+["'"'"']' "$repo" --include="*.py" 2>/dev/null || true; } | wc -l | tr -d ' ')
    py2_xrange=$({ grep -rl "xrange(" "$repo" --include="*.py" 2>/dev/null || true; } | wc -l | tr -d ' ')
  fi

  if (( js_files + ts_files > 0 )); then
    react_class=$({ grep -rlE "extends (React\.)?Component" "$repo" --include="*.jsx" --include="*.tsx" --include="*.js" --include="*.ts" 2>/dev/null || true; } | wc -l | tr -d ' ')
  fi
  ok "  1c. patterns: javax=$javax_count ejb=$ejb_count mdb=$mdb_count weblogic=$weblogic_count py2_print=$py2_print py2_xrange=$py2_xrange react_class=$react_class"

  # ── 1d. Write detect.json ──
  info "  1d. writing detect.json..."
  jq -n \
    --arg repo "$repo" \
    --argjson manifests "$(jq -n --argjson pom "$has_pom" --argjson pkg "$has_pkg" \
                              --argjson pyproj "$has_pyproj" --argjson reqtxt "$has_reqtxt" \
                              --argjson setup "$has_setup" \
                              '{pom_xml:$pom, package_json:$pkg, pyproject_toml:$pyproj, requirements_txt:$reqtxt, setup_py:$setup}')" \
    --argjson files "$(jq -n --argjson j "$java_files" --argjson p "$py_files" \
                             --argjson js "$js_files" --argjson ts "$ts_files" \
                             --argjson cs "$cs_files" --argjson go "$go_files" \
                             --argjson rb "$rb_files" --argjson rs "$rs_files" \
                             '{java:$j, python:$p, javascript:$js, typescript:$ts, csharp:$cs, go:$go, ruby:$rb, rust:$rs}')" \
    --argjson patterns "$(jq -n \
                             --argjson jx "$javax_count" --argjson ejb "$ejb_count" \
                             --argjson mdb "$mdb_count" --argjson wl "$weblogic_count" \
                             --argjson p2p "$py2_print" --argjson p2x "$py2_xrange" \
                             --argjson rc "$react_class" \
                             '{javax_imports:$jx, ejb_files:$ejb, mdb_files:$mdb, weblogic_stubs:$wl, py2_print_stmts:$p2p, py2_xrange_files:$p2x, react_class_components:$rc}')" \
    '{repo:$repo, manifests:$manifests, files:$files, patterns:$patterns}' \
  > "$out"

  ok "Step 1/5 complete → $out"
}
