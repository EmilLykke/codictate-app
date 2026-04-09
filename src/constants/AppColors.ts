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
 * Must match `useFonts` keys from @expo-google-fonts (Iceland / Iceberg 400 Regular).
 */
export const appFontFamily = {
  sans: 'Iceland_400Regular',
  brand: 'Iceberg_400Regular',
} as const

export const appFontSize = {
  body: 23,
} as const
