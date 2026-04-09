import { Stack } from 'expo-router'
import { ScreenLanguagePicker } from '@/components/Settings/ScreenLanguagePicker'

export default function SettingsLanguageRoute() {
  return (
    <>
      <Stack.Screen options={{ title: 'Language' }} />
      <ScreenLanguagePicker />
    </>
  )
}
