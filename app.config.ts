import "tsx/cjs";
import { ExpoConfig } from "expo/config";
import withKeyboardExtension from "./plugins/withKeyboardExtension";
import withFluidAudio from "./plugins/withFluidAudio";
import withCrispASR from "./plugins/withCrispASR";
import withLlama from "./plugins/withLlama";
import withFormattingAU from "./plugins/withFormattingAU";
import withParakeetCpp from "./plugins/withParakeetCpp";
import withOnnxRuntime from "./plugins/withOnnxRuntime";

const config: ExpoConfig = {
  name: "Codictate",
  slug: "codictate",
  version: "1.0.4",
  orientation: "portrait",
  icon: "./assets/icon.iconset/icon_512x512@2x.png",
  scheme: "codictateapp",
  userInterfaceStyle: "dark",
  ios: {
    icon: "./assets/icon.iconset/icon_512x512@2x.png",
    bundleIdentifier: "app.codictate",
    // Signs every target, extensions included. Prebuild recreates ios/ each run since
    // SDK 57, so a team picked in Xcode does not survive the next prebuild.
    appleTeamId: "L256GR2793",
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
                  "inter-app-audio": true,
                },
              },
              {
                targetName: "CodictateFormattingAU",
                bundleIdentifier: "app.codictate.formattingau",
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
    "expo-asset",
    [
      "expo-build-properties",
      {
        ios: {
          deploymentTarget: "17.0",
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
    "expo-font",
    "expo-image",
    "expo-status-bar",
    "expo-web-browser",
  ],
  assetBundlePatterns: ["assets/models/*"],
  experiments: {
    typedRoutes: true,
    reactCompiler: true,
  },
};

// Expo runs config-plugin mods in reverse registration order, so the innermost
// wrapper here runs its mods last. withCrispASR must run after
// withKeyboardExtension, which rewrites the app target's HEADER_SEARCH_PATHS and
// FRAMEWORK_SEARCH_PATHS wholesale on every prebuild; withCrispASR appends the
// crispasr entries to whatever it leaves behind. withParakeetCpp and
// withOnnxRuntime (ekko and ekko-pnc) sit inside it for the same reason.
// withFluidAudio sits inside withKeyboardExtension too, so it runs after the
// keyboard extension target exists and can link FluidAudio to it.
// withFormattingAU (the Dictation AU) is innermost, so it runs last: it links the
// crispasr, llama, parakeet and onnxruntime references the other plugins add (were it
// first, they would find a reference and skip embedding their framework in the app),
// and it needs the keyboard target and the app's shared sources that
// withKeyboardExtension adds.
export default withKeyboardExtension(
  withFluidAudio(
    withCrispASR(
      withLlama(withParakeetCpp(withOnnxRuntime(withFormattingAU(config)))),
    ),
  ),
);
