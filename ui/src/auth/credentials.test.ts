// T123 (FR-102, AD-28): the operator's credentials are held in memory only. Spy fakes stand in for
// every browser persistence surface — localStorage, sessionStorage, document.cookie, indexedDB and
// history state — and the whole login flow runs against a fake supervisor; not one write happens.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  authorizationHeader,
  base64Utf8,
  clearCredentials,
  getCredentials,
  hasCredentials,
  login,
  logout,
  setCredentials,
  signOutReason,
  subscribeCredentials,
  type FetchLike,
} from './credentials.ts'
import { AuthError, fetchSuggestedPrompts, streamPrompt } from '../api/stream.ts'

interface Writes {
  count: number
  log: string[]
}

function spyStorage(name: string, writes: Writes): Storage {
  const data = new Map<string, string>()
  const target = {
    get length() {
      return data.size
    },
    key: (i: number) => [...data.keys()][i] ?? null,
    getItem: (k: string) => data.get(k) ?? null,
    setItem: (k: string, v: string) => {
      writes.count += 1
      writes.log.push(`${name}.setItem(${k})`)
      data.set(k, v)
    },
    removeItem: (k: string) => {
      writes.count += 1
      writes.log.push(`${name}.removeItem(${k})`)
      data.delete(k)
    },
    clear: () => {
      writes.count += 1
      writes.log.push(`${name}.clear()`)
      data.clear()
    },
  }
  // a property assignment (localStorage.x = …) is a write too
  return new Proxy(target, {
    set(obj, prop, value) {
      writes.count += 1
      writes.log.push(`${name}.${String(prop)} =`)
      return Reflect.set(obj, prop, value)
    },
    defineProperty(obj, prop, desc) {
      writes.count += 1
      writes.log.push(`${name}.defineProperty(${String(prop)})`)
      return Reflect.defineProperty(obj, prop, desc)
    },
  }) as unknown as Storage
}

function installFakes(): { writes: Writes; restore: () => void } {
  const writes: Writes = { count: 0, log: [] }
  const names = ['localStorage', 'sessionStorage', 'document', 'indexedDB', 'history'] as const
  const g = globalThis as unknown as Record<string, unknown>
  const saved = names.map((n) => [n, Object.getOwnPropertyDescriptor(globalThis, n)] as const)
  let cookie = ''
  const document = {
    get cookie() {
      return cookie
    },
    set cookie(value: string) {
      writes.count += 1
      writes.log.push('document.cookie =')
      cookie = value
    },
  }
  const indexedDB = {
    open: () => {
      writes.count += 1
      writes.log.push('indexedDB.open')
      throw new Error('indexedDB must not be used')
    },
  }
  const history = {
    pushState: () => {
      writes.count += 1
      writes.log.push('history.pushState')
    },
    replaceState: () => {
      writes.count += 1
      writes.log.push('history.replaceState')
    },
  }
  const fakes: Record<string, unknown> = {
    localStorage: spyStorage('localStorage', writes),
    sessionStorage: spyStorage('sessionStorage', writes),
    document,
    indexedDB,
    history,
  }
  for (const n of names) {
    Object.defineProperty(globalThis, n, { value: fakes[n], configurable: true, writable: true })
  }
  assert.equal(g.localStorage, fakes.localStorage)
  return {
    writes,
    restore: () => {
      for (const [n, desc] of saved) {
        if (desc) Object.defineProperty(globalThis, n, desc)
        else delete g[n]
      }
    },
  }
}

interface Call {
  url: string
  init?: RequestInit
}

function fakeSupervisor(user: string, pass: string, calls: Call[]): FetchLike {
  const expected = `Basic ${base64Utf8(`${user}:${pass}`)}`
  return async (url, init) => {
    calls.push({ url, init })
    const headers = new Headers(init?.headers)
    if (headers.get('authorization') !== expected) {
      return new Response(JSON.stringify({ type: 'error', status: 'FAILED', reason: 'authentication required' }), {
        status: 401,
        headers: { 'www-authenticate': 'Basic realm="agentic-netops"' },
      })
    }
    return new Response(JSON.stringify({ prompts: [] }), { status: 200 })
  }
}

test('authorizationHeader is Basic base64(user:pass), UTF-8 safe', () => {
  assert.equal(authorizationHeader({ username: 'operator', password: 'p4ss' }), `Basic ${btoa('operator:p4ss')}`)
  // "ü" is two UTF-8 bytes; btoa over UTF-16 code units would be wrong or throw
  const header = authorizationHeader({ username: 'jürgen', password: 'pässwörd€' })
  assert.equal(header, 'Basic asO8cmdlbjpww6Rzc3fDtnJk4oKs')
  assert.equal(authorizationHeader(null), null)
})

test('set/get/clear hold credentials in memory with zero storage or cookie writes', () => {
  const { writes, restore } = installFakes()
  try {
    clearCredentials()
    assert.equal(getCredentials(), null)
    setCredentials('operator', 'secret')
    assert.deepEqual(getCredentials(), { username: 'operator', password: 'secret' })
    assert.equal(hasCredentials(), true)
    assert.equal(authorizationHeader(), `Basic ${btoa('operator:secret')}`)
    logout()
    assert.equal(getCredentials(), null)
    assert.equal(authorizationHeader(), null)
    assert.equal(signOutReason(), 'logout')
    assert.equal(writes.count, 0, writes.log.join(', '))
    assert.equal((globalThis as unknown as { document: { cookie: string } }).document.cookie, '')
  } finally {
    restore()
  }
})

test('a full login flow (401 then 200) writes nothing to storage or cookies', async () => {
  const { writes, restore } = installFakes()
  const calls: Call[] = []
  const fetch = fakeSupervisor('operator', 'right', calls)
  const changes: string[] = []
  const unsubscribe = subscribeCredentials(() => changes.push(hasCredentials() ? 'in' : 'out'))
  try {
    clearCredentials()
    const refused = await login('operator', 'wrong', { fetch })
    assert.equal(refused.ok, false)
    assert.ok(!refused.ok && /refused/.test(refused.error))
    assert.equal(getCredentials(), null, 'a refused credential is not held')

    const accepted = await login('operator', 'right', { fetch })
    assert.deepEqual(accepted, { ok: true })
    assert.deepEqual(getCredentials(), { username: 'operator', password: 'right' })
    assert.deepEqual(changes, ['in'])

    // verification asks the supervisor's credentialed, thread-free route with the header
    assert.equal(calls.length, 2)
    assert.equal(calls[1].url, '/api/suggested-prompts')
    assert.equal(new Headers(calls[1].init?.headers).get('authorization'), `Basic ${btoa('operator:right')}`)
    assert.equal(calls[1].init?.credentials, 'omit')

    // later calls carry the held credential
    await fetchSuggestedPrompts({ fetch })
    assert.equal(new Headers(calls[2].init?.headers).get('authorization'), `Basic ${btoa('operator:right')}`)

    logout()
    assert.equal(getCredentials(), null)
    assert.equal(writes.count, 0, writes.log.join(', '))
    assert.equal((globalThis as unknown as { document: { cookie: string } }).document.cookie, '')
  } finally {
    unsubscribe()
    restore()
  }
})

test('any later 401 clears the credentials (the page returns to the form)', async () => {
  const { writes, restore } = installFakes()
  const calls: Call[] = []
  try {
    setCredentials('operator', 'rotated-away')
    const fetch = fakeSupervisor('operator', 'current', calls)
    await assert.rejects(() => fetchSuggestedPrompts({ fetch }), AuthError)
    assert.equal(getCredentials(), null)
    assert.equal(signOutReason(), 'refused')

    setCredentials('operator', 'rotated-away')
    await assert.rejects(() => streamPrompt({ prompt: 'hello' }, () => {}, { fetch }), AuthError)
    assert.equal(getCredentials(), null)
    assert.equal(writes.count, 0, writes.log.join(', '))
  } finally {
    restore()
  }
})

test('a login the supervisor cannot answer holds nothing', async () => {
  clearCredentials()
  const down: FetchLike = async () => {
    throw new TypeError('connection refused')
  }
  const result = await login('operator', 'x', { fetch: down })
  assert.equal(result.ok, false)
  assert.equal(getCredentials(), null)
  const unavailable: FetchLike = async () => new Response('bad gateway', { status: 502 })
  const r2 = await login('operator', 'x', { fetch: unavailable })
  assert.equal(r2.ok, false)
  assert.equal(getCredentials(), null)
  const empty = await login('', '', { fetch: unavailable })
  assert.equal(empty.ok, false)
})
