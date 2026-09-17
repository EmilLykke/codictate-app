import { Image } from 'expo-image'
import { Pressable, Text, View } from 'react-native'
import { appColors } from '@/constants/AppColors'
import {
  FORMATTING_CONTEXTS,
  FORMATTING_MODELS,
  FORMATTING_STYLES,
} from '@/constants/formatting'
import { useFormattingSettings } from '@/hooks/settings/use-formatting-settings'
import {
  SectionCard,
  SettingsScroll,
  settingsStyles as styles,
} from '@/components/Settings/settings-shared'

type FormattingSettings = ReturnType<typeof useFormattingSettings>

type TileOption<T extends string> = {
  value: T
  label: string
  description: string
  preview: string
}

/**
 * One choice with the sentence it produces, so Style and Context explain
 * themselves without a trip to the docs (same shape as the desktop tiles).
 */
function TileGroup<T extends string>({
  options,
  selected,
  onSelect,
}: {
  options: readonly TileOption<T>[]
  selected: T
  onSelect: (value: T) => void
}) {
  return (
    <View style={styles.tileGroup}>
      {options.map((option) => {
        const isSelected = option.value === selected
        return (
          <Pressable
            key={option.value}
            onPress={() => onSelect(option.value)}
            style={[styles.tile, isSelected ? styles.tileActive : null]}
            accessibilityRole="button"
            accessibilityLabel={`${option.label}: ${option.description}`}
            accessibilityState={{ selected: isSelected }}
          >
            <View style={styles.tileHeader}>
              <View style={styles.tileHeaderMain}>
                <Text style={styles.tileLabel} selectable>
                  {option.label}
                </Text>
                <Text style={styles.tileDescription} selectable>
                  {option.description}
                </Text>
              </View>
              {isSelected ? (
                <Image
                  source="sf:checkmark.circle.fill"
                  style={styles.modelCheckIcon}
                  contentFit="contain"
                  tintColor={appColors.foreground}
                />
              ) : null}
            </View>
            <View style={styles.tilePreviewWrap}>
              <Text style={styles.tilePreview} selectable>
                {option.preview}
              </Text>
            </View>
          </Pressable>
        )
      })}
    </View>
  )
}

function FormattingModelSection({
  settings,
}: {
  settings: FormattingSettings
}) {
  return (
    <SectionCard>
      <Text style={styles.sectionLabel} selectable>
        Model
      </Text>
      {FORMATTING_MODELS.map((option) => {
        const isS1Mini = option.value === 's1-mini'
        const isReady = settings.status?.ready === true
        const isDownloading = settings.downloadProgress !== null
        const isSelected = settings.model === option.value

        return (
          <View key={option.value} style={styles.modelRow}>
            <Pressable
              onPress={() => settings.chooseModel(option.value)}
              disabled={isS1Mini && !isReady}
              style={[
                styles.modelSelectHit,
                isS1Mini && !isReady ? styles.modelSelectDisabled : null,
                isSelected ? styles.modelSelectActive : null,
              ]}
              accessibilityRole="button"
              accessibilityState={{
                selected: isSelected,
                disabled: isS1Mini && !isReady,
              }}
            >
              <Text style={styles.modelTitle} selectable>
                {option.label}
              </Text>
              <Text style={styles.modelMeta} selectable>
                {isS1Mini && isDownloading
                  ? `Downloading… ${Math.round(
                      (settings.downloadProgress ?? 0) * 100
                    )}%`
                  : option.description}
              </Text>
              {isS1Mini && isDownloading ? (
                <View style={styles.progressTrack}>
                  <View
                    style={[
                      styles.progressFill,
                      {
                        width: `${Math.round(
                          (settings.downloadProgress ?? 0) * 100
                        )}%` as `${number}%`,
                      },
                    ]}
                  />
                </View>
              ) : null}
            </Pressable>
            <View style={styles.modelCheckWrap}>
              {isSelected ? (
                <Image
                  source="sf:checkmark.circle.fill"
                  style={styles.modelCheckIcon}
                  contentFit="contain"
                  tintColor={appColors.foreground}
                />
              ) : null}
            </View>
            {isS1Mini && !isDownloading ? (
              <Pressable
                onPress={
                  isReady ? settings.confirmDelete : settings.confirmDownload
                }
                style={styles.deleteHit}
                accessibilityRole="button"
              >
                <Text
                  style={isReady ? styles.deleteLabel : styles.downloadLabel}
                >
                  {isReady ? 'Delete' : 'Download'}
                </Text>
              </Pressable>
            ) : null}
          </View>
        )
      })}
    </SectionCard>
  )
}

/** Shared by the Settings screen and the home-screen Formatting sheet. */
export function FormattingPickerContent({
  settings,
}: {
  settings: FormattingSettings
}) {
  const isOff = settings.model === 'off'

  return (
    <>
      <Text style={styles.hint} selectable>
        Formatting rewrites the transcript on device: punctuation, casing and
        filler words. English only. If it cannot run or fails, Codictate keeps
        the raw transcript.
      </Text>

      <FormattingModelSection settings={settings} />

      <SectionCard>
        <Text style={styles.sectionLabel} selectable>
          Style
        </Text>
        <Text style={styles.subHint} selectable>
          {isOff ? ' Applies once a formatting model is on.' : ''}
        </Text>
        <TileGroup
          options={FORMATTING_STYLES}
          selected={settings.style}
          onSelect={settings.chooseStyle}
        />
      </SectionCard>

      <SectionCard>
        <Text style={styles.sectionLabel} selectable>
          Context
        </Text>
        <Text style={styles.subHint} selectable>
          What you are writing, so the shape of the text fits it.
          {isOff ? ' Applies once a formatting model is on.' : ''}
        </Text>
        <TileGroup
          options={FORMATTING_CONTEXTS}
          selected={settings.context}
          onSelect={settings.chooseContext}
        />
      </SectionCard>
    </>
  )
}

export function ScreenSettingsFormatting() {
  const settings = useFormattingSettings()

  return (
    <SettingsScroll>
      <FormattingPickerContent settings={settings} />
    </SettingsScroll>
  )
}
