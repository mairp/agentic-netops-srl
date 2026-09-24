// The login gate (T123; FR-102): the operator's credentials are verified against the supervisor
// before anything of the pipeline renders, and held in memory only (credentials.ts). A refused
// credential keeps the form with an error; nothing is stored anywhere.

import { useState, type FormEvent } from 'react'
import { login, type FetchLike } from './credentials.ts'

export interface LoginProps {
  fetch?: FetchLike
  /** Shown above the form, e.g. when a later call was refused and the operator was signed out. */
  notice?: string
}

export function Login({ fetch: fetchImpl, notice }: LoginProps) {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (busy) return
    setBusy(true)
    setError(null)
    const result = await login(username, password, { fetch: fetchImpl })
    setBusy(false)
    if (!result.ok) setError(result.error)
    // on success the credential store changes and App replaces this form with the conversation
  }

  return (
    <main className="login">
      <form className="card login-card" data-testid="login-form" onSubmit={submit} autoComplete="off">
        <h1>Agentic NetOps</h1>
        <p className="muted">Sign in with the operator credentials the provisioning script generated.</p>
        {notice ? <p className="note note-warn">{notice}</p> : null}
        <label>
          Username
          <input
            data-testid="login-username"
            name="username"
            autoComplete="username"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            required
          />
        </label>
        <label>
          Password
          <input
            data-testid="login-password"
            name="password"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
          />
        </label>
        {error ? (
          <p className="login-error" data-testid="login-error" role="alert">
            {error}
          </p>
        ) : null}
        <button type="submit" className="btn btn-primary" data-testid="login-submit" disabled={busy}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
        <p className="muted small">Lab credentials over loopback HTTP — not production-safe. They are kept in this page's memory only.</p>
      </form>
    </main>
  )
}

export default Login
