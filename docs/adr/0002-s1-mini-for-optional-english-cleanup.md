# iOS introduces optional English cleanup with S1-mini

iOS will offer Off and S1-mini by Superwhisper as its initial formatting choices. Qwen is outside this change: the reason for introducing S1-mini is its smaller model footprint and suitability for everyday transcript cleanup, not parity with every desktop Formatting Model.

Cleanup applies only to English and never switches to another model for an ineligible transcript. It must work for keyboard, Action Button and in-app Dictation, including destinations outside desktop app presets.

The small model download motivates this choice but does not establish the runtime memory budget. Speech recognition and cleanup residency, background execution and latency still need real-device validation before support can be claimed.

The default is standard written English with contractions retained. Users can select the model's supported writing styles. Codictate always sends the model's `lists` structure control so it can add bullets when the transcript calls for them and otherwise return prose. iOS does not need desktop app detection: general settings apply before each completed transcript is delivered.

There is no latency acceptance target. Users opt into S1-mini and decide whether its speed and output suit them. Live Transcription cleanup is outside this feature.

## Implementation requirements

- The native Host owns cleanup, model download and persisted selection so keyboard and Action Button dictation work without React Native running.
- Determine English eligibility, including Parakeet and automatic-language transcription. Preserve non-English or uncertain transcripts without model substitution. Detection cannot guarantee identifying every mixed-language transcript.
- A successful empty cleanup delivers no text. It is distinct from an inference failure, which preserves the transcript.
- Use the model's documented prompt and plain-text output contract, with its upstream name and distribution notices.
- Add the native runtime and sources through the existing config plugins. Validate compatibility with crispasr's existing native libraries and test memory, background execution and inference on an actual iPhone.

The implementation uses Apple's NaturalLanguage framework for automatic-language eligibility and a pinned llama.cpp xcframework for inference in the Host. The generic iPhoneOS build passes with llama and crispasr linked together, and the same Objective-C++ bridge passes real model tests using the runtime's macOS slice. Actual iPhone inference, memory pressure and background operation remain unvalidated on hardware.
