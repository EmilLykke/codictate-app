# crispasr replaces whisper.rn as the iOS ASR Harness, so Danish hviske can run

Codictate desktop ships the Danish Speech Model `hviske-v5-tiny`, whose GGUF weights are
Cohere2-architecture ASR weights that **only** crispasr's `cohere` backend can load;
whisper.cpp and llama.cpp cannot read them at all. Bringing Danish to iOS therefore means
bringing crispasr to iOS. crispasr publishes an official xcframework with `ios-arm64` and
simulator slices carrying the cohere backend and embedded Metal shaders, so we link it
into the main app target and **delete `whisper.rn`**, whose only role in this repo was
supplying whisper.cpp as a static library - it is imported from zero JavaScript files.
FluidAudio keeps Parakeet, because Core ML on the Neural Engine beats a ggml Metal path
we have not measured.

## Considered Options

- **crispasr for hviske only, keep `whisper.rn` for Whisper.** Rejected: crispasr's
  framework already exports the complete `whisper_*` API, and `WhisperBridge.mm` calls
  exactly seven of those symbols, all present in the shipped `crispasr.h`. Keeping
  `whisper.rn` would ship a second copy of whisper.cpp plus its React-Core / Fabric /
  Hermes pod graph for a library we already have.
- **crispasr for all three, drop FluidAudio too.** Rejected: crispasr does carry a
  Parakeet backend, but it runs on ggml/Metal while FluidAudio runs Core ML on the Neural
  Engine. Trading measured ANE execution for unmeasured GPU execution to remove one
  dependency is the wrong trade on a battery-powered device.
- **Build crispasr from source for iOS.** The repo ships `build-ios.sh` and
  `build-xcframework.sh`, and a source build could strip unused backends and link
  statically. Rejected for now: it adds a CMake + Xcode toolchain step to the build and
  lets the iOS and desktop apps drift onto different crispasr commits. Both apps pin the
  same `v0.8.29`, so a Danish bug reproduces identically on either.
- **Auto-route to hviske whenever the Transcription Language is Danish.** Rejected. It
  makes a 181 MB download a hidden precondition of a language setting, and it is a
  runtime fallback, which desktop rejected in its own ADR-0005. hviske is a Speech Model
  the user selects.

## Consequences

- **The language picker stops being decorative.** Today `TranscriptionEngine` has no
  language parameter, `WhisperEngine` hardcodes `"auto"`, and the setting lives in
  AsyncStorage where Swift never sees it. hviske cannot run without an explicit language
  code and a wrong code yields a fluent wrong-language transcript rather than an error, so
  wiring language end to end is a precondition of this change, not a follow-up. The
  setting moves to App Group UserDefaults alongside `preferredModelVariant`, with a
  one-shot migration from the old AsyncStorage key.
- **Language Lock applies to `base_en` too.** English-only weights fed `"da"` fail the
  same silent way hviske would. The mechanism costs one array literal per Speech Model, so
  it covers every Speech Model rather than special-casing hviske.
- **Dictation Readiness is computed in Swift**, not TypeScript. Desktop puts its resolver
  in the process that owns dictation; on iOS that is the Host, because keyboard and Action
  Button dictation run with no React Native process alive. React Native reads a computed
  readiness value and renders it.
- ~~**Memory was the open risk.**~~ **Closed 2026-08-22.** hviske measured 282 MB peak RSS
  on desktop, the engines cache their context and hold it resident, and the keyboard warm
  session keeps the app alive in the background, which is precisely the state iOS jetsams
  first. The cache-and-hold pattern survives the case it was most likely to fail: hviske
  selected, warm session armed, app backgrounded, keyboard dictation still succeeds, with
  resident memory watched under Instruments rather than inferred from the desktop figure.
  The remedy held in reserve, freeing the context on `didEnterBackgroundNotification` and
  reloading lazily, was not needed and is not implemented. Reach for it if a
  lower-memory device proves less forgiving than the one this was measured on.
- **Metal gets switched on for Whisper as a side effect.** `WhisperBridge.mm` sets
  `use_gpu = false` under the comment "GPU not available in extensions", but that file is
  built by the main app target only and has never been in the extension. The flag is
  corrected in a separate commit *after* the library swap is verified, so a regression has
  one cause and not two.
- ~~**Nobody has run the cohere backend on iOS.**~~ **Observed 2026-08-22.** Danish
  Dictation runs on a physical device, both in-app and through the keyboard warm path after
  backgrounding. The Whisper regression check passed too: the same audio through crispasr's
  library matches the retired `whisper.rn` build, so the Harness swap changed nothing for the
  Whisper Speech Models. What stays unobserved is narrow, and worth keeping honest: the
  simulator build was not exercised, and this is one device, so the result confirms rather
  than measures. Desktop still carries the equivalent gap on Windows, where the `cohere`
  backend is verified present by symbol inspection but no hviske Dictation has ever been run.
- **Two redistribution obligations.** crispasr is MIT, needing only attribution in the
  licences screen. hviske is CC BY-NC 4.0, mirrored at
  `emillykkegrann/hviske-v5-tiny-GGUF`, which binds codictate-app to remaining
  non-commercial for as long as it offers Danish. The repo has no StoreKit, RevenueCat or
  IAP today, and the weights are downloaded rather than bundled, so the shipped binary
  carries no NC content.
- **Retiring crispasr would take Danish with it**, and now Whisper as well. Danish support
  is downstream of this Harness decision, not independent of it.
