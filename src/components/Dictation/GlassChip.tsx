import { GlassView, isGlassEffectAPIAvailable } from 'expo-glass-effect'
import { Image } from 'expo-image'
import { Pressable, StyleSheet, Text, View } from 'react-native'
import type { ReactNode } from 'react'
import { appColors, appFontFamily } from '@/constants/AppColors'

type GlassChipProps = {
  onPress: () => void
  icon: string
  label: string
  accessibilityLabel: string
}

/** One control in the home-screen chip row: Speech Model, Formatting, Language. */
export function GlassChip({
  onPress,
  icon,
  label,
  accessibilityLabel,
}: GlassChipProps) {
  const content = (
    <>
      <Image
        source={icon}
        style={chipStyles.icon}
        contentFit="contain"
        tintColor={appColors.foreground}
      />
      <Text style={chipStyles.label} numberOfLines={1}>
        {label}
      </Text>
      <Image
        source="sf:chevron.up.chevron.down"
        style={chipStyles.chevron}
        contentFit="contain"
        tintColor={appColors.foregroundSubtle}
      />
    </>
  )

  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [
        chipStyles.pressable,
        pressed && chipStyles.pressed,
      ]}
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
        style={chipStyles.chipGlass}
      >
        {children}
      </GlassView>
    )
  }
  return <View style={chipStyles.chipFallback}>{children}</View>
}

const shell = {
  flexDirection: 'row',
  alignItems: 'center',
  justifyContent: 'center',
  gap: 6,
  height: 38,
  paddingHorizontal: 14,
  borderRadius: 22,
  borderCurve: 'continuous',
} as const

export const chipStyles = StyleSheet.create({
  chipGlass: shell,
  chipFallback: {
    ...shell,
    backgroundColor: 'rgba(255,255,255,0.1)',
  },
  pressable: {
    flex: 1,
    minWidth: 0,
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
    flexShrink: 1,
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    color: appColors.foreground,
  },
})
