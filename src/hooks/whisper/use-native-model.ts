import { useFocusEffect } from 'expo-router'
import { useCallback, useEffect, useRef, useState } from 'react'
import {
  ensureModel,
  getPreferredModel,
  isModelReady,
  onModelProgress,
  type ModelVariant,
} from 'codictate-dictation'

export type NativeModelState =
  | { status: 'checking' }
  | { status: 'downloading'; progress: number; variant: ModelVariant }
  | { status: 'ready'; variant: ModelVariant }
  | { status: 'error'; error: string; retry: () => void }

export function useNativeModel(): NativeModelState {
  const [state, setState] = useState<NativeModelState>({ status: 'checking' })

  /** Tracks `onModelProgress` filtering and which variant triggered the current download UI. */
  const activeVariantRef = useRef<ModelVariant>('base')

  const run = useCallback(() => {
    void getPreferredModel().then((variant) => {
      activeVariantRef.current = variant
      void isModelReady(variant).then((ready) => {
        if (ready) {
          setState((s) =>
            s.status === 'ready' && s.variant === variant
              ? s
              : { status: 'ready', variant }
          )
          return
        }

        setState((s) => {
          if (s.status === 'downloading' && s.variant === variant) return s
          return { status: 'downloading', progress: 0, variant }
        })

        void ensureModel(variant)
          .then(() => {
            setState({ status: 'ready', variant })
          })
          .catch((e: unknown) => {
            const msg = e instanceof Error ? e.message : 'Failed to load model'
            setState({ status: 'error', error: msg, retry: run })
          })
      })
    })
  }, [])

  useFocusEffect(
    useCallback(() => {
      run()
    }, [run])
  )

  useEffect(() => {
    const sub = onModelProgress((e) => {
      if (e.variant !== activeVariantRef.current) return
      setState((prev) =>
        prev.status === 'downloading' ? { ...prev, progress: e.progress } : prev
      )
    })
    return () => sub.remove()
  }, [])

  return state
}
