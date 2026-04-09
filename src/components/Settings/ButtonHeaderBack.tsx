import * as Haptics from 'expo-haptics'
import { Image } from 'expo-image'
import { useRouter } from 'expo-router'
import { Pressable, StyleSheet } from 'react-native'
import { appColors } from '@/constants/AppColors'

export function ButtonHeaderBack() {
  const router = useRouter()
  return (
    <Pressable
      onPress={() => {
        void Haptics.selectionAsync()
        router.back()
      }}
      style={styles.hit}
      accessibilityLabel="Back"
      accessibilityRole="button"
    >
      <Image
        source="sf:chevron.left"
        style={styles.icon}
        tintColor={appColors.foreground}
        contentFit="contain"
      />
    </Pressable>
  )
}

const styles = StyleSheet.create({
  hit: {
    width: 44,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
  },
  icon: {
    width: 22,
    height: 22,
  },
})
