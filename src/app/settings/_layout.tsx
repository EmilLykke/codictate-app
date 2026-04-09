import { Stack } from 'expo-router'
import { appColors, appFontFamily } from '@/constants/AppColors'

export default function SettingsLayout() {
  return (
    <Stack
      screenOptions={{
        contentStyle: { backgroundColor: appColors.page },
        headerStyle: { backgroundColor: appColors.page },
        headerTintColor: appColors.foreground,
        headerTitleStyle: { fontFamily: appFontFamily.sans },
        headerShadowVisible: false,
      }}
    />
  )
}
