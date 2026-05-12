#!/usr/bin/env bash
# lib/step-execute.sh — per-item stateless loop.
set -euo pipefail

step_execute() {
  local repo="$1"
  local plan="$RUN_DIR/plan.json"
  local migration_type
  migration_type=$(jq -r '.migration_type' "$plan")

  local total_items
  total_items=$(jq -r '.items | length' "$plan")
  info "Step 3/5: executing $total_items items (migration: $migration_type)"

  local ok_count=0 fail_count=0 skip_count=0 current=0

  while IFS= read -r item_json; do
    local n path action out
    n=$(echo "$item_json" | jq -r '.n')
    path=$(echo "$item_json" | jq -r '.path')
    action=$(echo "$item_json" | jq -r '.action')
    out="$RUN_DIR/item-$(printf '%03d' "$n").json"
    current=$((current + 1))

    # Resume: skip if already complete
    if [[ -s "$out" ]] && [[ "$(jq -r '.status' "$out" 2>/dev/null)" == "ok" ]]; then
      ok "  ($current/$total_items) #$n already done, skipping"
      ok_count=$((ok_count + 1))
      continue
    fi

    info "  ($current/$total_items) #$n [$action] $path"
    info "       invoking goose — this may take 15-60s per file..."

    goose_run "$MH_RECIPES/execute.yaml" --max-turns 10 \
      --params repo="$repo" \
      --params migration_type="$migration_type" \
      --params item_n="$n" \
      --params item_path="$path" \
      --params item_action="$action" \
    > "$out" || true

    # Check if we got valid output
    if [[ ! -s "$out" ]] || [[ "$(cat "$out")" == "null" ]]; then
      err "  ($current/$total_items) #$n goose produced no output"
      echo '{"status":"failed"}' > "$out"
      fail_count=$((fail_count + 1))
      continue
    fi

    local status
    status=$(jq -r '.status // "unknown"' "$out" 2>/dev/null)
    case "$status" in
      ok)
        ok_count=$((ok_count + 1))
        # Best-effort: tick the checklist (escape the dot in regex)
        sed -i.bak "s|- \[ \] ${n}\\\. |- [x] ${n}. |" "$repo/.goosehints" 2>/dev/null && rm -f "$repo/.goosehints.bak" || true
        ok "  ($current/$total_items) #$n done"
        ;;
      skipped)
        skip_count=$((skip_count + 1))
        warn "  ($current/$total_items) #$n skipped"
        ;;
      *)
        fail_count=$((fail_count + 1))
        err "  ($current/$total_items) #$n status=$status"
        ;;
    esac
  done < <(jq -c '.items[]' "$plan")

  jq -n --argjson ok "$ok_count" --argjson fail "$fail_count" --argjson skip "$skip_count" \
    '{ok:$ok, failed:$fail, skipped:$skip}' > "$RUN_DIR/execute-summary.json"

  echo
  ok "Step 3/5 complete: $ok_count ok, $fail_count failed, $skip_count skipped"
}
