import { useFocusEffect } from '@react-navigation/native'
import * as Haptics from 'expo-haptics'
import { Image } from 'expo-image'
import { useCallback, useEffect, useState } from 'react'
import { Alert, Pressable, Text, View } from 'react-native'
import { appColors } from '@/constants/AppColors'
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
import { formatFileSize } from '@/utils/format-file-size/format-file-size'
import {
  MODEL_LABELS,
  MODEL_META,
  MODEL_SIZE_MB,
  SectionCard,
  SettingsScroll,
  settingsStyles as styles,
} from '@/components/Settings/settings-shared'

export function ScreenSettingsModels() {
  const [models, setModels] = useState<ModelInfo[]>([])
  const [preferredVariant, setPreferredVariant] =
    useState<ModelVariant>('parakeet')
  const [downloadProgress, setDownloadProgress] = useState<
    Partial<Record<ModelVariant, number>>
  >({})

  useEffect(() => {
    const sub = onModelProgress((e) => {
      setDownloadProgress((prev) => ({ ...prev, [e.variant]: e.progress }))
    })
    return () => sub.remove()
  }, [])

  const refreshSpeechModelsUi = useCallback(() => {
    void Promise.all([listModels(), getPreferredModel()]).then(
      ([list, pref]) => {
        setModels(list)
        setPreferredVariant(pref)
      }
    )
  }, [])

  useFocusEffect(
    useCallback(() => {
      refreshSpeechModelsUi()
    }, [refreshSpeechModelsUi])
  )

  const confirmDelete = (row: ModelInfo) => {
    const label = MODEL_LABELS[row.variant] ?? row.variant
    const sizeStr = row.ready ? ` (${formatFileSize(row.size)})` : ''
    Alert.alert(
      'Delete model file?',
      `Remove ${label}${sizeStr} from this device? It will download again when needed.`,
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
                refreshSpeechModelsUi()
              }
            })()
          },
        },
      ]
    )
  }

  const clearDownloadProgress = (variant: ModelVariant) => {
    setDownloadProgress((prev) => {
      const next = { ...prev }
      delete next[variant]
      return next
    })
  }

  const startDownload = (variant: ModelVariant) => {
    setDownloadProgress((prev) => ({ ...prev, [variant]: 0 }))
    void ensureModel(variant)
      .then(async () => {
        clearDownloadProgress(variant)
        await Haptics.notificationAsync(
          Haptics.NotificationFeedbackType.Success
        )
        refreshSpeechModelsUi()
      })
      .catch((error: unknown) => {
        clearDownloadProgress(variant)
        const message =
          error instanceof Error
            ? error.message
            : 'Model download failed. Check your connection and try again.'
        Alert.alert('Download failed', message)
      })
  }

  const confirmRedownload = (row: ModelInfo) => {
    const label = MODEL_LABELS[row.variant] ?? row.variant
    Alert.alert(
      'Download model?',
      `Download ${label} now? Requires Wi-Fi and ~${MODEL_SIZE_MB[row.variant] ?? '?'} MB.`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Download',
          onPress: () => startDownload(row.variant),
        },
      ]
    )
  }

  const selectPreferredForInApp = (variant: ModelVariant) => {
    const row = models.find((m) => m.variant === variant)
    if (!row?.ready) return
    void Haptics.selectionAsync()
    void setPreferredModel(variant).then(() => setPreferredVariant(variant))
  }

  return (
    <SettingsScroll>
      <SectionCard>
        <Text style={styles.sectionLabel} selectable>
          Speech models
        </Text>
        <Text style={styles.subHint} selectable>
          Tap an installed model to use it for in-app dictation and the Action
          Button shortcut.
        </Text>

        {models.map((row) => {
          const label = MODEL_LABELS[row.variant] ?? row.variant
          const active = row.ready && preferredVariant === row.variant
          const progress = downloadProgress[row.variant]
          const isDownloading = progress !== undefined
          const metaLine = isDownloading
            ? `Downloading… ${Math.round(progress * 100)}%`
            : row.ready
              ? `${MODEL_META[row.variant] ?? ''} · ${formatFileSize(row.size)}`
              : `${MODEL_META[row.variant] ?? ''} · Not downloaded`

          return (
            <View key={row.variant} style={styles.modelRow}>
              <Pressable
                onPress={() => selectPreferredForInApp(row.variant)}
                disabled={!row.ready || isDownloading}
                style={[
                  styles.modelSelectHit,
                  row.ready && !isDownloading
                    ? null
                    : styles.modelSelectDisabled,
                  active ? styles.modelSelectActive : null,
                ]}
                accessibilityRole="button"
                accessibilityLabel={`Use ${label} for in-app dictation`}
                accessibilityState={{ selected: active, disabled: !row.ready }}
              >
                <View style={styles.modelInfo}>
                  <Text style={styles.modelTitle} selectable>
                    {label}
                  </Text>
                  <Text style={styles.modelMeta} selectable>
                    {metaLine}
                  </Text>
                </View>
                {isDownloading ? (
                  <View style={styles.progressTrack}>
                    <View
                      style={[
                        styles.progressFill,
                        {
                          width:
                            `${Math.round(progress * 100)}%` as `${number}%`,
                        },
                      ]}
                    />
                  </View>
                ) : null}
              </Pressable>
              <View style={styles.modelCheckWrap}>
                {active ? (
                  <Image
                    source="sf:checkmark.circle.fill"
                    style={styles.modelCheckIcon}
                    contentFit="contain"
                    tintColor={appColors.foreground}
                  />
                ) : null}
              </View>
              {isDownloading ? null : row.ready ? (
                <Pressable
                  onPress={() => confirmDelete(row)}
                  style={styles.deleteHit}
                  accessibilityLabel={`Delete ${label}`}
                  accessibilityRole="button"
                >
                  <Text style={styles.deleteLabel} selectable>
                    Delete
                  </Text>
                </Pressable>
              ) : (
                <Pressable
                  onPress={() => confirmRedownload(row)}
                  style={styles.deleteHit}
                  accessibilityLabel={`Download ${label}`}
                  accessibilityRole="button"
                >
                  <Text style={styles.downloadLabel} selectable>
                    Download
                  </Text>
                </Pressable>
              )}
            </View>
          )
        })}
      </SectionCard>
    </SettingsScroll>
  )
}
