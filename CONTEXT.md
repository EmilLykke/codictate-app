# Codictate domain glossary

## Dictation turn

One speak-to-text cycle: start recording, stop, transcribe, deliver the transcript (keyboard insert, clipboard, or in-app draft).

## Cold path

Keyboard signals the host by opening `codictateapp://keyboard-record`. Used when no valid keyboard warm session exists.

## Warm path

Keyboard writes `phase=start` to the App Group and posts a Darwin notification. The host must already be running a **listen session** (continuous `AVAudioEngine` + `UIBackgroundModes: audio`). A background `DispatchSourceTimer` polls App Group phase every 300ms (Darwin alone is unreliable while backgrounded). The keyboard must **not** call `extensionContext.open` on the warm path.

## Keyboard warm session / listen session

After the first completed keyboard dictation, the host starts a continuous AVAudioEngine listen session (orange mic indicator), sets `kbdListenSessionReady` only when the engine is running, and shows a Live Activity in standby. Subsequent dictations capture from the engine tap while the user stays in another app. User dismissing the standby Live Activity ends the session.

## Host

The main Codictate iOS app process running `KeyboardHostRecorder`. Owns recording, transcription, and warm session state. Does not require React Native for keyboard or Action Button dictation.

## Action Button dictation

Independent toggle via `AudioRecordingIntent`. Does not start a keyboard warm session. May pause an active keyboard warm mic during intent recording, then resume standby if the warm window has not expired.
