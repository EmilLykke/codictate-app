import { StyleSheet, View } from 'react-native'
import {
  isLanguageLocked,
  resolveTranscriptionLanguageId,
  speechModelLabel,
} from '@/constants/speech-models'
import { labelForTranscriptionLanguageId } from '@/constants/transcription-languages'
import { useTranscriptionLanguage } from '@/hooks/settings/transcription-language-context'
import { GlassChip } from '@/components/Dictation/GlassChip'
import type { ModelVariant } from 'codictate-dictation'

type Props = {
  modelVariant: ModelVariant
  onModelPress: () => void
  onLanguagePress: () => void
}

export function ModelLanguageChips({
  modelVariant,
  onModelPress,
  onLanguagePress,
}: Props) {
  const { languageId } = useTranscriptionLanguage()
  const modelLabel = speechModelLabel(modelVariant)
  // The chip names the language that will actually run, so a Locked Speech Model
  // left on Auto-detect reads as its own language rather than as a guess.
  const languageLabel = labelForTranscriptionLanguageId(
    resolveTranscriptionLanguageId(modelVariant, languageId)
  )
  // Language Lock: the chip still opens the sheet, which is where the lock is
  // explained and the accepted languages can be picked.
  const languageLocked = isLanguageLocked(modelVariant)

  return (
    <View style={styles.row}>
      <GlassChip
        onPress={onModelPress}
        icon="sf:cpu"
        label={modelLabel}
        accessibilityLabel={`Model: ${modelLabel}`}
      />
      <GlassChip
        onPress={onLanguagePress}
        icon={languageLocked ? 'sf:lock' : 'sf:globe'}
        label={languageLabel}
        accessibilityLabel={
          languageLocked
            ? `Language: ${languageLabel}, fixed by ${modelLabel}`
            : `Language: ${languageLabel}`
        }
      />
    </View>
  )
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    gap: 8,
    paddingBottom: 8,
    maxWidth: 368,
    alignSelf: 'center',
    width: '100%',
  },
})
