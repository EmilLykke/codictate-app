/**
 * Whisper often splits or mishears the product name — normalize before show/clipboard.
 * Matches codictate/main/src/bun/utils/whisper/speech2text.ts (fixBrandMishearings).
 */
const BRAND_TRANSCRIPT_FIXES: [RegExp, string][] = [
  [/\bcode\s+dictate\b/gi, 'Codictate'],
  [/\bcoding\s*tate\b/gi, 'Codictate'],
  [/\bco(?:\s+|[-–—]\s*)dictate\b/gi, 'Codictate'],
  [/\bkodi\s+dicate\b/gi, 'Codictate'],
  [/\bkodi\s+tat\b/gi, 'Codictate'],
  [/\bkodik\s+tat\b/gi, 'Codictate'],
  [/\bkodig\s+tate\b/gi, 'Codictate'],
  [/\bkodigtate\b/gi, 'Codictate'],
  [/\bkodig\s+tet\b/gi, 'Codictate'],
  [/\bkodigtet\b/gi, 'Codictate'],
  [/\bko\s+digtet\b/gi, 'Codictate'],
  [/\bkodigt\s+tade\b/gi, 'Codictate'],
  [/\bkodigttade\b/gi, 'Codictate'],
  [/\bkodigtede\b/gi, 'Codictate'],
  [/\bkodig\s+tede\b/gi, 'Codictate'],
  [/\bko\s+digtede\b/gi, 'Codictate'],
  [/\bKodak\s+Tech\b/gi, 'Codictate'],
  [/\bKodakTech\b/gi, 'Codictate'],
  [/\bcodec\s+cheat\b/gi, 'Codictate'],
  [/\bcodeccheat\b/gi, 'Codictate'],
  [/\bcodec\s+sheet\b/gi, 'Codictate'],
  [/\bcodecsheet\b/gi, 'Codictate'],
  [/\bcodec\s*t(?:ate|ape)\b/gi, 'Codictate'],
  [/\bcodec\s+tade\b/gi, 'Codictate'],
  [/\bcodectade\b/gi, 'Codictate'],
  [/\bcodexade\b/gi, 'Codictate'],
  [/\bcodex\s+ade\b/gi, 'Codictate'],
  [/\bcode\s+xade\b/gi, 'Codictate'],
  [/\bkodiktat\b/gi, 'Codictate'],
  [/\bkodictate\b/gi, 'Codictate'],
  [/\bcodictate\b/gi, 'Codictate'],
]

export function sanitizeWhisperTranscript(text: string): string {
  let t = text
  for (const [pattern, replacement] of BRAND_TRANSCRIPT_FIXES) {
    t = t.replace(pattern, replacement)
  }
  return t
}
