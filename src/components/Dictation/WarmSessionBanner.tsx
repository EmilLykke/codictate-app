import { Image } from 'expo-image'
import { Pressable, StyleSheet, Text, View } from 'react-native'
import Animated, { FadeIn, FadeOut } from 'react-native-reanimated'
import { appColors, appFontFamily } from '@/constants/AppColors'

type Props = {
  onEnd: () => void
}

export function WarmSessionBanner({ onEnd }: Props) {
  return (
    <Animated.View
      entering={FadeIn.duration(200)}
      exiting={FadeOut.duration(200)}
      style={styles.banner}
    >
      <Image
        source="sf:antenna.radiowaves.left.and.right"
        style={styles.icon}
        contentFit="contain"
        tintColor={appColors.foreground}
      />
      <Text style={styles.label}>Keyboard session active</Text>
      <View style={styles.spacer} />
      <Pressable
        onPress={onEnd}
        style={({ pressed }) => [
          styles.endButton,
          pressed ? styles.pressed : null,
        ]}
        accessibilityRole="button"
        accessibilityLabel="End keyboard session"
      >
        <Text style={styles.endLabel}>End</Text>
      </Pressable>
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
  icon: {
    width: 16,
    height: 16,
  },
  label: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    color: appColors.foreground,
  },
  spacer: {
    flex: 1,
  },
  endButton: {
    paddingVertical: 6,
    paddingHorizontal: 14,
    borderRadius: 10,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(255,255,255,0.1)',
  },
  pressed: {
    opacity: 0.7,
  },
  endLabel: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    fontWeight: '600',
    color: appColors.foreground,
  },
})
