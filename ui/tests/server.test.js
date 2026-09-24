// ui/server.mjs (the ui pod's static server and /api proxy): started on an ephemeral port against a
// fake supervisor — the stream route is proxied chunk by chunk with the Authorization header
// forwarded, nothing but the five routes is proxied, the SPA fallback serves index.html, and the
// server refuses to start without SUPERVISOR_BASE_URL.
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import http from 'node:http'
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const SERVER = fileURLToPath(new URL('../server.mjs', import.meta.url))
const AUTH = `Basic ${Buffer.from('operator:secret').toString('base64')}`

let upstream
let upstreamUrl
let releaseSecond // resolves the fake supervisor's second NDJSON chunk
const seen = []
let child
let base
let output = ''
let dist

function startServer(env) {
  const proc = spawn(process.execPath, [SERVER], {
    env: { PATH: process.env.PATH, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  return proc
}

before(async () => {
  upstream = http.createServer((req, res) => {
    let body = ''
    req.on('data', (c) => (body += c))
    req.on('end', () => {
      seen.push({ method: req.method, url: req.url, headers: req.headers, body })
      if (req.url === '/agent/prompt/stream') {
        res.writeHead(200, { 'content-type': 'application/x-ndjson', 'x-upstream': 'supervisor' })
        res.write('{"type":"status","correlation_id":"4bf92f3577b34da6a3ce929d0e0e4736","status":"RECEIVED_REQUEST","stage":"supervisor"}\n')
        releaseSecond = () =>
          res.end('{"type":"final","correlation_id":"4bf92f3577b34da6a3ce929d0e0e4736","status":"COMPLETED"}\n')
        return
      }
      if (req.url === '/suggested-prompts') {
        if (req.headers.authorization !== AUTH) {
          res.writeHead(401, { 'www-authenticate': 'Basic realm="agentic-netops"', 'content-type': 'application/json' })
          res.end('{"type":"error","status":"FAILED","reason":"authentication required"}')
          return
        }
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end('{"prompts":[]}')
        return
      }
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end('{"status":"ok"}')
    })
  })
  await new Promise((r) => upstream.listen(0, '127.0.0.1', r))
  upstreamUrl = `http://127.0.0.1:${upstream.address().port}`

  dist = mkdtempSync(join(tmpdir(), 'ui-dist-'))
  writeFileSync(join(dist, 'index.html'), '<!doctype html><title>Agentic NetOps</title><div id="root"></div>')
  mkdirSync(join(dist, 'assets'))
  writeFileSync(join(dist, 'assets', 'app.js'), 'console.log(1)')

  child = startServer({ SUPERVISOR_BASE_URL: upstreamUrl, PORT: '0', HOST: '127.0.0.1', UI_STATIC_ROOT: dist })
  base = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`server did not start: ${output}`)), 10000)
    child.stdout.on('data', (d) => {
      output += d
      const m = /listening on [^:]+:(\d+)/.exec(output)
      if (m) {
        clearTimeout(timer)
        resolve(`http://127.0.0.1:${m[1]}`)
      }
    })
    child.stderr.on('data', (d) => (output += d))
    child.on('exit', (code) => reject(new Error(`server exited ${code}: ${output}`)))
  })
})

after(async () => {
  child?.kill('SIGTERM')
  await new Promise((r) => upstream.close(r))
  rmSync(dist, { recursive: true, force: true })
})

test('the stream route is proxied incrementally with Authorization forwarded', async () => {
  const response = await fetch(`${base}/api/agent/prompt/stream`, {
    method: 'POST',
    headers: { authorization: AUTH, 'content-type': 'application/json' },
    body: JSON.stringify({ prompt: 'hello' }),
  })
  assert.equal(response.status, 200)
  assert.equal(response.headers.get('content-type'), 'application/x-ndjson')
  assert.equal(response.headers.get('x-upstream'), 'supervisor')
  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  // the first line arrives while the supervisor still holds the second: nothing is buffered
  let first = ''
  while (!first.includes('\n')) {
    const { value, done } = await reader.read()
    assert.equal(done, false, 'stream ended before the first line')
    first += decoder.decode(value, { stream: true })
  }
  assert.match(first, /"type":"status"/)
  assert.doesNotMatch(first, /"type":"final"/)
  releaseSecond()
  let rest = ''
  for (;;) {
    const { value, done } = await reader.read()
    if (done) break
    rest += decoder.decode(value, { stream: true })
  }
  assert.match(rest, /"type":"final"/)

  const req = seen.find((s) => s.url === '/agent/prompt/stream')
  assert.equal(req.method, 'POST')
  assert.equal(req.headers.authorization, AUTH)
  assert.equal(req.headers.host, new URL(upstreamUrl).host)
  assert.deepEqual(JSON.parse(req.body), { prompt: 'hello' })
  assert.doesNotMatch(output, /Basic|authorization|secret/i, 'a header reached the log')
})

test('a 401 from the supervisor passes through untouched', async () => {
  const response = await fetch(`${base}/api/suggested-prompts`, { headers: { authorization: 'Basic d3Jvbmc6d3Jvbmc=' } })
  assert.equal(response.status, 401)
  assert.equal(response.headers.get('www-authenticate'), 'Basic realm="agentic-netops"')
  assert.equal((await response.json()).reason, 'authentication required')
  const ok = await fetch(`${base}/api/suggested-prompts`, { headers: { authorization: AUTH } })
  assert.equal(ok.status, 200)
  assert.deepEqual(await ok.json(), { prompts: [] })
})

test('only the five routes are proxied', async () => {
  const before = seen.length
  for (const p of ['/api/agent/prompt', '/api/ws', '/api/', '/api', '/api/metrics', '/api/../health']) {
    const r = await fetch(`${base}${p}`)
    await r.arrayBuffer()
    if (p === '/api/../health') {
      // normalised by the client to /health: not /api at all — the SPA answers
      assert.equal(r.status, 200)
    } else {
      assert.equal(r.status, 404, p)
    }
  }
  const wrongMethod = await fetch(`${base}/api/agent/prompt/stream`)
  assert.equal(wrongMethod.status, 405)
  await wrongMethod.arrayBuffer()
  assert.equal(seen.length, before, 'an unlisted route reached the supervisor')
  for (const p of ['/api/health', '/api/v1/health', '/api/transport/config']) {
    const r = await fetch(`${base}${p}`)
    assert.equal(r.status, 200, p)
    await r.arrayBuffer()
  }
  assert.deepEqual(seen.slice(before).map((s) => s.url), ['/health', '/v1/health', '/transport/config'])
})

test('static files, SPA fallback to index.html and /healthz', async () => {
  const js = await fetch(`${base}/assets/app.js`)
  assert.equal(js.status, 200)
  assert.match(js.headers.get('content-type'), /javascript/)
  assert.equal(await js.text(), 'console.log(1)')
  for (const p of ['/', '/some/deep/link', '/conversation']) {
    const r = await fetch(`${base}${p}`)
    assert.equal(r.status, 200, p)
    assert.match(r.headers.get('content-type'), /text\/html/)
    assert.match(await r.text(), /<div id="root"><\/div>/)
  }
  // an encoded traversal is refused (a raw request: fetch would normalise the path first)
  const traversal = await new Promise((resolve, reject) => {
    const u = new URL(base)
    http
      .get({ host: u.hostname, port: u.port, path: '/..%2f..%2f..%2fetc%2fpasswd' }, (r) => {
        r.resume()
        r.on('end', () => resolve(r.statusCode))
      })
      .on('error', reject)
  })
  assert.equal(traversal, 400)
  const health = await fetch(`${base}/healthz`)
  assert.equal(health.status, 200)
  assert.equal(await health.text(), 'ok')
  const post = await fetch(`${base}/`, { method: 'POST' })
  assert.equal(post.status, 405)
})

test('without SUPERVISOR_BASE_URL the server refuses to start, naming it', async () => {
  const proc = startServer({ PORT: '0', HOST: '127.0.0.1' })
  let err = ''
  proc.stderr.on('data', (d) => (err += d))
  const code = await new Promise((r) => proc.on('exit', r))
  assert.notEqual(code, 0)
  assert.match(err, /SUPERVISOR_BASE_URL/)
})
