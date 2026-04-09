import { Text, View, StyleSheet } from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import { appColors, appFontFamily, appFontSize } from '../constants/AppColors'

export default function Index() {
  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.container}>
        <View style={styles.hero}>
          <Text style={styles.wordmarkBrand}>C</Text>
          <Text style={styles.wordmarkSans}>odictate</Text>
        </View>
        <View style={styles.paperCard}>
          <Text style={styles.subtitle}>
            Voice dictation for your workflow — mobile app coming soon.
          </Text>
        </View>
      </View>
    </SafeAreaView>
  )
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: appColors.page,
  },
  container: {
    flex: 1,
    backgroundColor: appColors.page,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 28,
  },
  hero: {
    flexDirection: 'row',
    alignItems: 'baseline',
    marginBottom: 28,
  },
  wordmarkBrand: {
    fontFamily: appFontFamily.brand,
    fontSize: 52,
    letterSpacing: -1,
    color: appColors.foreground,
  },
  wordmarkSans: {
    fontFamily: appFontFamily.sans,
    fontSize: 52,
    letterSpacing: -1,
    color: appColors.foreground,
  },
  paperCard: {
    maxWidth: 340,
    paddingVertical: 18,
    paddingHorizontal: 22,
    borderRadius: 16,
    backgroundColor: appColors.paper,
  },
  subtitle: {
    fontFamily: appFontFamily.sans,
    fontSize: appFontSize.body - 2,
    lineHeight: 28,
    textAlign: 'center',
    color: appColors.foregroundMuted,
  },
})
