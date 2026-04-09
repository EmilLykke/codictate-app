import { ExpoConfig } from 'expo/config'

const config: ExpoConfig = {
  name: 'codictate-app',
  slug: 'codictate-app',
  version: '1.0.0',
  orientation: 'portrait',
  icon: './assets/images/icon.png',
  scheme: 'codictateapp',
  userInterfaceStyle: 'dark',
  ios: {
    icon: './assets/expo.icon',
    bundleIdentifier: 'com.emillo2003.codictate-app',
    infoPlist: {
      NSMicrophoneUsageDescription:
        'Codictate uses the microphone to record your voice for on-device transcription.',
    },
  },
  android: {
    adaptiveIcon: {
      backgroundColor: '#E6F4FE',
      foregroundImage: './assets/images/android-icon-foreground.png',
      backgroundImage: './assets/images/android-icon-background.png',
      monochromeImage: './assets/images/android-icon-monochrome.png',
    },
    predictiveBackGestureEnabled: false,
  },
  web: {
    output: 'static',
    favicon: './assets/images/favicon.png',
  },
  plugins: [
    'expo-router',
    [
      'expo-build-properties',
      {
        ios: {
          deploymentTarget: '15.1',
        },
      },
    ],
    [
      'expo-splash-screen',
      {
        backgroundColor: '#000000',
        android: {
          image: './assets/images/splash-icon.png',
          imageWidth: 76,
        },
      },
    ],
    [
      'expo-audio',
      {
        microphonePermission:
          'Codictate uses the microphone to record your voice for on-device transcription.',
      },
    ],
    // whisper.rn uses auto-linking — no config plugin entry needed
  ],
  assetBundlePatterns: ['assets/models/*'],
  experiments: {
    typedRoutes: true,
    reactCompiler: true,
  },
}

export default config
