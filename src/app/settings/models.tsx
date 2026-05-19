import { Stack } from 'expo-router'
import { ScreenSettingsModels } from '@/components/Settings/ScreenSettingsModels'

export default function SettingsModelsRoute() {
  return (
    <>
      <Stack.Screen options={{ title: 'Speech models' }} />
      <ScreenSettingsModels />
    </>
  )
}
