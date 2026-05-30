import { Iceberg_400Regular } from '@expo-google-fonts/iceberg'
import {
  getRecordingPermissionsAsync,
  requestRecordingPermissionsAsync,
} from 'expo-audio'
import { useFonts } from 'expo-font'
import { Stack } from 'expo-router'
import * as SplashScreen from 'expo-splash-screen'
import { StatusBar } from 'expo-status-bar'
import { useEffect } from 'react'
import { Appearance } from 'react-native'
import { appColors, appFontFamily } from '../constants/AppColors'

Appearance.setColorScheme('dark')
import { TranscriptionLanguageProvider } from '../hooks/settings/transcription-language-context'
import { ModelManagementProvider } from '../hooks/whisper/model-management-context'

SplashScreen.preventAutoHideAsync()

export default function RootLayout() {
  const [loaded, error] = useFonts({
    Iceberg_400Regular,
  })

  useEffect(() => {
    if (loaded || error) {
      SplashScreen.hideAsync()
    }
  }, [loaded, error])

  useEffect(() => {
    void (async () => {
      const { granted, canAskAgain } = await getRecordingPermissionsAsync()
      if (!granted && canAskAgain) {
        await requestRecordingPermissionsAsync()
      }
    })()
  }, [])

  if (!loaded && !error) {
    return null
  }

  return (
    <TranscriptionLanguageProvider>
      <ModelManagementProvider>
        <StatusBar style="light" />
        <Stack
          screenOptions={{
            contentStyle: { backgroundColor: appColors.page },
            headerStyle: { backgroundColor: appColors.page },
            headerTintColor: appColors.foreground,
            headerTitleStyle: { fontFamily: appFontFamily.sans },
            headerShadowVisible: false,
            headerShown: false,
          }}
        />
      </ModelManagementProvider>
    </TranscriptionLanguageProvider>
  )
}
