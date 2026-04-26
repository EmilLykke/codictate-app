import { Image } from 'expo-image'
import * as Clipboard from 'expo-clipboard'
import * as Haptics from 'expo-haptics'
import {
  Alert,
  KeyboardAvoidingView,
  Pressable,
  Share,
  StyleSheet,
  Text,
  View,
} from 'react-native'
import { Stack } from 'expo-router'
import { useEffect, useRef, useState } from 'react'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import Animated from 'react-native-reanimated'
import {
  CardDictationComposer,
  type TextSelection,
} from '@/components/Dictation/CardDictationComposer'
import { ButtonHeaderSettings } from '@/components/Settings/ButtonHeaderSettings'
import { RecordButton } from '@/components/Dictation/RecordButton'
import { appColors, appFontFamily, appFontSize } from '@/constants/AppColors'
import { useRealtimeDictation } from '@/hooks/whisper/use-realtime-dictation'
import { useWhisperCtx } from '@/hooks/whisper/use-whisper-ctx'
import type { LiveActivity } from 'expo-widgets'
import DictationLiveActivity, {
  type DictationActivityProps,
} from '@/widgets/DictationLiveActivity'

export default function Index() {
  const whisper = useWhisperCtx()

  return (
    <>
      <Stack.Screen
        options={{
          headerShown: true,
          title: 'Codictate',
          headerLargeTitle: false,
          headerTitleStyle: {
            fontFamily: appFontFamily.brand,
            fontSize: process.env.EXPO_OS === 'ios' ? 20 : 24,
          },
          headerRight: () => <ButtonHeaderSettings />,
        }}
      />
      {whisper.status === 'downloading' || whisper.status === 'initializing' ? (
        <SetupScreen whisper={whisper} />
      ) : whisper.status === 'error' ? (
        <ErrorScreen error={whisper.error} onRetry={whisper.retry} />
      ) : (
        <DictationScreen />
      )}
    </>
  )
}

function DictationScreen() {
  const insets = useSafeAreaInsets()
  const { dictState, transcript, dictError, start, stop, clear } =
    useRealtimeDictation()
  const [draft, setDraft] = useState('')
  const [selection, setSelection] = useState<TextSelection>({
    start: 0,
    end: 0,
  })

  const isRecording = dictState === 'recording'
  const isProcessing = dictState === 'processing'

  const activityRef = useRef<LiveActivity<DictationActivityProps> | null>(null)

  useEffect(() => {
    if (process.env.EXPO_OS !== 'ios') return
    if (dictState === 'recording') {
      try {
        activityRef.current = DictationLiveActivity.start({ status: 'recording' })
      } catch {
        activityRef.current = null
      }
    } else if (dictState === 'processing') {
      void activityRef.current?.update({ status: 'processing' }).catch(() => {})
    } else if (dictState === 'idle' && activityRef.current) {
      void activityRef.current.end('default').catch(() => {})
      activityRef.current = null
    }
  }, [dictState])

  const handleButtonPress = () => {
    if (isRecording) {
      stop()
    } else if (dictState === 'idle') {
      start()
    }
  }

  useEffect(() => {
    if (!transcript) return
    const next = insertTextIntoDraft(draft, transcript, selection)
    setDraft(next.text)
    setSelection(next.selection)
    clear()
  }, [clear, draft, selection, transcript])

  const handleCopyDraft = async () => {
    if (!draft.trim()) {
      Alert.alert('Nothing to copy', 'Dictate or type something first.')
      return
    }
    await Clipboard.setStringAsync(draft)
    await Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
  }

  const handleShareDraft = async () => {
    if (!draft.trim()) {
      Alert.alert('Nothing to share', 'Dictate or type something first.')
      return
    }
    await Share.share({ message: draft })
  }

  const handleClearDraft = async () => {
    setDraft('')
    setSelection({ start: 0, end: 0 })
    await Haptics.selectionAsync()
  }

  return (
    <KeyboardAvoidingView
      style={[
        styles.dictationRoot,
        { paddingBottom: Math.max(insets.bottom, 12) },
      ]}
      behavior={process.env.EXPO_OS === 'ios' ? 'padding' : undefined}
    >
      <View style={styles.resultSlot}>
        <CardDictationComposer
          value={draft}
          selection={selection}
          onChangeText={setDraft}
          onSelectionChange={(event) =>
            setSelection(event.nativeEvent.selection)
          }
          onCopyPress={() => void handleCopyDraft()}
          onSharePress={() => void handleShareDraft()}
          onClearPress={() => void handleClearDraft()}
        />
      </View>

      {dictError ? (
        <View style={styles.errorBadge}>
          <Text style={styles.errorText} selectable>
            {dictError}
          </Text>
        </View>
      ) : null}

      <View style={styles.controlsColumn}>
        <RecordButton dictState={dictState} onPress={handleButtonPress} />
        <Text style={styles.hint}>
          {isRecording
            ? 'Tap to stop'
            : isProcessing
              ? 'Transcribing…'
              : 'Tap to dictate'}
        </Text>
      </View>
    </KeyboardAvoidingView>
  )
}

type SetupScreenProps =
  | { status: 'downloading'; progress: number }
  | { status: 'initializing' }

function SetupScreen(props: { whisper: SetupScreenProps }) {
  const { whisper } = props
  const isDownloading = whisper.status === 'downloading'
  const progress = isDownloading ? whisper.progress : 1
  const pct = Math.round(progress * 100)

  return (
    <View style={styles.centeredFill}>
      <View style={styles.setupContent}>
        <Text style={styles.setupTitle}>
          {isDownloading ? 'Downloading speech model' : 'Loading model…'}
        </Text>

        <View style={styles.progressTrack}>
          <Animated.View
            style={[
              styles.progressFill,
              {
                width: `${pct}%` as `${number}%`,
                transitionProperty: ['width'],
                transitionDuration: 300,
                transitionTimingFunction: 'ease-out',
              },
            ]}
          />
        </View>

        <Text style={styles.setupSubtitle}>
          {isDownloading
            ? `${pct}% · ~57 MB · one-time download`
            : 'Almost ready…'}
        </Text>
      </View>
    </View>
  )
}

function ErrorScreen({
  error,
  onRetry,
}: {
  error: Error
  onRetry: () => void
}) {
  return (
    <View style={styles.centeredFill}>
      <Image
        source="sf:exclamationmark.triangle"
        style={styles.errorIcon}
        contentFit="contain"
        tintColor="rgba(255,255,255,0.4)"
      />
      <Text style={styles.errorTitle} selectable>
        Failed to load model
      </Text>
      <Text style={styles.errorBody} selectable>
        {error.message}
      </Text>
      <Pressable onPress={onRetry} style={styles.retryButton}>
        <Text style={styles.retryLabel}>Try again</Text>
      </Pressable>
    </View>
  )
}

const styles = StyleSheet.create({
  dictationRoot: {
    flex: 1,
    backgroundColor: appColors.page,
    paddingHorizontal: 24,
    paddingTop: 8,
    gap: 12,
  },
  resultSlot: {
    flex: 1,
    minHeight: 0,
    width: '100%',
    maxWidth: 368,
    alignSelf: 'center',
  },
  centeredFill: {
    flex: 1,
    backgroundColor: appColors.page,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 32,
    gap: 16,
  },
  controlsColumn: {
    alignItems: 'center',
    gap: 6,
  },
  hint: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    color: appColors.foregroundSubtle,
    letterSpacing: 0.2,
    textAlign: 'center',
    paddingHorizontal: 16,
  },
  errorBadge: {
    paddingVertical: 10,
    paddingHorizontal: 16,
    borderRadius: 12,
    backgroundColor: 'rgba(220,38,38,0.15)',
    maxWidth: 368,
    alignSelf: 'center',
  },
  errorText: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    color: '#FCA5A5',
    textAlign: 'center',
    lineHeight: 22,
  },
  // Setup screen
  setupContent: {
    alignItems: 'center',
    gap: 12,
    width: '100%',
    maxWidth: 300,
  },
  setupTitle: {
    fontFamily: appFontFamily.sans,
    fontSize: appFontSize.body - 2,
    color: appColors.foreground,
    letterSpacing: 0.2,
  },
  progressTrack: {
    width: '100%',
    height: 3,
    borderRadius: 2,
    backgroundColor: 'rgba(255,255,255,0.1)',
    overflow: 'hidden',
  },
  progressFill: {
    height: '100%',
    borderRadius: 2,
    backgroundColor: 'rgba(255,255,255,0.7)',
  },
  setupSubtitle: {
    fontFamily: appFontFamily.sans,
    fontSize: 13,
    color: appColors.foregroundSubtle,
    letterSpacing: 0.1,
  },
  // Error screen
  errorIcon: {
    width: 40,
    height: 40,
    marginBottom: 4,
  },
  errorTitle: {
    fontFamily: appFontFamily.sans,
    fontSize: appFontSize.body - 2,
    color: appColors.foreground,
  },
  errorBody: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    color: appColors.foregroundMuted,
    textAlign: 'center',
    lineHeight: 22,
  },
  retryButton: {
    marginTop: 8,
    paddingVertical: 12,
    paddingHorizontal: 28,
    borderRadius: 50,
    backgroundColor: 'rgba(255,255,255,0.1)',
    borderCurve: 'continuous',
  },
  retryLabel: {
    fontFamily: appFontFamily.sans,
    fontSize: 16,
    color: appColors.foreground,
  },
})

function insertTextIntoDraft(
  draft: string,
  insertedText: string,
  selection: TextSelection
): { text: string; selection: TextSelection } {
  const before = draft.slice(0, selection.start)
  const after = draft.slice(selection.end)
  const leadingSpacer =
    before.length > 0 && !/[\s([{'"-]$/.test(before) ? ' ' : ''
  const trailingSpacer =
    after.length > 0 && !/^[\s,.;:!?)}\]'"-]/.test(after) ? ' ' : ''
  const merged = `${before}${leadingSpacer}${insertedText}${trailingSpacer}${after}`
  const cursor = before.length + leadingSpacer.length + insertedText.length

  return {
    text: merged,
    selection: { start: cursor, end: cursor },
  }
}
