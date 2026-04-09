import { File, Paths } from 'expo-file-system'
import {
  ACTIVE_WHISPER_MODEL,
  labelForWhisperModelFile,
} from '@/constants/whisper-models'

export type WhisperDiskModelRow = {
  filename: string
  label: string
  size: number
  isActive: boolean
}

function isGgmlBinName(name: string): boolean {
  return name.startsWith('ggml-') && name.endsWith('.bin')
}

export function listWhisperModelsOnDisk(): WhisperDiskModelRow[] {
  const doc = Paths.document
  if (!doc.exists) return []

  const rows: WhisperDiskModelRow[] = []
  for (const entry of doc.list()) {
    if (!(entry instanceof File)) continue
    const filename = entry.name
    if (!isGgmlBinName(filename)) continue
    if (!entry.exists) continue
    rows.push({
      filename,
      label: labelForWhisperModelFile(filename),
      size: entry.size,
      isActive: filename === ACTIVE_WHISPER_MODEL.filename,
    })
  }
  return rows.sort((a, b) => a.label.localeCompare(b.label))
}

export function deleteWhisperModelFile(filename: string): void {
  const f = new File(Paths.document, filename)
  if (f.exists) f.delete()
}
