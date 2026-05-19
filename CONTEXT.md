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
