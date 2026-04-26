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
import { ACTIVE_WHISPER_MODEL } from '@/constants/whisper-models'
import { appColors, appFontFamily, appFontSize } from '@/constants/AppColors'
import { useTranscriptionLanguage } from '@/hooks/settings/transcription-language-context'
import {
  useWhisperCtx,
  useWhisperModelActions,
} from '@/hooks/whisper/use-whisper-ctx'
import {
  deleteWhisperModelFile,
  listWhisperModelsOnDisk,
  type WhisperDiskModelRow,
} from '@/modules/whisper/whisper-disk-models'
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

export function ScreenSettings() {
  const { languageId } = useTranscriptionLanguage()
  const whisper = useWhisperCtx()
  const { purgeActiveModelAndReload } = useWhisperModelActions()
  const [models, setModels] = useState<WhisperDiskModelRow[]>([])

  const refreshModels = useCallback(() => {
    setModels(listWhisperModelsOnDisk())
  }, [])

  useFocusEffect(
    useCallback(() => {
      refreshModels()
    }, [refreshModels])
  )

  const modelReady = whisper.status === 'ready'

  const confirmDeleteInactive = (row: WhisperDiskModelRow) => {
    Alert.alert(
      'Delete model file?',
      `Remove ${row.label} (${formatFileSize(row.size)}) from this device? You can download it again later if needed.`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete',
          style: 'destructive',
          onPress: () => {
            deleteWhisperModelFile(row.filename)
            void Haptics.notificationAsync(
              Haptics.NotificationFeedbackType.Success
            )
            refreshModels()
          },
        },
      ]
    )
  }

  const confirmDeleteActive = (row: WhisperDiskModelRow) => {
    Alert.alert(
      'Remove active model?',
      `${row.label} is the model used for dictation. It will be downloaded again the next time you open the app (about ${formatFileSize(row.size)}).`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Remove & re-download',
          style: 'destructive',
          onPress: () => {
            void purgeActiveModelAndReload()
            void Haptics.notificationAsync(
              Haptics.NotificationFeedbackType.Success
            )
            refreshModels()
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
          Downloaded models
        </Text>
        <Text style={styles.subHint} selectable>
          Files in app storage matching{' '}
          <Text style={styles.mono}>ggml-*.bin</Text>. The active model is{' '}
          <Text style={styles.mono}>{ACTIVE_WHISPER_MODEL.filename}</Text>.
        </Text>

        {models.length === 0 ? (
          <Text style={styles.empty} selectable>
            No extra model files found.
          </Text>
        ) : (
          models.map((row) => (
            <View key={row.filename} style={styles.modelRow}>
              <View style={styles.modelInfo}>
                <Text style={styles.modelTitle} selectable>
                  {row.label}
                </Text>
                <Text style={styles.modelMeta} selectable>
                  {formatFileSize(row.size)}
                  {row.isActive ? ' · In use' : ''}
                </Text>
              </View>
              <Pressable
                onPress={() =>
                  row.isActive
                    ? modelReady
                      ? confirmDeleteActive(row)
                      : Alert.alert(
                          'Please wait',
                          'Wait until the speech model finishes loading before removing it.'
                        )
                    : confirmDeleteInactive(row)
                }
                style={styles.deleteHit}
                accessibilityLabel={`Delete ${row.label}`}
                accessibilityRole="button"
              >
                <Text
                  style={[
                    styles.deleteLabel,
                    row.isActive && !modelReady && styles.deleteDisabled,
                  ]}
                  selectable
                >
                  Delete
                </Text>
              </Pressable>
            </View>
          ))
        )}
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
  deleteDisabled: {
    color: appColors.foregroundSubtle,
  },
})
