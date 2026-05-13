import { useFocusEffect } from '@react-navigation/native'
import * as Haptics from 'expo-haptics'
import { GlassView, isGlassEffectAPIAvailable } from 'expo-glass-effect'
import { Image } from 'expo-image'
import { Link } from 'expo-router'
import type { ReactNode } from 'react'
import { useCallback, useEffect, useState } from 'react'
import {
  Alert,
  Linking,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native'
import {
  labelForTranscriptionLanguageId,
  TRANSCRIPTION_LANGUAGE_HINT,
} from '@/constants/transcription-languages'
import { appColors, appFontFamily, appFontSize } from '@/constants/AppColors'
import { useTranscriptionLanguage } from '@/hooks/settings/transcription-language-context'
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

function SectionCard({ children }: { children: ReactNode }) {
  const useGlass = isGlassEffectAPIAvailable()
  if (useGlass) {
    return (
      <GlassView
        glassEffectStyle="regular"
        isInteractive={false}
        style={styles.cardGlass}
      >
        {children}
      </GlassView>
    )
  }
  return <View style={styles.cardFallback}>{children}</View>
}

const MODEL_LABELS: Record<string, string> = {
  parakeet: 'Parakeet TDT v3',
  base: 'Whisper Base (Q5_1)',
}

const MODEL_TAGLINE: Record<string, string> = {
  parakeet: 'Best quality, Neural Engine (~500 MB)',
  base: 'Fallback, CPU-only (~57 MB)',
}

const MODEL_SIZE_MB: Record<string, string> = {
  parakeet: '500',
  base: '57',
}

const ACTION_BUTTON_SHORTCUT_URL =
  'https://www.icloud.com/shortcuts/376647f0244646a6a181f8ba1fdfe4d1'

/** iOS Settings deep links are not officially supported; try common forms, then fall back. */
const IOS_KEYBOARD_SETTINGS_URLS = [
  'App-Prefs:General&path=Keyboard/KEYBOARDS',
  'App-Prefs:General&path=Keyboard',
  'App-Prefs:General',
] as const

export function ScreenSettings() {
  const { languageId } = useTranscriptionLanguage()
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
      `Remove ${label}${sizeStr} from this device? It will be downloaded again automatically when needed.`,
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

  const confirmRedownload = (row: ModelInfo) => {
    const label = MODEL_LABELS[row.variant] ?? row.variant
    Alert.alert(
      'Download model?',
      `Download ${label} now? This requires Wi-Fi and ~${MODEL_SIZE_MB[row.variant] ?? '?'} MB.`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Download',
          onPress: () => {
            const clearProgress = () =>
              setDownloadProgress((prev) => {
                const next = { ...prev }
                delete next[row.variant]
                return next
              })
            void ensureModel(row.variant)
              .then(async () => {
                clearProgress()
                await Haptics.notificationAsync(
                  Haptics.NotificationFeedbackType.Success
                )
                refreshSpeechModelsUi()
              })
              .catch(clearProgress)
          },
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

  const openActionButtonShortcut = async () => {
    await Haptics.selectionAsync()
    const canOpen = await Linking.canOpenURL(ACTION_BUTTON_SHORTCUT_URL)
    if (!canOpen) {
      Alert.alert(
        'Unable to open Shortcut',
        'Open the Shortcuts app and add the Codictate Dictation shortcut manually.'
      )
      return
    }
    await Linking.openURL(ACTION_BUTTON_SHORTCUT_URL)
  }

  const openIosKeyboardSettings = async () => {
    await Haptics.selectionAsync()
    // canOpenURL always returns false for App-Prefs: without declaring the scheme
    // in LSApplicationQueriesSchemes, so skip the check and try directly.
    for (const url of IOS_KEYBOARD_SETTINGS_URLS) {
      try {
        await Linking.openURL(url)
        return
      } catch {
        /* try next URL */
      }
    }
    try {
      await Linking.openSettings()
    } catch {
      Alert.alert(
        'Unable to open Settings',
        'On your device, open Settings → General → Keyboard → Keyboards, and add Codictate.'
      )
    }
  }

  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.scrollContent}
      showsVerticalScrollIndicator={false}
    >
      {Platform.OS === 'ios' ? (
        <>
          <SectionCard>
            <Text style={styles.sectionLabel} selectable>
              Action Button shortcut
            </Text>
            <Text style={styles.hint} selectable>
              Add the Codictate Dictation shortcut, then assign it to the iPhone
              Action Button. It starts recording on the first press and copies
              the transcript to the clipboard after the second press.
            </Text>
            <Pressable
              onPress={() => void openActionButtonShortcut()}
              style={({ pressed }) => [
                styles.shortcutButton,
                pressed ? styles.rowPressed : null,
              ]}
              accessibilityRole="button"
              accessibilityLabel="Add Codictate Action Button shortcut"
            >
              <Image
                source="sf:square.and.arrow.down"
                style={styles.shortcutIcon}
                contentFit="contain"
                tintColor="#000000"
              />
              <Text style={styles.shortcutButtonText}>
                Add Action Button Shortcut
              </Text>
            </Pressable>
          </SectionCard>

          <SectionCard>
            <Text style={styles.sectionLabel} selectable>
              Dictation keyboard (iOS)
            </Text>
            <Pressable
              onPress={() => void openIosKeyboardSettings()}
              style={({ pressed }) => [
                styles.shortcutButton,
                pressed ? styles.rowPressed : null,
              ]}
              accessibilityRole="button"
              accessibilityLabel="Open Settings to Keyboards"
            >
              <Image
                source="sf:keyboard"
                style={styles.shortcutIcon}
                contentFit="contain"
                tintColor="#000000"
              />
              <Text style={styles.shortcutButtonText}>
                Open Keyboards in Settings
              </Text>
            </Pressable>
          </SectionCard>
        </>
      ) : null}

      <SectionCard>
        <Text style={styles.sectionLabel} selectable>
          Transcription
        </Text>
        <Link href="/settings/language" asChild>
          <Pressable style={styles.row}>
            <View style={styles.rowMain}>
              <Text style={styles.rowTitle} selectable>
                Language
              </Text>
              <Text style={styles.rowValue} selectable>
                {labelForTranscriptionLanguageId(languageId)}
              </Text>
            </View>
            <Image
              source="sf:chevron.right"
              style={styles.chevron}
              contentFit="contain"
              tintColor={appColors.foregroundSubtle}
            />
          </Pressable>
        </Link>
        <Text style={styles.hint} selectable>
          {TRANSCRIPTION_LANGUAGE_HINT}
        </Text>
      </SectionCard>

      <SectionCard>
        <Text style={styles.sectionLabel} selectable>
          Speech models
        </Text>
        <Text style={styles.subHint} selectable>
          Parakeet is the primary model, running on the Neural Engine for best
          quality. Whisper Base is a lightweight CPU fallback. Tap an installed
          row to choose the model for in-app dictation and the Action Button
          shortcut.
        </Text>

        {models.map((row) => {
          const label = MODEL_LABELS[row.variant] ?? row.variant
          const active = row.ready && preferredVariant === row.variant
          const progress = downloadProgress[row.variant]
          const isDownloading = progress !== undefined
          return (
            <View key={row.variant} style={[styles.modelRow]}>
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
                    {isDownloading
                      ? `Downloading… ${Math.round(progress * 100)}%`
                      : `${MODEL_TAGLINE[row.variant] ?? ''}${active ? ' · Active (in-app / Action Button)' : ''}${row.ready ? ` · ${formatFileSize(row.size)}` : ' · Not downloaded'}`}
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
    </ScrollView>
  )
}

const styles = StyleSheet.create({
  scroll: {
    flex: 1,
    backgroundColor: appColors.page,
  },
  scrollContent: {
    paddingHorizontal: 20,
    paddingVertical: 20,
    gap: 20,
    paddingBottom: 40,
  },
  cardGlass: {
    borderRadius: 18,
    borderCurve: 'continuous',
    overflow: 'hidden',
    paddingVertical: 16,
    paddingHorizontal: 18,
    gap: 12,
  },
  cardFallback: {
    borderRadius: 18,
    borderCurve: 'continuous',
    overflow: 'hidden',
    paddingVertical: 16,
    paddingHorizontal: 18,
    gap: 12,
    backgroundColor: 'rgba(255,255,255,0.06)',
    boxShadow: '0 2px 16px rgba(0,0,0,0.35)',
  },
  sectionLabel: {
    fontFamily: appFontFamily.sans,
    fontSize: 12,
    letterSpacing: 1.2,
    textTransform: 'uppercase',
    color: appColors.foregroundSubtle,
  },
  rowPressed: {
    opacity: 0.72,
  },
  shortcutButton: {
    minHeight: 48,
    borderRadius: 16,
    borderCurve: 'continuous',
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 10,
    paddingHorizontal: 16,
    backgroundColor: appColors.foreground,
  },
  shortcutIcon: {
    width: 18,
    height: 18,
  },
  shortcutButtonText: {
    fontFamily: appFontFamily.sans,
    fontSize: 15,
    fontWeight: '700',
    color: '#000000',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingVertical: 4,
  },
  rowMain: {
    flex: 1,
    gap: 4,
  },
  rowTitle: {
    fontFamily: appFontFamily.sans,
    fontSize: appFontSize.body - 5,
    color: appColors.foreground,
  },
  rowValue: {
    fontFamily: appFontFamily.sans,
    fontSize: 15,
    color: appColors.foregroundMuted,
  },
  chevron: {
    width: 14,
    height: 14,
    opacity: 0.85,
  },
  hint: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    lineHeight: 21,
    color: appColors.foregroundMuted,
  },
  subHint: {
    fontFamily: appFontFamily.sans,
    fontSize: 13,
    lineHeight: 19,
    color: appColors.foregroundMuted,
  },
  mono: {
    fontFamily: appFontFamily.sans,
    color: appColors.foreground,
  },
  empty: {
    fontFamily: appFontFamily.sans,
    fontSize: 15,
    color: appColors.foregroundSubtle,
    paddingVertical: 8,
  },
  modelRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingVertical: 2,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: 'rgba(255,255,255,0.12)',
  },
  modelSelectHit: {
    flex: 1,
    minWidth: 0,
    borderRadius: 12,
    paddingVertical: 8,
    paddingHorizontal: 8,
    marginVertical: 2,
  },
  modelSelectDisabled: {
    opacity: 0.62,
  },
  modelSelectActive: {
    backgroundColor: 'rgba(255,255,255,0.08)',
  },
  modelCheckWrap: {
    width: 28,
    alignItems: 'center',
    justifyContent: 'center',
  },
  modelCheckIcon: {
    width: 22,
    height: 22,
  },
  modelInfo: {
    flex: 1,
    gap: 2,
  },
  modelTitle: {
    fontFamily: appFontFamily.sans,
    fontSize: 16,
    color: appColors.foreground,
  },
  modelMeta: {
    fontFamily: appFontFamily.sans,
    fontSize: 13,
    color: appColors.foregroundMuted,
  },
  deleteHit: {
    paddingVertical: 8,
    paddingHorizontal: 12,
  },
  deleteLabel: {
    fontFamily: appFontFamily.sans,
    fontSize: 15,
    fontWeight: '600',
    color: '#F87171',
  },
  downloadLabel: {
    fontFamily: appFontFamily.sans,
    fontSize: 15,
    fontWeight: '600',
    color: appColors.foreground,
  },
  progressTrack: {
    height: 3,
    borderRadius: 2,
    backgroundColor: 'rgba(255,255,255,0.12)',
    overflow: 'hidden',
    marginTop: 6,
  },
  progressFill: {
    height: 3,
    borderRadius: 2,
    backgroundColor: appColors.foreground,
  },
})
