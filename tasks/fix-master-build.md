# Fix master build — flutter_soloud API migration + LiteRT clang flag

## Context
Master doesn't build. Two issues:

### Issue 1: flutter_soloud API drift (Android + iOS)
The `flutter_soloud` plugin API changed but app code wasn't migrated. Errors:

```
lib/blocs/audio_engine/audio_engine_mock.dart:185:19: Error: 'CaptureDevice' is imported from both 'package:flutter_recorder/src/enums.dart' and 'package:flutter_soloud/src/enums.dart'.
lib/blocs/audio_engine/audio_engine_mock.dart:62:19: Error: 'AudioMetadata' isn't a type.
lib/utils/waveform_extractor.dart:38:23: Error: Method not found: 'SoLoudController'.
lib/utils/waveform_extractor.dart:75:45: Error: The method 'readSamplesFromFile' isn't defined for the type 'SoLoud'.
lib/blocs/audio_engine/audio_recorder/audio_recorder_bloc.dart:699:42: Error: The method 'loadMem' isn't defined for the type 'SoLoud'.
lib/audio/channel_audio_buffer.dart:273:19: Error: The function 'tanh' isn't defined.
```

**Fix approach:**
- Add `show` / `hide` clauses to disambiguate `CaptureDevice` and `CaptureErrors` imports (both `flutter_recorder` and `flutter_soloud` export them)
- Find the new API equivalents for removed/renamed methods: `SoLoudController`, `readSamplesFromFile`, `loadMem`, `AudioMetadata`
- Check the flutter_soloud plugin source at `plugins/flutter_soloud/lib/` for current API
- Check the flutter_recorder plugin source at `plugins/flutter_recorder/lib/` for current API
- For `tanh`: import `dart:math` or use a manual implementation

### Issue 2: LiteRT clang flag (iOS only)
```
Error (Xcode): unsupported option '-G' for target 'arm64-apple-ios13'
```
The `-G` flag is a linker option not supported by Apple's clang for iOS targets. This comes from the LiteRT static archive build. Check the bazel build config or CMakeLists.txt in `plugins/flutter_recorder/third_party/LiteRT/` for where `-G` is passed and remove/guard it for iOS.

## Files likely needing changes
- `lib/blocs/audio_engine/audio_engine_mock.dart` — disambiguate imports, fix AudioMetadata
- `lib/utils/waveform_extractor.dart` — replace SoLoudController, readSamplesFromFile
- `lib/blocs/audio_engine/audio_recorder/audio_recorder_bloc.dart` — replace loadMem
- `lib/audio/channel_audio_buffer.dart` — fix tanh
- Possibly LiteRT build files for the `-G` flag

## Important
- Check the ACTUAL current API in `plugins/flutter_soloud/lib/src/soloud.dart` — don't guess
- Check `plugins/flutter_recorder/lib/` for the recorder API
- The submodule pins ARE correct — the app code just hasn't been updated to match

## Acceptance Criteria
- `flutter analyze --no-pub` produces zero new errors (existing plugin warnings are OK)
- `flutter build apk --release --target-platform android-arm64` succeeds
- `flutter build ios --no-codesign` succeeds (if Xcode available)

## DO NOT
- Change submodule pins or versions
- Delete functionality
- Skip or disable tests
- Modify the plugins themselves
