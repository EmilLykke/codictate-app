import type { ModelVariant } from 'codictate-dictation'

/**
 * The Speech Model table: one row per set of weights the user can select, with
 * its copy, its download size and its Language Lock. Settings and the dictation
 * screen both read this, so there is one place to add a Speech Model.
 *
 * `acceptedLanguageIds` is the Language Lock: the Transcription Language ids the
 * Speech Model accepts, or `null` for "every id in TRANSCRIPTION_LANGUAGE_OPTIONS".
 * A Locked Speech Model disables the rows it cannot run instead of accepting a
 * selection and ignoring it, because English-only or Danish-only weights fed
 * another language return a fluent wrong-language transcript and never an error.
 * `auto` stays pickable: it is the absence of a choice, and a Locked Speech Model
 * runs its pinned language for it. See `resolveTranscriptionLanguageId`.
 *
 * Dictation Readiness is not computed here. The Host owns that verdict; this
 * table only decides what the UI offers.
 */
export type SpeechModel = {
  variant: ModelVariant
  label: string
  /** Second line in the model list: family and approximate download size. */
  meta: string
  /** Approximate download size in MB, for the download confirmation prompt. */
  sizeMb: string
  description: string
  acceptedLanguageIds: readonly string[] | null
  /**
   * Finished sentence shown above the language picker while the lock applies. It
   * states what will run, including what Auto-detect resolves to, so the picker
   * never implies a second trip is required.
   */
  lockNote: string | null
}

/** The Transcription Language id meaning "the user expressed no preference". */
const AUTO_LANGUAGE_ID = 'auto'

export const SPEECH_MODELS: readonly SpeechModel[] = [
  {
    variant: 'parakeet',
    label: 'Parakeet TDT v3',
    meta: '~500 MB',
    sizeMb: '500',
    description: 'The fastest and best model.',
    // Parakeet takes no language input at all, so it is locked to automatic.
    acceptedLanguageIds: ['auto'],
    lockNote:
      'Parakeet TDT v3 detects the language itself, so the language stays on Auto-detect.',
  },
  {
    variant: 'base',
    label: 'Base (Q5_1)',
    meta: 'Whisper · ~57 MB',
    sizeMb: '57',
    description: 'Default model.',
    acceptedLanguageIds: null,
    lockNote: null,
  },
  {
    variant: 'base_en',
    label: 'Base.en (Q5_1)',
    meta: 'Whisper · ~57 MB',
    sizeMb: '57',
    description: 'Good for English only.',
    acceptedLanguageIds: ['en'],
    lockNote:
      'Base.en (Q5_1) transcribes English only. Auto-detect runs as English.',
  },
  {
    variant: 'hviske',
    label: 'Hviske V5 Tiny Q5',
    meta: '~181 MB',
    sizeMb: '181',
    description: 'Danish only. Best Danish accuracy, 11.3 WER.',
    acceptedLanguageIds: ['da'],
    lockNote:
      'Hviske V5 Tiny Q5 transcribes Danish only. Auto-detect runs as Danish.',
  },
]

const BY_VARIANT = new Map(SPEECH_MODELS.map((m) => [m.variant, m]))

export function speechModelFor(variant: string): SpeechModel | undefined {
  return BY_VARIANT.get(variant as ModelVariant)
}

export function speechModelLabel(variant: string): string {
  return BY_VARIANT.get(variant as ModelVariant)?.label ?? variant
}

export function speechModelMeta(variant: string): string {
  return BY_VARIANT.get(variant as ModelVariant)?.meta ?? ''
}

export function speechModelSizeMb(variant: string): string {
  return BY_VARIANT.get(variant as ModelVariant)?.sizeMb ?? '?'
}

export function speechModelDescription(variant: string): string | undefined {
  return BY_VARIANT.get(variant as ModelVariant)?.description
}

/** `null` means the Speech Model accepts every Transcription Language. */
export function acceptedLanguageIdsFor(
  variant: string
): readonly string[] | null {
  return BY_VARIANT.get(variant as ModelVariant)?.acceptedLanguageIds ?? null
}

export function isLanguageLocked(variant: string): boolean {
  return acceptedLanguageIdsFor(variant) != null
}

export function acceptsTranscriptionLanguage(
  variant: string,
  languageId: string
): boolean {
  const accepted = acceptedLanguageIdsFor(variant)
  if (accepted == null || accepted.includes(languageId)) return true
  // `auto` is the absence of a choice, not a conflicting one. A Locked Speech Model
  // takes it and runs its pinned language instead, so only an explicitly picked
  // other language conflicts.
  return languageId === AUTO_LANGUAGE_ID && lockedLanguageIdFor(variant) != null
}

/**
 * The Transcription Language that will actually run: a Locked Speech Model resolves
 * `auto` to its pinned language, everything else keeps the stored id. Mirrors
 * `ModelManager.Variant.resolvedLanguageId` in Swift, which is where the value an
 * engine receives is decided; this copy exists only so the UI can say what will happen.
 */
export function resolveTranscriptionLanguageId(
  variant: string,
  languageId: string
): string {
  const pinned = lockedLanguageIdFor(variant)
  if (pinned == null || languageId !== AUTO_LANGUAGE_ID) return languageId
  return pinned
}

/** The one language a Locked Speech Model pins to, or `null` when unlocked. */
export function lockedLanguageIdFor(variant: string): string | null {
  const accepted = acceptedLanguageIdsFor(variant)
  if (accepted == null || accepted.length !== 1) return null
  return accepted[0]
}

export function languageLockNoteFor(variant: string): string | null {
  return BY_VARIANT.get(variant as ModelVariant)?.lockNote ?? null
}
