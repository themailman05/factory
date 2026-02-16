# Port integration tests to Chonk bare-metal runner

## Context
We need a fast integration test workflow that runs on the `deep-1` bare-metal runner on Chonk (44-core Linux server) with direct ADB access to a Lenovo TB330FU tablet. This is the QA floor of our software factory — iteration speed is everything.

The existing `build-release.yml` workflow already has good patterns for self-hosted runner speed. Mirror those patterns.

## Requirements
- [ ] Create `.github/workflows/integration-tests-device.yml`
- [ ] Target `runs-on: [self-hosted, Linux]` (matches deep-1 runner)
- [ ] Trigger on `pull_request` to master + `workflow_dispatch` for manual/factory runs
- [ ] Cache strategy: `~/ci-cache/` with submodule-hash markers (same as build-release.yml)
- [ ] `clean: false` on checkout for incremental builds
- [ ] Recursive submodule init (with cache check via marker files)
- [ ] Run Flutter integration tests on physical device via `flutter test integration_test/<file> -d HVA78E9L`
- [ ] Run each test file as a separate step (not parallel — single device)
- [ ] Capture and upload artifacts: test logs, screenshots, any audio WAV files
- [ ] Pre-flight check: verify ADB device is connected before running tests

## Reference: build-release.yml patterns to copy
Look at `.github/workflows/build-release.yml` for:
- The checkout step with `clean: false`
- The submodule cache logic with `~/ci-cache/` and hash markers
- The Flutter SDK path setup
- The environment variable patterns

## Test files to run
1. `integration_test/simple_registration_test.dart` — auth flow (fast, run first as smoke test)
2. `integration_test/loop_e2e_test.dart` — full loop record/play
3. `integration_test/aec_test.dart` — AEC quality
4. `integration_test/aec_sweep_test.dart` — AEC parameter sweep

## Workflow structure
```yaml
name: Integration Tests (Device)
on:
  pull_request:
    branches: [master]
  workflow_dispatch:

jobs:
  device-tests:
    runs-on: [self-hosted, Linux]
    timeout-minutes: 30
    steps:
      - checkout (clean: false, submodules: recursive)
      - cache setup (~/ci-cache/ pattern from build-release.yml)
      - flutter pub get
      - ADB pre-flight: `adb -s HVA78E9L get-state` must return "device"
      - Run each integration test file as separate step
      - Upload artifacts (logs, audio, screenshots)
```

## Acceptance Criteria
- Workflow file passes `actionlint` or is valid YAML
- Workflow targets self-hosted Linux runner
- ADB device serial HVA78E9L is used for all test commands
- Artifacts are uploaded via actions/upload-artifact
- Cache strategy matches build-release.yml patterns

## DO NOT
- Modify any existing workflow files
- Modify Chonk's infrastructure or helm charts
- Add new dependencies to the Flutter project
- Change any integration test files
- Hardcode absolute paths (use `~/ci-cache/` and `$HOME` patterns from build-release.yml)
