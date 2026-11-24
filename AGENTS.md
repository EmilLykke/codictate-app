# codictate-app

Expo + React Native iOS app. On-device speech-to-text with four ASR engines: Parakeet TDT v3 (primary, Neural Engine, FluidAudio), Whisper base (crispasr), the Danish hviske (crispasr) and the Danish ekko (parakeet.cpp, always followed by the ekko-pnc Punctuation Model on ONNX Runtime). No cloud transcription.

## Building

Never run prebuild just to edit Swift files; build directly in Xcode or `expo run:ios`. Prebuild is only needed when `app.config.ts`, config plugins, or native module setup changes. Since SDK 57 `expo prebuild` deletes and recreates `ios/` every run (`--no-clean` keeps it), so the plugins must produce a working project from an empty `ios/` in one pass.

**Never edit files inside `ios/` directly.** Prebuild regenerates the entire `ios/` folder, wiping any direct edits. Always edit the source of truth:
- Swift source files → `targets/codictateapp/` (copied into `ios/` by `withKeyboardExtension` plugin)
- AppDelegate and SceneDelegate modifications → `plugins/withKeyboardExtension.ts` (string patches on Expo's SDK 58 template; prebuild fails loudly when an anchor is missing)
- Widget files → `targets/widgets/`
- Expo module native code → `modules/codictate-dictation/ios/`

```bash
bun run prebuild:ios   # recreate ios/ from app.config.ts (clean)
bun run ios            # expo run:ios
```

**Launch (scene life cycle, SDK 58):** `AppDelegate.didFinishLaunching` runs `KeyboardHostRecorder.bootstrap()` on every launch and only creates the React Native factory. `SceneDelegate` starts React Native when its scene first enters the foreground, never on a background launch (Action Button intent, background download relaunch). Host deep links (`keyboard-record`, `keyboard-session`, `dictation`) go to `AppDelegate.handleHostDeepLink` and never reach JS; `SceneDelegate` filters them out of warm links.

Plugin order matters: Expo runs mods in reverse registration order, so inner wrappers in `app.config.ts` run later. `withKeyboardExtension` registers the keyboard target last so it exists before its other mods, and `withFluidAudio` sits inside it to link FluidAudio to that target.

## Architecture

**App Group**: `group.app.codictate` -- shared container for UserDefaults state and every Speech Model's files, Parakeet's included.

**Entry points:**
- Main app (JS + `KeyboardHostRecorder.swift`) -- in-app dictation
- `CodictateDictationKeyboard` extension -- system keyboard with a Dictate button. With Parakeet as the Speech Model it dictates by itself on the In-keyboard path (`InKeyboardDictation.swift`: `getUserMedia` in a hidden `WKWebView`, Parakeet through FluidAudio on the Neural Engine, models read from the App Group); otherwise it only triggers the Host (Warm or Cold path)
- `AudioRecordingIntent` -- Action Button / Shortcuts

**Recording flow:** keyboard (Warm or Cold path; the In-keyboard path writes no phase and never involves the Host) or intent writes phase=start to App Group, main app picks it up via Darwin notification or deep link, records with `AVAudioRecorder` at 16 kHz, then routes through `TranscriptionEngine` protocol to `ParakeetEngine`, `WhisperEngine`, `CohereEngine` or `EkkoEngine` (ekko's text then goes through `PunctuationRestorer`), runs S1-mini formatting when eligible, writes transcript back to App Group.

**ASR engines (TranscriptionEngine protocol):**
- `ParakeetEngine` -- wraps FluidAudio's `AsrManager`. Uses `AsrModels.downloadAndLoad(to: modelDirectory, version: .v3)` for model management, with the models in the App Group. Runs on Neural Engine via CoreML.
- `WhisperEngine` -- wraps the existing `WhisperBridge` (ObjC++). Loads `ggml-base-q5_1.bin` from the App Group container. CPU-only.
- `CohereEngine` -- wraps `CohereBridge` (ObjC++) on crispasr's cohere backend. Runs the Danish hviske GGUF.
- `EkkoEngine` -- wraps `EkkoBridge` (ObjC++) on parakeet.cpp's C API. Runs the Danish ekko GGUF slice by slice (`AudioSlicer`), Metal on device, CPU on the simulator. Its Raw Transcript is lowercase and unpunctuated, so the router always passes it through `PunctuationRestorer` (ekko-pnc on ONNX Runtime via `EkkoPncBridge`), which never fails a Dictation. Loaded while the user speaks, like Parakeet.

Engine selection is stored in UserDefaults under `preferredModelVariant` (App Group). Default is `parakeet`. The `TranscriptionRouter` class in `KeyboardHostRecorder.swift` reads this preference and dispatches to the correct engine.

## Speech Models

| Variant | Engine | Storage | Size | Hardware |
|---|---|---|---|---|
| `parakeet` | Parakeet TDT v3 (FluidAudio) | `FluidAudio/Models/parakeet-tdt-0.6b-v3/` (App Group) | ~500 MB | Neural Engine |
| `base` | Whisper base-q5_1 | `ggml-base-q5_1.bin` (App Group) | ~57 MB | CPU |
| `base_en` | Whisper base.en-q5_1 | `ggml-base.en-q5_1.bin` (App Group) | ~57 MB | CPU |
| `hviske` | hviske-v5-tiny q5_0 (crispasr) | `hviske-v5-tiny-q5_0.gguf` (App Group) | ~181 MB | GPU (Metal) |
| `ekko` | ekko-v1-tiny q5_0 (parakeet.cpp) + ekko-pnc (ONNX Runtime) | `ekko-v1-tiny-q5_0.gguf` + `ekko-pnc/` (App Group) | ~152 MB | GPU (Metal) + CPU |

Parakeet models are downloaded by `ParakeetModelManager` via FluidAudio's `AsrModels.downloadAndLoad(to: modelDirectory, version: .v3)` into `<App Group>/FluidAudio/Models/parakeet-tdt-0.6b-v3/`: FluidAudio's own layout, rooted in the App Group instead of its default Application Support cache, so the keyboard extension can load the same files. The leaf must stay FluidAudio's folder name (`download(to:)` and `load(from:)` use `directory.deletingLastPathComponent()/<folderName>`); `ParakeetModelManager.modelDirectory` derives it, and `AppGroupModelManager.parakeetModelDirectory` and the keyboard extension hard-code it. At launch `ParakeetModelManager.migrateLegacyModelsIfNeeded()` (from `KeyboardHostRecorder.bootstrap()`) moves models an older build left in `Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3` into the App Group, and deleting Parakeet removes both folders. A `parakeetModelReady` flag in UserDefaults (App Group) persists across launches; the same launch step clears it when the models are not in the App Group folder. Whisper models are downloaded from `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/` into the App Group container. ekko downloads its GGUF and ekko-pnc's three runtime files from their Mirrors at pinned commits, all at once with one progress value, and installs a file only if its size and sha256 match the pin. It is ready only with all four on disk, and deleting it deletes both parts.

## FluidAudio SPM dependency

Added via `plugins/withFluidAudio.ts` config plugin. This plugin injects the `XCRemoteSwiftPackageReference` and `XCSwiftPackageProductDependency` into the Xcode project during prebuild.

## TranscriptionEngine -- files that must stay consistent

The engine abstraction lives in `targets/codictateapp/`:
- `TranscriptionEngine.swift` -- protocol with `func transcribe(wavPath: String) async throws -> String`
- `ParakeetEngine.swift` -- FluidAudio wrapper + `ParakeetModelManager`
- `WhisperEngine.swift` -- WhisperBridge wrapper
- `CohereEngine.swift` -- CohereBridge wrapper (hviske)
- `EkkoEngine.swift` -- EkkoBridge wrapper (ekko), with `AudioSlicer.swift`
- `PunctuationRestorer.swift` -- ekko-pnc, with `EkkoPnc.swift`, `EkkoPncTokenizer.swift`, `EkkoPncModel.swift`, `PythonText.swift` and `EkkoPncBridge`

These are compiled into the main app target by the `withKeyboardExtension` config plugin (see `ensureSourceFileBuiltByMainAppTarget` calls). A new Obj-C++ bridge header also goes in that plugin's bridging-header list.

## ModelManager -- three files that must stay in sync

Whenever you add, remove, or modify a model variant, update all three:

1. `targets/codictateapp/ModelManager.swift` -- source of truth for the main app target
2. `ios/Codictate/ModelManager.swift` -- main app target (generated by prebuild)
3. `modules/codictate-dictation/ios/AppGroupModelManager.swift` -- Expo module (cannot import main-app symbols)

The `Variant` enum uses explicit rawValues so the JS-facing string matches (`parakeet = "parakeet"`, `base = "base"`).

Download URLs live only in the main app target's copy: the Host performs every download,
so the module's copy has no `url` to drift from.

## ParakeetModelManager -- cross-module download flow

The Expo module cannot import FluidAudio directly. Model download is coordinated via NotificationCenter:

1. Expo module posts `codictate.parakeet.ensureModel`
2. `ParakeetModelManager` (installed in `KeyboardHostRecorder.bootstrap()`) receives and calls `downloadAndPrepare()`
3. Progress posted via `codictate.parakeet.progress` (userInfo: `["progress": Double]`)
4. Completion posted via `codictate.parakeet.ready` or `codictate.parakeet.failed`
5. `AppGroupModelManager` listens for these and resolves the `ensureModel` callback

## ModelManager -- cross-module download flow

The file-backed Speech Models (`base`, `base_en`, `hviske`, `ekko`) use the same shape, for a
different reason: **the Expo module must never own a background `URLSession`.** iOS
relaunches a terminated app to finish a background download without initialising React
Native, so a session attached from the module's `OnCreate` is never recreated on the one
launch that exists to file the bytes. The Host owns the single session and the module is a
requester:

1. Expo module posts `codictate.model.ensureModel` (userInfo: `["variant": String]`)
2. `ModelManager.installObserver()` (installed in `KeyboardHostRecorder.bootstrap()`) receives it and downloads on the one background session, `app.codictate.modeldownload.host`
3. Progress posted via `codictate.model.progress` (userInfo: `["variant": String, "progress": Double]`)
4. Completion posted via `codictate.model.ready` (`["variant", "path"]`) or `codictate.model.failed` (`["variant", "error"]`)
5. `AppGroupModelManager` listens for these and resolves the `ensureModel` callback

The module keeps everything that does not download and works with no Host code running:
readiness (`modelIsReady`), paths, `listModels` and `deleteModel`. There is exactly one
background session identifier in the process, declared as
`BackgroundDownloadEvents.sessionIdentifier` and consumed by `ModelManager`; the
AppDelegate hook injected by `plugins/withKeyboardExtension.ts` answers its completion
handler.

## DictationActivityAttributes -- three files that must stay in sync

Whenever you modify `ContentState` (e.g. adding a field), update all three:

1. `targets/codictateapp/DictationActivityAttributes.swift` -- source of truth
2. `ios/Codictate/DictationActivityAttributes.swift` -- main app target copy
3. `ios/ExpoWidgetsTarget/DictationActivityAttributes.swift` -- widget target copy

## DictationLiveActivityWidget -- two files that must stay in sync

1. `targets/widgets/DictationLiveActivityWidget.swift` -- source of truth
2. `ios/ExpoWidgetsTarget/DictationLiveActivityWidget.swift` -- compiled widget target copy

## codictate-dictation Expo module

Local module at `modules/codictate-dictation/`. Declared as `"codictate-dictation": "file:./modules/codictate-dictation"` in `package.json`.

**Important:** `node_modules/codictate-dictation/` is a real copy, not a symlink. After editing `modules/codictate-dictation/index.ts`, sync it manually; TypeScript reads from `node_modules`:

```bash
cp modules/codictate-dictation/index.ts node_modules/codictate-dictation/index.ts
```

Running `bun install` re-copies automatically, but won't happen mid-session.

## Domain docs

`GLOSSARY.md` is the glossary for this app's domain terms (Dictation turn, Warm path, Speech
Model, ASR Harness, Language Lock, Punctuation Restoration, Dictation Readiness). Use those terms in code and docs.
Architectural decisions and their rejected alternatives live in `docs/adr/`:

| ADR | Decision |
|---|---|
| `0001-crispasr-as-the-ios-asr-harness.md` | crispasr replaces `whisper.rn` as the ASR Harness, unlocking the Danish hviske Speech Model. FluidAudio keeps Parakeet |
| `0002-s1-mini-for-optional-english-cleanup.md` | S1-mini is the optional English Formatting Model |
| `0003-parakeet-cpp-and-onnx-runtime-for-ekko.md` | parakeet.cpp, built from source as a dynamic framework, runs the Danish ekko beside hviske; ONNX Runtime runs its Punctuation Model ekko-pnc |

## Linting / type checking

```bash
bun run lint          # ESLint
bun run lint:fix      # ESLint with auto-fix
bunx tsc --noEmit     # TypeScript
```
