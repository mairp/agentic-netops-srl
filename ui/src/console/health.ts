// The runtime readiness the console header, sidebar and canvas show (GET /api/v1/health; no
// credential — contracts/supervisor-http.md): the transport name and each worker's state, polled
// every 15 s. Ported from the predecessor's operator console (agentic-netops ui/src/App.tsx).

import { useEffect, useState } from 'react'
import { API_BASE } from '../auth/credentials.ts'

export interface HealthState {
  status: 'checking' | 'ok' | 'degraded' | 'offline'
  transport: string
  workers: Record<string, string>
}

export function useIntentHealth(): HealthState {
  const [health, setHealth] = useState<HealthState>({ status: 'checking', transport: 'SLIM', workers: {} })

  useEffect(() => {
    let active = true
    const refresh = async () => {
      try {
        const response = await fetch(`${API_BASE}/v1/health`)
        const body = (await response.json()) as { status?: unknown; transport?: unknown; workers?: unknown }
        if (!active) return
        const workers =
          body.workers && typeof body.workers === 'object' ? (body.workers as Record<string, string>) : {}
        setHealth({
          status: body.status === 'ok' ? 'ok' : 'degraded',
          transport: String(body.transport || 'SLIM').toUpperCase(),
          workers,
        })
      } catch {
        if (active) setHealth((current) => ({ ...current, status: 'offline' }))
      }
    }
    void refresh()
    const timer = window.setInterval(refresh, 15_000)
    return () => {
      active = false
      window.clearInterval(timer)
    }
  }, [])

  return health
}
