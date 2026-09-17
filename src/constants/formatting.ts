import type {
  FormattingContext,
  FormattingModel,
  FormattingStyle,
} from 'codictate-dictation'

export const FORMATTING_MODEL_SIZE_MB = 484

export const FORMATTING_MODELS: readonly {
  value: FormattingModel
  label: string
  description: string
}[] = [
  {
    value: 'off',
    label: 'Off',
    description: 'Keep the transcript as spoken.',
  },
  {
    value: 's1-mini',
    label: 'S1-mini by Superwhisper',
    description: `On-device English cleanup · ${FORMATTING_MODEL_SIZE_MB} MB`,
  },
]

/**
 * Style names and examples mirror the desktop app's S1 styling tiles
 * (`codictate/src/mainview/components/Settings/Sections/SectionFormatting.tsx`),
 * so the same setting reads the same on both products.
 */
export const FORMATTING_STYLES: readonly {
  value: FormattingStyle
  label: string
  description: string
  preview: string
}[] = [
  {
    value: 'casual',
    label: 'casual',
    description: 'Lowercase, keeps colloquialisms',
    preview:
      'i think we should ship friday, can you double check the release notes',
  },
  {
    value: 'semi-casual',
    label: 'Natural',
    description: 'Keeps your phrasing',
    preview:
      'I think we should ship Friday, can you double check the release notes?',
  },
  {
    value: 'semi-formal',
    label: 'Standard',
    description: 'Written English, contractions kept',
    preview:
      'I think we should ship on Friday. Can you double-check the release notes?',
  },
  {
    value: 'formal',
    label: 'Formal',
    description: 'Expands contractions',
    preview:
      'I think we should ship on Friday. Could you please double-check the release notes?',
  },
]

export const FORMATTING_CONTEXTS: readonly {
  value: FormattingContext
  label: string
  description: string
  preview: string
}[] = [
  {
    value: 'general',
    label: 'General',
    description: 'Notes, messages, anything',
    preview: 'Thanks for the update, I will take a look tonight.',
  },
  {
    value: 'email',
    label: 'Email',
    description: 'Greeting and sign-off on their own lines',
    preview:
      'Hi Mark,\n\nThanks for the update. I will review it tonight.\n\nBest,',
  },
]
