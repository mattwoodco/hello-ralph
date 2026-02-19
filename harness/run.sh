#!/usr/bin/env bash
set -uo pipefail

# Ralph CI — Main Loop Runner
# Exit codes: 0=success, 2=circuit breaker, 3=kill switch, 4=budget exceeded, 5=timeout

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$PROJECT_DIR/ralph.config.json"
STATE_DIR="$PROJECT_DIR/.ralph"
LOG_DIR="$STATE_DIR/logs"

# ─── Loop ID (for parallel execution isolation) ─────────────────────────────
LOOP_ID="${RALPH_LOOP_ID:-0}"
STATE_FILE="$STATE_DIR/.harness_state_${LOOP_ID}"

# ─── Load Config ─────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG" ]]; then
  echo "FATAL: $CONFIG not found" >&2
  exit 1
fi
if ! jq empty "$CONFIG" 2>/dev/null; then
  echo "FATAL: $CONFIG is not valid JSON" >&2
  exit 1
fi

config() { jq -r "$1 // empty" "$CONFIG"; }

MODE=$(config '.mode')
MAX_ITER=$(config '.maxIterations')
TIMEOUT_MIN=$(config '.timeoutMinutes')
ITER_TIMEOUT_MIN=$(config '.iterationTimeoutMinutes')
MODEL=$(config '.model')
KILL_VAR=$(config '.killSwitch')
BUDGET_MAX=$(config '.budgetMaxUsd')
LOG_RETENTION=$(config '.logRetention')
NO_PROGRESS_THRESH=$(config '.circuitBreaker.noProgressThreshold')
SAME_ERROR_THRESH=$(config '.circuitBreaker.sameErrorThreshold')

# Defaults for missing config fields
: "${MODE:=build}"
: "${MAX_ITER:=40}"
: "${TIMEOUT_MIN:=180}"
: "${ITER_TIMEOUT_MIN:=30}"
: "${MODEL:=claude-sonnet-4-6}"
: "${KILL_VAR:=RALPH_ENABLED}"
: "${BUDGET_MAX:=50}"
: "${LOG_RETENTION:=20}"
: "${NO_PROGRESS_THRESH:=3}"
: "${SAME_ERROR_THRESH:=5}"

# ─── Cross-platform timeout command ─────────────────────────────────────────
if command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
else
  echo "WARN: No timeout command found (install coreutils). Per-iteration timeout disabled." >&2
  TIMEOUT_CMD=""
fi

# ─── Source .ralphrc for claude settings ─────────────────────────────────────
RALPHRC="$PROJECT_DIR/.ralphrc"
if [[ -f "$RALPHRC" ]]; then
  # shellcheck source=/dev/null
  source "$RALPHRC"
fi

# ─── Init State ──────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    ITERATION=$(jq -r '.iteration // 0' "$STATE_FILE")
    TOTAL_COST=$(jq -r '.total_cost // 0' "$STATE_FILE")
    NO_PROGRESS_COUNT=$(jq -r '.no_progress_count // 0' "$STATE_FILE")
    LAST_ERROR=$(jq -r '.last_error // ""' "$STATE_FILE")
    SAME_ERROR_COUNT=$(jq -r '.same_error_count // 0' "$STATE_FILE")
  else
    ITERATION=0
    TOTAL_COST=0
    NO_PROGRESS_COUNT=0
    LAST_ERROR=""
    SAME_ERROR_COUNT=0
  fi
}

save_state() {
  local tmp_state="${STATE_FILE}.tmp"
  cat > "$tmp_state" << STATEEOF
{
  "iteration": $ITERATION,
  "total_cost": $TOTAL_COST,
  "no_progress_count": $NO_PROGRESS_COUNT,
  "last_error": $(echo "$LAST_ERROR" | jq -Rs .),
  "same_error_count": $SAME_ERROR_COUNT,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mode": "$MODE",
  "loop_id": "$LOOP_ID"
}
STATEEOF
  mv "$tmp_state" "$STATE_FILE"  # atomic write
}

load_state

# ─── Secret-safe logging ────────────────────────────────────────────────────
sanitize() {
  sed -E 's/(API_KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL)[=:][^ "]+/\1=***REDACTED***/gi'
}

log() {
  echo "[$(date -u +%H:%M:%S)][loop-$LOOP_ID] $*" | sanitize
}

# ─── Cleanup trap ────────────────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  log "Cleaning up (exit code: $exit_code)"

  # Kill orphaned chromium processes
  pkill -f "chromium.*--headless" 2>/dev/null || true
  pkill -f "chrome.*--headless" 2>/dev/null || true

  # Save final state
  save_state

  # Report final status
  if [[ $exit_code -ne 0 ]]; then
    "$SCRIPT_DIR/report.sh" --event failure --exit-code "$exit_code" --loop-id "$LOOP_ID" || true
  fi
}
trap cleanup EXIT

# ─── Log rotation ────────────────────────────────────────────────────────────
rotate_logs() {
  local count
  count=$(find "$LOG_DIR" -name "loop_${LOOP_ID}_*.log" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$count" -gt "$LOG_RETENTION" ]]; then
    local to_remove=$((count - LOG_RETENTION))
    find "$LOG_DIR" -name "loop_${LOOP_ID}_*.log" -type f -print0 | \
      xargs -0 ls -t | tail -n "$to_remove" | xargs rm -f
    log "Rotated $to_remove old log files"
  fi
}

# ─── Main Loop ───────────────────────────────────────────────────────────────
log "Ralph CI starting — mode=$MODE, max_iter=$MAX_ITER, budget=\$$BUDGET_MAX"
log "Resuming from iteration $ITERATION, accumulated cost=\$$TOTAL_COST"

LOOP_START=$(date +%s)

while [[ "$ITERATION" -lt "$MAX_ITER" ]]; do
  ITERATION=$((ITERATION + 1))
  ITER_LOG="$LOG_DIR/loop_${LOOP_ID}_iter_${ITERATION}.log"

  log "━━━ Iteration $ITERATION / $MAX_ITER ━━━"

  # ── 1. Kill switch check ──
  KILL_VALUE="${!KILL_VAR:-true}"
  if [[ "$KILL_VALUE" == "false" || "$KILL_VALUE" == "0" ]]; then
    log "Kill switch $KILL_VAR is disabled. Exiting."
    "$SCRIPT_DIR/report.sh" --event kill_switch --loop-id "$LOOP_ID" || true
    exit 3
  fi

  # ── 2. Workflow timeout check ──
  NOW=$(date +%s)
  ELAPSED_MIN=$(( (NOW - LOOP_START) / 60 ))
  if [[ "$ELAPSED_MIN" -ge "$TIMEOUT_MIN" ]]; then
    log "Workflow timeout reached ($ELAPSED_MIN >= $TIMEOUT_MIN min). Exiting."
    exit 5
  fi

  # ── 3. Record start SHA ──
  START_SHA=$(cd "$PROJECT_DIR" && git --no-pager rev-parse HEAD 2>/dev/null || echo "no-git")

  # ── 4. Run check.sh — if passes, we're done ──
  log "Running check.sh..."
  if "$SCRIPT_DIR/check.sh" > "$ITER_LOG.check" 2>&1; then
    log "All checks passed! Ralph CI complete."
    "$SCRIPT_DIR/report.sh" --event success --loop-id "$LOOP_ID" || true
    exit 0
  fi

  # ── 5. Run claude with per-iteration timeout ──
  log "Running claude (timeout: ${ITER_TIMEOUT_MIN}m, model: $MODEL)..."

  CLAUDE_ARGS=(
    --print
    --output-format json
    --model "$MODEL"
    --max-turns 30
  )

  # Add allowed tools from .ralphrc
  if [[ -n "${CLAUDE_ALLOWED_TOOLS:-}" ]]; then
    CLAUDE_ARGS+=(--allowedTools "$CLAUDE_ALLOWED_TOOLS")
  fi

  # Capture raw JSON output (do NOT pipe through sanitize — it corrupts JSON fields)
  CLAUDE_OUTPUT=""
  CLAUDE_EXIT=0
  if [[ -n "$TIMEOUT_CMD" ]]; then
    CLAUDE_OUTPUT=$(cd "$PROJECT_DIR" && "$TIMEOUT_CMD" "${ITER_TIMEOUT_MIN}m" \
      claude "${CLAUDE_ARGS[@]}" \
      "Read .ralph/PLAN.md, find the first PENDING step, execute it, run checks, update PLAN.md." \
      2>"$ITER_LOG") || CLAUDE_EXIT=$?
  else
    CLAUDE_OUTPUT=$(cd "$PROJECT_DIR" && \
      claude "${CLAUDE_ARGS[@]}" \
      "Read .ralph/PLAN.md, find the first PENDING step, execute it, run checks, update PLAN.md." \
      2>"$ITER_LOG") || CLAUDE_EXIT=$?
  fi

  if [[ $CLAUDE_EXIT -eq 124 ]]; then
    log "Claude timed out after ${ITER_TIMEOUT_MIN}m"
  elif [[ $CLAUDE_EXIT -ne 0 ]]; then
    log "Claude exited with code $CLAUDE_EXIT"
  else
    log "Claude completed successfully"
  fi

  # ── 6. Parse output for cost ──
  ITER_COST=0
  if [[ -n "$CLAUDE_OUTPUT" ]]; then
    ITER_COST=$(echo "$CLAUDE_OUTPUT" | jq -r '.cost_usd // .total_cost_usd // .result.cost_usd // 0' 2>/dev/null || echo "0")
  fi
  TOTAL_COST=$(echo "$TOTAL_COST + $ITER_COST" | bc 2>/dev/null || echo "$TOTAL_COST")

  # ── 7. Budget check ──
  OVER_BUDGET=$(echo "$TOTAL_COST > $BUDGET_MAX" | bc 2>/dev/null || echo "0")
  if [[ "$OVER_BUDGET" == "1" ]]; then
    log "Budget exceeded: \$$TOTAL_COST > \$$BUDGET_MAX. Exiting."
    "$SCRIPT_DIR/report.sh" --event budget_exceeded --loop-id "$LOOP_ID" || true
    exit 4
  fi

  # ── 8. Progress detection ──
  END_SHA=$(cd "$PROJECT_DIR" && git --no-pager rev-parse HEAD 2>/dev/null || echo "no-git")
  FILES_CHANGED=0
  if [[ "$START_SHA" != "$END_SHA" && "$START_SHA" != "no-git" ]]; then
    FILES_CHANGED=$(cd "$PROJECT_DIR" && git --no-pager diff --name-only "$START_SHA" HEAD 2>/dev/null | wc -l | tr -d ' ')
  else
    # Check for unstaged + staged changes
    FILES_CHANGED=$(cd "$PROJECT_DIR" && git --no-pager diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')
    STAGED=$(cd "$PROJECT_DIR" && git --no-pager diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
    FILES_CHANGED=$((FILES_CHANGED + STAGED))
  fi

  log "Files changed: $FILES_CHANGED, cost this iteration: \$$ITER_COST"

  # ── 9. Circuit breaker: no-progress ──
  if [[ "$FILES_CHANGED" -eq 0 ]]; then
    NO_PROGRESS_COUNT=$((NO_PROGRESS_COUNT + 1))
    log "No progress detected ($NO_PROGRESS_COUNT / $NO_PROGRESS_THRESH)"
    if [[ "$NO_PROGRESS_COUNT" -ge "$NO_PROGRESS_THRESH" ]]; then
      log "Circuit breaker tripped: no progress for $NO_PROGRESS_THRESH iterations"
      "$SCRIPT_DIR/report.sh" --event circuit_breaker --reason "no_progress" --loop-id "$LOOP_ID" || true
      exit 2
    fi
  else
    NO_PROGRESS_COUNT=0
  fi

  # ── 10. Circuit breaker: same error ──
  CURRENT_ERROR=""
  if [[ -f "$ITER_LOG.check" ]]; then
    CURRENT_ERROR=$(jq -r '.errors[0] // ""' "$ITER_LOG.check" 2>/dev/null || head -1 "$ITER_LOG.check" 2>/dev/null || echo "")
  fi
  if [[ -n "$CURRENT_ERROR" && "$CURRENT_ERROR" == "$LAST_ERROR" ]]; then
    SAME_ERROR_COUNT=$((SAME_ERROR_COUNT + 1))
    log "Same error repeated ($SAME_ERROR_COUNT / $SAME_ERROR_THRESH): $CURRENT_ERROR"
    if [[ "$SAME_ERROR_COUNT" -ge "$SAME_ERROR_THRESH" ]]; then
      log "Circuit breaker tripped: same error for $SAME_ERROR_THRESH iterations"
      "$SCRIPT_DIR/report.sh" --event circuit_breaker --reason "same_error" --loop-id "$LOOP_ID" || true
      exit 2
    fi
  else
    SAME_ERROR_COUNT=0
    LAST_ERROR="$CURRENT_ERROR"
  fi

  # ── 11. Git commit if changes exist ──
  if [[ "$FILES_CHANGED" -gt 0 ]]; then
    (cd "$PROJECT_DIR" && git add -A && git commit -m "ralph-ci: loop $LOOP_ID, iteration $ITERATION" --no-verify) || true
  fi

  # ── 12. Report iteration ──
  "$SCRIPT_DIR/report.sh" --event iteration \
    --iteration "$ITERATION" \
    --cost "$ITER_COST" \
    --total-cost "$TOTAL_COST" \
    --files-changed "$FILES_CHANGED" \
    --loop-id "$LOOP_ID" || true

  # ── 13. Polish mode: revert if checks fail ──
  if [[ "$MODE" == "polish" && "$FILES_CHANGED" -gt 0 ]]; then
    if ! "$SCRIPT_DIR/check.sh" > /dev/null 2>&1; then
      log "Polish mode: checks failed after iteration, reverting..."
      (cd "$PROJECT_DIR" && git reset --hard HEAD~1) || true
    fi
  fi

  # ── 14. Save state + rotate logs ──
  save_state
  rotate_logs

  log "Iteration $ITERATION complete. Cost so far: \$$TOTAL_COST"
done

log "Max iterations reached ($MAX_ITER). Exiting."
"$SCRIPT_DIR/report.sh" --event max_iterations --loop-id "$LOOP_ID" || true
exit 2
