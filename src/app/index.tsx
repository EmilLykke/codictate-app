import { Image } from 'expo-image'
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native'
import { Stack } from 'expo-router'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import Animated from 'react-native-reanimated'
import { ButtonHeaderSettings } from '@/components/Settings/ButtonHeaderSettings'
import { RecordButton } from '@/components/Dictation/RecordButton'
import { TranscriptCard } from '@/components/Dictation/TranscriptCard'
import { appColors, appFontFamily, appFontSize } from '@/constants/AppColors'
import { useRealtimeDictation } from '@/hooks/whisper/use-realtime-dictation'
import { useWhisperCtx } from '@/hooks/whisper/use-whisper-ctx'

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

  const isRecording = dictState === 'recording'
  const isProcessing = dictState === 'processing'

  const handleButtonPress = () => {
    if (isRecording) {
      stop()
    } else if (dictState === 'idle') {
      start()
    }
  }

  const showTranscript = Boolean(transcript) && !isRecording && !isProcessing
  const showNudge = !isRecording && !isProcessing

  return (
    <View
      style={[
        styles.dictationRoot,
        { paddingBottom: Math.max(insets.bottom, 12) },
      ]}
    >
      <View style={styles.resultSlot}>
        <View style={styles.resultSlotInner}>
          {isProcessing ? (
            <View style={styles.resultStateTop}>
              <View style={styles.processingBox}>
                <ActivityIndicator color="rgba(255,255,255,0.7)" />
                <Text style={styles.processingText} selectable>
                  Transcribing on your device…
                </Text>
              </View>
            </View>
          ) : null}

          {isRecording ? (
            <View style={styles.resultStateTop}>
              <View style={styles.livePreview}>
                <Text style={styles.livePreviewText} selectable>
                  Listening… tap the button again to stop.
                </Text>
              </View>
            </View>
          ) : null}

          {showTranscript && transcript ? (
            <TranscriptCard transcript={transcript} onClear={clear} />
          ) : null}

          {!isProcessing && !isRecording && !transcript ? (
            <Text style={styles.resultPlaceholder} selectable>
              Your transcription will appear here.
            </Text>
          ) : null}
        </View>
      </View>

      <View style={styles.errorBand}>
        {dictError ? (
          <View style={styles.errorBadge}>
            <Text style={styles.errorText} selectable>
              {dictError}
            </Text>
          </View>
        ) : null}
      </View>

      <View style={styles.controlsColumn}>
        {showNudge ? (
          <Image
            source="sf:chevron.compact.down"
            style={styles.nudgeChevron}
            contentFit="contain"
            tintColor="rgba(255,255,255,0.28)"
          />
        ) : null}
        <RecordButton dictState={dictState} onPress={handleButtonPress} />
        <Text style={styles.hint}>
          {isRecording
            ? 'Tap to stop'
            : isProcessing
              ? 'Transcribing…'
              : transcript
                ? 'Tap to dictate again'
                : 'Tap to start dictating'}
        </Text>
      </View>
    </View>
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
  },
  resultSlot: {
    flex: 1,
    minHeight: 0,
    width: '100%',
    maxWidth: 368,
    alignSelf: 'center',
  },
  resultSlotInner: {
    flex: 1,
    minHeight: 0,
    width: '100%',
    justifyContent: 'flex-start',
    alignItems: 'stretch',
  },
  resultStateTop: {
    width: '100%',
    paddingTop: 16,
    alignItems: 'center',
  },
  resultPlaceholder: {
    fontFamily: appFontFamily.sans,
    fontSize: 15,
    lineHeight: 22,
    color: appColors.foregroundSubtle,
    textAlign: 'center',
    paddingTop: 16,
    paddingHorizontal: 16,
    width: '100%',
  },
  centeredFill: {
    flex: 1,
    backgroundColor: appColors.page,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 32,
    gap: 16,
  },
  livePreview: {
    width: '100%',
    maxWidth: 340,
    paddingVertical: 14,
    paddingHorizontal: 18,
    borderRadius: 16,
    backgroundColor: 'rgba(255,255,255,0.05)',
    borderCurve: 'continuous',
  },
  livePreviewText: {
    fontFamily: appFontFamily.sans,
    fontSize: appFontSize.body - 3,
    lineHeight: 28,
    color: appColors.foregroundMuted,
    textAlign: 'center',
  },
  processingBox: {
    width: '100%',
    maxWidth: 340,
    paddingVertical: 20,
    paddingHorizontal: 20,
    borderRadius: 16,
    backgroundColor: 'rgba(255,255,255,0.06)',
    borderCurve: 'continuous',
    alignItems: 'center',
    gap: 12,
  },
  processingText: {
    fontFamily: appFontFamily.sans,
    fontSize: 15,
    color: appColors.foregroundMuted,
    textAlign: 'center',
  },
  errorBand: {
    width: '100%',
    maxWidth: 368,
    alignSelf: 'center',
    minHeight: 76,
    justifyContent: 'flex-end',
    paddingBottom: 6,
  },
  controlsColumn: {
    alignItems: 'center',
    gap: 6,
    paddingTop: 0,
  },
  nudgeChevron: {
    width: 20,
    height: 12,
    marginBottom: 2,
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
    maxWidth: 340,
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
