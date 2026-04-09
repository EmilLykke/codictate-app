import AsyncStorage from '@react-native-async-storage/async-storage'
import type { ReactNode } from 'react'
import React, {
  createContext,
  useCallback,
  useEffect,
  useMemo,
  useState,
} from 'react'
import {
  isValidTranscriptionLanguageId,
  transcribeLanguageOption,
} from '@/constants/transcription-languages'

const STORAGE_KEY = '@codictate/transcriptionLanguageId'

type TranscriptionLanguageValue = {
  languageId: string
  setLanguageId: (id: string) => Promise<void>
  hydrated: boolean
  transcribeLanguage: string
}

const TranscriptionLanguageCtx =
  createContext<TranscriptionLanguageValue | null>(null)

export function TranscriptionLanguageProvider({
  children,
}: {
  children: ReactNode
}) {
  const [languageId, setLanguageIdState] = useState('auto')
  const [hydrated, setHydrated] = useState(false)

  useEffect(() => {
    let cancelled = false
    void AsyncStorage.getItem(STORAGE_KEY).then((raw) => {
      if (cancelled) return
      if (raw != null && isValidTranscriptionLanguageId(raw)) {
        setLanguageIdState(raw)
      }
      setHydrated(true)
    })
    return () => {
      cancelled = true
    }
  }, [])

  const setLanguageId = useCallback(async (id: string) => {
    if (!isValidTranscriptionLanguageId(id)) return
    setLanguageIdState(id)
    await AsyncStorage.setItem(STORAGE_KEY, id)
  }, [])

  const value = useMemo<TranscriptionLanguageValue>(
    () => ({
      languageId,
      setLanguageId,
      hydrated,
      transcribeLanguage: transcribeLanguageOption(languageId),
    }),
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
