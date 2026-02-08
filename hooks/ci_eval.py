#!/usr/bin/env python3
"""
CI/CD evaluation hook for GitHub Actions PRs.

Runs checks, scores the PR, logs to Braintrust experiment, writes GHA summary.

Environment:
    BRAINTRUST_API_KEY
    PR_NUMBER, PR_BRANCH, COMMIT_SHA (from GitHub Actions)
"""
import os
import re
import subprocess
import sys
from pathlib import Path

import braintrust

PROJECT = os.environ.get("BRAINTRUST_CC_PROJECT", "Factory")
PR_NUMBER = os.environ.get("PR_NUMBER", "unknown")
PR_BRANCH = os.environ.get("PR_BRANCH", "unknown")
COMMIT_SHA = os.environ.get("COMMIT_SHA", "unknown")
SHORT_SHA = COMMIT_SHA[:7]

print(f"🏭 Factory CI Eval — PR #{PR_NUMBER} ({PR_BRANCH} @ {SHORT_SHA})")

# ── Run checks ────────────────────────────────────────────────────────────────

checks = {}
details = []


def run_check(name: str, cmd: str):
    print(f"  ▶ {name}")
    try:
        output = subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.STDOUT)
        checks[name] = 1.0
        print("    ✅ passed")
    except subprocess.CalledProcessError as e:
        output = e.output or ""
        checks[name] = 0.0
        print("    ❌ failed")

    tail = "\n".join(output.splitlines()[-20:])
    details.append(f"### {name}: {'✅' if checks[name] else '❌'}\n```\n{tail}\n```\n")


# Auto-detect project type
if Path("pubspec.yaml").exists():
    run_check("analyze", "flutter analyze --no-pub 2>&1")
    run_check("build_ios", "flutter build ios --no-codesign --release 2>&1 | tail -30")
    run_check("test", "flutter test 2>&1 | tail -30")
elif Path("package.json").exists():
    run_check("lint", "npm run lint 2>&1 | tail -30")
    run_check("test", "npm test 2>&1 | tail -30")
    run_check("build", "npm run build 2>&1 | tail -30")

# ── Diff metrics ──────────────────────────────────────────────────────────────

try:
    stat = subprocess.check_output(
        ["git", "diff", "origin/main...HEAD", "--stat"],
        text=True, stderr=subprocess.DEVNULL
    )
    files_changed = int(re.search(r"(\d+) file", stat).group(1)) if re.search(r"(\d+) file", stat) else 0
    insertions = int(re.search(r"(\d+) insertion", stat).group(1)) if re.search(r"(\d+) insertion", stat) else 0
    deletions = int(re.search(r"(\d+) deletion", stat).group(1)) if re.search(r"(\d+) deletion", stat) else 0
except Exception:
    files_changed = insertions = deletions = 0

total_diff = insertions + deletions
if total_diff <= 50:
    checks["diff_precision"] = 1.0
elif total_diff <= 150:
    checks["diff_precision"] = 0.7
elif total_diff <= 500:
    checks["diff_precision"] = 0.4
else:
    checks["diff_precision"] = 0.1

# ── Log to Braintrust ────────────────────────────────────────────────────────

experiment = braintrust.init(
    project=PROJECT,
    experiment=f"ci-pr{PR_NUMBER}-{SHORT_SHA}",
)

experiment.log(
    input=f"PR #{PR_NUMBER} ({PR_BRANCH})",
    output={
        "commit": SHORT_SHA,
        "files_changed": files_changed,
        "diff_lines": total_diff,
        "checks": checks,
    },
    scores=checks,
    metadata={
        "pr_number": PR_NUMBER,
        "branch": PR_BRANCH,
        "commit": SHORT_SHA,
    },
)

summary = experiment.summarize()
print()
print(f"📊 Experiment: ci-pr{PR_NUMBER}-{SHORT_SHA}")
print(f"   View: https://www.braintrust.dev/app/{PROJECT}/experiments/ci-pr{PR_NUMBER}-{SHORT_SHA}")

# ── GitHub Actions summary ────────────────────────────────────────────────────

summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
if summary_file:
    with open(summary_file, "a") as f:
        f.write(f"## 🏭 Factory Eval — PR #{PR_NUMBER}\n\n")
        f.write("| Metric | Score |\n|--------|-------|\n")
        for k, v in checks.items():
            f.write(f"| {k} | {v} |\n")
        f.write(f"\n**Diff:** {files_changed} files, +{insertions}/-{deletions} ({total_diff} total)\n\n")
        f.write(f"[View in Braintrust](https://www.braintrust.dev/app/{PROJECT}/experiments/ci-pr{PR_NUMBER}-{SHORT_SHA})\n\n")
        for d in details:
            f.write(d + "\n")

# Exit non-zero if any check failed
if any(v == 0.0 for k, v in checks.items() if k != "diff_precision"):
    sys.exit(1)
