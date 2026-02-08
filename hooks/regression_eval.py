#!/usr/bin/env python3
"""
Regression eval: replay dataset tasks through the factory and compare scores.

Fetches tasks from the 'factory-runs' dataset, re-runs them through ralph.sh,
and creates a comparison experiment linked to the dataset.

Usage:
    ./regression_eval.py                    # All tasks
    ./regression_eval.py --limit 5          # First 5
    ./regression_eval.py --dry-run          # Show tasks without running
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

import braintrust

PROJECT = os.environ.get("BRAINTRUST_CC_PROJECT", "Factory")
DATASET_NAME = "factory-runs"
FACTORY_DIR = Path(__file__).resolve().parent.parent

parser = argparse.ArgumentParser()
parser.add_argument("--limit", type=int, default=None)
parser.add_argument("--dry-run", action="store_true")
args = parser.parse_args()

print("🔄 Factory Regression Eval")
print()

# ── Fetch dataset ─────────────────────────────────────────────────────────────

dataset = braintrust.init_dataset(project=PROJECT, name=DATASET_NAME)
rows = list(dataset.fetch())

if args.limit:
    rows = rows[:args.limit]

print(f"  Found {len(rows)} tasks in dataset")

if not rows:
    print("  Nothing to replay. Run some tasks first!")
    sys.exit(0)

if args.dry_run:
    for row in rows:
        title = row.get("input", "").split("\n")[0].lstrip("# ").strip()
        meta = row.get("metadata", {})
        print(f"  • {title} (status={meta.get('actual_status')}, iters={meta.get('actual_iterations')})")
    sys.exit(0)

# ── Create regression experiment ──────────────────────────────────────────────

regression_id = f"regression-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
experiment = braintrust.init(
    project=PROJECT,
    experiment=regression_id,
    dataset=dataset,
)

print(f"  Experiment: {regression_id}")
print()

# ── Replay each task ─────────────────────────────────────────────────────────

passed = 0
failed = 0
repo = os.environ.get("RALPH_REPO", os.path.expanduser("~/src/flowstate"))

for row in rows:
    task_text = row.get("input", "")
    row_id = row.get("id", "unknown")
    expected = row.get("expected", {})
    title = task_text.split("\n")[0].lstrip("# ").strip()

    print(f"━━━ Replaying: {title} ━━━")

    # Write task to temp file
    with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False, prefix="factory-reg-") as f:
        f.write(task_text)
        task_file = f.name

    branch = f"agent/regression-{row_id[:8]}-{int(datetime.now().timestamp())}"

    try:
        result = subprocess.run(
            [str(FACTORY_DIR / "ralph.sh"), task_file, "--branch", branch],
            capture_output=True, text=True, timeout=600
        )
        ralph_status = result.stdout.strip().split("\n")[-1] if result.stdout else "error"
    except subprocess.TimeoutExpired:
        ralph_status = "timeout"
    except Exception as e:
        ralph_status = "error"

    # Find latest run dir
    runs_dir = FACTORY_DIR / "runs"
    run_dirs = sorted(runs_dir.glob("*/"), key=lambda p: p.stat().st_mtime, reverse=True) if runs_dir.exists() else []

    new_status = "error"
    new_iters = 0
    if run_dirs and (run_dirs[0] / "result.json").exists():
        run_result = json.loads((run_dirs[0] / "result.json").read_text())
        new_status = run_result.get("status", "error")
        new_iters = int(run_result.get("iterations", 0))

    # Score
    build_score = 1.0 if new_status == "success" else 0.0
    if new_iters <= 1:
        eff = 1.0
    elif new_iters <= 2:
        eff = 0.8
    elif new_iters <= 4:
        eff = 0.5
    else:
        eff = 0.2

    experiment.log(
        input=task_text,
        output={"status": new_status, "iterations": new_iters},
        expected=expected,
        scores={"build_passes": build_score, "efficiency": eff},
        dataset_record_id=row_id,
        metadata={"branch": branch, "original_id": row_id},
    )

    if new_status == "success":
        print(f"  ✅ Passed ({new_iters} iterations)")
        passed += 1
    else:
        print(f"  ❌ Failed ({new_status})")
        failed += 1

    # Cleanup
    os.unlink(task_file)
    try:
        subprocess.run(
            ["git", "-C", repo, "branch", "-D", branch],
            capture_output=True, timeout=10
        )
    except Exception:
        pass

# ── Summary ───────────────────────────────────────────────────────────────────

summary = experiment.summarize()
print()
print("━━━ Regression Complete ━━━")
print(f"  Passed: {passed} / {len(rows)}")
print(f"  View: https://www.braintrust.dev/app/{PROJECT}/experiments/{regression_id}")
