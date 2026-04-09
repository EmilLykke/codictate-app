import * as Haptics from 'expo-haptics'
import { useRouter } from 'expo-router'
import { useCallback } from 'react'
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native'
import { TRANSCRIPTION_LANGUAGE_OPTIONS } from '@/constants/transcription-languages'
import { appColors, appFontFamily, appFontSize } from '@/constants/AppColors'
import { useTranscriptionLanguage } from '@/hooks/settings/transcription-language-context'

type Row = (typeof TRANSCRIPTION_LANGUAGE_OPTIONS)[number]

export function ScreenLanguagePicker() {
  const router = useRouter()
  const { languageId, setLanguageId } = useTranscriptionLanguage()

  const onPick = useCallback(
    async (id: string) => {
      await setLanguageId(id)
      void Haptics.selectionAsync()
      router.back()
    },
    [router, setLanguageId]
  )

  const renderItem = useCallback(
    ({ item }: { item: Row }) => {
      const selected = item.id === languageId
      return (
        <Pressable
          onPress={() => onPick(item.id)}
          style={({ pressed }) => [
            styles.row,
            pressed && styles.rowPressed,
            selected && styles.rowSelected,
          ]}
        >
          <Text
            style={[styles.rowLabel, selected && styles.rowLabelOn]}
            selectable
          >
            {item.label}
          </Text>
          {selected ? (
            <Text style={styles.check} selectable>
              ✓
            </Text>
          ) : null}
        </Pressable>
      )
    },
    [languageId, onPick]
  )

  const keyExtractor = useCallback((item: Row) => item.id, [])

  return (
    <FlatList
      data={TRANSCRIPTION_LANGUAGE_OPTIONS}
      keyExtractor={keyExtractor}
      renderItem={renderItem}
      style={styles.list}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.listContent}
      ItemSeparatorComponent={() => <View style={styles.sep} />}
      showsVerticalScrollIndicator={false}
    />
  )
}

const styles = StyleSheet.create({
  list: {
    flex: 1,
    backgroundColor: appColors.page,
  },
  listContent: {
    paddingHorizontal: 20,
    paddingVertical: 12,
    paddingBottom: 32,
  },
  sep: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: 'rgba(255,255,255,0.08)',
    marginLeft: 16,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 14,
    paddingHorizontal: 16,
    borderRadius: 14,
    borderCurve: 'continuous',
  },
  rowPressed: {
    backgroundColor: 'rgba(255,255,255,0.06)',
  },
  rowSelected: {
    backgroundColor: 'rgba(255,255,255,0.08)',
  },
  rowLabel: {
    fontFamily: appFontFamily.sans,
    fontSize: appFontSize.body - 4,
    color: appColors.foregroundMuted,
    flex: 1,
  },
  rowLabelOn: {
    color: appColors.foreground,
    fontWeight: '600',
  },
  check: {
    fontFamily: appFontFamily.sans,
    fontSize: 18,
    color: 'rgba(96, 165, 250, 0.95)',
    marginLeft: 12,
  },
})
