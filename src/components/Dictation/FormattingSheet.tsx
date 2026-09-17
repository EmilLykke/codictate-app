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
import { FormattingPickerContent } from '@/components/Settings/ScreenSettingsFormatting'
import { appColors, appFontFamily, appFontSize } from '@/constants/AppColors'
import type { useFormattingSettings } from '@/hooks/settings/use-formatting-settings'

type Props = {
  visible: boolean
  onClose: () => void
  settings: ReturnType<typeof useFormattingSettings>
}

export function FormattingSheet({ visible, onClose, settings }: Props) {
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
          <Text style={styles.title}>Formatting</Text>
          <Pressable onPress={onClose} style={styles.closeHit}>
            <Image
              source="sf:xmark.circle.fill"
              style={styles.closeIcon}
              contentFit="contain"
              tintColor="rgba(255,255,255,0.4)"
            />
          </Pressable>
        </View>
        <ScrollView
          contentContainerStyle={styles.content}
          showsVerticalScrollIndicator={false}
        >
          <FormattingPickerContent settings={settings} />
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
    marginBottom: 12,
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
    paddingBottom: 32,
    gap: 20,
  },
})
