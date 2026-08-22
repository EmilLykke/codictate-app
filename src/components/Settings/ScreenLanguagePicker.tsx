import * as Haptics from 'expo-haptics'
import { useRouter } from 'expo-router'
import { useCallback } from 'react'
import { FlatList, Pressable, StyleSheet, Text, View } from 'react-native'
import {
  labelForTranscriptionLanguageId,
  TRANSCRIPTION_LANGUAGE_OPTIONS,
} from '@/constants/transcription-languages'
import { appColors, appFontFamily, appFontSize } from '@/constants/AppColors'
import {
  acceptsTranscriptionLanguage,
  languageLockNoteFor,
  lockedLanguageIdFor,
} from '@/constants/speech-models'
import { useTranscriptionLanguage } from '@/hooks/settings/transcription-language-context'
import { useSharedModelManagement } from '@/hooks/whisper/model-management-context'

type Row = (typeof TRANSCRIPTION_LANGUAGE_OPTIONS)[number]

/**
 * Shown only on a genuine conflict: a language the user picked explicitly that the
 * Speech Model cannot run. Auto-detect never reaches this, so it names Auto-detect
 * as a way out unless the lock is Auto-detect already.
 */
function conflictHint(pinnedId: string): string {
  const pinned = labelForTranscriptionLanguageId(pinnedId)
  const auto = labelForTranscriptionLanguageId('auto')
  if (pinnedId === 'auto') return `Choose ${auto} to use it.`
  return `Choose ${pinned} or ${auto} to use it.`
}

export function LanguagePickerContent({
  onDismiss,
}: {
  onDismiss: () => void
}) {
  const { languageId, setLanguageId } = useTranscriptionLanguage()
  const { preferredVariant } = useSharedModelManagement()

  // Language Lock: the selected Speech Model decides which rows are pickable.
  // Rows it cannot run are disabled rather than pickable-and-ignored, because the
  // wrong language returns a fluent wrong-language transcript and never an error.
  // Auto-detect always stays pickable; a Locked Speech Model runs its own language
  // for it, which the lock note spells out.
  const lockNote = languageLockNoteFor(preferredVariant)
  const pinnedId = lockedLanguageIdFor(preferredVariant)
  const lockUnmet = !acceptsTranscriptionLanguage(preferredVariant, languageId)

  const onPick = useCallback(
    (id: string) => {
      setLanguageId(id)
      void Haptics.selectionAsync()
      onDismiss()
    },
    [onDismiss, setLanguageId]
  )

  const renderItem = useCallback(
    ({ item }: { item: Row }) => {
      const selected = item.id === languageId
      const pickable = acceptsTranscriptionLanguage(preferredVariant, item.id)
      return (
        <Pressable
          onPress={() => onPick(item.id)}
          disabled={!pickable}
          style={({ pressed }) => [
            styles.row,
            pressed && styles.rowPressed,
            selected && styles.rowSelected,
            !pickable && styles.rowLocked,
          ]}
          accessibilityRole="button"
          accessibilityState={{ selected, disabled: !pickable }}
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
    [languageId, onPick, preferredVariant]
  )

  const keyExtractor = useCallback((item: Row) => item.id, [])

  const header =
    lockNote == null ? null : (
      <Text style={styles.lockNote} selectable>
        {lockUnmet && pinnedId != null
          ? `${lockNote} ${conflictHint(pinnedId)}`
          : lockNote}
      </Text>
    )

  return (
    <FlatList
      data={TRANSCRIPTION_LANGUAGE_OPTIONS}
      keyExtractor={keyExtractor}
      renderItem={renderItem}
      ListHeaderComponent={header}
      style={styles.list}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.listContent}
      ItemSeparatorComponent={() => <View style={styles.sep} />}
      showsVerticalScrollIndicator={false}
    />
  )
}

export function ScreenLanguagePicker() {
  const router = useRouter()
  return <LanguagePickerContent onDismiss={() => router.back()} />
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
  rowLocked: {
    opacity: 0.32,
  },
  lockNote: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    lineHeight: 20,
    color: appColors.foregroundMuted,
    paddingHorizontal: 16,
    paddingBottom: 12,
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
