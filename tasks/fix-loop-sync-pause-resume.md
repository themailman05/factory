# Fix loop sync drift on pause/resume

## Context
When pausing and resuming the base loop, subsequent recordings (2nd, 3rd, etc) don't start in sync. They align to multiples of the original start position rather than the actual current loop point. The `SampleAccurateSync` class in `audio_recorder_bloc_v2.dart` tracks frame positions and loop boundaries, but `_globalFramePosition` freezes during pause (no audio callback data flows) and `_baseLoopStartFrame` is never recalculated on resume.

## Requirements
- [ ] When playback resumes after pause, recalculate `_baseLoopStartFrame` using the actual SoLoud playback position (not the stale pre-pause value)
- [ ] `_globalFramePosition` must be re-synced or the loop start must be adjusted to account for the pause gap
- [ ] `getNextRecordStartFrame()` must return a frame within ±256 frames (one buffer) of the actual loop boundary after a pause/resume cycle
- [ ] Add a unit test for `SampleAccurateSync` that proves the fix

## Testing Flow (this is how we verify it works)

### Unit Test: `test/blocs/audio_engine/sample_accurate_sync_test.dart`

Write a pure Dart unit test (no Flutter, no device needed) that:

1. **Setup**: Create `SampleAccurateSync`, set sample rate to 48000
2. **Set base loop**: 48000 frames (1 second loop), start frame = 0
3. **Simulate recording**: Advance `_globalFramePosition` to 72000 (1.5 loops in)
4. **Verify pre-pause**: `getNextRecordStartFrame(72000)` should return 96000 (start of 3rd loop cycle)
5. **Simulate pause**: Stop advancing `_globalFramePosition` (it stays at 72000)
6. **Simulate resume after 2 seconds**: The real SoLoud playback position is now at 0.5s into the loop (24000 frames into current cycle). Call the resume/re-sync method with this actual position.
7. **Verify post-resume**: `getNextRecordStartFrame(currentFrame)` should return a value that is exactly one loop boundary ahead of the actual playback position — NOT based on the stale pre-pause frame count.

The test MUST fail on the current code (before the fix) and pass after.

### How to make `SampleAccurateSync` testable
- The class is currently embedded in the bloc. You may need to:
  - Extract it to its own file, OR
  - Make `_globalFramePosition` and `_baseLoopStartFrame` accessible for testing (package-private or via a test helper)
  - Add a `resyncAfterResume(int actualPositionInLoopFrames)` method

## Files to Modify
- `lib/blocs/audio_engine/audio_recorder/audio_recorder_bloc_v2.dart` — SampleAccurateSync: add resume re-sync method
- `lib/components/LoopStation.dart` — call `_updateRecorderBaseLoop()` on playback resume (not just on loop change)
- `lib/blocs/audio_engine/audio_player/audio_player_bloc.dart` — emit state that triggers re-sync on unpause
- `test/blocs/audio_engine/sample_accurate_sync_test.dart` — NEW: unit test proving the fix

## Acceptance Criteria (automated checks)
- `flutter analyze` passes with zero issues
- `flutter test test/blocs/audio_engine/sample_accurate_sync_test.dart` passes
- The test includes the pause/resume scenario described above
- The test asserts frame alignment within ±256 frames (one audio buffer)

## Evaluation Criteria (human review)
- [ ] The test WOULD FAIL on the original code (verify by reading the test logic against the original sync behavior)
- [ ] The fix is in the sync math, not in suppressing the test
- [ ] No changes to `getNextRecordStartFrame()` quantization logic (the calculation is correct, the inputs were wrong)
- [ ] The resume re-sync uses actual playback position, not elapsed wall-clock time

## DO NOT
- Delete or skip any existing tests
- Modify SoLoud native bindings
- Change the buffer size (256) or quantization logic in `getNextRecordStartFrame()`
- Add `// ignore` annotations
- Hardcode frame values to make the test pass
- Use `DateTime.now()` or wall-clock time for frame re-sync (use audio frame positions only)
