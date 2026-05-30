import { useCallback, useEffect, useRef, useState } from 'react'
import { AppState } from 'react-native'
import { useFocusEffect } from 'expo-router'
import * as Haptics from 'expo-haptics'
import {
  isKeyboardWarmSessionActive,
  endKeyboardWarmSession,
} from 'codictate-dictation'

export function useWarmSession() {
  const [isActive, setIsActive] = useState(false)
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null)

  const poll = useCallback(() => {
    void isKeyboardWarmSessionActive().then(setIsActive)
  }, [])

  useFocusEffect(
    useCallback(() => {
      poll()
      intervalRef.current = setInterval(poll, 5000)
      return () => {
        if (intervalRef.current) clearInterval(intervalRef.current)
      }
    }, [poll])
  )

  useEffect(() => {
    const sub = AppState.addEventListener('change', (state) => {
      if (state === 'active') poll()
    })
    return () => sub.remove()
  }, [poll])

  const end = useCallback(async () => {
    await endKeyboardWarmSession()
    setIsActive(false)
    await Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success)
  }, [])

  return { isActive, end, refresh: poll }
}
