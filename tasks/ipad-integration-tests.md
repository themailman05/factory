# Add iPad Integration Tests to CI

## Context
We run integration tests on every push/PR on Chonk's Lenovo TB330FU (Android) via `integration-tests.yml`. The Mac mini has an iPad 10th gen (00008101-000D68611411A01E, iOS 26.2.1) connected via USB. We should run the same test suite on iPad for iOS device coverage.

Currently the only integration test is `RegistrationFlow` (`integration_test/simple_registration_test.dart`).

## Requirements
- [ ] New workflow (or new job in existing workflow) that runs integration tests on the iPad via the Mac mini runner
- [ ] Runs on same triggers: push to master/develop/neural-2, PRs to master, manual dispatch
- [ ] Uses `flutter test integration_test/... -d 00008101-000D68611411A01E`
- [ ] Runs the same test files as Android (currently `simple_registration_test.dart`)
- [ ] 5-minute timeout per test, 30-minute job timeout
- [ ] Uploads test logs as artifacts
- [ ] Posts PR comment with iPad results (separate from Android comment)
- [ ] Sends Telegram notification on completion
- [ ] Does NOT interfere with the iOS release build job (concurrency group or sequencing)

## Files Likely Involved
- `.github/workflows/integration-tests.yml` (add job) or new `.github/workflows/integration-tests-ios.yml`
- Possibly `ios/Podfile` if build issues arise

## Acceptance Criteria
- `flutter build ios --debug --no-codesign` succeeds
- Integration test runs on physical iPad and passes
- Workflow triggers on push to master
- Telegram notification fires
- No regressions to Android integration tests or iOS release build

## Anti-Patterns (DO NOT)
- Do NOT delete or skip existing tests
- Do NOT use simulator — must target physical iPad
- Do NOT hardcode device IDs in workflow (use `flutter devices` or a runner label convention)
- Do NOT run on cloud runners — Mac mini self-hosted only

## References
- Current Android integration tests: `.github/workflows/integration-tests.yml`
- iPad device: `00008101-000D68611411A01E` (iOS 26.2.1)
- Mac runner labels: `[self-hosted, macOS, ARM64]`
- Signing team: `UG98388868`
- Trello card: https://trello.com/c/cHcPGJEW
