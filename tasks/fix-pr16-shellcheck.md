# Fix shellcheck warnings in integration-tests-device.yml

## Context
The workflow file `.github/workflows/integration-tests-device.yml` has shellcheck warnings (SC2086 double-quoting, SC2162 read -r, SC2129 grouped redirects). Fix all of them.

## Requirements
- [ ] All `${{ env.DEVICE_SERIAL }}` and `${{ env.FLUTTER_VERSION }}` references in shell scripts are double-quoted
- [ ] All `read` calls use `-r` flag
- [ ] Grouped redirects use `{ cmd1; cmd2; } >> file` pattern where flagged
- [ ] `actionlint .github/workflows/integration-tests-device.yml` produces zero errors (shellcheck info-level warnings are acceptable)

## Files to Modify
- `.github/workflows/integration-tests-device.yml` — ONLY this file

## Acceptance Criteria
- `actionlint` on the file shows no errors (info-level shellcheck is OK)
- Workflow YAML is still valid

## DO NOT
- Modify any other workflow files
- Change the logic or structure of the workflow
- Remove any steps
