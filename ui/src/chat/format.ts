// Operator-term wording shared by the conversation's cards (T125; FR-080, FR-082).

import type { FinalChunk, ProgressChunk, Stage, WorkflowStatus } from '../api/stream.ts'

/** Each pipeline stage in the operator's terms, never the worker's name. */
export const STAGE_LABELS: Record<Stage, string> = {
  supervisor: 'Supervisor',
  mapper: 'Interpretation',
  allocator: 'Assignment',
  deployer: 'Deployment',
}

export function stageLabel(stage: Stage): string {
  return STAGE_LABELS[stage] ?? stage
}

const STATUS_WORDS: Record<WorkflowStatus, string> = {
  RECEIVED_REQUEST: 'Request received',
  VALIDATED: 'Validated',
  MAPPED: 'Interpreted',
  ALLOCATED: 'Assigned',
  APPROVED: 'Approved',
  PROVISIONING: 'Provisioning',
  CONFIGURED: 'Configured',
  VERIFIED: 'Verified',
  COMPLETED: 'Completed',
  FAILED: 'Failed',
  STATUS_UNKNOWN: 'Status unknown',
}

/** A workflow status in words (the token itself is never the answer shown). */
export function statusWords(status: WorkflowStatus): string {
  return STATUS_WORDS[status] ?? status
}

const TRACE_HEADER = /Traceback \(most recent call last\)/
const PY_FRAME = /File "[^"]+", line \d+/
const JS_FRAME = /\bat [\w.$<>]+ \([^)]*:\d+:\d+\)|^\s*at \S+:\d+:\d+\s*$/

/** Whether `text` looks like a Python or JavaScript stack trace. */
export function looksLikeTrace(text: string): boolean {
  return TRACE_HEADER.test(text) || PY_FRAME.test(text) || text.split('\n').some((l) => JS_FRAME.test(l))
}

/**
 * The operator-readable part of a reason: when it looks like a stack trace, only its last line
 * that is not a frame, a trace header or indented source (a Python trace's exception line, a
 * JavaScript error's message) — a stack trace never reaches the page.
 */
export function readableReason(reason: string): string {
  const text = reason.trim()
  if (!looksLikeTrace(text)) return text
  const kept = text
    .split('\n')
    .filter((line) => line.trim() !== '')
    .filter((line) => !TRACE_HEADER.test(line) && !PY_FRAME.test(line) && !JS_FRAME.test(line))
    .filter((line) => !/^\s/.test(line))
  const last = kept.length > 0 ? kept[kept.length - 1] : ''
  const cleaned = last
    .replace(TRACE_HEADER, '')
    .replace(new RegExp(PY_FRAME.source, 'g'), '')
    .replace(/\bat [\w.$<>]+ \([^)]*:\d+:\d+\)/g, '')
    .trim()
  return cleaned || 'the stage failed; the full trace is under the correlation id'
}

const ACL_STATEMENT = /Rules are evaluated[\s\S]*$/

/**
 * The access-list statement a first confirmation carries (evaluation order, priority range,
 * unmatched traffic — agents/supervisors/provisioning/prompts/acl-evaluation.md), or null.
 */
export function aclStatement(prompt: string): string | null {
  const match = ACL_STATEMENT.exec(prompt)
  return match ? match[0].trim() : null
}

/** Whether an interpretation payload carries an access list. */
export function payloadHasAcl(payload: Record<string, unknown> | undefined): boolean {
  if (!payload) return false
  const acl = payload.acl
  return acl !== undefined && acl !== null && acl !== false
}

export type Tone = 'success' | 'progress' | 'warning' | 'failure' | 'info'

export function progressView(chunk: ProgressChunk): { tone: Tone; title: string; detail: string } {
  const target = chunk.resource
  switch (chunk.ready) {
    case 'True':
      return { tone: 'success', title: 'Converged', detail: `${target} is ready.` }
    case 'Unknown':
      return {
        tone: 'warning',
        title: 'Readiness unknown',
        detail: `readiness unknown for ${target}: ${chunk.reason ?? 'no reason reported'}`,
      }
    case 'False':
      if (chunk.reason === 'Deleting') {
        return { tone: 'progress', title: 'Removal in progress', detail: `removal in progress: ${target} is being deleted.` }
      }
      return {
        tone: 'progress',
        title: 'In progress',
        detail: `not ready yet: ${chunk.reason ?? 'no reason reported'} (${target})`,
      }
    default:
      return { tone: 'progress', title: statusWords(chunk.status), detail: `${target}` }
  }
}

export function finalView(chunk: FinalChunk): { tone: Tone; title: string; text: string } {
  const message = chunk.message ? readableReason(chunk.message) : ''
  switch (chunk.status) {
    case 'COMPLETED':
      return { tone: 'success', title: 'Completed', text: message || 'The request completed.' }
    case 'PROVISIONING':
      return {
        tone: 'progress',
        title: 'In progress',
        text: message || 'Still in progress: the change has not finished yet.',
      }
    case 'STATUS_UNKNOWN':
      return {
        tone: 'warning',
        title: 'Outcome unknown',
        text: message || 'The outcome could not be observed; ask for the service status.',
      }
    case 'FAILED':
      return {
        tone: 'failure',
        title: /declin/i.test(message) ? 'Declined' : 'Not completed',
        text: message || 'The request did not complete.',
      }
    default:
      return { tone: 'info', title: 'Answer', text: message || statusWords(chunk.status) }
  }
}
