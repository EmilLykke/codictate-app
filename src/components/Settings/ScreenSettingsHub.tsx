import { Image } from 'expo-image'
import { Link, type Href } from 'expo-router'
import { Platform, Pressable, Text, View } from 'react-native'
import { labelForTranscriptionLanguageId } from '@/constants/transcription-languages'
import { appColors } from '@/constants/AppColors'
import { resolveTranscriptionLanguageId } from '@/constants/speech-models'
import { useTranscriptionLanguage } from '@/hooks/settings/transcription-language-context'
import { useSharedModelManagement } from '@/hooks/whisper/model-management-context'
import {
  SettingsHubActionButtonSection,
  SettingsHubKeyboardSection,
  SettingsHubWarmSessionSection,
} from '@/components/Settings/SettingsHubIosSections'
import {
  SectionCard,
  SettingsScroll,
  settingsStyles as styles,
} from '@/components/Settings/settings-shared'
import { DictationReadinessBanner } from '@/components/DictationReadinessBanner'
import { useDictationReadiness } from '@/hooks/whisper/use-dictation-readiness'

export function ScreenSettingsHub() {
  const isIos = Platform.OS === 'ios'
  const { languageId } = useTranscriptionLanguage()
  const { preferredVariant } = useSharedModelManagement()
  const readiness = useDictationReadiness()
  // The row names the language that will actually run: a Locked Speech Model reads
  // Auto-detect as its own language.
  const effectiveLanguageId = resolveTranscriptionLanguageId(
    preferredVariant,
    languageId
  )

  return (
    <SettingsScroll>
      <DictationReadinessBanner readiness={readiness} />

      {isIos ? (
        <>
          <SettingsHubActionButtonSection />
          <SettingsHubKeyboardSection />
          <SettingsHubWarmSessionSection />
        </>
      ) : null}

      <SectionCard>
        <Link href="/settings/language" asChild>
          <Pressable style={styles.hubRow}>
            <View style={styles.hubRowMain}>
              <Text style={styles.hubRowTitle} selectable>
                Language
              </Text>
              <Text style={styles.hubRowSubtitle} selectable>
                {labelForTranscriptionLanguageId(effectiveLanguageId)}
              </Text>
            </View>
            <Image
              source="sf:chevron.right"
              style={styles.chevron}
              contentFit="contain"
              tintColor={appColors.foregroundSubtle}
            />
          </Pressable>
        </Link>

        <Link href={'/settings/models' as Href} asChild>
          <Pressable style={styles.hubRow}>
            <View style={styles.hubRowMain}>
              <Text style={styles.hubRowTitle} selectable>
                Speech models
              </Text>
              <Text style={styles.hubRowSubtitle} selectable>
                Download and choose ASR model
              </Text>
            </View>
            <Image
              source="sf:chevron.right"
              style={styles.chevron}
              contentFit="contain"
              tintColor={appColors.foregroundSubtle}
            />
          </Pressable>
        </Link>

        <Link href={'/settings/licenses' as Href} asChild>
          <Pressable style={styles.hubRow}>
            <View style={styles.hubRowMain}>
              <Text style={styles.hubRowTitle} selectable>
                Open-source licenses
              </Text>
              <Text style={styles.hubRowSubtitle} selectable>
                Whisper, Hviske, Parakeet, FluidAudio
              </Text>
            </View>
            <Image
              source="sf:chevron.right"
              style={styles.chevron}
              contentFit="contain"
              tintColor={appColors.foregroundSubtle}
            />
          </Pressable>
        </Link>
      </SectionCard>
    </SettingsScroll>
  )
}
