# Codictate domain glossary

## Dictation turn

One speak-to-text cycle: start recording, stop, transcribe, deliver the transcript (keyboard insert, clipboard, or in-app draft).

## Cold path

Keyboard signals the host by opening `codictateapp://keyboard-record`. Used when no valid keyboard warm session exists and the In-keyboard path is not eligible, or when an In-keyboard capture fails to start.

## Warm path

Keyboard writes `phase=start` to the App Group and posts a Darwin notification. The host must already be running a **listen session** (continuous `AVAudioEngine` + `UIBackgroundModes: audio`). A background `DispatchSourceTimer` polls App Group phase every ~250ms (Darwin alone is unreliable while backgrounded). The keyboard must **not** call `extensionContext.open` on the warm path. A valid warm session takes precedence over the In-keyboard path, so the keyboard and the Host never both own the microphone.

## In-keyboard path

The keyboard records and transcribes a Dictation turn without opening the Host, even when
the app is closed, with any Speech Model. It captures with `getUserMedia` in a hidden
`WKWebView` (WebKit records in its own process, so the keyboard's microphone restriction
does not apply) into a WAV in the App Group's `KeyboardRecordings/`. Parakeet then
transcribes inside the keyboard, on the Neural Engine through FluidAudio, loading the
Host's models from the App Group; every other Speech Model runs in the Dictation AU, which
reads the WAV and answers with the finished text. It writes no phase to the App Group.
Eligible only with Full Access, the Speech Model's files in the App Group, a Transcription
Language its Language Lock accepts, the Host's published Dictation Readiness not blocked,
microphone granted, no Host warm session, and an idle shared phase; for Parakeet also a
Neural Engine, 5 GiB of memory and room in the keyboard's memory limit. Otherwise the
keyboard uses the Warm or Cold path. S1-mini does not block it: a warm Host records and
formats as before, and without one the Dictation AU formats the text. A capture that fails
to start hands that tap to the Cold path; a failed load or transcription shows
"Transcription failed" and sets the path aside for that Speech Model in the keyboard
process, so the next tap goes to the Host.
_Avoid_: local dictation, keyboard ASR.

## Dictation AU

The `CodictateFormattingAU` extension (it kept the target name and bundle id it had as the
Formatting AU): an Audio Unit with no interface and no audio work that the keyboard hosts
out of process, so an In-keyboard Dictation turn gets every Speech Model and S1-mini
without the Host. It is the UI kind of Audio Unit extension (`com.apple.AudioUnit-UI`)
because iOS gives that kind no hard memory ceiling, unlike the keyboard. It runs the Host's
own code on the App Group's files (`TranscriptionPipeline` with `WhisperEngine`,
`CohereEngine`, `EkkoEngine`, `PunctuationRestorer`, `S1MiniFormatter`), so a turn is
decoded and formatted exactly as in the Host: for Parakeet turns it only formats the
keyboard's text, for every other Speech Model it transcribes, restores punctuation for ekko
and formats, in one request. It loads the Speech Model and S1-mini when an In-keyboard turn
starts, holds one Speech Model at a time, and frees everything when the keyboard goes away
or memory runs short. It asks for Metal as the Host does and drops to the CPU for the rest
of its process if Metal fails. Formatting never fails a Dictation turn: on any fault or
after its timeout the keyboard inserts the unformatted text. Internal vocabulary; it never
appears in user-facing copy.
_Avoid_: plugin, effect, Formatting AU (its former name).

## Keyboard warm session / listen session

After the first completed keyboard dictation, the host starts a continuous AVAudioEngine listen session (orange mic indicator), sets `kbdListenSessionReady` only when the engine is running, and shows a Live Activity in **standby** ("Listening for the keyboard"). Subsequent dictations capture from the engine tap while the user stays in another app. User dismissing the standby Live Activity ends the session.

Warm-window validity is determined by `kbdWarmSessionActive` + `kbdWarmSessionExpiry`, not by engine readiness alone.

## Standby Live Activity

Passive Dynamic Island / lock-screen state after keyboard dictation completes. Shows the keyboard warm session is armed. No `widgetURL` (tap does not open the app). Swiping it away ends the warm session.

## Keyboard dictate button (visual states)

On the Codictate keyboard extension, the Dictate button is a small capsule (`DictatePill`) at the right of a quiet 44 pt strip above the keys, with only the dismiss glyph at the strip's left. It carries no text: each phase has a fill and a glyph. **Idle** is a key-colored capsule (white in light mode, the dark key grey in dark mode, with the keys' shadow) and a mic; while Parakeet's first-time load runs (**preparing**) the mic dims beside a small spinner. **Recording** is red with five white level bars (they follow the audio on the In-keyboard path and breathe slowly on the Warm and Cold paths, where the keyboard hears nothing). **Transcribing** is orange with a white spinner; a delivered transcript shows a checkmark on the idle capsule for about a second. An error is the only text the strip ever shows: one short red line between the dismiss glyph and the capsule that fades out after about 3 seconds, with the capsule back at idle. Distinct from the host app's orange mic indicator during a keyboard warm session.

## First-time Parakeet processing

Parakeet models load lazily via FluidAudio `AsrModels.downloadAndLoad` on the first transcribe of a install. While `parakeetModelReady` is false, the Live Activity shows extended copy ("first use may take a minute") and the keyboard's Dictate capsule shows its processing spinner. After the first successful transcribe, processing UI returns to generic "Transcribing...". On the In-keyboard path the keyboard compiles its own copy for the Neural Engine once per build (about 15 s); while that load runs, the idle capsule shows its dimmed mic with a small spinner (VoiceOver: "Getting ready").

## Host

The main Codictate iOS app process running `KeyboardHostRecorder`. Owns recording, transcription, and warm session state. Does not require React Native for keyboard or Action Button dictation.

## Action Button dictation

Independent toggle via `AudioRecordingIntent`. Starting Action Button dictation **ends** any active keyboard warm session (listen engine stopped, warm flags cleared). The keyboard can still stop an in-progress Action Button recording via the Dictate button (writes `stop_requested` + Darwin stop wake).

## Speech Model

One set of ASR weights the user can select, together with its id, its download and its
declared capabilities. `parakeet`, `base`, `base_en`, `hviske` and `ekko` are Speech Models.
_Avoid_: model variant, engine (a Speech Model is not the runtime that executes it).

## Formatting Model

The model the user selects to rewrite a transcript before delivery, such as S1-mini by
Superwhisper. Distinct from the Speech Model, which recognises speech.
On iOS, S1-mini always receives its `lists` structure control: it adds bullets when the
content calls for a list and otherwise returns prose. Structure is not a user setting.

## ASR Harness

The runtime library that loads a Speech Model's weights and produces a transcript.
Codictate iOS has two, each linked as an xcframework: **crispasr** runs `base`, `base_en`
and `hviske`, and **parakeet.cpp** runs `ekko`, whose GGUF crispasr cannot read. FluidAudio
is the exception: Parakeet runs on Core ML through FluidAudio's own `AsrManager`, not on a
Harness. ONNX Runtime, which runs the Punctuation Model, is not a Harness either: it
recognises no speech. Harness is internal vocabulary and never appears in user-facing copy.
_Avoid_: backend, engine, whisper.cpp (the last is a Harness implementation detail).

## Language Lock

A Speech Model's declaration of which Transcription Languages it accepts. `hviske`
and `ekko` lock to Danish, `base_en` to English, `parakeet` locks to automatic because it takes
no language input at all, and `base` accepts the full list. A Locked Speech Model
disables the languages it cannot run rather than silently ignoring a selection,
because feeding a Speech Model a language it does not support yields a fluent
wrong-language transcript and never an error.

Auto-detect is the absence of a choice, not a conflicting one: a Locked Speech Model
accepts it and runs its pinned language, resolved once in the Host before any engine
sees it. `languageUnsupportedByModel` therefore fires only on a language the user
picked explicitly, such as French while hviske is the Speech Model.

## Raw Transcript

The text a Speech Model produced, before any rewriting. ekko's is lowercase with no
punctuation.

## Punctuation Restoration

Adding punctuation and capital letters to a Raw Transcript, never removing a capital and
never changing, adding or removing any word. Danish only. On iOS it is always applied to
`ekko`, whose Raw Transcript has neither, and to no other Speech Model (iOS has no Add
punctuation switch for hviske). It runs in the Host (or, for an In-keyboard turn, the
Dictation AU) on the Raw Transcript before S1-mini formatting. It never fails a Dictation turn: on any fault the words are delivered as the
Speech Model wrote them, with no error. Not a Formatting Model: it does not rewrite.

## Punctuation Model

The weights that perform Punctuation Restoration (ekko-pnc), run on ONNX Runtime.
Distinct from a Speech Model, which recognises speech, and a Formatting Model, which
rewrites text. On iOS it is part of `ekko`'s download rather than a choice of its own:
`ekko` is ready only with it installed, and deleting `ekko` deletes it.

## Dictation Readiness

Whether the current (Speech Model, Transcription Language, permissions) combination can
start a Dictation turn right now. Computed in the Host, never in React Native, because
keyboard and Action Button dictation run with no JS process alive. Either runnable, or
blocked with exactly one reason from a closed set; there is no third state and no
substitution of a different Speech Model. The Host publishes it to the App Group; the
keyboard reads that before an In-keyboard turn, and the Dictation AU checks the same rule
(`DictationReadinessState.resolve`) before it runs a Speech Model.
_Avoid_: fallback, degraded mode.
