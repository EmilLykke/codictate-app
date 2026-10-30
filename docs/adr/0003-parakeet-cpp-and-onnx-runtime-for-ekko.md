# parakeet.cpp built from source runs ekko, ONNX Runtime runs ekko-pnc, beside hviske

Codictate desktop ships a second Danish Speech Model, RyeAI's `ekko-v1-tiny` (q5_0 GGUF), and
its Punctuation Model `ekko-pnc`, because ekko's Raw Transcript is lowercase with no
punctuation. ekko's GGUF loads only in **parakeet.cpp** (mudler/parakeet.cpp, MIT); crispasr
cannot read it. So iOS gets a second ASR Harness, parakeet.cpp v0.6.1, called in-process
through its C API (`parakeet_capi_*`), and ONNX Runtime 1.30.0 to run ekko-pnc on the CPU.
ekko is added **beside** hviske, not instead of it (codictate#88).

## Considered Options

- **Use a prebuilt parakeet.cpp, as ADR-0001 does for crispasr.** Not possible: upstream
  publishes no iOS artifact at any tag. ADR-0001 rejected a source build of crispasr because
  a prebuilt existed and a source build would let iOS and desktop drift. Here there is
  nothing prebuilt to take, so `scripts/build-parakeet-xcframework.sh` builds the pinned tag
  (`v0.6.1`, commit `5c9b0fb`) into an xcframework (`ios-arm64` and
  `ios-arm64_x86_64-simulator`, Metal embedded, CLI, server, tests, CED and voice detection
  off). The zip is published once as the `vendor-parakeet.cpp-v0.6.1` release asset of this
  repo and fetched and sha256-checked like crispasr, so a normal build still compiles no
  parakeet.cpp. Desktop pins the same tag, which keeps the "a Danish bug reproduces on either"
  property ADR-0001 cared about.
- **A static parakeet library.** Rejected. crispasr.framework and llama.framework each carry
  their own ggml, and parakeet.cpp brings a third, patched copy. Linked statically into the app
  binary, its ggml symbols would collide with or bind to the others. A **dynamic** framework
  that exports only `parakeet_capi_*` keeps its ggml private: Mach-O's two-level namespace
  binds each framework's ggml calls to its own image, the same way llama.framework already
  sits beside crispasr.framework.
- **Run ekko through crispasr.** Rejected: crispasr has no loader for parakeet.cpp's GGUF.
- **Core ML for ekko-pnc, or a hand-written runtime.** Rejected. Desktop runs `pnc.int8.onnx`
  in ONNX Runtime and the iOS port must be byte-identical to desktop's parity fixture. The
  same int8 graph on the same runtime version (1.30.0, desktop's onnxruntime-node) is the
  shortest path to that. ONNX Runtime comes from Microsoft's own prebuilt iOS pod archive,
  sha256-pinned; it is a **static** framework, so it is linked into the app binary rather than
  embedded. CPU execution provider only, telemetry disabled.
- **Replace hviske with ekko now.** Rejected for this change. Desktop measured ekko better and
  faster on FLEURS Danish (9.9 against 11.3 WER), but nobody has run ekko on an iPhone: memory,
  first Metal load time and background execution are unmeasured there. ekko ships beside
  hviske, and replacing hviske waits for a real-iPhone test (codictate#88).

## Consequences

- **Two ASR Harnesses, plus FluidAudio.** crispasr runs Whisper and hviske, parakeet.cpp runs
  ekko, FluidAudio runs Parakeet.
- **A vendor we build ourselves.** Bumping parakeet.cpp means re-running the build script,
  uploading a new release asset and re-pinning its sha256 (`scripts/vendor-manifest.ts`).
- **ekko is one download with two parts.** Its GGUF and ekko-pnc's three runtime files come
  from two Mirrors at pinned commits, sha256-checked, with one progress value. ekko is ready
  only when all four files are on disk. Deleting ekko deletes both parts, because on iOS
  nothing else uses ekko-pnc.
- **Punctuation Restoration always runs on ekko** and never fails a Dictation: on any fault the
  unpunctuated words are delivered.
- **Metal in the background is unverified for ekko**, as it is for Whisper and hviske:
  iOS does not run GPU work submitted while the app is in the background, which is where
  keyboard warm-path Dictations transcribe. To be checked on a device with the rest of #88.
- **Three more redistribution notices**: ekko-v1-tiny (NVIDIA Open Model License, RyeAI's
  CC BY 4.0 modifications, CoRal and FT Speech terms), ekko-pnc (CC BY 4.0 with the CoRal
  restrictions), parakeet.cpp and ONNX Runtime (MIT). They are in `third-party/`, `NOTICE` and
  the licences screen. The weights are downloaded, never bundled.
