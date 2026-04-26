import { HStack, Image, Text, VStack } from '@expo/ui/swift-ui'
import { font, foregroundStyle, padding } from '@expo/ui/swift-ui/modifiers'
import { createLiveActivity, type LiveActivityComponent } from 'expo-widgets'

type LiveActivityEnvironment = Parameters<LiveActivityComponent>[1]

export type DictationActivityProps = {
  status: 'recording' | 'processing'
}

const DictationActivity = (
  props: DictationActivityProps,
  environment: LiveActivityEnvironment
) => {
  'widget'
  const isRecording = props.status === 'recording'
  const accentColor = environment.colorScheme === 'dark' ? '#FFFFFF' : '#007AFF'
  const subtleColor =
    environment.colorScheme === 'dark'
      ? 'rgba(255,255,255,0.5)'
      : 'rgba(0,0,0,0.4)'

  const statusLabel = isRecording ? 'Recording…' : 'Transcribing…'
  const iconName = isRecording ? 'mic.fill' : 'waveform'

  return {
    banner: (
      <HStack modifiers={[padding({ all: 14 })]}>
        <Image systemName={iconName} color={accentColor} />
        <VStack>
          <Text
            modifiers={[
              font({ weight: 'bold', size: 15 }),
              foregroundStyle(accentColor),
            ]}
          >
            {statusLabel}
          </Text>
          <Text modifiers={[font({ size: 12 }), foregroundStyle(subtleColor)]}>
            Codictate
          </Text>
        </VStack>
      </HStack>
    ),
    compactLeading: <Image systemName={iconName} color={accentColor} />,
    compactTrailing: (
      <Text
        modifiers={[
          font({ size: 12, weight: 'semibold' }),
          foregroundStyle(accentColor),
        ]}
      >
        {isRecording ? 'REC' : '…'}
      </Text>
    ),
    minimal: <Image systemName="mic.fill" color={accentColor} />,
    expandedLeading: (
      <VStack modifiers={[padding({ all: 12 })]}>
        <Image systemName={iconName} color={accentColor} />
        <Text modifiers={[font({ size: 11 }), foregroundStyle(subtleColor)]}>
          {isRecording ? 'Mic' : 'AI'}
        </Text>
      </VStack>
    ),
    expandedTrailing: (
      <VStack modifiers={[padding({ all: 12 })]}>
        <Text
          modifiers={[
            font({ weight: 'bold', size: 16 }),
            foregroundStyle(accentColor),
          ]}
        >
          {isRecording ? 'Recording' : 'Transcribing'}
        </Text>
        <Text modifiers={[font({ size: 12 }), foregroundStyle(subtleColor)]}>
          Codictate
        </Text>
      </VStack>
    ),
  }
}

export default createLiveActivity('DictationActivity', DictationActivity)
