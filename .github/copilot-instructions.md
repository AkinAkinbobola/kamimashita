# Copilot instructions for kamimashita

## Build, test and lint commands

- Install deps: `flutter pub get`
- Run full test suite: `flutter test`
- Run a single test file: `flutter test test/<path_to_test>.dart`
- Run a single test by name: `flutter test --name "test name substring"`
- Run analyzer (lint/type checks): `flutter analyze`
- Format code: `dart format .`
- Run on a connected device/emulator: `flutter run`
- Run web (Chrome) debug: `flutter run -d chrome`
- Build release APK: `flutter build apk`

Notes:
- Lints come from `flutter_lints` and are configured in `analysis_options.yaml`.
- To update dependencies: `flutter pub upgrade`.

## High-level architecture

- This is a Flutter application using Dart null-safety (SDK >= 3.11.5).
- Typical layout:
  - `lib/` — main application code (entry: `lib/main.dart`)
  - `test/` — unit/widget/integration tests
  - `android/`, `ios/`, `web/`, `linux/`, `macos/`, `windows/` — platform folders
  - `pubspec.yaml` declares dependencies and assets
- The app uses Material/Cupertino as configured in `pubspec.yaml` and `uses-material-design: true`.

## Key conventions

- Linting: `flutter_lints` activated via `analysis_options.yaml`; fix reported issues with `dart fix --apply` when appropriate.
- Tests:
  - Keep tests under `test/` with descriptive filenames like `xyz_test.dart`.
  - Use `flutter test test/path_to_test.dart` to run one file; use `--name` to filter by test name.
- Assets and fonts must be listed in `pubspec.yaml` to be bundled.
- CI should run: `flutter pub get && flutter analyze && flutter test`.

## Existing docs and AI configs

- README.md contains a minimal project description.
- No existing Copilot/AI assistant config files (.github/copilot-instructions.md, CLAUDE.md, AGENTS.md, .cursorrules, .windsurfrules, CONVENTIONS.md) were found when this file was created.

---

Created by repository assistant.
