import { Image } from 'expo-image'
import { Pressable, Text, View } from 'react-native'
import { appColors } from '@/constants/AppColors'
import {
  MODEL_LABELS,
  MODEL_META,
  MODEL_DESCRIPTIONS,
  SectionCard,
  SettingsScroll,
  settingsStyles as styles,
} from '@/components/Settings/settings-shared'
import { IndeterminateProgressBar } from '@/components/IndeterminateProgressBar'
import { useSharedModelManagement } from '@/hooks/whisper/model-management-context'
import type { useModelManagement } from '@/hooks/whisper/use-model-management'

export function ModelListContent({
  management,
  onSelect,
}: {
  management: ReturnType<typeof useModelManagement>
  onSelect?: () => void
}) {
  const {
    models,
    preferredVariant,
    downloadProgress,
    selectPreferred,
    confirmDownload,
    confirmDelete,
  } = management

  return (
    <>
      {models.map((row) => {
        const label = MODEL_LABELS[row.variant] ?? row.variant
        const active = row.ready && preferredVariant === row.variant
        const progress = downloadProgress[row.variant]
        const isDownloading = progress !== undefined
        const isParakeet = row.variant === 'parakeet'
        const metaLine = isDownloading
          ? isParakeet
            ? 'Downloading…'
            : `Downloading… ${Math.round(progress * 100)}%`
          : row.ready
            ? `${MODEL_META[row.variant] ?? ''}`
            : `${MODEL_META[row.variant] ?? ''}`
        const description = MODEL_DESCRIPTIONS[row.variant]

        return (
          <View key={row.variant} style={styles.modelRow}>
            <Pressable
              onPress={() => {
                selectPreferred(row.variant)
                onSelect?.()
              }}
              disabled={!row.ready || isDownloading}
              style={[
                styles.modelSelectHit,
                row.ready && !isDownloading ? null : styles.modelSelectDisabled,
                active ? styles.modelSelectActive : null,
              ]}
              accessibilityRole="button"
              accessibilityLabel={`Use ${label} for in-app dictation`}
              accessibilityState={{ selected: active, disabled: !row.ready }}
            >
              <View style={styles.modelInfo}>
                <Text style={styles.modelTitle} selectable>
                  {label}
                </Text>
                <Text style={styles.modelMeta} selectable>
                  {metaLine}
                </Text>
                {description ? (
                  <Text style={styles.modelMeta} selectable>
                    {description}
                  </Text>
                ) : null}
              </View>
              {isDownloading ? (
                isParakeet ? (
                  <IndeterminateProgressBar />
                ) : (
                  <View style={styles.progressTrack}>
                    <View
                      style={[
                        styles.progressFill,
                        {
                          width:
                            `${Math.round(progress * 100)}%` as `${number}%`,
                        },
                      ]}
                    />
                  </View>
                )
              ) : null}
            </Pressable>
            <View style={styles.modelCheckWrap}>
              {active ? (
                <Image
                  source="sf:checkmark.circle.fill"
                  style={styles.modelCheckIcon}
                  contentFit="contain"
                  tintColor={appColors.foreground}
                />
              ) : null}
            </View>
            {isDownloading ? null : row.ready ? (
              <Pressable
                onPress={() => confirmDelete(row)}
                style={styles.deleteHit}
                accessibilityLabel={`Delete ${label}`}
                accessibilityRole="button"
              >
                <Text style={styles.deleteLabel} selectable>
                  Delete
                </Text>
              </Pressable>
            ) : (
              <Pressable
                onPress={() => confirmDownload(row.variant)}
                style={styles.deleteHit}
                accessibilityLabel={`Download ${label}`}
                accessibilityRole="button"
              >
                <Text style={styles.downloadLabel} selectable>
                  Download
                </Text>
              </Pressable>
            )}
          </View>
        )
      })}
    </>
  )
}

export function ScreenSettingsModels() {
  const management = useSharedModelManagement()

  return (
    <SettingsScroll>
      <SectionCard>
        <Text style={styles.sectionLabel} selectable>
          Speech models
        </Text>
        <ModelListContent management={management} />
      </SectionCard>
    </SettingsScroll>
  )
}
