/**
 * Shared App Group identifier used to share the keyboard model between the
 * main app and the CodictateDictationKeyboard extension.
 */
export const APP_GROUP_ID = 'group.com.emillo2003.codictate-app'

/**
 * Tiny Whisper model downloaded to the App Group container so the keyboard
 * extension can access it. Kept separate from ACTIVE_WHISPER_MODEL (Base)
 * because the extension has tighter memory constraints.
 */
export const KEYBOARD_WHISPER_MODEL = {
  filename: 'ggml-tiny-q5_1.bin',
  url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin',
  minSizeBytes: 20 * 1024 * 1024,
  label: 'Tiny (Q5_1)',
} as const

/**
 * On-disk Whisper GGML file used by the app. Change here to swap default model.
 */
export const ACTIVE_WHISPER_MODEL = {
  filename: 'ggml-base-q5_1.bin',
  url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin',
  minSizeBytes: 52 * 1024 * 1024,
  label: 'Base (Q5_1)',
} as const

/** Friendly labels for other GGML files users may still have on disk */
export const WHISPER_MODEL_FILE_LABELS: Record<string, string> = {
  'ggml-tiny-q5_1.bin': 'Tiny (Q5_1)',
  'ggml-base-q5_1.bin': 'Base (Q5_1)',
  'ggml-small-q5_1.bin': 'Small (Q5_1)',
  'ggml-medium-q5_1.bin': 'Medium (Q5_1)',
}

export function labelForWhisperModelFile(filename: string): string {
  return WHISPER_MODEL_FILE_LABELS[filename] ?? filename
}
