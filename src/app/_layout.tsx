import { Iceberg_400Regular } from '@expo-google-fonts/iceberg'
import { Iceland_400Regular } from '@expo-google-fonts/iceland'
import { useFonts } from 'expo-font'
import { Stack } from 'expo-router'
import * as SplashScreen from 'expo-splash-screen'
import { StatusBar } from 'expo-status-bar'
import { useEffect } from 'react'
import { appColors } from '../constants/AppColors'

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
    <>
      <StatusBar style="light" />
      <Stack
        screenOptions={{
          contentStyle: { backgroundColor: appColors.page },
          headerShown: false,
        }}
      />
    </>
  )
}
