import { Image } from 'expo-image'
import {
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native'
import { useSafeAreaInsets } from 'react-native-safe-area-context'
import { ModelListContent } from '@/components/Settings/ScreenSettingsModels'
import { appColors, appFontFamily, appFontSize } from '@/constants/AppColors'
import type { useModelManagement } from '@/hooks/whisper/use-model-management'

type Props = {
  visible: boolean
  onClose: () => void
  management: ReturnType<typeof useModelManagement>
}

export function ModelSwitcherSheet({ visible, onClose, management }: Props) {
  const insets = useSafeAreaInsets()

  return (
    <Modal
      visible={visible}
      animationType="slide"
      presentationStyle="pageSheet"
      onRequestClose={onClose}
    >
      <View
        style={[
          styles.container,
          { paddingTop: 16, paddingBottom: Math.max(insets.bottom, 16) },
        ]}
      >
        <View style={styles.header}>
          <Text style={styles.title}>Speech models</Text>
          <Pressable onPress={onClose} style={styles.closeHit}>
            <Image
              source="sf:xmark.circle.fill"
              style={styles.closeIcon}
              contentFit="contain"
              tintColor="rgba(255,255,255,0.4)"
            />
          </Pressable>
        </View>
        <ScrollView contentContainerStyle={styles.content}>
          <ModelListContent management={management} onSelect={onClose} />
        </ScrollView>
      </View>
    </Modal>
  )
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: appColors.page,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 20,
    paddingHorizontal: 20,
  },
  title: {
    fontFamily: appFontFamily.sans,
    fontSize: appFontSize.body,
    fontWeight: '700',
    color: appColors.foreground,
  },
  closeHit: {
    padding: 4,
  },
  closeIcon: {
    width: 24,
    height: 24,
  },
  content: {
    paddingHorizontal: 20,
  },
})
