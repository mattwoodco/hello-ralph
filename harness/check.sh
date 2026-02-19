#!/usr/bin/env bash
set -uo pipefail

# Ralph CI — Deterministic Success Gate
# Outputs JSON to stdout. Progress to stderr.
# Exit 0 = all checks pass. Exit 1 = at least one check failed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$PROJECT_DIR/ralph.config.json"

config() { jq -r "$1 // empty" "$CONFIG" 2>/dev/null; }

MODE=$(config '.mode')
: "${MODE:=build}"

CHECKS=$(config '.checks[]' 2>/dev/null || echo -e "build\ntypecheck\nlint\ntest")

RESULTS=()
ALL_PASS=true
ERRORS=()

cd "$PROJECT_DIR"

run_check() {
  local name="$1"
  local cmd="$2"
  local skip_if="$3"

  # Smart skip logic
  if [[ -n "$skip_if" && ! -f "$skip_if" ]]; then
    echo "  SKIP: $name ($skip_if not found)" >&2
    RESULTS+=("{\"name\":\"$name\",\"status\":\"skipped\",\"reason\":\"$skip_if not found\"}")
    return 0
  fi

  echo "  RUN:  $name" >&2
  local output start_time end_time duration exit_code
  start_time=$(date +%s)

  # Capture exit code WITHOUT || true (which masks failures)
  output=$(eval "$cmd" 2>&1)
  exit_code=$?

  end_time=$(date +%s)
  duration=$((end_time - start_time))

  if [[ $exit_code -eq 0 ]]; then
    echo "  PASS: $name (${duration}s)" >&2
    RESULTS+=("{\"name\":\"$name\",\"status\":\"pass\",\"duration\":$duration}")
  else
    echo "  FAIL: $name (exit $exit_code, ${duration}s)" >&2
    ALL_PASS=false
    local safe_output
    safe_output=$(echo "$output" | head -20 | jq -Rs .)
    RESULTS+=("{\"name\":\"$name\",\"status\":\"fail\",\"duration\":$duration,\"exit_code\":$exit_code,\"output\":$safe_output}")
    ERRORS+=("$name")
  fi
}

echo "Ralph CI — Running checks..." >&2

# ─── Build mode: check PLAN.md for PENDING steps ────────────────────────────
if [[ "$MODE" == "build" ]]; then
  PLAN_FILE="$PROJECT_DIR/.ralph/PLAN.md"
  if [[ -f "$PLAN_FILE" ]]; then
    PENDING_COUNT=$(grep -c "PENDING:" "$PLAN_FILE" 2>/dev/null) || true
    : "${PENDING_COUNT:=0}"
    if [[ "$PENDING_COUNT" -gt 0 ]]; then
      echo "  FAIL: plan_complete ($PENDING_COUNT PENDING steps remain)" >&2
      ALL_PASS=false
      RESULTS+=("{\"name\":\"plan_complete\",\"status\":\"fail\",\"output\":\"$PENDING_COUNT PENDING steps in PLAN.md\"}")
      ERRORS+=("plan_complete")
    else
      echo "  PASS: plan_complete (no PENDING steps)" >&2
      RESULTS+=("{\"name\":\"plan_complete\",\"status\":\"pass\"}")
    fi
  else
    echo "  SKIP: plan_complete (no PLAN.md found)" >&2
    RESULTS+=("{\"name\":\"plan_complete\",\"status\":\"skipped\",\"reason\":\"no PLAN.md\"}")
  fi
fi

# ─── Run configured checks ──────────────────────────────────────────────────
while IFS= read -r check; do
  [[ -z "$check" ]] && continue
  case "$check" in
    build)
      run_check "build" "bun run build" "package.json"
      ;;
    typecheck)
      run_check "typecheck" "bunx tsc --noEmit" "tsconfig.json"
      ;;
    lint)
      # Check for biome first (both .json and .jsonc), then eslint
      if [[ -f "biome.json" ]]; then
        run_check "lint" "bunx biome check ." ""
      elif [[ -f "biome.jsonc" ]]; then
        run_check "lint" "bunx biome check ." ""
      elif [[ -f ".eslintrc.json" || -f ".eslintrc.js" || -f "eslint.config.js" || -f "eslint.config.mjs" ]]; then
        run_check "lint" "bunx eslint ." ""
      else
        echo "  SKIP: lint (no linter config found)" >&2
        RESULTS+=("{\"name\":\"lint\",\"status\":\"skipped\",\"reason\":\"no linter config\"}")
      fi
      ;;
    test)
      # Check for test files
      TEST_FILES=$(find . -path ./node_modules -prune -o \( -name "*.test.*" -o -name "*.spec.*" \) -print 2>/dev/null | head -1)
      if [[ -n "$TEST_FILES" ]]; then
        run_check "test" "bun test" ""
      else
        echo "  SKIP: test (no test files found)" >&2
        RESULTS+=("{\"name\":\"test\",\"status\":\"skipped\",\"reason\":\"no test files\"}")
      fi
      ;;
    *)
      echo "  WARN: Unknown check '$check'" >&2
      ;;
  esac
done <<< "$CHECKS"

# ─── Build JSON output (safe empty-array handling) ──────────────────────────
if [[ ${#RESULTS[@]} -gt 0 ]]; then
  RESULTS_JSON=$(printf '%s\n' "${RESULTS[@]}" | jq -s '.')
else
  RESULTS_JSON="[]"
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  ERRORS_JSON=$(printf '%s\n' "${ERRORS[@]}" | jq -R . | jq -s '.')
else
  ERRORS_JSON="[]"
fi

cat << CHECKEOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "all_pass": $ALL_PASS,
  "mode": "$MODE",
  "checks": $RESULTS_JSON,
  "errors": $ERRORS_JSON
}
CHECKEOF

if $ALL_PASS; then
  exit 0
else
  exit 1
fi
