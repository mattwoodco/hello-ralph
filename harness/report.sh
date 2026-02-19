#!/usr/bin/env bash
set -uo pipefail

# Ralph CI — Structured Reporting + Webhook Alerts
# Usage: report.sh --event <event> [--iteration N] [--cost N] [--total-cost N]
#        [--files-changed N] [--exit-code N] [--reason STR] [--loop-id N]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$PROJECT_DIR/ralph.config.json"
STATE_DIR="$PROJECT_DIR/.ralph"

config() { jq -r "$1 // empty" "$CONFIG" 2>/dev/null; }

# ─── Parse args ──────────────────────────────────────────────────────────────
EVENT=""
ITERATION=""
COST="0"
TOTAL_COST="0"
FILES_CHANGED="0"
EXIT_CODE=""
REASON=""
LOOP_ID="${RALPH_LOOP_ID:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --event)        EVENT="$2"; shift 2 ;;
    --iteration)    ITERATION="$2"; shift 2 ;;
    --cost)         COST="$2"; shift 2 ;;
    --total-cost)   TOTAL_COST="$2"; shift 2 ;;
    --files-changed) FILES_CHANGED="$2"; shift 2 ;;
    --exit-code)    EXIT_CODE="$2"; shift 2 ;;
    --reason)       REASON="$2"; shift 2 ;;
    --loop-id)      LOOP_ID="$2"; shift 2 ;;
    *)              shift ;;
  esac
done

# Loop-scoped output files (prevents parallel loops from stomping each other)
REPORT_FILE="$STATE_DIR/report_${LOOP_ID}.json"
HISTORY_FILE="$STATE_DIR/report_history_${LOOP_ID}.jsonl"

mkdir -p "$STATE_DIR"

# ─── Gather project metrics ─────────────────────────────────────────────────
GIT_SHA=$(cd "$PROJECT_DIR" && git --no-pager rev-parse --short HEAD 2>/dev/null || echo "unknown")
BRANCH=$(cd "$PROJECT_DIR" && git --no-pager branch --show-current 2>/dev/null || echo "unknown")

# Parse PLAN.md for progress
DONE_COUNT=0
PENDING_COUNT=0
TOTAL_STEPS=0
if [[ -f "$STATE_DIR/PLAN.md" ]]; then
  DONE_COUNT=$(grep -c "DONE:" "$STATE_DIR/PLAN.md" 2>/dev/null) || true
  PENDING_COUNT=$(grep -c "PENDING:" "$STATE_DIR/PLAN.md" 2>/dev/null) || true
  : "${DONE_COUNT:=0}"
  : "${PENDING_COUNT:=0}"
  TOTAL_STEPS=$((DONE_COUNT + PENDING_COUNT))
fi

# ─── Write report.json (atomic — write to tmp then mv) ──────────────────────
TMP_REPORT="${REPORT_FILE}.tmp"
cat > "$TMP_REPORT" << REPORTEOF
{
  "event": "$EVENT",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "loop_id": "$LOOP_ID",
  "iteration": ${ITERATION:-0},
  "git_sha": "$GIT_SHA",
  "branch": "$BRANCH",
  "mode": "$(config '.mode')",
  "cost_usd": $COST,
  "total_cost_usd": $TOTAL_COST,
  "files_changed": $FILES_CHANGED,
  "plan_done": $DONE_COUNT,
  "plan_pending": $PENDING_COUNT,
  "plan_total": $TOTAL_STEPS,
  "exit_code": ${EXIT_CODE:-null},
  "reason": $(echo "${REASON:-}" | jq -Rs .)
}
REPORTEOF
mv "$TMP_REPORT" "$REPORT_FILE"

# ─── Append to history (JSONL — append-only for trends) ─────────────────────
jq -c '.' "$REPORT_FILE" >> "$HISTORY_FILE"

# ─── Webhook delivery ───────────────────────────────────────────────────────
WEBHOOK_URL=$(config '.webhook.url')
WEBHOOK_EVENTS=$(config '.webhook.events[]' 2>/dev/null || echo "")

should_notify() {
  local event="$1"
  echo "$WEBHOOK_EVENTS" | grep -qw "$event"
}

if [[ -n "$WEBHOOK_URL" && "$WEBHOOK_URL" != "null" && "$WEBHOOK_URL" != "" ]]; then
  # Map events to webhook event names
  NOTIFY_EVENT=""
  case "$EVENT" in
    success)         should_notify "success" && NOTIFY_EVENT="success" ;;
    failure)         should_notify "failure" && NOTIFY_EVENT="failure" ;;
    circuit_breaker) should_notify "circuit_breaker" && NOTIFY_EVENT="circuit_breaker" ;;
    kill_switch)     should_notify "failure" && NOTIFY_EVENT="kill_switch" ;;
    budget_exceeded) should_notify "failure" && NOTIFY_EVENT="budget_exceeded" ;;
    stalled)         should_notify "stalled" && NOTIFY_EVENT="stalled" ;;
    max_iterations)  should_notify "failure" && NOTIFY_EVENT="max_iterations" ;;
  esac

  if [[ -n "$NOTIFY_EVENT" ]]; then
    REPO_NAME=$(basename "$PROJECT_DIR")
    PAYLOAD=$(cat << WEBHOOKEOF
{
  "text": "Ralph CI [$REPO_NAME] — $NOTIFY_EVENT (loop $LOOP_ID, iter ${ITERATION:-0}, \$$TOTAL_COST spent, $DONE_COUNT/$TOTAL_STEPS done)",
  "event": "$NOTIFY_EVENT",
  "repo": "$REPO_NAME",
  "branch": "$BRANCH",
  "loop_id": "$LOOP_ID",
  "iteration": ${ITERATION:-0},
  "total_cost_usd": $TOTAL_COST,
  "plan_progress": "$DONE_COUNT/$TOTAL_STEPS",
  "git_sha": "$GIT_SHA",
  "reason": "${REASON:-}",
  "exit_code": ${EXIT_CODE:-null}
}
WEBHOOKEOF
)
    curl -s -X POST "$WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      --max-time 10 || echo "WARN: Webhook delivery failed" >&2
  fi
fi
