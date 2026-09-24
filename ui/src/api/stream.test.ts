// T124 (FR-052, FR-081, AD-40, AD-53): the NDJSON client — incremental reads, thread continuation,
// the typed chunk union, and `ready` kept as the three-valued status string.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { clearCredentials, setCredentials, type FetchLike } from '../auth/credentials.ts'
import {
  AuthError,
  HttpError,
  fetchSuggestedPrompts,
  ndjsonLines,
  parseChunk,
  streamPrompt,
  type Chunk,
} from './stream.ts'

const CID = '4bf92f3577b34da6a3ce929d0e0e4736'
const THREAD = '3f2b8c1e-1d2a-4c3b-9e8f-0a1b2c3d4e5f'

/** A body delivered in the given byte pieces, one read each, with an observable read count. */
function pieces(parts: (string | Uint8Array)[]): { stream: ReadableStream<Uint8Array>; pulled: () => number } {
  const enc = new TextEncoder()
  let i = 0
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (i >= parts.length) {
        controller.close()
        return
      }
      const p = parts[i]
      i += 1
      controller.enqueue(typeof p === 'string' ? enc.encode(p) : p)
    },
  })
  return { stream, pulled: () => i }
}

interface Call {
  url: string
  init?: RequestInit
}

function serving(body: ReadableStream<Uint8Array> | string, status = 200, calls: Call[] = []): FetchLike {
  return async (url, init) => {
    calls.push({ url, init })
    return new Response(body, { status, headers: { 'content-type': 'application/x-ndjson' } })
  }
}

const line = (o: object) => `${JSON.stringify(o)}\n`

test('ndjsonLines splits across reads, handles CRLF and a trailing unterminated line', async () => {
  const bytes = new TextEncoder().encode('{"a":"ü"}\r\n')
  const { stream } = pieces(['{"a"', ':1}\n{"b":', '2}\r\n\n', bytes.slice(0, 7), bytes.slice(7), '{"c":3}'])
  const out: string[] = []
  for await (const l of ndjsonLines(stream)) out.push(l)
  assert.deepEqual(out, ['{"a":1}', '{"b":2}', '{"a":"ü"}', '{"c":3}'])
})

test('streamPrompt posts {prompt, thread_id} with the Basic header and no principal', async () => {
  setCredentials('operator', 'secret')
  const calls: Call[] = []
  const body = line({ type: 'final', status: 'COMPLETED', correlation_id: CID, thread_id: THREAD, message: 'ok' })
  await streamPrompt({ prompt: 'yes', threadId: THREAD }, () => {}, { fetch: serving(body, 200, calls) })
  assert.equal(calls.length, 1)
  assert.equal(calls[0].url, '/api/agent/prompt/stream')
  assert.equal(calls[0].init?.method, 'POST')
  const headers = new Headers(calls[0].init?.headers)
  assert.equal(headers.get('authorization'), `Basic ${btoa('operator:secret')}`)
  assert.equal(headers.get('content-type'), 'application/json')
  const sent = JSON.parse(String(calls[0].init?.body))
  assert.deepEqual(sent, { prompt: 'yes', thread_id: THREAD })
  assert.equal('principal' in sent, false)

  await streamPrompt({ prompt: 'first' }, () => {}, { fetch: serving(body, 200, calls) })
  assert.deepEqual(JSON.parse(String(calls[1].init?.body)), { prompt: 'first' })
  clearCredentials()
})

test('chunks are delivered as they arrive, typed, with thread and correlation captured', async () => {
  setCredentials('operator', 'secret')
  const text = [
    line({ type: 'status', correlation_id: CID, thread_id: THREAD, status: 'RECEIVED_REQUEST', stage: 'supervisor' }),
    line({ type: 'stage', correlation_id: CID, thread_id: THREAD, stage: 'mapper', status: 'MAPPED', payload: { service_type: 'vlan' } }),
    line({ type: 'confirmation_request', correlation_id: CID, thread_id: THREAD, stage: 'mapper', status: 'MAPPED', prompt: 'Confirm this vlan interpretation?', refusable: true }),
    line({ type: 'stage', correlation_id: CID, thread_id: THREAD, stage: 'deployer', status: 'VERIFIED', out_of_band: 'modified', resource: 'Network/migr-svc1', payload: {} }),
    line({ type: 'progress', correlation_id: CID, thread_id: THREAD, status: 'PROVISIONING', resource: 'Network/migr-svc1', ready: 'False', reason: 'Deleting' }),
    line({ type: 'progress', correlation_id: CID, thread_id: THREAD, status: 'VERIFIED', resource: 'Network/migr-svc1', ready: 'Unknown', reason: 'VerificationFailed' }),
    line({ type: 'error', correlation_id: CID, thread_id: THREAD, stage: 'deployer', status: 'FAILED', reason: 'deleted', out_of_band: 'deleted' }),
  ].join('')
  // cut the text into small reads so chunks straddle them
  const parts: string[] = []
  for (let i = 0; i < text.length; i += 37) parts.push(text.slice(i, i + 37))
  const { stream, pulled } = pieces(parts)
  const seen: Chunk[] = []
  const readsAtDelivery: number[] = []
  const result = await streamPrompt({ prompt: 'x' }, (c) => {
    seen.push(c)
    readsAtDelivery.push(pulled())
  }, { fetch: serving(stream) })
  assert.deepEqual(seen.map((c) => c.type), ['status', 'stage', 'confirmation_request', 'stage', 'progress', 'progress', 'error'])
  // incremental: the first chunk was delivered long before the body was read to the end
  assert.ok(readsAtDelivery[0] < parts.length / 2, `first chunk after ${readsAtDelivery[0]} of ${parts.length} reads`)
  assert.equal(result.threadId, THREAD)
  assert.equal(result.correlationId, CID)
  assert.equal(result.chunks, 7)
  assert.equal(result.last?.type, 'error')
  const oob = seen[3]
  assert.ok(oob.type === 'stage' && oob.out_of_band === 'modified')
  const deleting = seen[4]
  assert.ok(deleting.type === 'progress')
  assert.equal(deleting.ready, 'False')
  assert.equal(typeof deleting.ready, 'string')
  assert.equal(deleting.reason, 'Deleting')
  const unknown = seen[5]
  assert.ok(unknown.type === 'progress' && unknown.ready === 'Unknown' && unknown.reason === 'VerificationFailed')
  const err = seen[6]
  assert.ok(err.type === 'error' && err.out_of_band === 'deleted' && err.stage === 'deployer')
  clearCredentials()
})

test('ready is never coerced: a boolean or another value is a protocol error chunk', async () => {
  setCredentials('operator', 'secret')
  for (const bad of [true, false, 'true', 'Ready', 1]) {
    const body = line({ type: 'progress', correlation_id: CID, thread_id: THREAD, status: 'VERIFIED', resource: 'Network/a', ready: bad })
    const seen: Chunk[] = []
    await streamPrompt({ prompt: 'x' }, (c) => seen.push(c), { fetch: serving(body) })
    assert.equal(seen.length, 1)
    const c = seen[0]
    assert.equal(c.type, 'error', `ready=${JSON.stringify(bad)} accepted`)
    assert.ok(c.type === 'error' && c.client === true && /ready/.test(c.reason))
  }
  assert.throws(() => parseChunk({ type: 'progress', correlation_id: CID, status: 'VERIFIED', resource: 'r', ready: true }))
  for (const ready of ['True', 'False', 'Unknown'] as const) {
    const c = parseChunk({ type: 'progress', correlation_id: CID, status: 'VERIFIED', resource: 'r', ready })
    assert.ok(c.type === 'progress' && c.ready === ready)
  }
  clearCredentials()
})

test('invalid chunks (non-JSON, unknown type, status outside the set) surface as client errors', async () => {
  setCredentials('operator', 'secret')
  const body = [
    'not json\n',
    line({ type: 'websocket', correlation_id: CID, status: 'COMPLETED' }),
    line({ type: 'final', correlation_id: CID, status: 'DONE' }),
    line({ type: 'stage', correlation_id: CID, status: 'MAPPED', stage: 'mapper', out_of_band: 'moved' }),
    line({ type: 'final', correlation_id: CID, thread_id: THREAD, status: 'PROVISIONING', message: 'removal in progress: waiting on leaf02' }),
  ].join('')
  const seen: Chunk[] = []
  const result = await streamPrompt({ prompt: 'x' }, (c) => seen.push(c), { fetch: serving(body) })
  assert.deepEqual(seen.map((c) => c.type), ['error', 'error', 'error', 'error', 'final'])
  for (const c of seen.slice(0, 4)) assert.ok(c.type === 'error' && c.client === true)
  assert.equal(result.last?.type, 'final')
  assert.equal(result.last?.status, 'PROVISIONING')
  clearCredentials()
})

test('401 raises AuthError and clears the credentials; other statuses carry the body reason', async () => {
  setCredentials('operator', 'secret')
  const unauthorized = JSON.stringify({ type: 'error', status: 'FAILED', reason: 'authentication required' })
  await assert.rejects(() => streamPrompt({ prompt: 'x' }, () => {}, { fetch: serving(unauthorized, 401) }), AuthError)

  setCredentials('operator', 'secret')
  const refused = JSON.stringify({ detail: 'principal: extra fields not permitted' })
  await assert.rejects(
    () => streamPrompt({ prompt: 'x' }, () => {}, { fetch: serving(refused, 400) }),
    (err: unknown) => err instanceof HttpError && err.status === 400 && /principal/.test(err.reason),
  )
  const reasoned = JSON.stringify({ type: 'error', status: 'FAILED', reason: 'the supervisor is starting' })
  await assert.rejects(
    () => streamPrompt({ prompt: 'x' }, () => {}, { fetch: serving(reasoned, 503) }),
    (err: unknown) => err instanceof HttpError && err.reason === 'the supervisor is starting',
  )
  clearCredentials()
  await assert.rejects(() => streamPrompt({ prompt: 'x' }, () => {}, { fetch: serving('', 200) }), AuthError)
})

test('fetchSuggestedPrompts returns the construct prompts', async () => {
  setCredentials('operator', 'secret')
  const calls: Call[] = []
  const body = JSON.stringify({ prompts: [{ shape: 'vlan', construct: 'vlan', prompt: 'Create vlan 120 on leaf01 ethernet-1/2 for tenant acme' }] })
  const got = await fetchSuggestedPrompts({ fetch: serving(body, 200, calls) })
  assert.equal(calls[0].url, '/api/suggested-prompts')
  assert.equal(got.prompts.length, 1)
  assert.equal(got.prompts[0].construct, 'vlan')
  const noted = await fetchSuggestedPrompts({ fetch: serving(JSON.stringify({ prompts: [], note: 'no site inventory' })) })
  assert.equal(noted.note, 'no site inventory')
  clearCredentials()
})
