import { Linking, Pressable, StyleSheet, Text, View } from 'react-native'
import { appColors, appFontFamily } from '@/constants/AppColors'
import {
  SectionCard,
  SettingsScroll,
  settingsStyles,
} from '@/components/Settings/settings-shared'

type LicenseEntry = {
  name: string
  copyright: string
  licenseType: string
  licenseUrl: string
  projectUrl: string
  /** Upstream NOTICE file, when the license requires one to be carried. */
  noticeUrl?: string
  /**
   * Verbatim upstream NOTICE text. Apache 2.0 section 4(d) lets a derivative
   * work carry these attributions in a display it generates, which is the path
   * this app takes: the built .ipa ships no NOTICE file, so this screen is
   * where the notice has to be readable.
   */
  noticeBody?: string
  note?: string
}

const s1MiniNoticeBody = `S1-mini-GGUF
Copyright 2026 Superwhisper

GGUF conversions of S1-mini, which is itself a derivative of Qwen3-0.6B,
Copyright 2024 Alibaba Cloud, licensed under the Apache License, Version 2.0.

Any use, distribution, or integration of this model, whether unmodified or
as part of a derivative work or product, must continue to identify it by its
original name, "S1-mini" by "Superwhisper", using that exact capitalization.
This restates the ADDITIONAL TERM of the LICENSE file, which is the
operative text.`

const licenses: LicenseEntry[] = [
  {
    name: 'OpenAI Whisper',
    copyright: 'Copyright (c) 2022 OpenAI',
    licenseType: 'MIT License',
    licenseUrl: 'https://github.com/openai/whisper/blob/main/LICENSE',
    projectUrl: 'https://github.com/openai/whisper',
    note:
      'Whisper is used for on-device speech recognition. ' +
      'Code and model weights are released under the MIT License.',
  },
  {
    name: 'whisper.cpp',
    copyright: 'Copyright (c) 2023-2026 The ggml authors',
    licenseType: 'MIT License',
    licenseUrl: 'https://github.com/ggerganov/whisper.cpp/blob/master/LICENSE',
    projectUrl: 'https://github.com/ggerganov/whisper.cpp',
    note:
      'C/C++ port of OpenAI Whisper. Its ggml inference code runs the Whisper ' +
      'speech models on device, linked through CrispASR.',
  },
  {
    name: 'CrispASR',
    copyright: 'Copyright (c) CrispStrobe',
    licenseType: 'MIT License',
    licenseUrl: 'https://github.com/CrispStrobe/CrispASR/blob/main/LICENSE',
    projectUrl: 'https://github.com/CrispStrobe/CrispASR',
    note:
      'ggml speech recognition runtime, linked as an xcframework. It loads both ' +
      'the Whisper and the Hviske speech models.',
  },
  {
    name: 'hviske-v5-tiny',
    copyright: 'Copyright syvai',
    licenseType: 'CC BY-NC 4.0',
    licenseUrl: 'https://creativecommons.org/licenses/by-nc/4.0/legalcode',
    projectUrl: 'https://huggingface.co/syvai/hviske-v5-tiny',
    note:
      'Danish speech recognition weights by syvai, used for on-device Danish ' +
      'dictation. Codictate downloads a GGUF conversion of the original weights ' +
      'that it mirrors at huggingface.co/emillykkegrann/hviske-v5-tiny-GGUF. ' +
      'Non-commercial use only.',
  },
  {
    name: 'NVIDIA Parakeet TDT v3',
    copyright: 'Copyright NVIDIA Corporation',
    licenseType: 'CC BY 4.0',
    licenseUrl: 'https://creativecommons.org/licenses/by/4.0/legalcode',
    projectUrl: 'https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3',
    note:
      'Parakeet TDT v3 is used for on-device speech recognition on Neural Engine. ' +
      'No modifications were made to the model weights.',
  },
  {
    name: 'FluidAudio',
    copyright: 'Copyright FluidInference',
    licenseType: 'Apache License 2.0',
    licenseUrl:
      'https://github.com/FluidInference/FluidAudio/blob/main/LICENSE',
    projectUrl: 'https://github.com/FluidInference/FluidAudio',
    note: 'Swift SDK for running Parakeet inference on the Apple Neural Engine.',
  },
  {
    name: 'S1-mini by Superwhisper',
    copyright: 'Copyright 2026 Superwhisper',
    licenseType: 'Apache License 2.0 + naming term',
    licenseUrl:
      'https://huggingface.co/superwhisper/s1-mini-GGUF/blob/main/LICENSE',
    projectUrl: 'https://huggingface.co/superwhisper/s1-mini-GGUF',
    noticeUrl:
      'https://huggingface.co/superwhisper/s1-mini-GGUF/blob/main/NOTICE',
    noticeBody: s1MiniNoticeBody,
    note:
      'English text-normalization model used for optional on-device transcript ' +
      'formatting. Distributed under Apache 2.0 with an additional requirement ' +
      'to retain the name “S1-mini” by “Superwhisper”.',
  },
  {
    name: 'llama.cpp',
    copyright: 'Copyright (c) 2023-2026 The ggml authors',
    licenseType: 'MIT License',
    licenseUrl: 'https://github.com/ggml-org/llama.cpp/blob/master/LICENSE',
    projectUrl: 'https://github.com/ggml-org/llama.cpp',
    note: 'On-device inference runtime used to run S1-mini.',
  },
]

const mitLicenseBody = `Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.`

export function ScreenSettingsLicenses() {
  return (
    <SettingsScroll>
      <Text style={settingsStyles.hint}>
        Codictate uses the following open-source software and models. Tap any
        license link to view the full text.
      </Text>

      {licenses.map((entry) => (
        <SectionCard key={entry.name}>
          <Text style={settingsStyles.hubRowTitle}>{entry.name}</Text>

          {entry.note ? <Text style={styles.note}>{entry.note}</Text> : null}

          <Text style={styles.copyright}>{entry.copyright}</Text>

          <View style={styles.linkRow}>
            <Pressable onPress={() => Linking.openURL(entry.licenseUrl)}>
              <Text style={styles.link}>{entry.licenseType}</Text>
            </Pressable>
            <Text style={styles.separator}>|</Text>
            <Pressable onPress={() => Linking.openURL(entry.projectUrl)}>
              <Text style={styles.link}>Project</Text>
            </Pressable>
            {entry.noticeUrl ? (
              <>
                <Text style={styles.separator}>|</Text>
                <Pressable onPress={() => Linking.openURL(entry.noticeUrl!)}>
                  <Text style={styles.link}>NOTICE</Text>
                </Pressable>
              </>
            ) : null}
          </View>

          {entry.licenseType === 'MIT License' ? (
            <Text style={styles.licenseBody}>{mitLicenseBody}</Text>
          ) : null}

          {entry.noticeBody ? (
            <Text style={styles.licenseBody}>{entry.noticeBody}</Text>
          ) : null}
        </SectionCard>
      ))}
    </SettingsScroll>
  )
}

const styles = StyleSheet.create({
  note: {
    fontFamily: appFontFamily.sans,
    fontSize: 13,
    lineHeight: 19,
    color: appColors.foregroundMuted,
  },
  copyright: {
    fontFamily: appFontFamily.sans,
    fontSize: 12,
    lineHeight: 18,
    color: appColors.foregroundSubtle,
  },
  linkRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  link: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    color: '#60A5FA',
  },
  separator: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    color: appColors.foregroundSubtle,
  },
  licenseBody: {
    fontFamily: appFontFamily.sans,
    fontSize: 10,
    lineHeight: 15,
    color: appColors.foregroundSubtle,
    marginTop: 4,
  },
})
