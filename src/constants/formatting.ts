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

export const FORMATTING_STYLES: readonly {
  value: FormattingStyle
  label: string
}[] = [
  { value: 'casual', label: 'Casual' },
  { value: 'semi-casual', label: 'Semi-casual' },
  { value: 'semi-formal', label: 'Semi-formal' },
  { value: 'formal', label: 'Formal' },
]

export const FORMATTING_CONTEXTS: readonly {
  value: FormattingContext
  label: string
}[] = [
  { value: 'general', label: 'General' },
  { value: 'email', label: 'Email' },
]
