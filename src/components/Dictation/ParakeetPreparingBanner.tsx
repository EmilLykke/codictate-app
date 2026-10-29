import { ActivityIndicator, StyleSheet, Text } from 'react-native'
import Animated, { FadeIn, FadeOut } from 'react-native-reanimated'
import { appColors, appFontFamily } from '@/constants/AppColors'

/** Shown while the Host prepares Parakeet after an app update. */
export function ParakeetPreparingBanner() {
  return (
    <Animated.View
      entering={FadeIn.duration(200)}
      exiting={FadeOut.duration(200)}
      style={styles.banner}
      accessibilityRole="text"
    >
      <ActivityIndicator size="small" color={appColors.foregroundMuted} />
      <Text style={styles.label}>Preparing Parakeet</Text>
    </Animated.View>
  )
}

const styles = StyleSheet.create({
  banner: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingVertical: 10,
    paddingHorizontal: 14,
    borderRadius: 14,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(255,255,255,0.06)',
    marginBottom: 12,
    maxWidth: 368,
    alignSelf: 'center',
    width: '100%',
  },
  label: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    color: appColors.foreground,
  },
})
