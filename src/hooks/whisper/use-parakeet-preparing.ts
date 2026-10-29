import { isParakeetPreparing, onParakeetPreparing } from 'codictate-dictation'
import { useEffect, useState } from 'react'
import { AppState } from 'react-native'

/**
 * Whether the Host is preparing Parakeet after an app update. The Host only
 * reports it once the load has run for more than about 1 s, so a quick load
 * never flashes on screen.
 */
export function useParakeetPreparing(): boolean {
  const [preparing, setPreparing] = useState(isParakeetPreparing)

  useEffect(() => {
    const sub = onParakeetPreparing((event) => setPreparing(event.preparing))
    // An event sent between render and subscribe is lost, so re-read now.
    setPreparing(isParakeetPreparing())
    const appStateSub = AppState.addEventListener('change', (next) => {
      if (next === 'active') setPreparing(isParakeetPreparing())
    })
    return () => {
      sub.remove()
      appStateSub.remove()
    }
  }, [])

  return preparing
}
