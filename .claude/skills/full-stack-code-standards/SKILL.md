---
name: full-stack-code-standards
description: Applies TypeScript/React naming, file layout, performance, and UI conventions for web and mobile (Expo). Use when writing or reviewing app code, structuring features, or when the user asks for project style, file organization, or production-quality UI.
---

# Full-stack code standards (web + mobile)

## Response habit

After finishing edits, give a **10-line summary max** of what changed (no more than ten lines).

## Code style

- Concise technical TypeScript; functional and declarative patterns; **no classes**.
- Prefer iteration and small modules over duplication.
- Names: auxiliary verbs (`isLoading`, `hasError`).

## Naming

| Kind | Convention |
|------|------------|
| Directories (non-components) | kebab-case |
| Variables, functions | camelCase |
| Components + component filenames | PascalCase |
| Other filenames | kebab-case |
| Component files | Prefix by type: `ButtonAccount.tsx`, `CardAnalyticsMain.tsx` |

## Layout (never flat dumps)

Group by **domain/feature** in subfolders.

**Components** — PascalCase folder + PascalCase file:

- `components/Dashboard/UserProfile.tsx`
- `components/Auth/LoginForm.tsx`

**Utils** — kebab-case folder + kebab-case file:

- `utils/name-formatter/fullname.ts`
- `utils/currency-formatter/format-price.ts`

**Types** — kebab-case folder + kebab-case file:

- `types/user-types/profile.ts`
- `types/api-types/error.ts`

- One responsibility per file; split into a sibling file in the same folder if it grows.

## Syntax

- Declarative TSX.
- **Helpers**: below the main component, **above** the default export.

## UI

- Use other project skills when relevant (Expo UI, data fetching, etc.).
- Production polish: spacing, typography, hierarchy; **mobile-first** responsive; platform-native conventions where it matters.
- Avoid generic or cookie-cutter UI.

## Performance

- Prefer server rendering and server components on web where the stack allows; minimize unnecessary client code.
- Memoize when it measurably cuts re-renders; lazy-load non-critical UI.
- Images: WebP on web where appropriate; correct formats on mobile; dimensions + lazy loading.
- Target Web Vitals on web; frame rate and memory on mobile.

## Client vs server

- Isolate **platform API** usage in small client-only components.
- Prefer server for data fetching and global state when the stack supports it.
- Client fetching: **@tanstack/react-query** when client-side fetch is required.
- **Web**: add the framework’s client directive (e.g. Next.js `use client`) on files that use client-only hooks.
- **Mobile (Expo/RN)**: prefer native/platform APIs for perf-sensitive paths over heavy third-party abstractions.
