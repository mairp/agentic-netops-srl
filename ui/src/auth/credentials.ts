// The operator's credentials, held in memory only (T123; FR-102, contracts/supervisor-http.md
// "Authentication"). They live in this module's closure and nowhere else: never localStorage,
// sessionStorage, a cookie, IndexedDB, the URL or history state. A reload forgets them, and the
// operator signs in again — there is no session and no token (the route count stays at five).

export interface Credentials {
  readonly username: string
  readonly password: string
}

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>

/** The proxy prefix the ui server forwards to the supervisor (ui/server.mjs, vite dev proxy). */
export const API_BASE = '/api'

let current: Credentials | null = null
let signedOut: SignOutReason | null = null
const listeners = new Set<() => void>()

function notify(): void {
  for (const listener of listeners) listener()
}

/** Why the operator was last signed out: `refused` (a 401 after sign-in) or `logout`. */
export type SignOutReason = 'refused' | 'logout'

export function setCredentials(username: string, password: string): void {
  current = Object.freeze({ username, password })
  signedOut = null
  notify()
}

export function signOutReason(): SignOutReason | null {
  return signedOut
}

export function getCredentials(): Credentials | null {
  return current
}

export function hasCredentials(): boolean {
  return current !== null
}

/** Forget the credentials (logout, or any 401 from the supervisor). */
export function clearCredentials(reason: SignOutReason = 'refused'): void {
  if (current === null) return
  current = null
  signedOut = reason
  notify()
}

/** Subscribe to credential changes (useSyncExternalStore); returns the unsubscribe. */
export function subscribeCredentials(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

/** Base64 of the UTF-8 bytes of `text` (btoa alone only accepts Latin-1). */
export function base64Utf8(text: string): string {
  const bytes = new TextEncoder().encode(text)
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

/** `Basic base64(user:pass)` for the given credentials, else the held ones; null when none. */
export function authorizationHeader(credentials: Credentials | null = current): string | null {
  if (credentials === null) return null
  return `Basic ${base64Utf8(`${credentials.username}:${credentials.password}`)}`
}

export type LoginResult = { ok: true } | { ok: false; error: string }

/**
 * Verify `username`/`password` against the supervisor (GET /suggested-prompts, a credentialed
 * route that creates no thread). 200 → the credentials are held and the pipeline may render;
 * 401 → refused, nothing is held; anything else → the supervisor could not be asked, nothing is held.
 */
export async function login(
  username: string,
  password: string,
  options: { fetch?: FetchLike; base?: string } = {},
): Promise<LoginResult> {
  const doFetch: FetchLike = options.fetch ?? ((input, init) => fetch(input, init))
  const header = authorizationHeader({ username, password })
  if (!username || !password || header === null) {
    clearCredentials()
    return { ok: false, error: 'Enter a username and a password.' }
  }
  let response: Response
  try {
    response = await doFetch(`${options.base ?? API_BASE}/suggested-prompts`, {
      method: 'GET',
      headers: { authorization: header, accept: 'application/json' },
      credentials: 'omit',
      cache: 'no-store',
    })
  } catch {
    clearCredentials()
    return { ok: false, error: 'The supervisor could not be reached. Try again.' }
  }
  if (response.status === 200) {
    setCredentials(username, password)
    return { ok: true }
  }
  clearCredentials()
  if (response.status === 401) {
    return { ok: false, error: 'The supervisor refused these credentials.' }
  }
  return { ok: false, error: `The supervisor answered ${response.status}; the credentials were not verified.` }
}

/** Logout: the credentials are forgotten and the login form returns. */
export function logout(): void {
  clearCredentials('logout')
}
