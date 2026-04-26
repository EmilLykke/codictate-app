import { Image } from 'expo-image'
import {
  InputAccessoryView,
  Keyboard,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native'
import type {
  NativeSyntheticEvent,
  TextInputSelectionChangeEventData,
} from 'react-native'
import { appColors, appFontFamily, appFontSize } from '@/constants/AppColors'

const INPUT_ACCESSORY_ID = 'dictation-composer'

type TextSelection = {
  start: number
  end: number
}

type CardDictationComposerProps = {
  value: string
  selection: TextSelection
  onChangeText: (text: string) => void
  onSelectionChange: (
    event: NativeSyntheticEvent<TextInputSelectionChangeEventData>
  ) => void
  onCopyPress: () => void
  onSharePress: () => void
  onClearPress: () => void
}

export function CardDictationComposer(props: CardDictationComposerProps) {
  const {
    value,
    selection,
    onChangeText,
    onSelectionChange,
    onCopyPress,
    onSharePress,
    onClearPress,
  } = props

  return (
    <>
      <View style={styles.card}>
        <TextInput
          multiline
          value={value}
          selection={selection}
          onChangeText={onChangeText}
          onSelectionChange={onSelectionChange}
          placeholder="Dictate or type…"
          placeholderTextColor={appColors.foregroundSubtle}
          selectionColor="rgba(255,255,255,0.9)"
          style={styles.input}
          textAlignVertical="top"
          autoCorrect
          inputAccessoryViewID={INPUT_ACCESSORY_ID}
        />

        <View style={styles.actions}>
          <ActionButton
            icon="sf:doc.on.doc"
            label="Copy"
            onPress={onCopyPress}
            tintColor="rgba(255,255,255,0.72)"
          />
          <ActionButton
            icon="sf:square.and.arrow.up"
            label="Share"
            onPress={onSharePress}
            tintColor="rgba(255,255,255,0.72)"
          />
          <ActionButton
            icon="sf:trash"
            label="Clear"
            onPress={onClearPress}
            tintColor="rgba(255,255,255,0.52)"
          />
        </View>
      </View>

      <InputAccessoryView nativeID={INPUT_ACCESSORY_ID}>
        <View style={styles.accessoryBar}>
          <Pressable
            onPress={Keyboard.dismiss}
            style={styles.doneButton}
            hitSlop={8}
          >
            <Text style={styles.doneLabel}>Done</Text>
          </Pressable>
        </View>
      </InputAccessoryView>
    </>
  )
}

type ActionButtonProps = {
  icon: string
  label: string
  onPress: () => void
  tintColor: string
}

function ActionButton(props: ActionButtonProps) {
  const { icon, label, onPress, tintColor } = props

  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [
        styles.actionButton,
        pressed && styles.actionButtonPressed,
      ]}
    >
      <Image
        source={icon}
        style={styles.actionIcon}
        contentFit="contain"
        tintColor={tintColor}
      />
      <Text style={styles.actionLabel} selectable>
        {label}
      </Text>
    </Pressable>
  )
}

export type { TextSelection }

const styles = StyleSheet.create({
  card: {
    flex: 1,
    minHeight: 0,
    width: '100%',
    maxWidth: 368,
    alignSelf: 'center',
    backgroundColor: appColors.paper,
    borderRadius: 22,
    borderCurve: 'continuous',
    paddingTop: 16,
    paddingHorizontal: 16,
    paddingBottom: 14,
    gap: 14,
    boxShadow: '0 8px 28px rgba(0, 0, 0, 0.32)',
  },
  input: {
    flex: 1,
    minHeight: 220,
    color: appColors.foreground,
    fontFamily: appFontFamily.sans,
    fontSize: appFontSize.body - 2,
    lineHeight: 29,
    padding: 0,
  },
  actions: {
    flexDirection: 'row',
    gap: 10,
  },
  actionButton: {
    flex: 1,
    minHeight: 44,
    borderRadius: 14,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(255,255,255,0.08)',
    alignItems: 'center',
    justifyContent: 'center',
    flexDirection: 'row',
    gap: 7,
  },
  actionButtonPressed: {
    backgroundColor: 'rgba(255,255,255,0.14)',
  },
  actionIcon: {
    width: 16,
    height: 16,
  },
  actionLabel: {
    fontFamily: appFontFamily.sans,
    fontSize: 14,
    color: appColors.foregroundMuted,
  },
  accessoryBar: {
    backgroundColor: '#1c1c1e',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: 'rgba(255,255,255,0.1)',
    paddingHorizontal: 16,
    paddingVertical: 8,
    flexDirection: 'row',
    justifyContent: 'flex-end',
    alignItems: 'center',
  },
  doneButton: {
    paddingHorizontal: 4,
    paddingVertical: 4,
  },
  doneLabel: {
    fontFamily: appFontFamily.sans,
    fontSize: 17,
    fontWeight: '600',
    color: '#0A84FF',
  },
})
