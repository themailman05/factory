#!/usr/bin/env python3
"""
PR Scorer — evaluates factory output against original task criteria.

Inputs:
  1. Original prompt/message from Liam (what was asked)
  2. Trello card (acceptance criteria, requirements)
  3. PR diff (what was actually done)
  4. CI results (did it pass?)

Scores using Braintrust LLM scorer:
  - requirements_met: Did the PR satisfy all requirements from the task?
  - acceptance_criteria: Did it meet the stated acceptance criteria?
  - no_regressions: Did it avoid breaking things (DO NOT list)?
  - overall: Weighted composite

Usage: ./score_pr.py <run-dir>
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import braintrust
from braintrust import Eval, init_logger

RUN_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else None
if not RUN_DIR or not (RUN_DIR / "result.json").exists():
    print("Usage: score_pr.py <run-dir>", file=sys.stderr)
    sys.exit(1)

PROJECT = os.environ.get("BRAINTRUST_CC_PROJECT", "Factory")
REPO = os.environ.get("RALPH_REPO", os.path.expanduser("~/src/flowstate"))

# ── Load run data ─────────────────────────────────────────────────────────────

result = json.loads((RUN_DIR / "result.json").read_text())
task_text = (RUN_DIR / "task.md").read_text() if (RUN_DIR / "task.md").exists() else ""

run_id = result["run_id"]
status = result["status"]
iters = int(result["iterations"])
branch = result.get("branch", "")
pr_url = result.get("pr", "")

# ── Gather evidence ──────────────────────────────────────────────────────────

# 1. PR diff
diff_content = ""
diff_stat = ""
try:
    diff_stat = subprocess.check_output(
        ["git", "-C", REPO, "diff", f"origin/master...{branch}", "--stat"],
        text=True, stderr=subprocess.DEVNULL
    )[:2000]
    diff_content = subprocess.check_output(
        ["git", "-C", REPO, "diff", f"origin/master...{branch}"],
        text=True, stderr=subprocess.DEVNULL
    )[:15000]  # Cap at 15k chars for LLM context
except Exception as e:
    print(f"  ⚠️  Could not get diff: {e}")

# 2. CI results (check logs from the run dir)
ci_log = ""
for f in sorted(RUN_DIR.glob("ci-iter-*.log")):
    ci_log += f.read_text()[-3000:]  # Last 3k per iteration
if not ci_log:
    # Check final local check log
    for f in sorted(RUN_DIR.glob("checks-iter-*.log")):
        ci_log += f.read_text()[-3000:]

# 3. Trello card (if linked in task)
trello_info = ""
# Extract trello URL or card ID from task
trello_match = re.search(r'trello\.com/c/(\w+)', task_text)
if not trello_match:
    trello_match = re.search(r'Card[:\s]+(\w+)', task_text, re.IGNORECASE)

if trello_match:
    card_id = trello_match.group(1)
    try:
        api_key = os.environ.get("TRELLO_API_KEY", "")
        token = os.environ.get("TRELLO_TOKEN", "")
        if api_key and token:
            import urllib.request
            url = f"https://api.trello.com/1/cards/{card_id}?key={api_key}&token={token}&fields=name,desc"
            with urllib.request.urlopen(url) as resp:
                card = json.loads(resp.read())
                trello_info = f"Card: {card.get('name', '')}\n{card.get('desc', '')}"
    except Exception as e:
        print(f"  ⚠️  Could not fetch Trello card: {e}")

# ── Build scoring prompt ─────────────────────────────────────────────────────

scoring_prompt = f"""You are evaluating a code PR produced by an automated software factory.

## Original Task
{task_text}

## Trello Card Context
{trello_info or "(no Trello card linked)"}

## PR Diff Summary
{diff_stat}

## PR Diff (truncated)
```diff
{diff_content[:10000]}
```

## CI/Check Results
```
{ci_log[:3000] or "(no CI results available)"}
```

## Run Status
- Status: {status}
- Iterations: {iters}
- Branch: {branch}

---

Score this PR on the following dimensions. For each, provide a score from 0.0 to 1.0 and a brief justification.

1. **requirements_met**: Did the PR address ALL requirements listed in the task? (1.0 = all met, 0.5 = partially, 0.0 = missed key requirements)

2. **acceptance_criteria**: Did the PR meet the stated acceptance criteria? (1.0 = all criteria satisfied, 0.0 = none met)

3. **no_regressions**: Did the PR avoid the "DO NOT" items? Did it avoid breaking existing functionality? (1.0 = clean, 0.0 = introduced regressions)

4. **code_quality**: Is the code well-structured, idiomatic, and maintainable? (1.0 = excellent, 0.5 = acceptable, 0.0 = poor)

5. **completeness**: Is this a complete solution or a partial/WIP? (1.0 = fully complete, 0.5 = mostly done, 0.0 = barely started)

Respond in JSON format:
```json
{{
  "requirements_met": {{"score": 0.0, "reason": "..."}},
  "acceptance_criteria": {{"score": 0.0, "reason": "..."}},
  "no_regressions": {{"score": 0.0, "reason": "..."}},
  "code_quality": {{"score": 0.0, "reason": "..."}},
  "completeness": {{"score": 0.0, "reason": "..."}},
  "overall": {{"score": 0.0, "reason": "one-line summary"}},
  "verdict": "PASS|FAIL|NEEDS_WORK"
}}
```

The overall score should be a weighted average: requirements_met (30%), acceptance_criteria (25%), no_regressions (20%), code_quality (10%), completeness (15%).
Set verdict to PASS if overall >= 0.7, NEEDS_WORK if >= 0.4, FAIL otherwise.
"""

# ── Call LLM scorer via Braintrust ────────────────────────────────────────────

print(f"  🧠 Scoring PR with LLM...")

# Use braintrust's OpenAI-compatible client
from braintrust import wrap_openai
from openai import OpenAI

client = wrap_openai(OpenAI(
    api_key=os.environ.get("BRAINTRUST_API_KEY"),
    base_url="https://api.braintrust.dev/v1/proxy",
))

response = client.chat.completions.create(
    model="claude-sonnet-4-20250514",
    messages=[
        {"role": "system", "content": "You are a code review scorer. Be precise and honest. Score based on evidence in the diff and CI results, not assumptions."},
        {"role": "user", "content": scoring_prompt},
    ],
    temperature=0,
    max_tokens=2000,
)

raw_response = response.choices[0].message.content

# Parse JSON from response
json_match = re.search(r'```json\s*(.*?)\s*```', raw_response, re.DOTALL)
if json_match:
    scores_json = json.loads(json_match.group(1))
else:
    # Try raw JSON
    scores_json = json.loads(raw_response)

# ── Extract scores ────────────────────────────────────────────────────────────

scores = {}
reasons = {}
for key in ["requirements_met", "acceptance_criteria", "no_regressions", "code_quality", "completeness", "overall"]:
    entry = scores_json.get(key, {})
    scores[key] = float(entry.get("score", 0.0))
    reasons[key] = entry.get("reason", "")

verdict = scores_json.get("verdict", "UNKNOWN")

print(f"  📊 Scores:")
for k, v in scores.items():
    print(f"     {k}: {v:.1f} — {reasons.get(k, '')}")
print(f"  🏷️  Verdict: {verdict}")

# ── Log to Braintrust ────────────────────────────────────────────────────────

logger = init_logger(project=PROJECT)
logger.log(
    input={
        "task": task_text[:5000],
        "trello": trello_info[:2000],
    },
    output={
        "status": status,
        "pr": pr_url,
        "branch": branch,
        "diff_lines": diff_stat[:500],
        "verdict": verdict,
        "reasons": reasons,
    },
    scores=scores,
    metadata={
        "run_id": run_id,
        "scorer": "llm-pr-scorer",
        "model": "claude-sonnet-4-20250514",
        "iterations": iters,
    },
)

# Also update the experiment if it exists
try:
    experiment = braintrust.init(
        project=PROJECT,
        experiment=f"ralph-{run_id}",
    )
    experiment.log(
        input=task_text[:5000],
        output={
            "status": status,
            "verdict": verdict,
            "pr": pr_url,
        },
        scores=scores,
        metadata={
            "run_id": run_id,
            "scorer": "llm-pr-scorer",
            "reasons": reasons,
        },
    )
    experiment.summarize()
except Exception:
    pass

print(f"\n  ✅ Scored and logged to Braintrust project: {PROJECT}")

# ── Write local result ────────────────────────────────────────────────────────

score_result = {
    "run_id": run_id,
    "scores": scores,
    "reasons": reasons,
    "verdict": verdict,
    "scorer": "llm-pr-scorer",
}
(RUN_DIR / "score.json").write_text(json.dumps(score_result, indent=2))
print(f"  💾 Saved to {RUN_DIR / 'score.json'}")
