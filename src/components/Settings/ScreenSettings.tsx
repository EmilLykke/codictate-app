import { useFocusEffect } from '@react-navigation/native'
import * as Haptics from 'expo-haptics'
import { GlassView, isGlassEffectAPIAvailable } from 'expo-glass-effect'
import { Image } from 'expo-image'
import { Link } from 'expo-router'
import type { ReactNode } from 'react'
import { useCallback, useState } from 'react'
import {
  Alert,
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
  listModels,
  type ModelInfo,
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
  base: 'Base (Q5_1)',
  tiny: 'Tiny (Q5_1)',
}

const MODEL_USE: Record<string, string> = {
  base: 'In-app dictation',
  tiny: 'Keyboard extension',
}

export function ScreenSettings() {
  const { languageId } = useTranscriptionLanguage()
  const [models, setModels] = useState<ModelInfo[]>([])

  const refreshModels = useCallback(() => {
    void listModels().then(setModels)
  }, [])

  useFocusEffect(
    useCallback(() => {
      refreshModels()
    }, [refreshModels])
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
            void deleteModel(row.variant).then(() => {
              void Haptics.notificationAsync(
                Haptics.NotificationFeedbackType.Success
              )
              refreshModels()
            })
          },
        },
      ]
    )
  }

  const confirmRedownload = (row: ModelInfo) => {
    const label = MODEL_LABELS[row.variant] ?? row.variant
    Alert.alert(
      'Download model?',
      `Download ${label} now? This requires Wi-Fi and ~${row.variant === 'base' ? '143' : '57'} MB.`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Download',
          onPress: () => {
            void ensureModel(row.variant).then(() => {
              void Haptics.notificationAsync(
                Haptics.NotificationFeedbackType.Success
              )
              refreshModels()
            })
          },
        },
      ]
    )
  }

  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.scrollContent}
      showsVerticalScrollIndicator={false}
    >
      {Platform.OS === 'ios' ? (
        <SectionCard>
          <Text style={styles.sectionLabel} selectable>
            Dictation keyboard (iOS)
          </Text>
          <Text style={styles.hint} selectable>
            Add <Text style={styles.stepsEm}>Codictate</Text> under Settings ›
            General › Keyboard › Keyboards. It includes a normal QWERTY row for
            typing. The microphone cannot run inside the extension: dictation
            opens the main app to record, then transcribes on the device while
            you switch back (background audio keeps the session alive).
          </Text>
          <Text style={styles.stepsList} selectable>
            1. Enable the keyboard and{' '}
            <Text style={styles.stepsEm}>Allow Full Access</Text>
            {'\n'}
            2. First tap: opens Codictate to start recording — return to your
            app
            {'\n'}
            3. Second tap: stop; text is inserted into the field (also copied to
            the clipboard). The small (Tiny) model in shared storage must be
            present — open Codictate on Wi‑Fi once if the keyboard asks to
            download it
            {'\n'}
            4. You can still dictate inside Codictate and use{' '}
            <Text style={styles.stepsEm}>Copy</Text> /{' '}
            <Text style={styles.stepsEm}>Share</Text> as before
          </Text>
        </SectionCard>
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
          Stored in the shared App Group container so both the main app and
          keyboard extension can access them.
        </Text>

        {models.map((row) => (
          <View key={row.variant} style={styles.modelRow}>
            <View style={styles.modelInfo}>
              <Text style={styles.modelTitle} selectable>
                {MODEL_LABELS[row.variant] ?? row.variant}
              </Text>
              <Text style={styles.modelMeta} selectable>
                {MODEL_USE[row.variant] ?? ''}
                {row.ready
                  ? ` · ${formatFileSize(row.size)}`
                  : ' · Not downloaded'}
              </Text>
            </View>
            {row.ready ? (
              <Pressable
                onPress={() => confirmDelete(row)}
                style={styles.deleteHit}
                accessibilityLabel={`Delete ${MODEL_LABELS[row.variant] ?? row.variant}`}
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
                accessibilityLabel={`Download ${MODEL_LABELS[row.variant] ?? row.variant}`}
                accessibilityRole="button"
              >
                <Text style={styles.downloadLabel} selectable>
                  Download
                </Text>
              </Pressable>
            )}
          </View>
        ))}
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
  keyboardSetupRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingVertical: 10,
    marginTop: 4,
  },
  rowPressed: {
    opacity: 0.72,
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
  stepsList: {
    fontFamily: appFontFamily.sans,
    fontSize: 13,
    lineHeight: 20,
    color: appColors.foregroundMuted,
    marginTop: 4,
  },
  stepsEm: {
    fontFamily: appFontFamily.sans,
    fontWeight: '600',
    color: appColors.foreground,
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
    gap: 12,
    paddingVertical: 10,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: 'rgba(255,255,255,0.12)',
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
})
