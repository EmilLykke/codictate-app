---
name: expo-glass-effect
description: Complete guide for using expo-glass-effect (GlassView, GlassContainer) to create native iOS liquid glass UI. Use when building glass cards, frosted buttons, translucent overlays, animated glass transitions, or any component using GlassView or GlassContainer.
---

# expo-glass-effect

Native iOS liquid glass via `UIVisualEffectView`. Only renders on iOS 26+; falls back to a plain `View` on unsupported platforms.

## Import

```tsx
import {
  GlassView,
  GlassContainer,
  isLiquidGlassAvailable,
  isGlassEffectAPIAvailable,
} from 'expo-glass-effect'
```

## GlassView

```tsx
<GlassView
  style={{ borderRadius: 20, padding: 20, overflow: 'hidden' }}
  glassEffectStyle="regular"   // 'regular' | 'clear' | 'none'
  isInteractive={false}        // true for buttons/pressables
  colorScheme="auto"           // 'auto' | 'light' | 'dark'
  tintColor="#15E6D4"          // optional tint
>
  <Text>Content</Text>
</GlassView>
```

**Always set `overflow: 'hidden'` when using `borderRadius`.**

### glassEffectStyle values

| Value | Use case |
|-------|----------|
| `'regular'` | Default — medium opacity, adapts to surroundings |
| `'clear'` | Higher transparency, for media-rich backgrounds |
| `'none'` | Hidden (use instead of `opacity: 0` — see below) |

### Interactive glass (buttons)

Use `isInteractive` + `Pressable` inside for the correct native feel:

```tsx
<GlassView isInteractive style={{ borderRadius: 50, overflow: 'hidden' }}>
  <Pressable style={{ paddingVertical: 12, paddingHorizontal: 24, alignItems: 'center' }} onPress={handlePress}>
    <Text style={{ color: PlatformColor('label'), fontWeight: '600' }}>Action</Text>
  </Pressable>
</GlassView>
```

Use `PlatformColor('label')` / `PlatformColor('secondaryLabel')` for text inside GlassView — it adapts correctly to whatever content shows through the glass.

### Glass card pattern

```tsx
<GlassView style={{ borderRadius: 22, borderCurve: 'continuous', padding: 20, overflow: 'hidden' }}>
  <Text style={{ color: PlatformColor('secondaryLabel'), fontSize: 11, letterSpacing: 1.5 }}>
    LABEL
  </Text>
  <Text style={{ color: PlatformColor('label'), fontSize: 44, fontWeight: '800' }}>
    Value
  </Text>
</GlassView>
```

## GlassContainer

Merges multiple `GlassView` children into a single combined glass effect. The `spacing` prop controls the distance at which elements start influencing each other.

```tsx
<GlassContainer spacing={10} style={{ flexDirection: 'row', gap: 8 }}>
  <GlassView style={{ width: 60, height: 60, borderRadius: 30 }} isInteractive />
  <GlassView style={{ width: 50, height: 50, borderRadius: 25 }} />
</GlassContainer>
```

## Animating glass

### Built-in animation (preferred)

Use the `animate` config object on `glassEffectStyle` — **never change `opacity`** to show/hide glass:

```tsx
<GlassView
  glassEffectStyle={{
    style: visible ? 'regular' : 'none',
    animate: true,
    animationDuration: 0.4,  // seconds
  }}
/>
```

### Opacity animation workaround

If you must animate opacity, use Reanimated on a wrapper view and toggle `glassEffectStyle` in `useAnimatedProps`:

```tsx
import Animated, { useAnimatedProps, useAnimatedStyle, useSharedValue, withTiming } from 'react-native-reanimated'
const AnimatedGlassView = Animated.createAnimatedComponent(GlassView)

const fadeOpacity = useSharedValue(0)

const glassProps = useAnimatedProps(() => ({
  glassEffectStyle: fadeOpacity.value > 0.01 ? 'regular' : 'none',
}))

const wrapperStyle = useAnimatedStyle(() => ({
  opacity: fadeOpacity.value,
}))

// Render:
<Animated.View style={[wrapperStyle, { borderRadius: 20, overflow: 'hidden' }]}>
  <AnimatedGlassView animatedProps={glassProps} style={{ ...StyleSheet.absoluteFill }} />
</Animated.View>
```

**Never set `opacity: 0` directly on `GlassView` or any parent — it breaks the glass effect entirely.**

## Availability checks

```tsx
import { isLiquidGlassAvailable, isGlassEffectAPIAvailable } from 'expo-glass-effect'

// Check before rendering GlassView to avoid crashes on iOS 26 betas
if (isGlassEffectAPIAvailable()) {
  // safe to use GlassView
}

// Check if the full liquid glass design system is active
if (isLiquidGlassAvailable()) {
  // liquid glass components available
}
```

### Fallback pattern

```tsx
import { GlassView, isLiquidGlassAvailable } from 'expo-glass-effect'
import { BlurView } from 'expo-blur'

const AdaptiveGlass: React.FC<{ style?: ViewStyle; children?: React.ReactNode }> = ({ style, children }) => {
  if (isLiquidGlassAvailable()) {
    return <GlassView style={[{ overflow: 'hidden' }, style]}>{children}</GlassView>
  }
  return (
    <BlurView tint="systemMaterial" intensity={80} style={[{ overflow: 'hidden' }, style]}>
      {children}
    </BlurView>
  )
}
```

## Key rules

- `overflow: 'hidden'` is required for `borderRadius` clipping
- Use `PlatformColor('label')` for text — not hardcoded colors
- Use `isInteractive` on any GlassView that wraps a pressable
- Animate via `glassEffectStyle.animate`, never via `opacity`
- Only available iOS 26+ — always provide a fallback or check `isLiquidGlassAvailable()`
- Do not nest GlassViews inside each other (use `GlassContainer` instead for merging)
