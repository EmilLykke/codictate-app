import {
  addDictationReadinessListener,
  getDictationReadiness,
  type DictationReadiness,
} from 'codictate-dictation'
import { useEffect, useState } from 'react'
import { AppState } from 'react-native'
import { useTranscriptionLanguage } from '@/hooks/settings/transcription-language-context'
import { useSharedModelManagement } from '@/hooks/whisper/model-management-context'

/**
 * Dictation Readiness as the Host computed it. This hook reads and re-reads a
 * verdict; it never derives one, never substitutes another Speech Model and
 * never degrades a blocked state into a runnable one.
 *
 * Three things make it re-ask:
 * - the Host's own `codictate.readiness.changed` event,
 * - foregrounding, because a keyboard or Action Button turn can change the
 *   answer while JS is suspended,
 * - a Speech Model, Transcription Language or download change made from JS.
 */
export function useDictationReadiness(): DictationReadiness {
  const [readiness, setReadiness] = useState<DictationReadiness>(
    getDictationReadiness
  )
  const { languageId } = useTranscriptionLanguage()
  const { preferredVariant, models } = useSharedModelManagement()

  const readyVariants = models
    .filter((m) => m.ready)
    .map((m) => m.variant)
    .join(',')

  useEffect(() => {
    const sub = addDictationReadinessListener(setReadiness)
    const appStateSub = AppState.addEventListener('change', (next) => {
      if (next === 'active') setReadiness(getDictationReadiness())
    })
    return () => {
      sub.remove()
      appStateSub.remove()
    }
  }, [])

  useEffect(() => {
    setReadiness(getDictationReadiness())
  }, [languageId, preferredVariant, readyVariants])

  return readiness
}
