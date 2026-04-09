import {
  AudioQuality,
  IOSOutputFormat,
  type RecordingOptions,
} from 'expo-audio'

/**
 * whisper.rn only decodes standard PCM WAV (44-byte header + int16 LE samples).
 * M4A/AAC from RecordingPresets.HIGH_QUALITY is mis-read as PCM → silence → empty transcript.
 *
 * @see whisper.rn ios/RNWhisperAudioUtils.m decodeWaveFile / decodeWaveData
 */
export const WHISPER_RECORDING_OPTIONS: RecordingOptions = {
  extension: '.wav',
  sampleRate: 16000,
  numberOfChannels: 1,
  bitRate: 256000,
  ios: {
    outputFormat: IOSOutputFormat.LINEARPCM,
    audioQuality: AudioQuality.HIGH,
    linearPCMBitDepth: 16,
    linearPCMIsBigEndian: false,
    linearPCMIsFloat: false,
  },
  android: {
    outputFormat: 'mpeg4',
    audioEncoder: 'aac',
  },
  web: {
    mimeType: 'audio/wav',
    bitsPerSecond: 256000,
  },
}

/** Reject recordings smaller than this (bytes) — likely failed or silent. */
export const WHISPER_MIN_RECORDING_BYTES = 1200
