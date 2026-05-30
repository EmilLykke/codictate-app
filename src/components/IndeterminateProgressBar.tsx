import { useEffect } from 'react'
import Animated, {
  useAnimatedStyle,
  useSharedValue,
  withRepeat,
  withTiming,
  Easing,
} from 'react-native-reanimated'
import { StyleSheet, View } from 'react-native'

type Props = {
  trackColor?: string
  fillColor?: string
}

export function IndeterminateProgressBar({
  trackColor = 'rgba(255,255,255,0.1)',
  fillColor = 'rgba(255,255,255,0.7)',
}: Props) {
  const translateX = useSharedValue(-1)

  useEffect(() => {
    translateX.value = withRepeat(
      withTiming(1, { duration: 1200, easing: Easing.inOut(Easing.ease) }),
      -1,
      true
    )
  }, [translateX])

  const animatedStyle = useAnimatedStyle(() => ({
    transform: [{ translateX: translateX.value * 120 }],
  }))

  return (
    <View style={[styles.track, { backgroundColor: trackColor }]}>
      <Animated.View
        style={[styles.fill, { backgroundColor: fillColor }, animatedStyle]}
      />
    </View>
  )
}

const styles = StyleSheet.create({
  track: {
    width: '100%',
    height: 3,
    borderRadius: 2,
    overflow: 'hidden',
  },
  fill: {
    width: 80,
    height: '100%',
    borderRadius: 2,
  },
})
