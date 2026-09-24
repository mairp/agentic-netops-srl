// The conversation's state model (T125): an append-only list of entries — what the operator sent,
// each chunk as it arrived, notices and thread dividers. Pure helpers, tested without a DOM.

import type { Chunk } from '../api/stream.ts'
import type { Answer } from './Confirmation.tsx'
import { payloadHasAcl } from './format.ts'

export type Entry =
  | { id: number; kind: 'operator'; text: string }
  | { id: number; kind: 'chunk'; chunk: Chunk }
  | { id: number; kind: 'notice'; text: string; testId: string }
  | { id: number; kind: 'divider' }

/** An entry before it is given its id. */
export type EntryInit = Entry extends infer E ? (E extends Entry ? Omit<E, 'id'> : never) : never

export type Answers = Readonly<Record<number, Answer>>

export const DECLINE_NOTICE = 'Declined — nothing was submitted; you can amend the request.'

/**
 * The confirmation that can be answered now: the latest confirmation request, unanswered, with
 * nothing the operator sent (and no new thread) after it. Null when there is none.
 */
export function openConfirmation(entries: readonly Entry[], answers: Answers): number | null {
  for (let i = entries.length - 1; i >= 0; i -= 1) {
    const entry = entries[i]
    if (entry.kind === 'operator' || entry.kind === 'divider') return null
    if (entry.kind === 'chunk' && entry.chunk.type === 'confirmation_request') {
      return answers[entry.id] === undefined ? entry.id : null
    }
  }
  return null
}

/** Whether the interpretation before entry `index` (on the same thread) carries an access list. */
export function aclBefore(entries: readonly Entry[], index: number): boolean {
  for (let i = index - 1; i >= 0; i -= 1) {
    const entry = entries[i]
    if (entry.kind === 'divider') return false
    if (entry.kind === 'chunk' && entry.chunk.type === 'stage' && entry.chunk.stage === 'mapper') {
      return payloadHasAcl(entry.chunk.payload)
    }
  }
  return false
}
