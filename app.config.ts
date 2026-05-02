import "tsx/cjs";
import { ExpoConfig } from "expo/config";
import withKeyboardExtension from "./plugins/withKeyboardExtension";

const config: ExpoConfig = {
  name: "Codictate",
  slug: "codictate",
  version: "1.0.0",
  orientation: "portrait",
  icon: "./assets/images/icon.png",
  scheme: "codictateapp",
  userInterfaceStyle: "dark",
  ios: {
    icon: "./assets/codictate.icon",
    bundleIdentifier: "app.codictate",
    infoPlist: {
      ITSAppUsesNonExemptEncryption: false,
      NSMicrophoneUsageDescription:
        "Codictate uses the microphone to record your voice for on-device transcription.",
      UIBackgroundModes: ["audio"],
      LSApplicationQueriesSchemes: ["App-Prefs"],
    },
    entitlements: {
      "com.apple.security.application-groups": ["group.app.codictate"],
    },
  },
  android: {
    adaptiveIcon: {
      backgroundColor: "#000000",
      foregroundImage: "./assets/images/icon.png",
    },
    predictiveBackGestureEnabled: false,
  },
  web: {
    output: "static",
    favicon: "./assets/images/icon.png",
  },
  extra: {
    eas: {
      projectId: "6d9b2adc-0482-4953-b3ec-8ea381f454e0",
      build: {
        experimental: {
          ios: {
            appExtensions: [
              {
                targetName: "CodictateDictationKeyboard",
                bundleIdentifier: "app.codictate.keyboard",
                entitlements: {
                  "com.apple.security.application-groups": [
                    "group.app.codictate",
                  ],
                },
              },
              {
                targetName: "ExpoWidgetsTarget",
                bundleIdentifier: "app.codictate.ExpoWidgetsTarget",
                entitlements: {
                  "com.apple.security.application-groups": [
                    "group.app.codictate",
                  ],
                },
              },
            ],
          },
        },
      },
    },
  },
  plugins: [
    "expo-router",
    [
      "expo-build-properties",
      {
        ios: {
          deploymentTarget: "16.1",
        },
      },
    ],
    [
      "expo-widgets",
      {
        groupIdentifier: "group.app.codictate",
      },
    ],
    [
      "expo-splash-screen",
      {
        backgroundColor: "#000000",
        android: {
          image: "./assets/images/icon.png",
          imageWidth: 76,
        },
      },
    ],
    [
      "expo-audio",
      {
        microphonePermission:
          "Codictate uses the microphone to record your voice for on-device transcription.",
      },
    ],
  ],
  assetBundlePatterns: ["assets/models/*"],
  experiments: {
    typedRoutes: true,
    reactCompiler: true,
  },
};

export default withKeyboardExtension(config);
