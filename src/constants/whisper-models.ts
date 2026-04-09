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
