import { File, Paths } from 'expo-file-system'
import { initWhisper, WhisperContext } from 'whisper.rn'
import { ACTIVE_WHISPER_MODEL } from '@/constants/whisper-models'

export type ModelLoadProgress =
  | { phase: 'downloading'; progress: number }
  | { phase: 'initializing' }

export async function loadWhisperModel(
  onProgress?: (update: ModelLoadProgress) => void
): Promise<WhisperContext> {
  const modelFile = new File(Paths.document, ACTIVE_WHISPER_MODEL.filename)
  const minSize = ACTIVE_WHISPER_MODEL.minSizeBytes

  const needsDownload = !modelFile.exists || modelFile.size < minSize
  let fileForWhisper = modelFile

  if (needsDownload) {
    if (modelFile.exists) {
      modelFile.delete()
    }

    let simulated = 0
    const progressTimer = setInterval(() => {
      simulated = Math.min(simulated + 0.018, 0.92)
      onProgress?.({ phase: 'downloading', progress: simulated })
    }, 350)

    try {
      fileForWhisper = await File.downloadFileAsync(
        ACTIVE_WHISPER_MODEL.url,
        modelFile,
        {
          idempotent: true,
        }
      )
      if (fileForWhisper.size < minSize) {
        throw new Error('Downloaded model is incomplete.')
      }
    } finally {
      clearInterval(progressTimer)
    }

    onProgress?.({ phase: 'downloading', progress: 1 })
  }

  if (!fileForWhisper.exists || fileForWhisper.size < minSize) {
    throw new Error('Whisper model is missing or incomplete.')
  }

  onProgress?.({ phase: 'initializing' })

  return initWhisper({ filePath: fileForWhisper.uri })
}
