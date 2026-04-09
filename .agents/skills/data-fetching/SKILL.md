---
name: data-fetching
description: Data fetching and sending patterns using native fetch and React Query. Use this skill whenever the user asks to fetch data, load data from an API, send data to the backend, create API calls, integrate with a backend, make HTTP requests, implement data loading, or build features that read/write data to/from a server. Covers useQuery for GET requests and useMutation for POST, PUT, PATCH, DELETE.
---

# Data Fetching with Fetch + React Query

This skill guides implementing data fetching and mutations in TypeScript/React using native `fetch` and `@tanstack/react-query`. Always use React Query for client-side data — do not use raw `useEffect` + `useState` for API calls.

## Core Stack

- **HTTP client**: Native `fetch` only (no axios or other libraries).
- **State management**: `@tanstack/react-query` for all GET and mutation operations.
- **Imports**: `useQuery`, `useMutation`, `useQueryClient` from `@tanstack/react-query`.

## Fetching Data (useQuery)

Use `useQuery` for GET requests. It handles loading, error, caching, and refetching.

```tsx
const { data, isLoading, error } = useQuery({
  queryKey: ['resource', id],  // Unique key; include IDs/variables
  queryFn: async () => {
    const res = await fetch(`${APP_CONFIG.backendUrl}/resource/${id}`)
    if (!res.ok) throw new Error('Failed to fetch')
    return res.json()
  },
  enabled: !!id,  // Optional: only run when id is truthy
})
```

**Query keys**: Use arrays. Include resource type and identifiers: `['tournament', id]`, `['clubs']`, `['division', divisionId]`. Use for cache invalidation.

**Error handling**: Throw from `queryFn` on non-ok responses. React Query surfaces `error` and `isError`.

**Stale data**: Use `keepPreviousData` when paginating to avoid UI flicker:
```tsx
import { keepPreviousData } from '@tanstack/react-query'

useQuery({
  queryKey: ['items', page],
  queryFn: () => fetch(...).then(r => r.json()),
  placeholderData: keepPreviousData,
})
```

## Sending Data (useMutation)

Use `useMutation` for POST, PUT, PATCH, DELETE.

```tsx
const queryClient = useQueryClient()
const { mutate, isPending, isSuccess, isError, error } = useMutation({
  mutationFn: async (payload: CreatePayload) => {
    const res = await fetch(`${APP_CONFIG.backendUrl}/resource`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
    const data = await res.json()
    if (!res.ok || !data.ok) throw new Error(data.error || 'Request failed')
    return data
  },
  onSuccess: () => {
    queryClient.invalidateQueries({ queryKey: ['resource'] })
  },
})

// Call: mutate(payload)
```

**Invalidation**: After successful mutations, invalidate related queries so UI stays fresh:
```tsx
onSuccess: () => {
  queryClient.invalidateQueries({ queryKey: ['resource'] })
  // or more specific: queryClient.invalidateQueries({ queryKey: ['resource', id] })
}
```

**Reset**: Use `reset()` after success to clear error/success state when closing modals.

## Authenticated Requests

For endpoints requiring auth, use Clerk's `useAuth().getToken()` inside the queryFn/mutationFn. Throw early if no token.

**Authorized query**:
```tsx
const { getToken } = useAuth()

const { data: club } = useQuery<Club | null>({
  queryKey: ['club', organization?.id],
  queryFn: async () => {
    const token = await getToken()
    if (!token || !organization?.id) throw new Error('No authentication')

    const options = {
      method: 'GET',
      headers: {
        Authorization: `Bearer ${token}`,
      },
    }
    const response = await fetch(
      `${APP_CONFIG.backendUrl}/club/org-id/${organization?.id}`,
      options
    )
    return response.json()
  },
  enabled: !!organization?.id,
})
```

**Authorized mutation**:
```tsx
const { getToken } = useAuth()

const { mutate, isPending } = useMutation<{ url?: string }, Error, CreatePayload>({
  mutationFn: async ({ priceId, productType }) => {
    const token = await getToken()
    if (!token) throw new Error('No authentication token')

    const options = {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ priceId, productType }),
    }

    const res = await fetch(
      `${APP_CONFIG.backendUrl}/stripe/create-checkout-session`,
      options
    )

    const data = await res.json()
    if (!res.ok) throw new Error(data.error || 'Request failed')
    return data
  },
})
```

## Other Patterns

**Base URL**: Use `APP_CONFIG.backendUrl` for API root.

**Typed responses**: Always type the generic:
```tsx
useQuery<TournamentResponse>({
  queryKey: ['tournament', id],
  queryFn: async () => {
    const res = await fetch(...)
    return res.json()
  },
})
```

## Component Usage

- Add `'use client'` at the top when using hooks in Next.js App Router.
- Avoid `useState` for data that comes from the server — use query/mutation state instead.
- Handle loading and error states in the UI:
```tsx
if (isLoading) return <Spinner />
if (error) return <div>Error: {error.message}</div>
```

## Quick Reference

| Task              | Hook          | Method  |
|-------------------|---------------|---------|
| Load list/detail  | useQuery      | GET     |
| Create            | useMutation   | POST    |
| Update            | useMutation   | PUT/PATCH |
| Delete            | useMutation   | DELETE  |

Always pair mutations with appropriate `queryClient.invalidateQueries` in `onSuccess`.
