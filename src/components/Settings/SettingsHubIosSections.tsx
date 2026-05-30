import { useFocusEffect } from 'expo-router'
import * as Haptics from 'expo-haptics'
import { Image } from 'expo-image'
import { useCallback, useState } from 'react'
import { Alert, Linking, Pressable, Text, View } from 'react-native'
import { appColors } from '@/constants/AppColors'
import {
  getKeyboardWarmDuration,
  setKeyboardWarmDuration,
} from 'codictate-dictation'
import { useWarmSession } from '@/hooks/whisper/use-warm-session'
import {
  ACTION_BUTTON_SHORTCUT_URL,
  IOS_SETTINGS_ROOT_URL,
  KEYBOARD_ENABLE_STEPS,
  SectionCard,
  settingsStyles as styles,
  WARM_DURATION_OPTIONS,
} from '@/components/Settings/settings-shared'

export function SettingsHubActionButtonSection() {
  const openActionButtonShortcut = async () => {
    await Haptics.selectionAsync()
    const canOpen = await Linking.canOpenURL(ACTION_BUTTON_SHORTCUT_URL)
    if (!canOpen) {
      Alert.alert(
        'Unable to open Shortcut',
        'Open the Shortcuts app and add the Codictate Dictation shortcut manually.'
      )
      return
    }
    await Linking.openURL(ACTION_BUTTON_SHORTCUT_URL)
  }

  return (
    <SectionCard>
      <Text style={styles.hint} selectable>
        When shortcut has been added. Use it as the action button shortcut.
      </Text>
      <Pressable
        onPress={() => void openActionButtonShortcut()}
        style={({ pressed }) => [
          styles.shortcutButton,
          pressed ? styles.rowPressed : null,
        ]}
        accessibilityRole="button"
        accessibilityLabel="Add Codictate Action Button shortcut"
      >
        <Image
          source="sf:square.and.arrow.down"
          style={styles.shortcutIcon}
          contentFit="contain"
          tintColor="#000000"
        />
        <Text style={styles.shortcutButtonText}>
          Add Action Button Shortcut
        </Text>
      </Pressable>
    </SectionCard>
  )
}

export function SettingsHubKeyboardSection() {
  const openIosSettings = async () => {
    await Haptics.selectionAsync()
    try {
      await Linking.openURL(IOS_SETTINGS_ROOT_URL)
    } catch {
      Alert.alert(
        'Unable to open Settings',
        `Open the Settings app manually. ${KEYBOARD_ENABLE_STEPS}`
      )
    }
  }

  return (
    <SectionCard>
      <Text style={styles.sectionLabel} selectable>
        Dictation keyboard
      </Text>
      <Text style={styles.hint} selectable>
        Opens the Settings app.{'\n'}
        <Text style={styles.bold} selectable>
          {KEYBOARD_ENABLE_STEPS}
        </Text>
      </Text>
      <Pressable
        onPress={() => void openIosSettings()}
        style={({ pressed }) => [
          styles.shortcutButton,
          pressed ? styles.rowPressed : null,
        ]}
        accessibilityRole="button"
        accessibilityLabel="Open Settings app"
      >
        <Image
          source="sf:keyboard"
          style={styles.shortcutIcon}
          contentFit="contain"
          tintColor="#000000"
        />
        <Text style={styles.shortcutButtonText}>Open Settings</Text>
      </Pressable>
    </SectionCard>
  )
}

export function SettingsHubWarmSessionSection() {
  const warmSession = useWarmSession()
  const [warmDurationSeconds, setWarmDurationSeconds] = useState(60)

  useFocusEffect(
    useCallback(() => {
      void getKeyboardWarmDuration().then(setWarmDurationSeconds)
    }, [])
  )

  return (
    <SectionCard>
      <Text style={styles.sectionLabel} selectable>
        Keyboard warm session
      </Text>
      <Text style={styles.subHint} selectable>
        How long the mic stays ready after a keyboard dictation.
      </Text>
      <View style={styles.selectGroup}>
        {WARM_DURATION_OPTIONS.map((option) => {
          const selected = warmDurationSeconds === option.seconds
          return (
            <Pressable
              key={option.seconds}
              onPress={() => {
                void (async () => {
                  await setKeyboardWarmDuration(option.seconds)
                  setWarmDurationSeconds(option.seconds)
                  await Haptics.selectionAsync()
                })()
              }}
              style={[
                styles.selectRow,
                selected ? styles.selectRowActive : null,
              ]}
              accessibilityRole="button"
              accessibilityState={{ selected }}
            >
              <Text style={styles.rowTitle} selectable>
                {option.label}
              </Text>
              {selected ? (
                <Image
                  source="sf:checkmark.circle.fill"
                  style={styles.modelCheckIcon}
                  contentFit="contain"
                  tintColor={appColors.foreground}
                />
              ) : null}
            </Pressable>
          )
        })}
      </View>
      {warmSession.isActive ? (
        <Pressable
          onPress={() => void warmSession.end()}
          style={({ pressed }) => [
            styles.shortcutButton,
            pressed ? styles.rowPressed : null,
          ]}
          accessibilityRole="button"
          accessibilityLabel="End keyboard session"
        >
          <Image
            source="sf:xmark.circle"
            style={styles.shortcutIcon}
            contentFit="contain"
            tintColor="#000000"
          />
          <Text style={styles.shortcutButtonText}>End keyboard session</Text>
        </Pressable>
      ) : null}
    </SectionCard>
  )
}
