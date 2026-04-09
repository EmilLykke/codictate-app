import React, {
  createContext,
  useCallback,
  useEffect,
  useRef,
  useState,
} from 'react'
import { File, Paths } from 'expo-file-system'
import { WhisperContext } from 'whisper.rn'
import { ACTIVE_WHISPER_MODEL } from '@/constants/whisper-models'
import {
  loadWhisperModel,
  ModelLoadProgress,
} from '@/modules/whisper/init-whisper'

export type WhisperState =
  | { status: 'downloading'; progress: number }
  | { status: 'initializing' }
  | { status: 'ready'; ctx: WhisperContext }
  | { status: 'error'; error: Error; retry: () => void }

const WhisperCtx = createContext<WhisperState>({
  status: 'downloading',
  progress: 0,
})

export type WhisperModelActions = {
  /** Release loaded context (if any) and run download/init again. */
  reloadModel: () => Promise<void>
  /** Release context, delete the active model file, then download/init again. */
  purgeActiveModelAndReload: () => Promise<void>
}

const WhisperActionsCtx = createContext<WhisperModelActions | null>(null)

export function WhisperProvider({ children }: { children: React.ReactNode }) {
  const [state, setState] = useState<WhisperState>({
    status: 'downloading',
    progress: 0,
  })
  const ctxRef = useRef<WhisperContext | null>(null)

  useEffect(() => {
    if (state.status === 'ready') ctxRef.current = state.ctx
    else ctxRef.current = null
  }, [state])

  const load = useCallback(() => {
    setState({ status: 'downloading', progress: 0 })

    loadWhisperModel((update: ModelLoadProgress) => {
      if (update.phase === 'downloading') {
        setState({ status: 'downloading', progress: update.progress })
      } else {
        setState({ status: 'initializing' })
      }
    })
      .then((ctx) => setState({ status: 'ready', ctx }))
      .catch((err: unknown) => {
        const error =
          err instanceof Error ? err : new Error('Failed to load model')
        setState({ status: 'error', error, retry: load })
      })
  }, [])

  const reloadModel = useCallback(async () => {
    const c = ctxRef.current
    if (c) {
      try {
        await c.release()
      } catch {
        // ignore
      }
      ctxRef.current = null
    }
    load()
  }, [load])

  const purgeActiveModelAndReload = useCallback(async () => {
    const c = ctxRef.current
    if (c) {
      try {
        await c.release()
      } catch {
        // ignore
      }
      ctxRef.current = null
    }
    const f = new File(Paths.document, ACTIVE_WHISPER_MODEL.filename)
    if (f.exists) {
      f.delete()
    }
    load()
  }, [load])

  useEffect(() => {
    load()
  }, [load])

  const actions = React.useMemo<WhisperModelActions>(
    () => ({ reloadModel, purgeActiveModelAndReload }),
    [reloadModel, purgeActiveModelAndReload]
  )

  return (
    <WhisperActionsCtx.Provider value={actions}>
      <WhisperCtx.Provider value={state}>{children}</WhisperCtx.Provider>
    </WhisperActionsCtx.Provider>
  )
}

export function useWhisperCtx(): WhisperState {
  return React.use(WhisperCtx)
}

export function useWhisperModelActions(): WhisperModelActions {
  const v = React.use(WhisperActionsCtx)
  if (v == null) {
    throw new Error(
      'useWhisperModelActions must be used within WhisperProvider'
    )
  }
  return v
}
