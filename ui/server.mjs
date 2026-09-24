// The ui pod's server (T125/T126; FR-080, FR-102; contracts/supervisor-http.md): dependency-free
// (node:http only), run by docker/Dockerfile.ui.
//
//   GET /healthz                  liveness/readiness of this pod: "ok", touches nothing else
//   /api/<route>                  same-origin proxy to ${SUPERVISOR_BASE_URL}/<route>, ONLY for
//                                   POST /api/agent/prompt/stream   GET /api/suggested-prompts
//                                   GET  /api/transport/config      GET /api/v1/health
//                                   GET  /api/health
//                                 anything else under /api is 404 (a known route with another
//                                 method is 405). The Authorization header is forwarded untouched;
//                                 only hop-by-hop headers are dropped; the response body (NDJSON)
//                                 is streamed through as it arrives, never buffered; nothing is
//                                 stored and no header is ever logged.
//   anything else (GET/HEAD)      the built single-page application from UI_STATIC_ROOT
//                                 (default /srv/dist), index.html for unknown paths, nothing
//                                 outside the root.
//
// Environment: SUPERVISOR_BASE_URL (required — the server refuses to start without it; deployment
// configuration, ConfigMap ui-env, never baked into the image), PORT (default 3000; 0 = any free
// port), HOST (default 0.0.0.0), UI_STATIC_ROOT (default /srv/dist).
import fs from 'node:fs'
import http from 'node:http'
import https from 'node:https'
import path from 'node:path'

const log = (msg) => process.stdout.write(`${new Date().toISOString()} ui-server ${msg}\n`)
const fail = (msg) => {
  process.stderr.write(`ui-server: ${msg}\n`)
  process.exit(1)
}

const baseRaw = (process.env.SUPERVISOR_BASE_URL ?? '').trim()
if (!baseRaw) fail('SUPERVISOR_BASE_URL is required (the supervisor base URL, e.g. http://supervisor.agentic-netops-agents.svc:9090); refusing to start')
let base
try {
  base = new URL(baseRaw)
} catch {
  fail(`SUPERVISOR_BASE_URL is not a URL: ${JSON.stringify(baseRaw)}; refusing to start`)
}
if (base.protocol !== 'http:' && base.protocol !== 'https:') {
  fail(`SUPERVISOR_BASE_URL must be http(s), got ${base.protocol}; refusing to start`)
}
const basePath = base.pathname.replace(/\/+$/, '')
const client = base.protocol === 'https:' ? https : http

const portRaw = process.env.PORT ?? '3000'
const port = Number(portRaw)
if (!Number.isInteger(port) || port < 0 || port > 65535) fail(`PORT is not a port: ${JSON.stringify(portRaw)}`)
const host = process.env.HOST || '0.0.0.0'
const root = path.resolve(process.env.UI_STATIC_ROOT || '/srv/dist')

// The five supervisor routes the browser may reach, by path, with their one method.
const ROUTES = new Map([
  ['/agent/prompt/stream', 'POST'],
  ['/suggested-prompts', 'GET'],
  ['/transport/config', 'GET'],
  ['/v1/health', 'GET'],
  ['/health', 'GET'],
])

// RFC 9110 §7.6.1 hop-by-hop headers, plus any named by the Connection header.
const HOP_BY_HOP = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'proxy-connection',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
])

function endToEnd(headers) {
  const named = new Set(
    String(headers.connection ?? '')
      .split(',')
      .map((h) => h.trim().toLowerCase())
      .filter(Boolean),
  )
  const out = {}
  for (const [name, value] of Object.entries(headers)) {
    const key = name.toLowerCase()
    if (HOP_BY_HOP.has(key) || named.has(key) || key === 'host') continue
    out[key] = value
  }
  return out
}

function sendJson(res, status, body, extra = {}) {
  const data = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(data),
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    ...extra,
  })
  res.end(data)
}

function proxy(req, res, route, search) {
  const started = Date.now()
  const headers = endToEnd(req.headers)
  headers.host = base.host
  const upstream = client.request(
    {
      protocol: base.protocol,
      hostname: base.hostname,
      port: base.port || undefined,
      method: req.method,
      path: `${basePath}${route}${search}`,
      headers,
    },
    (up) => {
      res.writeHead(up.statusCode ?? 502, endToEnd(up.headers))
      res.flushHeaders()
      up.on('data', (chunk) => res.write(chunk))
      up.on('end', () => {
        res.end()
        log(`${req.method} /api${route} -> ${up.statusCode} ${Date.now() - started}ms`)
      })
      up.on('error', () => res.destroy())
    },
  )
  upstream.on('error', (err) => {
    log(`${req.method} /api${route} -> upstream error ${err.code ?? err.message}`)
    if (!res.headersSent) {
      sendJson(res, 502, { type: 'error', status: 'FAILED', reason: 'the supervisor could not be reached' })
    } else {
      res.destroy()
    }
  })
  // the operator closed the page mid-stream: stop asking the supervisor
  res.on('close', () => {
    if (!res.writableFinished) upstream.destroy()
  })
  req.pipe(upstream)
}

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.map': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
}

const SECURITY = {
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
  'x-frame-options': 'DENY',
  'content-security-policy':
    "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
}

function serveStatic(req, res, pathname) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { allow: 'GET, HEAD' })
    res.end()
    return
  }
  let decoded
  try {
    decoded = decodeURIComponent(pathname)
  } catch {
    res.writeHead(400)
    res.end()
    return
  }
  let file = path.normalize(path.join(root, decoded))
  if (file !== root && !file.startsWith(root + path.sep)) {
    res.writeHead(400)
    res.end()
    return
  }
  let stat = fs.statSync(file, { throwIfNoEntry: false })
  if (!stat || stat.isDirectory()) {
    file = path.join(root, 'index.html')
    stat = fs.statSync(file, { throwIfNoEntry: false })
    if (!stat) {
      res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' })
      res.end('not found')
      return
    }
  }
  const isIndex = path.basename(file) === 'index.html'
  res.writeHead(200, {
    'content-type': TYPES[path.extname(file)] ?? 'application/octet-stream',
    'content-length': stat.size,
    'cache-control': isIndex ? 'no-store' : 'public, max-age=31536000, immutable',
    ...SECURITY,
  })
  if (req.method === 'HEAD') {
    res.end()
    return
  }
  fs.createReadStream(file).pipe(res)
}

const server = http.createServer((req, res) => {
  let url
  try {
    url = new URL(req.url ?? '/', 'http://ui')
  } catch {
    res.writeHead(400)
    res.end()
    return
  }
  const { pathname, search } = url
  if (pathname === '/healthz') {
    res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' })
    res.end('ok')
    return
  }
  if (pathname === '/api' || pathname.startsWith('/api/')) {
    const route = pathname.slice('/api'.length)
    const method = ROUTES.get(route)
    if (!method) {
      sendJson(res, 404, { type: 'error', status: 'FAILED', reason: `no such route: ${pathname}` })
      return
    }
    if (req.method !== method) {
      sendJson(res, 405, { type: 'error', status: 'FAILED', reason: `${pathname} accepts ${method} only` }, { allow: method })
      return
    }
    req.socket.setNoDelay(true)
    proxy(req, res, route, search)
    return
  }
  serveStatic(req, res, pathname)
})

// Streams may run for minutes (convergence watches): no request timeout on this server.
server.requestTimeout = 0
server.listen(port, host, () => {
  const addr = server.address()
  log(`listening on ${host}:${typeof addr === 'object' && addr ? addr.port : port}; static ${root}; /api -> ${base.origin}${basePath}`)
})

const stop = () => {
  server.close(() => process.exit(0))
  server.closeIdleConnections()
  setTimeout(() => process.exit(0), 5000).unref()
}
process.on('SIGTERM', stop)
process.on('SIGINT', stop)
