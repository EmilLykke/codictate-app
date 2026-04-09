import * as Haptics from 'expo-haptics'
import { Image } from 'expo-image'
import { ActivityIndicator, Pressable, StyleSheet } from 'react-native'
import Animated, { FadeIn, FadeOut } from 'react-native-reanimated'
import type { DictationState } from '@/hooks/whisper/use-realtime-dictation'

type RecordButtonProps = {
  dictState: DictationState
  onPress: () => void
}

const BUTTON_SIZE = 80
const RING_SIZE = BUTTON_SIZE

const pulseOut = {
  from: { transform: [{ scale: 1 }], opacity: 0.55 },
  to: { transform: [{ scale: 2.4 }], opacity: 0 },
}

const PULSE_DELAYS = [0, 550, 1100]

export function RecordButton({ dictState, onPress }: RecordButtonProps) {
  const isRecording = dictState === 'recording'
  const isProcessing = dictState === 'processing'

  const handlePress = async () => {
    await Haptics.impactAsync(
      isRecording
        ? Haptics.ImpactFeedbackStyle.Light
        : Haptics.ImpactFeedbackStyle.Medium
    )
    onPress()
  }

  return (
    <Pressable
      onPress={handlePress}
      disabled={isProcessing}
      style={styles.hitArea}
      accessibilityLabel={isRecording ? 'Stop recording' : 'Start recording'}
      accessibilityRole="button"
    >
      {/* Expanding pulse rings — mounted only while recording */}
      {isRecording &&
        PULSE_DELAYS.map((delay) => (
          <Animated.View
            key={delay}
            entering={FadeIn.duration(400)}
            exiting={FadeOut.duration(300)}
            style={[
              styles.pulseRing,
              {
                animationName: pulseOut,
                animationDuration: '2000ms',
                animationDelay: `${delay}ms`,
                animationTimingFunction: 'ease-out',
                animationIterationCount: 'infinite',
              },
            ]}
          />
        ))}

      {/* Main button circle */}
      <Animated.View
        style={[
          styles.button,
          {
            backgroundColor: isRecording
              ? '#DC2626'
              : isProcessing
                ? 'rgba(255,255,255,0.06)'
                : 'rgba(255,255,255,0.12)',
            transitionProperty: ['backgroundColor'],
            transitionDuration: 220,
            transitionTimingFunction: 'ease-in-out',
          },
        ]}
      >
        {isProcessing ? (
          <ActivityIndicator color="rgba(255,255,255,0.6)" size="small" />
        ) : (
          <Image
            source={isRecording ? 'sf:stop.fill' : 'sf:microphone.fill'}
            style={styles.icon}
            contentFit="contain"
            tintColor={isRecording ? '#fff' : 'rgba(255,255,255,0.85)'}
          />
        )}
      </Animated.View>
    </Pressable>
  )
}

const styles = StyleSheet.create({
  hitArea: {
    width: 120,
    height: 120,
    alignItems: 'center',
    justifyContent: 'center',
  },
  pulseRing: {
    position: 'absolute',
    width: RING_SIZE,
    height: RING_SIZE,
    borderRadius: RING_SIZE / 2,
    borderWidth: 1.5,
    borderColor: '#DC2626',
  },
  button: {
    width: BUTTON_SIZE,
    height: BUTTON_SIZE,
    borderRadius: BUTTON_SIZE / 2,
    alignItems: 'center',
    justifyContent: 'center',
    borderCurve: 'continuous',
  },
  icon: {
    width: 28,
    height: 28,
  },
})
