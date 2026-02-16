# Ensure build/release packaging uploads to App Store Connect for TestFlight

## Context
When a developer (this software factory) or a human developer creates a PR, an installable build should be available for iOS for testing via TestFlight. The existing `build-release.yml` workflow builds iOS but the App Store Connect upload step may not be fully working — the API key install was recently fixed (PR #13) but the `APP_STORE_API_KEY` secret (base64-encoded .p8 content) may need verification.

The build tag format is `PR#<number>-<short-sha>` injected via `--dart-define=BUILD_TAG=PR#<number>-<short-sha>` so testers can identify which PR build they're running.

## Requirements
- [ ] `build-release.yml` produces a signed IPA artifact downloadable from GitHub Actions
- [ ] IPA is uploaded to App Store Connect via `xcrun altool` or `xcrun notarytool`
- [ ] TestFlight build appears under bundle ID `io.ziptech.CloudLoop`
- [ ] Build number is unique per run (use `${{ github.run_number }}` or timestamp)
- [ ] PR gets a comment with the build tag and TestFlight availability status
- [ ] `BUILD_TAG` is visible somewhere in the app (settings, about, or debug overlay)

## Key Files
- `.github/workflows/build-release.yml` — existing iOS build workflow
- The altool key install step writes the .p8 to `./private_keys/`, `~/private_keys/`, `~/.private_keys/`, `~/.appstoreconnect/private_keys/`
- Secrets available: `APP_STORE_API_KEY_ID` ✅, `APP_STORE_API_ISSUER_ID` ✅, `APP_STORE_API_KEY` ❓ (base64 .p8 content — verify it's set)

## What needs to happen
1. Verify the IPA build step in `build-release.yml` produces a valid artifact
2. Verify the altool upload step works (uses the .p8 key from secrets)
3. Add a step to post a PR comment with build tag when upload succeeds
4. Ensure `--dart-define=BUILD_TAG=PR#${{ github.event.pull_request.number }}-${{ github.sha | truncate 7 }}` is passed to the flutter build command
5. Add `actions/upload-artifact` step for the IPA so it's downloadable from GitHub regardless of TestFlight

## Acceptance Criteria
- `flutter analyze` passes with zero issues
- Workflow YAML is valid
- IPA artifact is uploaded to GitHub Actions
- altool upload step has proper error handling (don't fail silently)
- PR comment step posts build tag

## DO NOT
- Delete or skip existing tests
- Break CI/CD or disable any existing workflow targets
- Remove any existing build steps
- Change the bundle ID or signing configuration
- Modify the altool key path logic (it was just fixed in PR #13)
