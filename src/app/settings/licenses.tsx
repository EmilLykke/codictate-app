import { Stack } from 'expo-router'
import { ScreenSettingsLicenses } from '@/components/Settings/ScreenSettingsLicenses'

export default function SettingsLicensesRoute() {
  return (
    <>
      <Stack.Screen options={{ title: 'Licenses' }} />
      <ScreenSettingsLicenses />
    </>
  )
}
