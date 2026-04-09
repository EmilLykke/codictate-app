import * as Haptics from 'expo-haptics'
import { Image } from 'expo-image'
import { useRouter } from 'expo-router'
import { Pressable, StyleSheet } from 'react-native'

export function ButtonHeaderSettings() {
  const router = useRouter()
  return (
    <Pressable
      onPress={() => {
        void Haptics.selectionAsync()
        router.push('/settings')
      }}
      style={styles.hit}
      accessibilityLabel="Settings"
      accessibilityRole="button"
    >
      <Image
        source="sf:gearshape"
        style={styles.icon}
        tintColor="#FFFFFF"
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
