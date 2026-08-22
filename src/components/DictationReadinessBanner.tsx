import type { DictationReadiness } from 'codictate-dictation'
import { Image } from 'expo-image'
import { StyleSheet, Text, View } from 'react-native'
import { appFontFamily } from '@/constants/AppColors'

/**
 * Shows the Host's blocked reason verbatim. The message is written in Swift so
 * this screen, the keyboard and the Action Button cannot disagree about why
 * dictation will not start. Renders nothing while dictation is runnable.
 */
export function DictationReadinessBanner({
  readiness,
}: {
  readiness: DictationReadiness
}) {
  if (!readiness.blocked) return null

  return (
    <View style={styles.banner} accessibilityRole="alert">
      <Image
        source="sf:exclamationmark.triangle.fill"
        style={styles.icon}
        contentFit="contain"
        tintColor="#FBBF24"
      />
      <Text style={styles.message} selectable>
        {readiness.message}
      </Text>
    </View>
  )
}

const styles = StyleSheet.create({
  banner: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    paddingVertical: 10,
    paddingHorizontal: 14,
    borderRadius: 12,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(251,191,36,0.14)',
    maxWidth: 368,
    width: '100%',
    alignSelf: 'center',
    marginBottom: 12,
  },
  icon: {
    width: 16,
    height: 16,
  },
  message: {
    flex: 1,
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    lineHeight: 20,
    color: '#FCD34D',
  },
})
