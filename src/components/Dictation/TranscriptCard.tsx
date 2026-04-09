import * as Clipboard from 'expo-clipboard'
import * as Haptics from 'expo-haptics'
import { Image } from 'expo-image'
import { useState } from 'react'
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native'
import { appColors, appFontFamily, appFontSize } from '@/constants/AppColors'

type TranscriptCardProps = {
  transcript: string
  onClear: () => void
}

const CIRCLE = 48

export function TranscriptCard({ transcript, onClear }: TranscriptCardProps) {
  const [copied, setCopied] = useState(false)

  const handleCopy = async () => {
    await Clipboard.setStringAsync(transcript)
    await Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  const handleClear = () => {
    void Haptics.selectionAsync()
    onClear()
  }

  return (
    <View style={styles.outer}>
      <View style={styles.card}>
        <Text style={styles.clipboardHint} selectable>
          Copied to clipboard — paste anywhere (e.g. Notes or Messages).
        </Text>
        <ScrollView
          style={styles.transcriptScroll}
          contentContainerStyle={styles.transcriptScrollContent}
          showsVerticalScrollIndicator
          nestedScrollEnabled
        >
          <Text selectable style={styles.transcriptText}>
            {transcript}
          </Text>
        </ScrollView>

        <View style={styles.actions}>
          <Pressable
            onPress={handleCopy}
            style={({ pressed }) => [
              styles.actionCircle,
              pressed && styles.actionCirclePressed,
            ]}
            accessibilityLabel={
              copied ? 'Copied to clipboard' : 'Copy transcript again'
            }
            accessibilityRole="button"
          >
            <Image
              source={copied ? 'sf:checkmark' : 'sf:doc.on.doc'}
              style={styles.actionIcon}
              contentFit="contain"
              tintColor={copied ? '#4ADE80' : 'rgba(255,255,255,0.65)'}
            />
          </Pressable>
          <Pressable
            onPress={handleClear}
            style={({ pressed }) => [
              styles.actionCircle,
              pressed && styles.actionCirclePressed,
            ]}
            accessibilityLabel="Clear transcript"
            accessibilityRole="button"
          >
            <Image
              source="sf:trash"
              style={styles.actionIcon}
              contentFit="contain"
              tintColor="rgba(255,255,255,0.45)"
            />
          </Pressable>
        </View>
      </View>
    </View>
  )
}

const styles = StyleSheet.create({
  outer: {
    flex: 1,
    minHeight: 0,
    width: '100%',
    alignItems: 'stretch',
  },
  card: {
    flex: 1,
    minHeight: 0,
    backgroundColor: appColors.paper,
    borderRadius: 20,
    paddingTop: 16,
    paddingHorizontal: 16,
    paddingBottom: 10,
    gap: 10,
    borderCurve: 'continuous',
    boxShadow: '0 4px 24px rgba(0, 0, 0, 0.4)',
    maxWidth: 360,
    width: '100%',
  },
  clipboardHint: {
    fontFamily: appFontFamily.sans,
    fontSize: 12,
    lineHeight: 17,
    color: appColors.foregroundSubtle,
  },
  transcriptScroll: {
    flex: 1,
    minHeight: 72,
  },
  transcriptScrollContent: {
    paddingBottom: 4,
  },
  transcriptText: {
    fontFamily: appFontFamily.sans,
    fontSize: appFontSize.body - 2,
    lineHeight: 28,
    color: appColors.foreground,
    letterSpacing: 0.1,
  },
  actions: {
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 16,
    paddingTop: 4,
  },
  actionCircle: {
    width: CIRCLE,
    height: CIRCLE,
    borderRadius: CIRCLE / 2,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(255,255,255,0.09)',
    borderCurve: 'continuous',
  },
  actionCirclePressed: {
    backgroundColor: 'rgba(255,255,255,0.14)',
  },
  actionIcon: {
    width: 22,
    height: 22,
  },
})
