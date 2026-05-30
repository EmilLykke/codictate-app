import { useCallback, useEffect, useState } from 'react'
import { Alert } from 'react-native'
import * as Haptics from 'expo-haptics'
import {
  deleteModel,
  ensureModel,
  getPreferredModel,
  listModels,
  onModelProgress,
  setPreferredModel,
  type ModelInfo,
  type ModelVariant,
} from 'codictate-dictation'
import {
  MODEL_LABELS,
  MODEL_SIZE_MB,
} from '@/components/Settings/settings-shared'

export function useModelManagement() {
  const [models, setModels] = useState<ModelInfo[]>([])
  const [preferredVariant, setPreferredVariant] = useState<ModelVariant>('base')
  const [downloadProgress, setDownloadProgress] = useState<
    Partial<Record<ModelVariant, number>>
  >({})

  useEffect(() => {
    const sub = onModelProgress((e) => {
      setDownloadProgress((prev) => ({ ...prev, [e.variant]: e.progress }))
    })
    return () => sub.remove()
  }, [])

  const refresh = useCallback(() => {
    void Promise.all([listModels(), getPreferredModel()]).then(
      ([list, pref]) => {
        setModels(list)
        setPreferredVariant(pref)
      }
    )
  }, [])

  useEffect(() => {
    refresh()
  }, [refresh])

  const clearDownloadProgress = (variant: ModelVariant) => {
    setDownloadProgress((prev) => {
      const next = { ...prev }
      delete next[variant]
      return next
    })
  }

  const startDownload = useCallback(
    (variant: ModelVariant) => {
      setDownloadProgress((prev) => ({ ...prev, [variant]: 0 }))
      void ensureModel(variant)
        .then(async () => {
          clearDownloadProgress(variant)
          await Haptics.notificationAsync(
            Haptics.NotificationFeedbackType.Success
          )
          refresh()
        })
        .catch((error: unknown) => {
          clearDownloadProgress(variant)
          const message =
            error instanceof Error
              ? error.message
              : 'Model download failed. Check your connection and try again.'
          Alert.alert('Download failed', message)
        })
    },
    [refresh]
  )

  const confirmDownload = useCallback(
    (variant: ModelVariant) => {
      const label = MODEL_LABELS[variant] ?? variant
      Alert.alert(
        'Download model?',
        `Download ${label} now? Requires Wi-Fi and ~${MODEL_SIZE_MB[variant] ?? '?'} MB.`,
        [
          { text: 'Cancel', style: 'cancel' },
          { text: 'Download', onPress: () => startDownload(variant) },
        ]
      )
    },
    [startDownload]
  )

  const confirmDelete = useCallback(
    (row: ModelInfo) => {
      const label = MODEL_LABELS[row.variant] ?? row.variant
      Alert.alert(
        'Delete model file?',
        `Remove ${label} from this device? It will download again when needed.`,
        [
          { text: 'Cancel', style: 'cancel' },
          {
            text: 'Delete',
            style: 'destructive',
            onPress: () => {
              void (async () => {
                const wasPreferred = preferredVariant === row.variant
                try {
                  await deleteModel(row.variant)
                  if (wasPreferred) {
                    const listAfter = await listModels()
                    const next = listAfter.find((m) => m.ready)?.variant
                    if (next) await setPreferredModel(next)
                  }
                  await Haptics.notificationAsync(
                    Haptics.NotificationFeedbackType.Success
                  )
                } finally {
                  refresh()
                }
              })()
            },
          },
        ]
      )
    },
    [preferredVariant, refresh]
  )

  const selectPreferred = useCallback(
    (variant: ModelVariant) => {
      const row = models.find((m) => m.variant === variant)
      if (!row?.ready) return
      void Haptics.selectionAsync()
      void setPreferredModel(variant).then(() => setPreferredVariant(variant))
    },
    [models]
  )

  return {
    models,
    preferredVariant,
    downloadProgress,
    refresh,
    startDownload,
    confirmDownload,
    confirmDelete,
    selectPreferred,
  }
}
