# AGENTS.md

Guidance for coding agents working in this repository.

## Project Snapshot
- **Type:** Flutter application
- **Primary language:** Dart
- **Key directories:** `lib/`, `test/`, `.github/workflows/`
- **Main entrypoint:** `lib/main.dart`

## Setup
1. Install Flutter SDK (CI uses **Flutter 3.38.9**).
2. Install dependencies:
   ```bash
   flutter pub get
   ```

## Local Validation
Run the same checks as CI before submitting changes:

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Optional build parity checks used in CI:

```bash
flutter build apk --debug
flutter build web --release --base-href "/DanbooruViewer/"
```

## Change Guidelines
- Keep changes minimal and scoped to the task.
- Avoid unrelated refactors.
- Preserve existing behavior unless the task requires a behavior change.
- Update docs when behavior or workflow changes.

## CI Reference
Primary CI workflow: `.github/workflows/ci.yml`.
