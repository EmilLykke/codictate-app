import { useCallback, useEffect, useRef, useState } from 'react'
import { AppState, type AppStateStatus } from 'react-native'
import * as Haptics from 'expo-haptics'
import {
  acknowledgeError,
  cancel as nativeCancel,
  consumeTranscript,
  getState,
  onError,
  onStateChange,
  onTranscript,
  start as nativeStart,
  stop as nativeStop,
  type DictationPhase,
} from 'codictate-dictation'

export type DictationState = 'idle' | 'recording' | 'processing'

export type RealtimeDictation = {
  dictState: DictationState
  transcript: string | null
  dictError: string | null
  start: () => Promise<void>
  stop: () => Promise<void>
  clear: () => void
}

function viewStateForPhase(phase: DictationPhase): DictationState {
  switch (phase) {
    case 'start':
    case 'recording':
      return 'recording'
    case 'stop_requested':
    case 'processing':
      return 'processing'
    default:
      return 'idle'
  }
}

function haptic(fn: () => Promise<void>) {
  void fn().catch(() => {})
}

/**
 * Drives the native dictation coordinator (KeyboardHostRecorder) via the
 * `codictate-dictation` Expo module. All recording + Whisper transcription runs
 * natively, so the JS thread suspending in the background does NOT stop the session.
 *
 * Also flushes transcripts produced while JS was suspended (e.g. keyboard or
 * Action Button started/finished a session) when the app foregrounds.
 */
export function useRealtimeDictation(): RealtimeDictation {
  const [dictState, setDictState] = useState<DictationState>('idle')
  const [transcript, setTranscript] = useState<string | null>(null)
  const [dictError, setDictError] = useState<string | null>(null)

  const lastAppStateRef = useRef<AppStateStatus>(AppState.currentState)

  const flushPending = useCallback(async () => {
    try {
      const text = await consumeTranscript()
      if (text) setTranscript(text)
      const snap = await getState()
      setDictState(viewStateForPhase(snap.phase))
      if (snap.phase === 'failed' && snap.error) {
        setDictError(snap.error)
        await acknowledgeError()
      }
    } catch {
      // ignore
    }
  }, [])

  // Initial sync — pick up any state set before the hook mounted (e.g. from keyboard).
  useEffect(() => {
    void flushPending()
  }, [flushPending])

  // Re-sync when the app comes to the foreground. JS may have been suspended while
  // a session completed; we need to flush the queued transcript.
  useEffect(() => {
    const sub = AppState.addEventListener('change', (next) => {
      const prev = lastAppStateRef.current
      lastAppStateRef.current = next
      if (prev !== 'active' && next === 'active') {
        void flushPending()
      }
    })
    return () => sub.remove()
  }, [flushPending])

  // Subscribe to native events — covers the live (in-app, not suspended) path.
  useEffect(() => {
    const stateSub = onStateChange((event) => {
      setDictState(viewStateForPhase(event.phase))
      if (event.phase === 'failed' && event.error) {
        setDictError(event.error)
        void acknowledgeError().catch(() => {})
      }
    })
    const transcriptSub = onTranscript((event) => {
      if (event.transcript) {
        setTranscript(event.transcript)
        haptic(() =>
          Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
        )
      }
    })
    const errorSub = onError((event) => {
      setDictError(event.message)
      haptic(() =>
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error)
      )
    })
    return () => {
      stateSub.remove()
      transcriptSub.remove()
      errorSub.remove()
    }
  }, [])

  const start = useCallback(async () => {
    setDictError(null)
    setTranscript(null)
    haptic(() => Haptics.selectionAsync())
    try {
      await nativeStart('host')
    } catch (e) {
      setDictError(
        e instanceof Error ? e.message : 'Could not start recording.'
      )
      setDictState('idle')
      haptic(() =>
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error)
      )
    }
  }, [])

  const stop = useCallback(async () => {
    try {
      await nativeStop()
    } catch (e) {
      setDictError(e instanceof Error ? e.message : 'Could not stop recording.')
      // Best-effort: cancel the native session so we don't get stuck.
      void nativeCancel().catch(() => {})
      setDictState('idle')
    }
  }, [])

  const clear = useCallback(() => {
    setTranscript(null)
    setDictError(null)
  }, [])

  return { dictState, transcript, dictError, start, stop, clear }
}
