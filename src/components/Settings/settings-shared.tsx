import { GlassView, isGlassEffectAPIAvailable } from 'expo-glass-effect'
import type { ReactNode } from 'react'
import { ScrollView, StyleSheet, View } from 'react-native'
import { appColors, appFontFamily, appFontSize } from '@/constants/AppColors'

export const ACTION_BUTTON_SHORTCUT_URL =
  'https://www.icloud.com/shortcuts/376647f0244646a6a181f8ba1fdfe4d1'

export const IOS_SETTINGS_ROOT_URL = 'App-Prefs:'

export const WARM_DURATION_OPTIONS = [
  { label: '1 minute', seconds: 60 },
  { label: '3 minutes', seconds: 180 },
  { label: '5 minutes', seconds: 300 },
  { label: '15 minutes', seconds: 900 },
  { label: '30 minutes', seconds: 1800 },
] as const

export const MODEL_LABELS: Record<string, string> = {
  parakeet: 'Parakeet TDT v3',
  base: 'Whisper Base (Q5_1)',
}

export const MODEL_META: Record<string, string> = {
  parakeet: 'Neural Engine · ~500 MB',
  base: 'CPU fallback · ~57 MB',
}

export const MODEL_SIZE_MB: Record<string, string> = {
  parakeet: '500',
  base: '57',
}

export const KEYBOARD_ENABLE_STEPS =
  'General → Keyboard → Keyboards → Add New Keyboard → Codictate.'

type SettingsScrollProps = {
  children: ReactNode
}

export function SettingsScroll(props: SettingsScrollProps) {
  return (
    <ScrollView
      style={styles.scroll}
      contentInsetAdjustmentBehavior="automatic"
      contentContainerStyle={styles.scrollContent}
      showsVerticalScrollIndicator={false}
    >
      {props.children}
    </ScrollView>
  )
}

export function SectionCard({ children }: { children: ReactNode }) {
  const useGlass = isGlassEffectAPIAvailable()
  if (useGlass) {
    return (
      <GlassView
        glassEffectStyle="regular"
        isInteractive={false}
        style={styles.cardGlass}
      >
        {children}
      </GlassView>
    )
  }
  return <View style={styles.cardFallback}>{children}</View>
}

const styles = StyleSheet.create({
  bold: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    fontWeight: '700',
    color: appColors.foreground,
  },
  scroll: {
    flex: 1,
    backgroundColor: appColors.page,
  },
  scrollContent: {
    paddingHorizontal: 20,
    paddingVertical: 20,
    gap: 20,
    paddingBottom: 40,
  },
  cardGlass: {
    borderRadius: 18,
    borderCurve: 'continuous',
    overflow: 'hidden',
    paddingVertical: 16,
    paddingHorizontal: 18,
    gap: 12,
  },
  cardFallback: {
    borderRadius: 18,
    borderCurve: 'continuous',
    overflow: 'hidden',
    paddingVertical: 16,
    paddingHorizontal: 18,
    gap: 12,
    backgroundColor: 'rgba(255,255,255,0.06)',
    boxShadow: '0 2px 16px rgba(0,0,0,0.35)',
  },
  sectionLabel: {
    fontFamily: appFontFamily.sans,
    fontSize: 12,
    letterSpacing: 1.2,
    textTransform: 'uppercase',
    color: appColors.foregroundSubtle,
  },
  rowPressed: {
    opacity: 0.72,
  },
  shortcutButton: {
    minHeight: 48,
    borderRadius: 16,
    borderCurve: 'continuous',
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 10,
    paddingHorizontal: 16,
    backgroundColor: appColors.foreground,
  },
  shortcutIcon: {
    width: 18,
    height: 18,
  },
  shortcutButtonText: {
    fontFamily: appFontFamily.sans,
    fontSize: 15,
    fontWeight: '700',
    color: '#000000',
  },
  hubRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingVertical: 6,
  },
  hubRowMain: {
    flex: 1,
    gap: 4,
  },
  hubRowTitle: {
    fontFamily: appFontFamily.sans,
    fontSize: appFontSize.body - 5,
    color: appColors.foreground,
  },
  hubRowSubtitle: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    color: appColors.foregroundMuted,
    lineHeight: 20,
  },
  chevron: {
    width: 14,
    height: 14,
    opacity: 0.85,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingVertical: 4,
  },
  rowMain: {
    flex: 1,
    gap: 4,
  },
  rowTitle: {
    fontFamily: appFontFamily.sans,
    fontSize: appFontSize.body - 5,
    color: appColors.foreground,
  },
  rowValue: {
    fontFamily: appFontFamily.sans,
    fontSize: 15,
    color: appColors.foregroundMuted,
  },
  hint: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    lineHeight: 21,
    color: appColors.foregroundMuted,
  },
  subHint: {
    fontFamily: appFontFamily.sans,
    fontSize: 13,
    lineHeight: 19,
    color: appColors.foregroundMuted,
  },
  selectGroup: {
    borderRadius: 12,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  selectRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingVertical: 10,
    paddingHorizontal: 12,
  },
  selectRowActive: {
    backgroundColor: 'rgba(255,255,255,0.08)',
  },
  modelRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingVertical: 2,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: 'rgba(255,255,255,0.12)',
  },
  modelSelectHit: {
    flex: 1,
    minWidth: 0,
    borderRadius: 12,
    paddingVertical: 8,
    paddingHorizontal: 8,
    marginVertical: 2,
  },
  modelSelectDisabled: {
    opacity: 0.62,
  },
  modelSelectActive: {
    backgroundColor: 'rgba(255,255,255,0.08)',
  },
  modelCheckWrap: {
    width: 28,
    alignItems: 'center',
    justifyContent: 'center',
  },
  modelCheckIcon: {
    width: 22,
    height: 22,
  },
  modelInfo: {
    flex: 1,
    gap: 2,
  },
  modelTitle: {
    fontFamily: appFontFamily.sans,
    fontSize: 16,
    color: appColors.foreground,
  },
  modelMeta: {
    fontFamily: appFontFamily.sans,
    fontSize: 13,
    color: appColors.foregroundMuted,
  },
  deleteHit: {
    paddingVertical: 8,
    paddingHorizontal: 12,
  },
  deleteLabel: {
    fontFamily: appFontFamily.sans,
    fontSize: 15,
    fontWeight: '600',
    color: '#F87171',
  },
  downloadLabel: {
    fontFamily: appFontFamily.sans,
    fontSize: 15,
    fontWeight: '600',
    color: appColors.foreground,
  },
  progressTrack: {
    height: 3,
    borderRadius: 2,
    backgroundColor: 'rgba(255,255,255,0.12)',
    overflow: 'hidden',
    marginTop: 6,
  },
  progressFill: {
    height: 3,
    borderRadius: 2,
    backgroundColor: appColors.foreground,
  },
})

export const settingsStyles = styles
