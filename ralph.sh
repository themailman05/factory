#!/usr/bin/env bash
###############################################################################
# ralph.sh — Ralph Wiggum Loop harness for Claude Code
#
# Runs Claude Code in a retry loop against external checks (build, test, lint)
# until all checks pass or safety limits are hit. Traces to Braintrust.
#
# Inspired by: Ralph Wiggum Loop pattern + Steve Yegge's Gas Town factory model
#
# Usage:
#   ./ralph.sh <task-file.md>
#   ./ralph.sh <task-file.md> --branch my-feature --max-iters 10
#
# Environment:
#   BRAINTRUST_API_KEY     — Required for tracing
#   BRAINTRUST_CC_PROJECT  — Braintrust project name (default: "factory")
#   RALPH_MAX_ITERS        — Max iterations (default: 8)
#   RALPH_MAX_COST_USD     — Max spend per run (default: 5.00)
#   RALPH_REPO             — Repo path (default: ~/src/flowstate)
#   RALPH_CHECKS           — Colon-separated check commands (default: build+test)
#   RALPH_MODEL            — Claude model (default: sonnet)
#   RALPH_NOTIFY_CHAT      — Telegram chat ID for notifications
###############################################################################
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
MAX_ITERS="${RALPH_MAX_ITERS:-8}"
MAX_COST="${RALPH_MAX_COST_USD:-5.00}"
REPO="${RALPH_REPO:-$HOME/src/flowstate}"
MODEL="${RALPH_MODEL:-claude-opus-4-6}"
PROJECT="${BRAINTRUST_CC_PROJECT:-factory}"
NOTIFY_CHAT="${RALPH_NOTIFY_CHAT:-}"
CHECKS="${RALPH_CHECKS:-}"
CHECK_SCRIPT=""
BRANCH=""
TASK_FILE=""
RUN_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3)"
LOG_DIR="$HOME/.openclaw/workspace/factory/runs/$RUN_ID"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)   BRANCH="$2"; shift 2 ;;
    --max-iters) MAX_ITERS="$2"; shift 2 ;;
    --max-cost) MAX_COST="$2"; shift 2 ;;
    --model)    MODEL="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --checks)   CHECKS="$2"; shift 2 ;;
    --check-script) CHECK_SCRIPT="$2"; shift 2 ;;
    --help|-h)
      head -20 "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *)
      if [[ -z "$TASK_FILE" ]]; then
        TASK_FILE="$1"; shift
      else
        echo "Unknown arg: $1" >&2; exit 1
      fi ;;
  esac
done

if [[ -z "$TASK_FILE" ]]; then
  echo "Usage: ralph.sh <task-file.md> [--branch NAME] [--max-iters N]" >&2
  exit 1
fi

if [[ ! -f "$TASK_FILE" ]]; then
  echo "Task file not found: $TASK_FILE" >&2
  exit 1
fi

# ── Setup ─────────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
cp "$TASK_FILE" "$LOG_DIR/task.md"

TASK="$(cat "$TASK_FILE")"
BRANCH="${BRANCH:-agent/ralph-$RUN_ID}"

echo "🏭 Ralph Wiggum Loop — Run $RUN_ID"
echo "   Task:       $(head -1 "$TASK_FILE")"
echo "   Branch:     $BRANCH"
echo "   Repo:       $REPO"
echo "   Model:      $MODEL"
echo "   Max iters:  $MAX_ITERS"
echo "   Max cost:   \$$MAX_COST"
echo "   Log dir:    $LOG_DIR"
echo ""

cd "$REPO"

# Create branch if it doesn't exist
if ! git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
  git checkout -b "$BRANCH" origin/master 2>/dev/null || git checkout -b "$BRANCH"
  echo "   Created branch: $BRANCH"
else
  git checkout "$BRANCH"
  echo "   Checked out existing branch: $BRANCH"
fi

# ── Default checks ────────────────────────────────────────────────────────────
if [[ -z "$CHECKS" ]]; then
  # Auto-detect checks based on repo
  if [[ -f "pubspec.yaml" ]]; then
    CHECKS="flutter_analyze:flutter_build_ios"
  elif [[ -f "package.json" ]]; then
    CHECKS="npm_test"
  elif [[ -f "Makefile" ]]; then
    CHECKS="make_test"
  else
    CHECKS="true"  # no-op check
  fi
fi

# ── Check runners ─────────────────────────────────────────────────────────────
run_checks() {
  local check_log="$LOG_DIR/checks-iter-$1.log"
  local failed=0

  # If a check script is provided, run it directly
  if [[ -n "$CHECK_SCRIPT" ]]; then
    echo "  ▶ Running check script: $CHECK_SCRIPT"
    if ! bash "$CHECK_SCRIPT" 2>&1 | tee -a "$check_log"; then
      failed=1
    fi
    return $failed
  fi

  IFS=':' read -ra CHECK_LIST <<< "$CHECKS"
  for check in "${CHECK_LIST[@]}"; do
    echo "  ▶ Running check: $check"
    case "$check" in
      flutter_analyze)
        if ! ~/development/flutter/bin/flutter analyze --no-pub 2>&1 | tee -a "$check_log"; then
          failed=1
        fi ;;
      flutter_build_ios)
        if ! ~/development/flutter/bin/flutter build ios --no-codesign --release 2>&1 | tail -50 | tee -a "$check_log"; then
          failed=1
        fi ;;
      flutter_test)
        if ! ~/development/flutter/bin/flutter test 2>&1 | tee -a "$check_log"; then
          failed=1
        fi ;;
      npm_test)
        if ! npm test 2>&1 | tee -a "$check_log"; then
          failed=1
        fi ;;
      make_test)
        if ! make test 2>&1 | tee -a "$check_log"; then
          failed=1
        fi ;;
      true)
        echo "  (no checks configured)" | tee -a "$check_log" ;;
      *)
        echo "  ▶ Custom check: $check"
        if ! eval "$check" 2>&1 | tee -a "$check_log"; then
          failed=1
        fi ;;
    esac
  done

  return $failed
}

# ── Main loop ─────────────────────────────────────────────────────────────────
ITER=0
FEEDBACK=""
STATUS="running"

while [[ $ITER -lt $MAX_ITERS ]]; do
  ITER=$((ITER + 1))
  echo ""
  echo "━━━ Iteration $ITER/$MAX_ITERS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Build the prompt
  PROMPT="$TASK"

  if [[ -n "$FEEDBACK" ]]; then
    PROMPT="$PROMPT

---
## PREVIOUS ATTEMPT FAILED — Iteration $((ITER - 1))

The following checks failed. Fix the issues and try again.
Do NOT disable tests, weaken assertions, or suppress errors.
Fix the actual underlying problem.

\`\`\`
$FEEDBACK
\`\`\`"
  fi

  PROMPT="$PROMPT

---
## INSTRUCTIONS
- You are on branch \`$BRANCH\` in \`$REPO\`
- Make your changes, then commit with a descriptive message
- Do not push — the harness handles that
- Focus on making the checks pass: $CHECKS
- Iteration $ITER of $MAX_ITERS — be efficient"

  # Write prompt to log
  echo "$PROMPT" > "$LOG_DIR/prompt-iter-$ITER.md"

  # Run Claude Code — output captured by Braintrust traces, not stdout
  echo "  🤖 Running Claude Code (model: $MODEL)..."
  unbuffer claude \
    --model "$MODEL" \
    -p \
    --dangerously-skip-permissions \
    --max-budget-usd "$MAX_COST" \
    --append-system-prompt "You are a factory worker in a Ralph Wiggum loop. Your job is to make the code changes described in the task and ensure all checks pass. Be surgical and precise. Do not over-engineer." \
    "$PROMPT" \
    > /dev/null 2>&1 || true

  # Run checks
  echo ""
  echo "  🔍 Running checks..."
  if run_checks "$ITER"; then
    echo ""
    echo "  ✅ All checks passed on iteration $ITER!"
    STATUS="success"
    break
  else
    FEEDBACK="$(cat "$LOG_DIR/checks-iter-$ITER.log" | tail -100)"
    echo ""
    echo "  ❌ Checks failed. Feeding errors back..."
    STATUS="retry"
  fi
done

# ── Wrap up ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━ Run Complete ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$STATUS" == "success" ]]; then
  # Push and create PR
  git push -u origin "$BRANCH" 2>&1
  echo "  📤 Pushed branch: $BRANCH"

  # Create draft PR
  PR_URL=$(gh pr create \
    --title "$(head -1 "$LOG_DIR/task.md" | sed 's/^#\+ //')" \
    --body "$(cat <<EOF
## 🏭 Factory Run: $RUN_ID

**Iterations:** $ITER/$MAX_ITERS
**Model:** $MODEL
**Status:** ✅ All checks passed

### Task
$(cat "$LOG_DIR/task.md")

### Checks
$CHECKS

---
*Generated by Ralph Wiggum Loop harness*
EOF
)" \
    --draft 2>&1)
  echo "  📋 Draft PR: $PR_URL"

  # Save result
  cat > "$LOG_DIR/result.json" <<EOF
{"run_id":"$RUN_ID","status":"success","iterations":$ITER,"branch":"$BRANCH","pr":"$PR_URL"}
EOF

  echo ""
  echo "  🎉 SUCCESS after $ITER iteration(s)"
  echo "  PR: $PR_URL"
else
  cat > "$LOG_DIR/result.json" <<EOF
{"run_id":"$RUN_ID","status":"failed","iterations":$ITER,"branch":"$BRANCH"}
EOF

  echo ""
  echo "  💀 FAILED after $MAX_ITERS iterations"
  echo "  Check logs: $LOG_DIR"
fi

# ── Post-run hooks ────────────────────────────────────────────────────────────
HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)/hooks"

# Eval hook — log scores to Braintrust (Python SDK)
VENV="$(cd "$(dirname "$0")" && pwd)/.venv"
if [[ -f "$HOOKS_DIR/post_run_eval.py" && -n "${BRAINTRUST_API_KEY:-}" ]]; then
  echo "  📊 Running post-run eval..."
  if [[ -f "$VENV/bin/python3" ]]; then
    "$VENV/bin/python3" "$HOOKS_DIR/post_run_eval.py" "$LOG_DIR" || echo "  ⚠️  Eval hook failed (non-fatal)"
  else
    echo "  ⚠️  No venv found at $VENV — run: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
  fi
fi

# Notify hook — send results to Telegram/webhook
if [[ -x "$HOOKS_DIR/notify.sh" ]]; then
  "$HOOKS_DIR/notify.sh" "$LOG_DIR" "${NOTIFY_CHAT:-}" 2>/dev/null || true
fi

echo "$STATUS"
