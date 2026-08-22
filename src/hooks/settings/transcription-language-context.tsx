import AsyncStorage from '@react-native-async-storage/async-storage'
import {
  getTranscriptionLanguageId,
  setTranscriptionLanguageId,
} from 'codictate-dictation'
import type { ReactNode } from 'react'
import React, {
  createContext,
  useCallback,
  useEffect,
  useMemo,
  useState,
} from 'react'
import { isValidTranscriptionLanguageId } from '@/constants/transcription-languages'

/**
 * Where the Transcription Language lived before it moved into App Group
 * UserDefaults. Read once by the migration below, then deleted.
 */
const LEGACY_STORAGE_KEY = '@codictate/transcriptionLanguageId'

const DEFAULT_LANGUAGE_ID = 'auto'

type TranscriptionLanguageValue = {
  languageId: string
  setLanguageId: (id: string) => void
  hydrated: boolean
}

const TranscriptionLanguageCtx =
  createContext<TranscriptionLanguageValue | null>(null)

/**
 * The Transcription Language is stored in App Group UserDefaults, not in
 * AsyncStorage, because keyboard and Action Button dictation run with no React
 * Native process alive and the Host has to read the same value.
 */
export function TranscriptionLanguageProvider({
  children,
}: {
  children: ReactNode
}) {
  const [languageId, setLanguageIdState] = useState(readStoredLanguageId)
  const [hydrated, setHydrated] = useState(false)

  useEffect(() => {
    let cancelled = false
    void migrateLegacyLanguageId(readStoredLanguageId()).then((id) => {
      if (cancelled) return
      setLanguageIdState(id)
      setHydrated(true)
    })
    return () => {
      cancelled = true
    }
  }, [])

  const setLanguageId = useCallback((id: string) => {
    if (!isValidTranscriptionLanguageId(id)) return
    setLanguageIdState(id)
    setTranscriptionLanguageId(id)
  }, [])

  const value = useMemo<TranscriptionLanguageValue>(
    () => ({ languageId, setLanguageId, hydrated }),
    [languageId, setLanguageId, hydrated]
  )

  return (
    <TranscriptionLanguageCtx.Provider value={value}>
      {children}
    </TranscriptionLanguageCtx.Provider>
  )
}

export function useTranscriptionLanguage(): TranscriptionLanguageValue {
  const v = React.use(TranscriptionLanguageCtx)
  if (v == null) {
    throw new Error(
      'useTranscriptionLanguage must be used within TranscriptionLanguageProvider'
    )
  }
  return v
}

function readStoredLanguageId(): string {
  const stored = getTranscriptionLanguageId()
  return isValidTranscriptionLanguageId(stored) ? stored : DEFAULT_LANGUAGE_ID
}

/**
 * One-shot upgrade path: copy the old AsyncStorage value into the App Group the
 * first time this build runs, then drop the old key so it never runs again.
 * An App Group value the user has already chosen always wins.
 */
async function migrateLegacyLanguageId(current: string): Promise<string> {
  const legacy = await AsyncStorage.getItem(LEGACY_STORAGE_KEY)
  if (legacy == null) return current
  await AsyncStorage.removeItem(LEGACY_STORAGE_KEY)
  if (current !== DEFAULT_LANGUAGE_ID) return current
  if (!isValidTranscriptionLanguageId(legacy)) return current
  setTranscriptionLanguageId(legacy)
  return legacy
}
