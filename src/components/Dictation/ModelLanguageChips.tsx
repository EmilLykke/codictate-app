import { GlassView, isGlassEffectAPIAvailable } from 'expo-glass-effect'
import { Image } from 'expo-image'
import { Pressable, StyleSheet, Text, View } from 'react-native'
import { appColors, appFontFamily } from '@/constants/AppColors'
import { MODEL_LABELS } from '@/components/Settings/settings-shared'
import { labelForTranscriptionLanguageId } from '@/constants/transcription-languages'
import { useTranscriptionLanguage } from '@/hooks/settings/transcription-language-context'
import type { ModelVariant } from 'codictate-dictation'
import type { ReactNode } from 'react'

type Props = {
  modelVariant: ModelVariant
  onModelPress: () => void
  onLanguagePress: () => void
}

export function ModelLanguageChips({
  modelVariant,
  onModelPress,
  onLanguagePress,
}: Props) {
  const { languageId } = useTranscriptionLanguage()
  const modelLabel = MODEL_LABELS[modelVariant] ?? modelVariant
  const languageLabel = labelForTranscriptionLanguageId(languageId)

  return (
    <View style={styles.row}>
      <GlassChip
        onPress={onModelPress}
        icon="sf:cpu"
        label={modelLabel}
        accessibilityLabel={`Model: ${modelLabel}`}
      />
      <GlassChip
        onPress={onLanguagePress}
        icon="sf:globe"
        label={languageLabel}
        accessibilityLabel={`Language: ${languageLabel}`}
      />
    </View>
  )
}

function GlassChip({
  onPress,
  icon,
  label,
  accessibilityLabel,
}: {
  onPress: () => void
  icon: string
  label: string
  accessibilityLabel: string
}) {
  const content = (
    <>
      <Image
        source={icon}
        style={styles.icon}
        contentFit="contain"
        tintColor={appColors.foreground}
      />
      <Text style={styles.label} numberOfLines={1}>
        {label}
      </Text>
      <Image
        source="sf:chevron.up.chevron.down"
        style={styles.chevron}
        contentFit="contain"
        tintColor={appColors.foregroundSubtle}
      />
    </>
  )

  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [styles.pressable, pressed && styles.pressed]}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
    >
      <ChipShell>{content}</ChipShell>
    </Pressable>
  )
}

function ChipShell({ children }: { children: ReactNode }) {
  if (isGlassEffectAPIAvailable()) {
    return (
      <GlassView
        glassEffectStyle="regular"
        isInteractive={false}
        style={styles.chipGlass}
      >
        {children}
      </GlassView>
    )
  }
  return <View style={styles.chipFallback}>{children}</View>
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    gap: 8,
    paddingBottom: 8,
    maxWidth: 368,
    alignSelf: 'center',
    width: '100%',
  },
  chipGlass: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    height: 38,
    paddingHorizontal: 14,
    borderRadius: 22,
    borderCurve: 'continuous',
  },
  chipFallback: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    height: 38,
    paddingHorizontal: 14,
    borderRadius: 22,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(255,255,255,0.1)',
  },
  pressable: {
    flex: 1,
  },
  pressed: {
    transform: [{ scale: 0.96 }],
  },
  icon: {
    width: 15,
    height: 15,
  },
  chevron: {
    width: 10,
    height: 10,
    marginLeft: 2,
  },
  label: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    color: appColors.foreground,
    maxWidth: 140,
  },
})
