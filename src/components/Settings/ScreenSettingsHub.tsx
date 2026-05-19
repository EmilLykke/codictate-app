import { Image } from 'expo-image'
import { Link, type Href } from 'expo-router'
import { Platform, Pressable, Text, View } from 'react-native'
import { labelForTranscriptionLanguageId } from '@/constants/transcription-languages'
import { appColors } from '@/constants/AppColors'
import { useTranscriptionLanguage } from '@/hooks/settings/transcription-language-context'
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

export function ScreenSettingsHub() {
  const isIos = Platform.OS === 'ios'
  const { languageId } = useTranscriptionLanguage()

  return (
    <SettingsScroll>
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
                {labelForTranscriptionLanguageId(languageId)}
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
      </SectionCard>
    </SettingsScroll>
  )
}
