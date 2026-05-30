import { createContext, useContext, type ReactNode } from 'react'
import { useModelManagement } from './use-model-management'

type ModelManagementValue = ReturnType<typeof useModelManagement>

const ModelManagementCtx = createContext<ModelManagementValue | null>(null)

export function ModelManagementProvider({ children }: { children: ReactNode }) {
  const management = useModelManagement()
  return (
    <ModelManagementCtx.Provider value={management}>
      {children}
    </ModelManagementCtx.Provider>
  )
}

export function useSharedModelManagement(): ModelManagementValue {
  const ctx = useContext(ModelManagementCtx)
  if (!ctx)
    throw new Error(
      'useSharedModelManagement must be used within ModelManagementProvider'
    )
  return ctx
}
