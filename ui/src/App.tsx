// The chat surface (T123-T125; FR-080 to FR-082, FR-102): the login gate until the supervisor
// accepts the operator's credentials, then the conversation. Any later 401 clears the in-memory
// credentials, which returns the page to the form.

import { useSyncExternalStore } from 'react'
import { Login } from './auth/Login.tsx'
import { getCredentials, logout, signOutReason, subscribeCredentials } from './auth/credentials.ts'
import { Conversation } from './chat/Conversation.tsx'

export default function App() {
  const credentials = useSyncExternalStore(subscribeCredentials, getCredentials, () => null)

  if (!credentials) {
    const notice =
      signOutReason() === 'refused' ? 'The supervisor refused the credentials; sign in again.' : undefined
    return <Login notice={notice} />
  }

  return (
    <div className="app">
      <header className="app-head">
        <h1>Agentic NetOps</h1>
        <span className="who">
          signed in as <strong>{credentials.username}</strong>
        </span>
        <button type="button" className="btn btn-secondary" data-testid="logout" onClick={logout}>
          Log out
        </button>
      </header>
      <main>
        <Conversation />
      </main>
    </div>
  )
}
