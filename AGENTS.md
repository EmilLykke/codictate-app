# codictate-app

Expo + React Native iOS app. On-device speech-to-text via whisper.cpp (no cloud). Three entry points: in-app, keyboard extension, Action Button shortcut.

## Building

Never run prebuild just to edit Swift files — build directly in Xcode or `expo run:ios`. Prebuild is only needed when `app.json`, config plugins, or native module setup changes. `--clean` nukes the whole `ios/` folder; only use it when things are truly broken.

```bash
bun run prebuild:ios   # regenerate ios/ from app.config.ts (no clean)
bun run ios            # expo run:ios
```

## Architecture

**App Group**: `group.app.codictate` — shared container between the main app, keyboard extension, and App Intent. All model files, WAV recordings, and UserDefaults state live here.

**Entry points:**
- Main app (JS + `KeyboardHostRecorder.swift`) — in-app dictation
- `CodictateDictationKeyboard` extension — system keyboard with a Dictate button
- `AudioRecordingIntent` — Action Button / Shortcuts

**Recording flow:** keyboard/intent writes phase=start to App Group → main app picks it up via Darwin notification or deep link → records with `AVAudioRecorder` → transcribes with `WhisperBridge` → writes transcript back to App Group.

## Whisper Models

Downloaded from `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/` into the App Group container.

| Variant | File | Size |
|---|---|---|
| `base` | `ggml-base-q5_1.bin` | ~57 MB |
| `small` | `ggml-small-q5_1.bin` | ~181 MB |

The keyboard extension always uses `base` (memory budget). The main app and Action Button use the user's preferred model.

## ModelManager — three files that must stay in sync

Whenever you add, remove, or modify a model variant, update all three:

1. `ios/Codictate/ModelManager.swift` — main app target
2. `targets/codictateapp/ModelManager.swift` — duplicate for the app target build
3. `modules/codictate-dictation/ios/AppGroupModelManager.swift` — Expo module (cannot import main-app symbols)

The `Variant` enum uses explicit rawValues so the JS-facing string matches (`largeV3Turbo = "large-v3-turbo"`).

## codictate-dictation Expo module

Local module at `modules/codictate-dictation/`. Declared as `"codictate-dictation": "file:./modules/codictate-dictation"` in `package.json`.

**Important:** `node_modules/codictate-dictation/` is a real copy, not a symlink. After editing `modules/codictate-dictation/index.ts`, sync it manually — TypeScript reads from `node_modules`:

```bash
cp modules/codictate-dictation/index.ts node_modules/codictate-dictation/index.ts
```

Running `bun install` re-copies automatically, but won't happen mid-session.

## Linting / type checking

```bash
bun run lint          # ESLint
bun run lint:fix      # ESLint with auto-fix
bunx tsc --noEmit      # TypeScript
```
