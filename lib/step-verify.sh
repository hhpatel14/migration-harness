#!/usr/bin/env bash
# lib/step-verify.sh — single-shot verify recipe call.
set -euo pipefail

step_verify() {
  local repo="$1"
  local out="$2"        # caller specifies path so fix-loop can re-verify
  local migration_type
  migration_type=$(jq -r '.migration_type' "$RUN_DIR/plan.json")

  info "Step 4/5: verifying build + tests (migration: $migration_type)"
  info "  invoking goose — running build, may take 30-120s..."

  goose_run "$MH_RECIPES/verify.yaml" --max-turns 5 \
    --params repo="$repo" \
    --params migration_type="$migration_type" \
  > "$out" || true

  if [[ ! -s "$out" ]] || [[ "$(cat "$out")" == "null" ]]; then
    err "  verify produced no output"
    return 1
  fi

  local build_ok tests_passed tests_total err_count
  build_ok=$(jq -r '.build_ok // false' "$out")
  tests_passed=$(jq -r '.tests_passed // 0' "$out")
  tests_total=$(jq -r '.tests_total // 0' "$out")
  err_count=$(jq -r '(.errors // []) | length' "$out")

  if [[ "$build_ok" == "true" ]]; then
    ok "  build: OK | tests: $tests_passed/$tests_total passed | errors: $err_count"
  else
    err "  build: FAILED | tests: $tests_passed/$tests_total passed | errors: $err_count"
  fi

  if (( err_count > 0 )); then
    info "  first error:"
    jq -r '.errors[0] | "    \(.file // "?"):\(.line // "?") — \(.message // "unknown")"' "$out" >&2
  fi

  # Return non-zero if build failed
  [[ "$build_ok" == "true" ]] || return 1
}
