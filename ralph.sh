#!/usr/bin/env bash
###############################################################################
# ralph.sh — Ralph Wiggum Loop harness for Claude Code
#
# Full factory loop:
#   1. Claude Code makes changes (with retry on local check failures)
#   2. Local checks (analyze, lint, test) — fast feedback
#   3. Push + create draft PR
#   4. Wait for CI to complete (GHA checks on the PR)
#   5. If CI fails: feed errors back, retry from step 1
#   6. If CI passes: run Braintrust eval, capture scores
#   7. THEN notify with real results
#
# Usage:
#   ./ralph.sh <task-file.md>
#   ./ralph.sh <task-file.md> --branch my-feature --max-iters 10
#
# Environment:
#   BRAINTRUST_API_KEY     — Required for tracing
#   RALPH_MAX_ITERS        — Max iterations (default: 8)
#   RALPH_MAX_COST_USD     — Max spend per run (default: 5.00)
#   RALPH_REPO             — Repo path (default: ~/src/flowstate)
#   RALPH_MODEL            — Claude model (default: claude-opus-4-6)
#   RALPH_NOTIFY_CHAT      — Telegram chat ID for notifications
#   RALPH_CI_TIMEOUT       — Minutes to wait for CI (default: 30)
#   RALPH_SKIP_CI          — Set to "true" to skip CI wait (local checks only)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
MAX_ITERS="${RALPH_MAX_ITERS:-8}"
MAX_COST="${RALPH_MAX_COST_USD:-50.00}"
REPO="${RALPH_REPO:-$HOME/src/flowstate}"
MODEL="${RALPH_MODEL:-claude-opus-4-6}"
PROJECT="${BRAINTRUST_CC_PROJECT:-factory}"
NOTIFY_CHAT="${RALPH_NOTIFY_CHAT:-906083113}"
CHECKS="${RALPH_CHECKS:-}"
CHECK_SCRIPT=""
CI_TIMEOUT="${RALPH_CI_TIMEOUT:-30}"
SKIP_CI="${RALPH_SKIP_CI:-false}"
BRANCH=""
TASK_FILE=""
RUN_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3)"
LOG_DIR="$SCRIPT_DIR/runs/$RUN_ID"
PR_URL=""

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)       BRANCH="$2"; shift 2 ;;
    --max-iters)    MAX_ITERS="$2"; shift 2 ;;
    --max-cost)     MAX_COST="$2"; shift 2 ;;
    --model)        MODEL="$2"; shift 2 ;;
    --repo)         REPO="$2"; shift 2 ;;
    --checks)       CHECKS="$2"; shift 2 ;;
    --check-script) CHECK_SCRIPT="$2"; shift 2 ;;
    --ci-timeout)   CI_TIMEOUT="$2"; shift 2 ;;
    --skip-ci)      SKIP_CI="true"; shift ;;
    --notify)       NOTIFY_CHAT="$2"; shift 2 ;;
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

# ── Telegram notify helper ────────────────────────────────────────────────────
# Sends progress updates via OpenClaw's sessions_send or direct API
notify() {
  local msg="$1"
  echo "  📨 $msg"

  # Use openclaw CLI if available, otherwise skip
  if command -v openclaw &>/dev/null && [[ -n "$NOTIFY_CHAT" ]]; then
    openclaw message send --channel telegram --target "$NOTIFY_CHAT" --message "$msg" 2>/dev/null || true
  fi
}

# ── Setup ─────────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
cp "$TASK_FILE" "$LOG_DIR/task.md"

TASK="$(cat "$TASK_FILE")"
TASK_TITLE="$(head -1 "$TASK_FILE" | sed 's/^#\+ //')"
BRANCH="${BRANCH:-agent/ralph-$RUN_ID}"

echo "🏭 Ralph Wiggum Loop — Run $RUN_ID"
echo "   Task:       $TASK_TITLE"
echo "   Branch:     $BRANCH"
echo "   Repo:       $REPO"
echo "   Model:      $MODEL"
echo "   Max iters:  $MAX_ITERS"
echo "   Max cost:   \$$MAX_COST"
echo "   CI timeout: ${CI_TIMEOUT}min"
echo "   Log dir:    $LOG_DIR"
echo ""

notify "🏭 Factory run started: *${TASK_TITLE}*
Branch: \`$BRANCH\`
Model: $MODEL | Max iters: $MAX_ITERS"

cd "$REPO"

# Create or checkout branch
if ! git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
  git checkout -b "$BRANCH" origin/master 2>/dev/null || git checkout -b "$BRANCH"
  echo "   Created branch: $BRANCH"
else
  git checkout "$BRANCH"
  echo "   Checked out existing branch: $BRANCH"
fi

# Ensure submodules are pinned to the correct commits
echo "   Syncing submodules..."
git submodule sync --recursive 2>/dev/null
git submodule update --init --force plugins/f_link plugins/flutter_soloud 2>/dev/null
git submodule update --init --force plugins/flutter_recorder 2>/dev/null
echo "   Submodules synced"

# ── Default checks ────────────────────────────────────────────────────────────
if [[ -z "$CHECKS" && -z "$CHECK_SCRIPT" ]]; then
  if [[ -f "pubspec.yaml" ]]; then
    CHECKS="flutter_analyze"
  elif [[ -f "package.json" ]]; then
    CHECKS="npm_test"
  elif [[ -f "Makefile" ]]; then
    CHECKS="make_test"
  else
    CHECKS="true"
  fi
fi

# ── Local check runner ────────────────────────────────────────────────────────
run_local_checks() {
  local check_log="$LOG_DIR/checks-iter-$1.log"
  local failed=0

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
        echo "  (no local checks configured)" | tee -a "$check_log" ;;
      *)
        echo "  ▶ Custom check: $check"
        if ! eval "$check" 2>&1 | tee -a "$check_log"; then
          failed=1
        fi ;;
    esac
  done

  return $failed
}

# ── CI wait: poll GHA until checks pass/fail ──────────────────────────────────
wait_for_ci() {
  local branch="$1"
  local timeout_min="$2"
  local ci_log="$LOG_DIR/ci-iter-$ITER.log"
  local deadline=$((SECONDS + timeout_min * 60))
  local poll_interval=30

  echo "  ⏳ Waiting for CI on $branch (timeout: ${timeout_min}min)..."
  notify "⏳ Waiting for CI on PR..."

  while [[ $SECONDS -lt $deadline ]]; do
    sleep "$poll_interval"

    # Get all check runs for the PR
    local checks_json
    checks_json=$(gh pr checks "$branch" --json "name,state,link" 2>&1) || continue

    local total pending failed passed
    total=$(echo "$checks_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "0")
    pending=$(echo "$checks_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for c in d if c['state'] in ('PENDING','QUEUED','IN_PROGRESS')))" 2>/dev/null || echo "0")
    failed=$(echo "$checks_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for c in d if c['state'] == 'FAILURE'))" 2>/dev/null || echo "0")
    passed=$(echo "$checks_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(1 for c in d if c['state'] == 'SUCCESS'))" 2>/dev/null || echo "0")

    echo "    CI: $passed passed, $failed failed, $pending pending (of $total)"

    if [[ "$total" -eq 0 ]]; then
      continue  # Checks haven't started yet
    fi

    if [[ "$pending" -eq 0 ]]; then
      # All checks completed
      echo "$checks_json" > "$ci_log"

      if [[ "$failed" -gt 0 ]]; then
        echo "  ❌ CI failed ($failed failures)"

        # Capture failure details
        local fail_details
        fail_details=$(echo "$checks_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for c in d:
    if c['state'] == 'FAILURE':
        print(f'  FAILED: {c[\"name\"]} — {c[\"link\"]}')
" 2>/dev/null || echo "")
        echo "$fail_details" | tee -a "$ci_log"

        # Try to get CI run logs for failed jobs
        local run_ids
        run_ids=$(gh run list --branch "$branch" --limit 5 --json databaseId,status,conclusion \
          | python3 -c "import json,sys; [print(r['databaseId']) for r in json.load(sys.stdin) if r.get('conclusion')=='failure']" 2>/dev/null || true)

        for rid in $run_ids; do
          echo "  Fetching logs for run $rid..." | tee -a "$ci_log"
          gh run view "$rid" --log-failed 2>/dev/null | tail -50 >> "$ci_log" || true
        done

        return 1
      else
        echo "  ✅ All CI checks passed!"
        notify "✅ CI passed on PR"
        return 0
      fi
    fi
  done

  echo "  ⏰ CI timed out after ${timeout_min} minutes" | tee -a "$ci_log"
  return 2
}

# ── Braintrust eval ───────────────────────────────────────────────────────────
run_eval() {
  local venv="$SCRIPT_DIR/.venv"
  local hooks_dir="$SCRIPT_DIR/hooks"

  if [[ ! -f "$venv/bin/python3" ]]; then
    echo "  ⚠️  No venv at $venv — skipping eval"
    return
  fi

  if [[ -z "${BRAINTRUST_API_KEY:-}" ]]; then
    echo "  ⚠️  No BRAINTRUST_API_KEY — skipping eval"
    return
  fi

  # 1. Mechanical scorer (build/efficiency/diff/integrity)
  if [[ -f "$hooks_dir/post_run_eval.py" ]]; then
    echo "  📊 Running mechanical eval..."
    "$venv/bin/python3" "$hooks_dir/post_run_eval.py" "$LOG_DIR" || echo "  ⚠️  Mechanical eval failed (non-fatal)"
  fi

  # 2. LLM scorer (requirements/acceptance/regressions/quality/completeness)
  if [[ -f "$hooks_dir/score_pr.py" ]]; then
    echo "  🧠 Running LLM PR scorer..."
    "$venv/bin/python3" "$hooks_dir/score_pr.py" "$LOG_DIR" || echo "  ⚠️  LLM scorer failed (non-fatal)"

    # Include verdict in notification
    if [[ -f "$LOG_DIR/score.json" ]]; then
      VERDICT=$(python3 -c "import json; print(json.load(open('$LOG_DIR/score.json'))['verdict'])" 2>/dev/null || echo "UNKNOWN")
      OVERALL=$(python3 -c "import json; print(f\"{json.load(open('$LOG_DIR/score.json'))['scores']['overall']:.1f}\")" 2>/dev/null || echo "?")
      echo "  🏷️  Verdict: $VERDICT (overall: $OVERALL)"
    fi
  fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
ITER=0
FEEDBACK=""
STATUS="running"
PR_CREATED=false

while [[ $ITER -lt $MAX_ITERS ]]; do
  ITER=$((ITER + 1))
  echo ""
  echo "━━━ Iteration $ITER/$MAX_ITERS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  notify "🔄 Iteration $ITER/$MAX_ITERS: Running Claude Code..."

  # ── Step 1: Build prompt ──
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
- Focus on making the checks pass
- Iteration $ITER of $MAX_ITERS — be efficient"

  echo "$PROMPT" > "$LOG_DIR/prompt-iter-$ITER.md"

  # ── Step 2: Run Claude Code ──
  echo "  🤖 Running Claude Code (model: $MODEL)..."
  unbuffer claude \
    --model "$MODEL" \
    -p \
    --dangerously-skip-permissions \
    --max-budget-usd "$MAX_COST" \
    --append-system-prompt "You are a factory worker in a Ralph Wiggum loop. Your job is to make the code changes described in the task and ensure all checks pass. Be surgical and precise. Do not over-engineer." \
    "$PROMPT" \
    > /dev/null 2>&1 || true

  # ── Step 3: Local checks (fast feedback) ──
  echo ""
  echo "  🔍 Running local checks..."
  notify "🔍 Iteration $ITER: Running local checks..."

  if ! run_local_checks "$ITER"; then
    FEEDBACK="$(cat "$LOG_DIR/checks-iter-$ITER.log" 2>/dev/null | tail -100)"
    echo ""
    echo "  ❌ Local checks failed. Retrying..."
    notify "❌ Iteration $ITER: Local checks failed, retrying..."
    STATUS="retry"
    continue
  fi

  echo "  ✅ Local checks passed"

  # ── Step 4: Push + PR ──
  echo ""
  echo "  📤 Pushing to origin..."
  git push -u origin "$BRANCH" 2>&1
  echo "  📤 Pushed branch: $BRANCH"

  if [[ "$PR_CREATED" == false ]]; then
    PR_URL=$(gh pr create \
      --title "$TASK_TITLE" \
      --body "$(cat <<EOF
## 🏭 Factory Run: $RUN_ID

**Iterations:** $ITER/$MAX_ITERS (so far)
**Model:** $MODEL
**Status:** ⏳ Awaiting CI

### Task
$(cat "$LOG_DIR/task.md")

---
*Generated by L-Automatique factory harness*
EOF
)" \
      --draft 2>&1 || echo "PR already exists")

    if [[ "$PR_URL" == *"already exists"* ]]; then
      PR_URL=$(gh pr view "$BRANCH" --json url -q '.url' 2>/dev/null || echo "unknown")
    fi

    PR_CREATED=true
    echo "  📋 PR: $PR_URL"
    notify "📤 PR created: $PR_URL
⏳ Waiting for CI..."
  else
    echo "  📋 Pushed update to existing PR: $PR_URL"
    notify "📤 Pushed fixes to PR, waiting for CI..."
  fi

  # ── Step 5: Wait for CI ──
  if [[ "$SKIP_CI" == "true" ]]; then
    echo "  ⏩ Skipping CI wait (--skip-ci)"
    STATUS="success"
    break
  fi

  # Give GHA a moment to pick up the push
  sleep 10

  ci_result=0
  wait_for_ci "$BRANCH" "$CI_TIMEOUT" || ci_result=$?

  if [[ $ci_result -eq 0 ]]; then
    STATUS="success"
    break
  elif [[ $ci_result -eq 2 ]]; then
    # Timeout — don't retry, just report
    notify "⏰ CI timed out after ${CI_TIMEOUT}min. Check: $PR_URL"
    STATUS="ci_timeout"
    break
  else
    # CI failed — feed errors back
    FEEDBACK="CI FAILED. Check logs:
$(cat "$LOG_DIR/ci-iter-$ITER.log" 2>/dev/null | tail -100)"
    echo ""
    echo "  ❌ CI failed. Feeding errors back..."
    notify "❌ Iteration $ITER: CI failed, retrying..."
    STATUS="retry"
  fi
done

# ── Final result ──────────────────────────────────────────────────────────────
echo ""
echo "━━━ Run Complete ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$STATUS" == "success" ]]; then
  # Update PR description with final status
  gh pr edit "$BRANCH" --body "$(cat <<EOF
## 🏭 Factory Run: $RUN_ID

**Iterations:** $ITER/$MAX_ITERS
**Model:** $MODEL
**Status:** ✅ All checks passed (local + CI)

### Task
$(cat "$LOG_DIR/task.md")

---
*Generated by L-Automatique factory harness*
EOF
)" 2>/dev/null || true

  # Save result
  cat > "$LOG_DIR/result.json" <<EOF
{"run_id":"$RUN_ID","status":"success","iterations":$ITER,"max_iters":$MAX_ITERS,"branch":"$BRANCH","pr":"$PR_URL","model":"$MODEL"}
EOF

  # Run Braintrust eval
  run_eval

  echo ""
  echo "  🎉 SUCCESS after $ITER iteration(s)"
  echo "  PR: $PR_URL"
  # Build score summary for notification
  SCORE_MSG=""
  if [[ -f "$LOG_DIR/score.json" ]]; then
    SCORE_MSG=$(python3 -c "
import json
s = json.load(open('$LOG_DIR/score.json'))
v = s['verdict']
o = s['scores']['overall']
reasons = s.get('reasons', {})
overall_reason = reasons.get('overall', '')
print(f'Verdict: {v} ({o:.1f}/1.0)')
print(f'{overall_reason}')
for k in ['requirements_met','acceptance_criteria','no_regressions']:
    sc = s['scores'].get(k, 0)
    r = reasons.get(k, '')
    print(f'  {k}: {sc:.1f} — {r}')
" 2>/dev/null || echo "Score: unavailable")
  fi

  notify "🏭✅ Factory run complete!

*${TASK_TITLE}*
PR: $PR_URL
Iterations: $ITER/$MAX_ITERS
Model: $MODEL

📊 $SCORE_MSG"

elif [[ "$STATUS" == "ci_timeout" ]]; then
  cat > "$LOG_DIR/result.json" <<EOF
{"run_id":"$RUN_ID","status":"ci_timeout","iterations":$ITER,"branch":"$BRANCH","pr":"$PR_URL","model":"$MODEL"}
EOF

  echo ""
  echo "  ⏰ CI TIMED OUT after $ITER iteration(s)"

else
  cat > "$LOG_DIR/result.json" <<EOF
{"run_id":"$RUN_ID","status":"failed","iterations":$ITER,"max_iters":$MAX_ITERS,"branch":"$BRANCH","pr":"${PR_URL:-none}","model":"$MODEL"}
EOF

  echo ""
  echo "  💀 FAILED after $MAX_ITERS iterations"
  echo "  Check logs: $LOG_DIR"
  notify "🏭❌ Factory run FAILED

*${TASK_TITLE}*
Iterations: $MAX_ITERS/$MAX_ITERS exhausted
Model: $MODEL
Logs: $LOG_DIR"
fi

echo "$STATUS"
