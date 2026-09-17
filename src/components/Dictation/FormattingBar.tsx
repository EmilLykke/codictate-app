import { GlassView, isGlassEffectAPIAvailable } from 'expo-glass-effect'
import { Image } from 'expo-image'
import { useState } from 'react'
import { Pressable, StyleSheet, Text, View } from 'react-native'
import type { ReactNode } from 'react'
import { FormattingSheet } from '@/components/Dictation/FormattingSheet'
import { appColors, appFontFamily } from '@/constants/AppColors'
import type { useFormattingSettings } from '@/hooks/settings/use-formatting-settings'

type Props = {
  settings: ReturnType<typeof useFormattingSettings>
}

/**
 * Home-screen entry point to Formatting: the row names the feature and its
 * current setting, and the sheet behind it also downloads the model — nothing
 * about formatting is reachable only from Settings.
 */
export function FormattingBar({ settings }: Props) {
  const [visible, setVisible] = useState(false)
  const isOff = settings.model === 'off'
  // Style and Context names mean nothing from the home screen; the row only
  // reports whether formatting will run. The sheet explains the rest.
  const value = isOff ? 'Off' : 'On'

  return (
    <>
      <Pressable
        onPress={() => setVisible(true)}
        style={({ pressed }) => [styles.pressable, pressed && styles.pressed]}
        accessibilityRole="button"
        accessibilityLabel={`Formatting: ${value}. Opens formatting options.`}
      >
        <BarShell>
          <Image
            source="sf:wand.and.stars"
            style={styles.icon}
            contentFit="contain"
            tintColor={appColors.foreground}
          />
          <Text style={styles.title} numberOfLines={1}>
            Formatting
          </Text>
          <Text style={styles.value} numberOfLines={1}>
            {value}
          </Text>
          <Image
            source="sf:chevron.right"
            style={styles.chevron}
            contentFit="contain"
            tintColor={appColors.foregroundSubtle}
          />
        </BarShell>
      </Pressable>

      <FormattingSheet
        visible={visible}
        onClose={() => setVisible(false)}
        settings={settings}
      />
    </>
  )
}

function BarShell({ children }: { children: ReactNode }) {
  if (isGlassEffectAPIAvailable()) {
    return (
      <GlassView
        glassEffectStyle="regular"
        isInteractive={false}
        style={styles.barGlass}
      >
        {children}
      </GlassView>
    )
  }
  return <View style={styles.barFallback}>{children}</View>
}

const shell = {
  flexDirection: 'row',
  alignItems: 'center',
  gap: 8,
  minHeight: 44,
  paddingHorizontal: 14,
  borderRadius: 16,
  borderCurve: 'continuous',
} as const

const styles = StyleSheet.create({
  pressable: {
    width: '100%',
    maxWidth: 368,
    alignSelf: 'center',
    marginTop: 10,
  },
  pressed: {
    opacity: 0.72,
  },
  barGlass: shell,
  barFallback: {
    ...shell,
    backgroundColor: 'rgba(255,255,255,0.08)',
  },
  icon: {
    width: 16,
    height: 16,
  },
  title: {
    flex: 1,
    fontFamily: appFontFamily.sans,
    fontSize: 15,
    color: appColors.foreground,
  },
  value: {
    flexShrink: 1,
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    color: appColors.foregroundMuted,
  },
  chevron: {
    width: 12,
    height: 12,
  },
})
