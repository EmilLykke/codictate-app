import { Stack } from 'expo-router'
import { ButtonHeaderBack } from '@/components/Settings/ButtonHeaderBack'
import { ScreenSettings } from '@/components/Settings/ScreenSettings'

export default function SettingsIndexRoute() {
  return (
    <>
      <Stack.Screen
        options={{
          title: 'Settings',
          headerLeft: () => <ButtonHeaderBack />,
        }}
      />
      <ScreenSettings />
    </>
  )
}
