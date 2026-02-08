#!/usr/bin/env python3
"""
Post-run evaluation: score, log traces, create experiment, append to dataset.

Called by ralph.sh after completion. Uses the Braintrust Python SDK.

Usage: ./post_run_eval.py <run-dir>
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import braintrust

RUN_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else None
if not RUN_DIR or not (RUN_DIR / "result.json").exists():
    print("Usage: post_run_eval.py <run-dir>", file=sys.stderr)
    sys.exit(1)

PROJECT = os.environ.get("BRAINTRUST_CC_PROJECT", "Factory")
DATASET_NAME = "factory-runs"
REPO = os.environ.get("RALPH_REPO", os.path.expanduser("~/src/flowstate"))

# ── Load run data ─────────────────────────────────────────────────────────────

result = json.loads((RUN_DIR / "result.json").read_text())
task_text = (RUN_DIR / "task.md").read_text() if (RUN_DIR / "task.md").exists() else "unknown"
task_title = task_text.split("\n")[0].lstrip("# ").strip()

run_id = result["run_id"]
status = result["status"]
iters = int(result["iterations"])
branch = result.get("branch", "")
pr = result.get("pr", "")

# ── Scoring ───────────────────────────────────────────────────────────────────

build_score = 1.0 if status == "success" else 0.0

# Efficiency: 1-shot is ideal
if iters <= 1:
    efficiency = 1.0
elif iters <= 2:
    efficiency = 0.8
elif iters <= 4:
    efficiency = 0.5
else:
    efficiency = 0.2

# Diff precision: smaller is better
diff_lines = 0
diff_content = ""
try:
    stat_output = subprocess.check_output(
        ["git", "-C", REPO, "diff", f"origin/master...{branch}", "--stat"],
        text=True, stderr=subprocess.DEVNULL
    )
    # Parse "X insertions(+), Y deletions(-)"
    m = re.search(r"(\d+) insertion", stat_output)
    insertions = int(m.group(1)) if m else 0
    m = re.search(r"(\d+) deletion", stat_output)
    deletions = int(m.group(1)) if m else 0
    diff_lines = insertions + deletions

    diff_content = subprocess.check_output(
        ["git", "-C", REPO, "diff", f"origin/master...{branch}"],
        text=True, stderr=subprocess.DEVNULL
    )
except Exception:
    pass

if diff_lines <= 50:
    diff_score = 1.0
elif diff_lines <= 150:
    diff_score = 0.7
elif diff_lines <= 500:
    diff_score = 0.4
else:
    diff_score = 0.1

# Integrity: detect metric gaming
integrity = 1.0
if re.search(r"^\+.*//\s*(ignore|nolint|no-check)", diff_content, re.MULTILINE):
    integrity *= 0.3
if re.search(r"^-.*(?:test\(|expect\(|assert)", diff_content, re.MULTILINE):
    integrity *= 0.5

scores = {
    "build_passes": build_score,
    "efficiency": efficiency,
    "diff_precision": diff_score,
    "integrity": integrity,
}

print(f"  Scores: build={build_score} efficiency={efficiency} "
      f"diff={diff_score} ({diff_lines} lines) integrity={integrity}")

# ── 1. Log to project (traces view) ──────────────────────────────────────────

logger = braintrust.init_logger(project=PROJECT)
logger.log(
    input=task_title,
    output=status,
    scores=scores,
    metadata={
        "run_id": run_id,
        "status": status,
        "iterations": iters,
        "branch": branch,
        "pr": pr,
        "diff_lines": diff_lines,
        "source": "ralph-loop",
    },
)
print("  📊 Logged to project traces")

# ── 2. Create experiment ──────────────────────────────────────────────────────

experiment = braintrust.init(
    project=PROJECT,
    experiment=f"ralph-{run_id}",
)

experiment.log(
    input=task_text,
    output={
        "status": status,
        "iterations": iters,
        "branch": branch,
        "pr": pr,
        "diff_lines": diff_lines,
    },
    expected={
        "status": "success",
        "max_iterations": 1,
    },
    scores=scores,
    metadata={
        "run_id": run_id,
        "task_title": task_title,
        "branch": branch,
        "pr": pr,
    },
)

summary = experiment.summarize()
print(f"  🧪 Experiment: ralph-{run_id}")

# ── 3. Append to dataset ─────────────────────────────────────────────────────

# Collect check output from final iteration
final_check = ""
check_file = RUN_DIR / f"checks-iter-{iters}.log"
if check_file.exists():
    lines = check_file.read_text().splitlines()
    final_check = "\n".join(lines[-30:])

# Diff summary
diff_summary = ""
try:
    diff_summary = subprocess.check_output(
        ["git", "-C", REPO, "diff", f"origin/master...{branch}", "--stat"],
        text=True, stderr=subprocess.DEVNULL
    )[:2000]
except Exception:
    pass

dataset = braintrust.init_dataset(project=PROJECT, name=DATASET_NAME)
dataset.insert(
    input=task_text,
    expected={
        "status": "success",
        "scores": {
            "build_passes": 1.0,
            "efficiency": 1.0,
            "diff_precision": 0.7,
            "integrity": 1.0,
        },
    },
    metadata={
        "run_id": run_id,
        "actual_status": status,
        "actual_iterations": iters,
        "actual_scores": scores,
        "diff_summary": diff_summary,
        "check_output": final_check,
        "branch": branch,
        "pr": pr,
    },
    id=run_id,
)
dataset.flush()
print(f"  📦 Appended to dataset: {DATASET_NAME}")
print()
print(f"  View: https://www.braintrust.dev/app/{PROJECT}/experiments/ralph-{run_id}")
