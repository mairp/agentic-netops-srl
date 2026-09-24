// The NDJSON client of POST /agent/prompt/stream (T124; FR-052, FR-081, FR-102;
// contracts/supervisor-http.md; chunk models agents/common/schemas/stream.py).
//
// The browser calls the same-origin proxy (/api/<route>, ui/server.mjs), sends the operator's
// Basic header and a body of {prompt, thread_id?} — never a principal: the principal is the
// authenticated username. Chunks are read incrementally as they arrive and validated into a typed
// union. A progress chunk's `ready` is the Ready condition's status string "True" | "False" |
// "Unknown" with its reason, and is NEVER coerced to a boolean: any other value (a boolean
// included) is a protocol error, surfaced as a client-side error chunk.

import {
  API_BASE,
  authorizationHeader,
  clearCredentials,
  type FetchLike,
} from '../auth/credentials.ts'

export type Stage = 'supervisor' | 'mapper' | 'allocator' | 'deployer'
export type Ready = 'True' | 'False' | 'Unknown'
export type OutOfBand = 'modified' | 'deleted'
export type WorkflowStatus =
  | 'RECEIVED_REQUEST'
  | 'VALIDATED'
  | 'MAPPED'
  | 'ALLOCATED'
  | 'APPROVED'
  | 'PROVISIONING'
  | 'CONFIGURED'
  | 'VERIFIED'
  | 'COMPLETED'
  | 'FAILED'
  | 'STATUS_UNKNOWN'

export const STAGES: readonly Stage[] = ['supervisor', 'mapper', 'allocator', 'deployer']
export const READY_VALUES: readonly Ready[] = ['True', 'False', 'Unknown']
export const WORKFLOW_STATUSES: readonly WorkflowStatus[] = [
  'RECEIVED_REQUEST',
  'VALIDATED',
  'MAPPED',
  'ALLOCATED',
  'APPROVED',
  'PROVISIONING',
  'CONFIGURED',
  'VERIFIED',
  'COMPLETED',
  'FAILED',
  'STATUS_UNKNOWN',
]

interface ChunkBase {
  correlation_id: string
  status: WorkflowStatus
  thread_id?: string
}

export interface StatusChunk extends ChunkBase {
  type: 'status'
  stage: Stage
  message?: string
}

export interface ResourceName {
  kind: string
  name: string
}

export interface StageChunk extends ChunkBase {
  type: 'stage'
  stage: Stage
  payload?: Record<string, unknown>
  resources?: ResourceName[]
  resource?: string
  out_of_band?: OutOfBand
  message?: string
}

export interface ConfirmationRequestChunk extends ChunkBase {
  type: 'confirmation_request'
  stage: Stage
  prompt: string
  refusable: boolean
}

export interface ProgressChunk extends ChunkBase {
  type: 'progress'
  resource: string
  ready?: Ready
  reason?: string
}

export interface FinalChunk extends ChunkBase {
  type: 'final'
  message?: string
}

export interface ErrorChunk extends ChunkBase {
  type: 'error'
  stage: Stage
  reason: string
  retryable: boolean
  out_of_band?: OutOfBand
  /** Set when the chat surface itself produced the chunk (a protocol or transport failure). */
  client?: true
}

export type Chunk =
  | StatusChunk
  | StageChunk
  | ConfirmationRequestChunk
  | ProgressChunk
  | FinalChunk
  | ErrorChunk

export type ChunkType = Chunk['type']

/** The supervisor refused the credential (401): the caller returns to the login form. */
export class AuthError extends Error {
  constructor(message = 'authentication required') {
    super(message)
    this.name = 'AuthError'
  }
}

/** A non-200, non-401 answer; `reason` is the body's reason when it has one. */
export class HttpError extends Error {
  readonly status: number
  readonly reason: string
  constructor(status: number, reason: string) {
    super(reason)
    this.name = 'HttpError'
    this.status = status
    this.reason = reason
  }
}

type Json = Record<string, unknown>

const isObject = (v: unknown): v is Json => typeof v === 'object' && v !== null && !Array.isArray(v)
const isString = (v: unknown): v is string => typeof v === 'string'

/** A client-side error chunk (stage supervisor: the answer as a whole could not be read). */
export function clientError(reason: string, context: { correlationId?: string; threadId?: string } = {}): ErrorChunk {
  const chunk: ErrorChunk = {
    type: 'error',
    stage: 'supervisor',
    status: 'FAILED',
    reason,
    retryable: false,
    correlation_id: context.correlationId ?? '',
    client: true,
  }
  if (context.threadId) chunk.thread_id = context.threadId
  return chunk
}

class ProtocolError extends Error {}

function field<T>(obj: Json, key: string, ok: (v: unknown) => v is T, what: string): T {
  const value = obj[key]
  if (!ok(value)) throw new ProtocolError(`${key} ${what}`)
  return value
}

function optional<T>(obj: Json, key: string, ok: (v: unknown) => v is T, what: string): T | undefined {
  const value = obj[key]
  if (value === undefined || value === null) return undefined
  if (!ok(value)) throw new ProtocolError(`${key} ${what}`)
  return value
}

const isStage = (v: unknown): v is Stage => isString(v) && (STAGES as readonly string[]).includes(v)
const isReady = (v: unknown): v is Ready => isString(v) && (READY_VALUES as readonly string[]).includes(v)
const isStatus = (v: unknown): v is WorkflowStatus =>
  isString(v) && (WORKFLOW_STATUSES as readonly string[]).includes(v)
const isOutOfBand = (v: unknown): v is OutOfBand => v === 'modified' || v === 'deleted'
const isBool = (v: unknown): v is boolean => typeof v === 'boolean'
const isResources = (v: unknown): v is ResourceName[] =>
  Array.isArray(v) && v.every((r) => isObject(r) && isString(r.kind) && isString(r.name))

/**
 * Validate one decoded chunk. Throws on anything the contract does not allow — an unknown type, a
 * status outside the closed set, a stage outside the four, or a `ready` that is not one of the three
 * status strings (a boolean is refused, never coerced).
 */
export function parseChunk(data: unknown): Chunk {
  if (!isObject(data)) throw new ProtocolError('a chunk is not a JSON object')
  const type = data.type
  const base: ChunkBase = {
    correlation_id: field(data, 'correlation_id', isString, 'is missing or not a string'),
    status: field(data, 'status', isStatus, `is not a workflow status (${JSON.stringify(data.status)})`),
  }
  const threadId = optional(data, 'thread_id', isString, 'is not a string')
  if (threadId !== undefined) base.thread_id = threadId
  const put = <C extends Chunk>(chunk: C, key: keyof C & string, value: unknown): void => {
    if (value !== undefined) (chunk as unknown as Record<string, unknown>)[key] = value
  }
  switch (type) {
    case 'status': {
      const chunk: StatusChunk = { ...base, type, stage: field(data, 'stage', isStage, 'is not a stage') }
      put(chunk, 'message', optional(data, 'message', isString, 'is not a string'))
      return chunk
    }
    case 'stage': {
      const chunk: StageChunk = { ...base, type, stage: field(data, 'stage', isStage, 'is not a stage') }
      put(chunk, 'payload', optional(data, 'payload', isObject, 'is not an object'))
      put(chunk, 'resources', optional(data, 'resources', isResources, 'is not a list of {kind, name}'))
      put(chunk, 'resource', optional(data, 'resource', isString, 'is not a string'))
      put(chunk, 'out_of_band', optional(data, 'out_of_band', isOutOfBand, 'is not "modified" or "deleted"'))
      put(chunk, 'message', optional(data, 'message', isString, 'is not a string'))
      return chunk
    }
    case 'confirmation_request': {
      const refusable = optional(data, 'refusable', isBool, 'is not a boolean')
      return {
        ...base,
        type,
        stage: field(data, 'stage', isStage, 'is not a stage'),
        prompt: field(data, 'prompt', isString, 'is missing'),
        refusable: refusable ?? true,
      }
    }
    case 'progress': {
      const chunk: ProgressChunk = { ...base, type, resource: field(data, 'resource', isString, 'is missing') }
      if (data.ready !== undefined && data.ready !== null && !isReady(data.ready)) {
        throw new ProtocolError(
          `ready must be the status string "True", "False" or "Unknown", got ${JSON.stringify(data.ready)}`,
        )
      }
      put(chunk, 'ready', optional(data, 'ready', isReady, 'is not a Ready status string'))
      put(chunk, 'reason', optional(data, 'reason', isString, 'is not a string'))
      return chunk
    }
    case 'final': {
      const chunk: FinalChunk = { ...base, type }
      put(chunk, 'message', optional(data, 'message', isString, 'is not a string'))
      return chunk
    }
    case 'error': {
      const chunk: ErrorChunk = {
        ...base,
        type,
        stage: field(data, 'stage', isStage, 'is not a stage'),
        reason: field(data, 'reason', isString, 'is missing'),
        retryable: optional(data, 'retryable', isBool, 'is not a boolean') ?? false,
      }
      put(chunk, 'out_of_band', optional(data, 'out_of_band', isOutOfBand, 'is not "modified" or "deleted"'))
      return chunk
    }
    default:
      throw new ProtocolError(`unknown chunk type ${JSON.stringify(type)}`)
  }
}

export interface StreamRequest {
  prompt: string
  threadId?: string
}

export interface StreamOptions {
  fetch?: FetchLike
  signal?: AbortSignal
  base?: string
}

export interface StreamResult {
  /** The thread to continue (the confirmation, an amendment): the last thread_id seen. */
  threadId?: string
  /** The last correlation id seen. */
  correlationId?: string
  /** How many chunks were delivered (client-side error chunks included). */
  chunks: number
  /** The terminal chunk, when the turn ended with one (final or error). */
  last?: FinalChunk | ErrorChunk
}

function defaultFetch(): FetchLike {
  return (input, init) => fetch(input, init)
}

async function reasonOf(response: Response): Promise<string> {
  const text = await response.text().catch(() => null)
  if (text === null) return `the supervisor answered ${response.status}`
  try {
    const body: unknown = JSON.parse(text)
    if (isObject(body)) {
      if (isString(body.reason) && body.reason) return body.reason
      if (isString(body.detail) && body.detail) return body.detail
      if (Array.isArray(body.detail) && body.detail.length > 0) {
        return body.detail
          .map((d) => (isObject(d) && isString(d.msg) ? d.msg : JSON.stringify(d)))
          .join('; ')
      }
    }
  } catch {
    // not JSON: fall through to the text
  }
  const trimmed = text.trim()
  return trimmed ? trimmed.slice(0, 500) : `the supervisor answered ${response.status}`
}

/** Split an NDJSON byte stream into lines as it arrives (CRLF, split reads, a last unterminated line). */
export async function* ndjsonLines(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      let newline = buffer.indexOf('\n')
      while (newline >= 0) {
        const line = buffer.slice(0, newline).replace(/\r$/, '')
        buffer = buffer.slice(newline + 1)
        if (line.trim()) yield line
        newline = buffer.indexOf('\n')
      }
    }
    buffer += decoder.decode()
    const last = buffer.replace(/\r$/, '')
    if (last.trim()) yield last
  } finally {
    reader.releaseLock()
  }
}

/**
 * POST one prompt (a new request, a "yes"/"no" confirmation or an amendment on `threadId`) and
 * deliver each chunk to `onChunk` as it arrives. Throws AuthError on 401 (the credentials are
 * cleared first) and HttpError on any other non-200 answer.
 */
export async function streamPrompt(
  request: StreamRequest,
  onChunk: (chunk: Chunk) => void,
  options: StreamOptions = {},
): Promise<StreamResult> {
  const header = authorizationHeader()
  if (header === null) throw new AuthError('not signed in')
  const doFetch = options.fetch ?? defaultFetch()
  const body: { prompt: string; thread_id?: string } = { prompt: request.prompt }
  if (request.threadId) body.thread_id = request.threadId
  const response = await doFetch(`${options.base ?? API_BASE}/agent/prompt/stream`, {
    method: 'POST',
    headers: {
      authorization: header,
      'content-type': 'application/json',
      accept: 'application/x-ndjson',
    },
    body: JSON.stringify(body),
    credentials: 'omit',
    cache: 'no-store',
    signal: options.signal,
  })
  if (response.status === 401) {
    clearCredentials()
    throw new AuthError()
  }
  if (response.status !== 200) {
    throw new HttpError(response.status, await reasonOf(response))
  }

  const result: StreamResult = { chunks: 0, threadId: request.threadId }
  const deliver = (chunk: Chunk): void => {
    if (chunk.thread_id) result.threadId = chunk.thread_id
    if (chunk.correlation_id) result.correlationId = chunk.correlation_id
    if (chunk.type === 'final' || chunk.type === 'error') result.last = chunk
    result.chunks += 1
    onChunk(chunk)
  }
  const handle = (line: string): void => {
    let decoded: unknown
    try {
      decoded = JSON.parse(line)
    } catch {
      deliver(clientError('the supervisor sent a line that is not JSON', context()))
      return
    }
    try {
      deliver(parseChunk(decoded))
    } catch (err) {
      const why = err instanceof Error ? err.message : String(err)
      deliver(clientError(`the supervisor sent a chunk this surface cannot read: ${why}`, context()))
    }
  }
  const context = () => ({ correlationId: result.correlationId, threadId: result.threadId })

  if (response.body) {
    for await (const line of ndjsonLines(response.body)) handle(line)
  } else {
    for (const line of (await response.text()).split('\n')) {
      const trimmed = line.replace(/\r$/, '')
      if (trimmed.trim()) handle(trimmed)
    }
  }
  return result
}

export interface SuggestedPrompt {
  shape: string
  construct: string
  prompt: string
}

export interface SuggestedPrompts {
  prompts: SuggestedPrompt[]
  note?: string
}

/** GET /suggested-prompts: the construct-vocabulary prompts on the site's real inventory. */
export async function fetchSuggestedPrompts(options: { fetch?: FetchLike; base?: string; signal?: AbortSignal } = {}): Promise<SuggestedPrompts> {
  const header = authorizationHeader()
  if (header === null) throw new AuthError('not signed in')
  const doFetch = options.fetch ?? defaultFetch()
  const response = await doFetch(`${options.base ?? API_BASE}/suggested-prompts`, {
    method: 'GET',
    headers: { authorization: header, accept: 'application/json' },
    credentials: 'omit',
    cache: 'no-store',
    signal: options.signal,
  })
  if (response.status === 401) {
    clearCredentials()
    throw new AuthError()
  }
  if (response.status !== 200) throw new HttpError(response.status, await reasonOf(response))
  const body: unknown = await response.json()
  if (!isObject(body) || !Array.isArray(body.prompts)) {
    throw new HttpError(response.status, 'the suggested prompts are not in the expected shape')
  }
  const prompts = body.prompts.filter(
    (p): p is SuggestedPrompt => isObject(p) && isString(p.prompt) && isString(p.shape) && isString(p.construct),
  )
  const out: SuggestedPrompts = { prompts }
  if (isString(body.note)) out.note = body.note
  return out
}

