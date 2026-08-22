# Codictate domain glossary

## Dictation turn

One speak-to-text cycle: start recording, stop, transcribe, deliver the transcript (keyboard insert, clipboard, or in-app draft).

## Cold path

Keyboard signals the host by opening `codictateapp://keyboard-record`. Used when no valid keyboard warm session exists.

## Warm path

Keyboard writes `phase=start` to the App Group and posts a Darwin notification. The host must already be running a **listen session** (continuous `AVAudioEngine` + `UIBackgroundModes: audio`). A background `DispatchSourceTimer` polls App Group phase every ~250ms (Darwin alone is unreliable while backgrounded). The keyboard must **not** call `extensionContext.open` on the warm path.

## Keyboard warm session / listen session

After the first completed keyboard dictation, the host starts a continuous AVAudioEngine listen session (orange mic indicator), sets `kbdListenSessionReady` only when the engine is running, and shows a Live Activity in **standby** ("Listening for the keyboard"). Subsequent dictations capture from the engine tap while the user stays in another app. User dismissing the standby Live Activity ends the session.

Warm-window validity is determined by `kbdWarmSessionActive` + `kbdWarmSessionExpiry`, not by engine readiness alone.

## Standby Live Activity

Passive Dynamic Island / lock-screen state after keyboard dictation completes. Shows the keyboard warm session is armed. No `widgetURL` (tap does not open the app). Swiping it away ends the warm session.

## Keyboard dictate button (visual states)

On the Codictate keyboard extension, the Dictate key uses color to show phase: **red** while recording (stop icon), **orange** while transcribing/processing (waveform icon). Idle uses a light red-tinted key background. Distinct from the host app's orange mic indicator during a keyboard warm session.

## First-time Parakeet processing

Parakeet models load lazily via FluidAudio `AsrModels.downloadAndLoad` on the first transcribe of a install. While `parakeetModelReady` is false, keyboard strip and Live Activity show extended copy ("first use may take a minute"). After the first successful transcribe, processing UI returns to generic "Transcribing...".

## Host

The main Codictate iOS app process running `KeyboardHostRecorder`. Owns recording, transcription, and warm session state. Does not require React Native for keyboard or Action Button dictation.

## Action Button dictation

Independent toggle via `AudioRecordingIntent`. Starting Action Button dictation **ends** any active keyboard warm session (listen engine stopped, warm flags cleared). The keyboard can still stop an in-progress Action Button recording via the Dictate button (writes `stop_requested` + Darwin stop wake).

## Speech Model

One set of ASR weights the user can select, together with its id, its download and its
declared capabilities. `parakeet`, `base`, `base_en` and `hviske` are Speech Models.
_Avoid_: model variant, engine (a Speech Model is not the runtime that executes it).

## ASR Harness

The runtime library that loads a Speech Model's weights and produces a transcript.
Codictate iOS has one, **crispasr**, linked as an xcframework. FluidAudio is the
exception: Parakeet runs on Core ML through FluidAudio's own `AsrManager`, not on the
Harness. Harness is internal vocabulary and never appears in user-facing copy.
_Avoid_: backend, engine, whisper.cpp (the last is a Harness implementation detail).

## Language Lock

A Speech Model's declaration of which Transcription Languages it accepts. `hviske`
locks to Danish, `base_en` to English, `parakeet` locks to automatic because it takes
no language input at all, and `base` accepts the full list. A Locked Speech Model
disables the languages it cannot run rather than silently ignoring a selection,
because feeding a Speech Model a language it does not support yields a fluent
wrong-language transcript and never an error.

Auto-detect is the absence of a choice, not a conflicting one: a Locked Speech Model
accepts it and runs its pinned language, resolved once in the Host before any engine
sees it. `languageUnsupportedByModel` therefore fires only on a language the user
picked explicitly, such as French while hviske is the Speech Model.

## Dictation Readiness

Whether the current (Speech Model, Transcription Language, permissions) combination can
start a Dictation turn right now. Computed in the Host, never in React Native, because
keyboard and Action Button dictation run with no JS process alive. Either runnable, or
blocked with exactly one reason from a closed set; there is no third state and no
substitution of a different Speech Model.
_Avoid_: fallback, degraded mode.
