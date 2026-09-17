import { Stack } from 'expo-router'
import { ScreenSettingsFormatting } from '@/components/Settings/ScreenSettingsFormatting'

export default function SettingsFormattingRoute() {
  return (
    <>
      <Stack.Screen options={{ title: 'Formatting' }} />
      <ScreenSettingsFormatting />
    </>
  )
}
