#!/usr/bin/env bash
# lib/step-fix-loop.sh — bounded verify/fix iteration.
set -euo pipefail

step_fix_loop() {
  local repo="$1"
  local migration_type
  migration_type=$(jq -r '.migration_type' "$RUN_DIR/plan.json")
  local max="${MH_MAX_FIX_ITERATIONS:-3}"

  info "Step 5/5: verify/fix loop (max $max iterations)"

  local iter=1
  while (( iter <= max )); do
    local verify_out="$RUN_DIR/verify-$iter.json"

    info "  iteration $iter/$max — verifying..."
    if step_verify "$repo" "$verify_out"; then
      local err_count
      err_count=$(jq -r '(.errors // []) | length' "$verify_out" 2>/dev/null || echo 0)
      if (( err_count == 0 )); then
        ok "  iteration $iter/$max — build clean, no errors!"
        ok "Step 5/5 complete"
        return 0
      fi
    fi

    # Check if we have errors to fix
    if [[ ! -s "$verify_out" ]]; then
      err "  iteration $iter/$max — verify produced no output; stopping"
      return 1
    fi

    local err_count
    err_count=$(jq -r '(.errors // []) | length' "$verify_out" 2>/dev/null || echo 0)
    if (( err_count == 0 )); then
      warn "  iteration $iter/$max — build not OK but no errors reported; cannot auto-fix"
      return 1
    fi

    local err_file err_msg
    err_file=$(jq -r '.errors[0].file // "unknown"' "$verify_out")
    err_msg=$(jq -r '.errors[0].message // "unknown error"' "$verify_out")

    info "  iteration $iter/$max — fixing: $err_file"
    info "       error: ${err_msg:0:100}"
    info "       invoking goose to fix..."

    local fix_out="$RUN_DIR/fix-$iter.json"
    goose_run "$MH_RECIPES/fix.yaml" --max-turns 8 \
      --params repo="$repo" \
      --params migration_type="$migration_type" \
      --params error_file="$err_file" \
      --params error_message="$err_msg" \
    > "$fix_out" || true

    if [[ ! -s "$fix_out" ]] || [[ "$(cat "$fix_out")" == "null" ]]; then
      err "  iteration $iter/$max — fix produced no output"
      return 1
    fi

    local fixed
    fixed=$(jq -r '.fixed // false' "$fix_out" 2>/dev/null)
    if [[ "$fixed" != "true" ]]; then
      err "  iteration $iter/$max — fix did not succeed ($err_file)"
      jq -r '.summary // empty' "$fix_out" >&2 2>/dev/null || true
      return 1
    fi

    local file_changed
    file_changed=$(jq -r '.file_changed // "?"' "$fix_out")
    ok "  iteration $iter/$max — fixed $file_changed"
    iter=$((iter + 1))
  done

  warn "  hit max iterations ($max) — manual intervention needed"
  return 1
}
