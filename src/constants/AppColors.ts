import { Platform } from 'react-native'

/**
 * Semantic colors aligned with codictate/main `src/mainview/index.css` @theme tokens.
 */
export const appColors = {
  page: '#000000',
  canvas: '#000000',
  foreground: '#FFFFFF',
  paper: 'rgba(166, 166, 166, 0.2)',
  foregroundMuted: 'rgba(255, 255, 255, 0.5)',
  foregroundSubtle: 'rgba(255, 255, 255, 0.42)',
} as const

/**
 * `sans` uses the platform UI font (SF Pro on iOS, sans-serif on Android).
 * `brand` is the Codictate wordmark only — must match `useFonts` in root `_layout.tsx`.
 */
export const appFontFamily = {
  sans: Platform.select({
    ios: 'System',
    android: 'sans-serif',
    default: 'System',
  })!,
  brand: 'Iceberg_400Regular',
} as const

export const appFontSize = {
  body: 23,
} as const
