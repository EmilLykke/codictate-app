import * as Clipboard from 'expo-clipboard'
import {
  AudioModule,
  RecordingPresets,
  setAudioModeAsync,
  useAudioRecorder,
} from 'expo-audio'
import { File } from 'expo-file-system'
import * as Haptics from 'expo-haptics'
import { useCallback, useState } from 'react'
import type { TranscribeResult } from 'whisper.rn'
import {
  WHISPER_MIN_RECORDING_BYTES,
  WHISPER_RECORDING_OPTIONS,
} from '@/constants/whisper-recording'
import { useTranscriptionLanguage } from '@/hooks/settings/transcription-language-context'
import { sanitizeWhisperTranscript } from '@/utils/whisper-transcript/sanitize-whisper-transcript'
import { useWhisperCtx } from './use-whisper-ctx'

export type DictationState = 'idle' | 'recording' | 'processing'

export type RealtimeDictation = {
  dictState: DictationState
  transcript: string | null
  dictError: string | null
  start: () => Promise<void>
  stop: () => Promise<void>
  clear: () => void
}

function textFromTranscribeResult(result: TranscribeResult): string {
  const direct = result.result?.trim() ?? ''
  if (direct.length > 0) return direct
  const fromSegments =
    result.segments
      ?.map((s) => s.text)
      .join('')
      .trim() ?? ''
  return fromSegments
}

function haptic(fn: () => Promise<void>) {
  void fn().catch(() => {})
}

async function resetAudioModeForPlayback(): Promise<void> {
  try {
    await setAudioModeAsync({
      allowsRecording: false,
      playsInSilentMode: true,
      interruptionMode: 'duckOthers',
      shouldPlayInBackground: false,
      shouldRouteThroughEarpiece: false,
    })
  } catch {
    // ignore
  }
}

export function useRealtimeDictation(): RealtimeDictation {
  const whisper = useWhisperCtx()
  const { transcribeLanguage } = useTranscriptionLanguage()
  const recorder = useAudioRecorder(
    process.env.EXPO_OS === 'ios'
      ? WHISPER_RECORDING_OPTIONS
      : RecordingPresets.HIGH_QUALITY
  )
  const [dictState, setDictState] = useState<DictationState>('idle')
  const [transcript, setTranscript] = useState<string | null>(null)
  const [dictError, setDictError] = useState<string | null>(null)

  const start = useCallback(async () => {
    if (whisper.status !== 'ready' || dictState !== 'idle') return

    const { granted } = await AudioModule.requestRecordingPermissionsAsync()
    if (!granted) {
      haptic(() =>
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error)
      )
      setDictError('Microphone permission is required for dictation.')
      return
    }

    setTranscript(null)
    setDictError(null)

    try {
      await setAudioModeAsync({
        allowsRecording: true,
        playsInSilentMode: true,
        interruptionMode: 'duckOthers',
        shouldPlayInBackground: false,
        shouldRouteThroughEarpiece: false,
      })
      await recorder.prepareToRecordAsync()
      recorder.record()
      setDictState('recording')
      haptic(() => Haptics.selectionAsync())
    } catch (e) {
      haptic(() =>
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error)
      )
      setDictError(
        e instanceof Error ? e.message : 'Could not start recording.'
      )
      setDictState('idle')
      await resetAudioModeForPlayback()
    }
  }, [whisper.status, dictState, recorder])

  const stop = useCallback(async () => {
    if (dictState !== 'recording') return
    if (whisper.status !== 'ready') {
      setDictState('idle')
      return
    }

    setDictState('processing')

    try {
      await recorder.stop()
      const uri = recorder.uri ?? recorder.getStatus().url
      if (!uri) {
        throw new Error('No recording file was produced.')
      }

      const recorded = new File(uri)
      if (!recorded.exists) {
        throw new Error('Recording file is missing.')
      }
      if (recorded.size < WHISPER_MIN_RECORDING_BYTES) {
        throw new Error(
          'Recording is too short or empty — hold the button longer and speak.'
        )
      }

      const { promise } = whisper.ctx.transcribe(uri, {
        language: transcribeLanguage,
      })
      const transcription = await promise

      if (transcription.isAborted) {
        throw new Error('Transcription was interrupted.')
      }

      const text = sanitizeWhisperTranscript(
        textFromTranscribeResult(transcription)
      )
      if (!text) {
        const androidHint =
          process.env.EXPO_OS === 'android'
            ? ' (Android: recorder output may not be WAV yet — use iOS for reliable dictation.)'
            : ''
        haptic(() =>
          Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning)
        )
        setDictError(
          `No speech detected. Try again, speak clearly, and record a few seconds.${androidHint}`
        )
        setTranscript(null)
      } else {
        setTranscript(text)
        await Clipboard.setStringAsync(text)
        haptic(() =>
          Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
        )
      }
    } catch (e) {
      haptic(() =>
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error)
      )
      setDictError(e instanceof Error ? e.message : 'Transcription failed.')
      setTranscript(null)
    } finally {
      setDictState('idle')
      await resetAudioModeForPlayback()
    }
  }, [dictState, recorder, whisper, transcribeLanguage])

  const clear = useCallback(() => {
    setTranscript(null)
    setDictError(null)
  }, [])

  return { dictState, transcript, dictError, start, stop, clear }
}
