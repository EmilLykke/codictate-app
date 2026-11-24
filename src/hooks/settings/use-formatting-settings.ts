import { useFocusEffect } from 'expo-router'
import * as Haptics from 'expo-haptics'
import { useCallback, useEffect, useState } from 'react'
import { Alert, AppState } from 'react-native'
import {
  deleteFormattingModel,
  ensureFormattingModel,
  getFormattingContext,
  getFormattingModel,
  getFormattingModelStatus,
  getFormattingStyle,
  onFormattingModelProgress,
  onFormattingModelStatus,
  onFormattingSettingsChange,
  setFormattingContext,
  setFormattingModel,
  setFormattingStyle,
  type FormattingContext,
  type FormattingModel,
  type FormattingModelStatus,
  type FormattingStyle,
} from 'codictate-dictation'
import { FORMATTING_MODEL_SIZE_MB } from '@/constants/formatting'

export function useFormattingSettings() {
  const [model, setModelState] = useState(getFormattingModel)
  const [style, setStyleState] = useState(getFormattingStyle)
  const [context, setContextState] = useState(getFormattingContext)
  const [status, setStatus] = useState<FormattingModelStatus | null>(null)
  const [downloadProgress, setDownloadProgress] = useState<number | null>(null)

  const refresh = useCallback(() => {
    setModelState(getFormattingModel())
    setStyleState(getFormattingStyle())
    setContextState(getFormattingContext())
    void getFormattingModelStatus().then((next) => {
      setStatus(next)
      // A download in flight keeps the progress it last reported.
      setDownloadProgress((prev) => (next.downloading ? (prev ?? 0) : null))
    })
  }, [])

  useFocusEffect(refresh)

  // The keyboard's S1-mini switch writes the Formatting Model too: re-read when the
  // Host reports a change, and on every foreground, because a suspended app misses it.
  useEffect(() => {
    const changeSub = onFormattingSettingsChange(refresh)
    const appStateSub = AppState.addEventListener('change', (next) => {
      if (next === 'active') refresh()
    })
    return () => {
      changeSub.remove()
      appStateSub.remove()
    }
  }, [refresh])

  useEffect(() => {
    const progressSubscription = onFormattingModelProgress(({ progress }) => {
      setDownloadProgress(progress)
    })
    const statusSubscription = onFormattingModelStatus((next) => {
      setStatus(next)
      setDownloadProgress(next.downloading ? 0 : null)
    })
    return () => {
      progressSubscription.remove()
      statusSubscription.remove()
    }
  }, [])

  const chooseModel = useCallback(
    (value: FormattingModel) => {
      if (value === 's1-mini' && !status?.ready) return
      setFormattingModel(value)
      setModelState(value)
      void Haptics.selectionAsync()
    },
    [status?.ready]
  )

  const chooseStyle = useCallback((value: FormattingStyle) => {
    setFormattingStyle(value)
    setStyleState(value)
    void Haptics.selectionAsync()
  }, [])

  const chooseContext = useCallback((value: FormattingContext) => {
    setFormattingContext(value)
    setContextState(value)
    void Haptics.selectionAsync()
  }, [])

  const startDownload = useCallback(() => {
    setDownloadProgress(0)
    void ensureFormattingModel()
      .then(async () => {
        setDownloadProgress(null)
        setStatus(await getFormattingModelStatus())
        await Haptics.notificationAsync(
          Haptics.NotificationFeedbackType.Success
        )
      })
      .catch((error: unknown) => {
        setDownloadProgress(null)
        const message =
          error instanceof Error
            ? error.message
            : 'The model download failed. Check your connection and try again.'
        Alert.alert('Download failed', message)
      })
  }, [])

  const confirmDownload = useCallback(() => {
    Alert.alert(
      'Download S1-mini?',
      `Download the ${FORMATTING_MODEL_SIZE_MB} MB model for on-device English formatting?`,
      [
        { text: 'Cancel', style: 'cancel' },
        { text: 'Download', onPress: startDownload },
      ]
    )
  }, [startDownload])

  const confirmDelete = useCallback(() => {
    Alert.alert(
      'Delete S1-mini?',
      'Remove the formatting model from this device and turn formatting off?',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete',
          style: 'destructive',
          onPress: () => {
            void deleteFormattingModel()
              .then(async () => {
                setModelState('off')
                setStatus(await getFormattingModelStatus())
                await Haptics.notificationAsync(
                  Haptics.NotificationFeedbackType.Success
                )
              })
              .catch((error: unknown) => {
                const message =
                  error instanceof Error
                    ? error.message
                    : 'The formatting model could not be deleted.'
                Alert.alert('Delete failed', message)
              })
          },
        },
      ]
    )
  }, [])

  return {
    model,
    style,
    context,
    status,
    downloadProgress,
    chooseModel,
    chooseStyle,
    chooseContext,
    confirmDownload,
    confirmDelete,
  }
}
