import { Iceberg_400Regular } from '@expo-google-fonts/iceberg'
import { Iceland_400Regular } from '@expo-google-fonts/iceland'
import { useFonts } from 'expo-font'
import { Stack } from 'expo-router'
import * as SplashScreen from 'expo-splash-screen'
import { StatusBar } from 'expo-status-bar'
import { useEffect } from 'react'
import { appColors, appFontFamily } from '../constants/AppColors'
import { TranscriptionLanguageProvider } from '../hooks/settings/transcription-language-context'

SplashScreen.preventAutoHideAsync()

export default function RootLayout() {
  const [loaded, error] = useFonts({
    Iceland_400Regular,
    Iceberg_400Regular,
  })

  useEffect(() => {
    if (loaded || error) {
      SplashScreen.hideAsync()
    }
  }, [loaded, error])

  if (!loaded && !error) {
    return null
  }

  return (
    <TranscriptionLanguageProvider>
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
    </TranscriptionLanguageProvider>
  )
}
