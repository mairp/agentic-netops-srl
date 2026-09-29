// Which agent the stream is on, derived from the transcript alone (the canvas and the sidebar
// light it while a turn streams). Pure; tested without a DOM.

import type { Stage } from '../api/stream.ts'
import type { Entry } from '../chat/conversation.ts'
import { finalView } from '../chat/format.ts'

export function activeStage(entries: readonly Entry[]): Stage | '' {
  for (let i = entries.length - 1; i >= 0; i -= 1) {
    const entry = entries[i]
    if (entry.kind === 'divider') return ''
    if (entry.kind !== 'chunk') continue
    const chunk = entry.chunk
    if (chunk.type === 'progress') return 'deployer'
    if ('stage' in chunk && chunk.stage) return chunk.stage
  }
  return entries.length ? 'supervisor' : ''
}

/** The canvas heading's workflow state: the last chunk's status, or what the console waits for. */
export function workflowStatus(entries: readonly Entry[], streaming: boolean): string {
  const last = [...entries].reverse().find((e) => e.kind === 'chunk')
  if (!last || last.kind !== 'chunk') return streaming ? 'Agents working' : 'Ready for intent'
  const chunk = last.chunk
  if (chunk.type === 'error') return 'Action required'
  if (chunk.type === 'confirmation_request') return 'Approval requested'
  if (chunk.type === 'final') return finalView(chunk).title.toUpperCase()
  return streaming ? chunk.status.replaceAll('_', ' ') : 'Workflow paused'
}
