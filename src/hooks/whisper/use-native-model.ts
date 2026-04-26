import { useCallback, useEffect, useState } from 'react'
import { ensureModel, isModelReady, onModelProgress } from 'codictate-dictation'

export type NativeModelState =
  | { status: 'checking' }
  | { status: 'downloading'; progress: number }
  | { status: 'ready' }
  | { status: 'error'; error: string; retry: () => void }

export function useNativeModel(): NativeModelState {
  const [state, setState] = useState<NativeModelState>({ status: 'checking' })

  const run = useCallback(() => {
    setState({ status: 'checking' })
    void isModelReady('base').then((ready) => {
      if (ready) {
        setState({ status: 'ready' })
        return
      }
      setState({ status: 'downloading', progress: 0 })
      void ensureModel('base')
        .then(() => setState({ status: 'ready' }))
        .catch((e: unknown) => {
          const msg = e instanceof Error ? e.message : 'Failed to load model'
          setState({ status: 'error', error: msg, retry: run })
        })
    })
  }, []) // stable — only calls module-level imports

  useEffect(() => {
    run()
  }, [run])

  useEffect(() => {
    const sub = onModelProgress((e) => {
      if (e.variant !== 'base') return
      setState((prev) =>
        prev.status === 'downloading' ? { ...prev, progress: e.progress } : prev
      )
    })
    return () => sub.remove()
  }, [])

  return state
}
