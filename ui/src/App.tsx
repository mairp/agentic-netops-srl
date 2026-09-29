// The chat surface (T123-T125; FR-080 to FR-082, FR-102): the login gate until the supervisor
// accepts the operator's credentials, then the operator console. Any later 401 clears the
// in-memory credentials, which returns the page to the form.
//
// The console is the predecessor's layout (agentic-netops ui/src/App.tsx): top bar, agent-network
// sidebar, the live A2A workflow canvas, and the conversation below a draggable divider.

import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react'
import { Login } from './auth/Login.tsx'
import { getCredentials, logout, signOutReason, subscribeCredentials } from './auth/credentials.ts'
import { ConversationPanel } from './chat/Conversation.tsx'
import { useConversation } from './chat/useConversation.ts'
import { activeStage } from './console/activity.ts'
import { useIntentHealth } from './console/health.ts'
import MainArea from './console/MainArea.tsx'
import Navigation from './console/Navigation.tsx'
import ResizeHandle from './console/ResizeHandle.tsx'
import Sidebar from './console/Sidebar.tsx'

/** Smallest conversation height that stays usable (header + a message + composer). */
const CHAT_MIN_HEIGHT = 220
/** Conversation height until the operator picks their own (persisted). */
const CHAT_DEFAULT_HEIGHT = 486
/** What the canvas keeps while the conversation is dragged to full screen: its heading bar. */
const CANVAS_MIN_HEIGHT = 62
/** Rendered height of the divider row between the panels. */
const DIVIDER_HEIGHT = 6
const CHAT_HEIGHT_KEY = 'agentic-netops-chat-height'
const THEME_KEY = 'agentic-netops-theme'

function loadChatHeight(): number {
  try {
    const parsed = Number.parseInt(localStorage.getItem(CHAT_HEIGHT_KEY) ?? '', 10)
    if (Number.isFinite(parsed) && parsed >= CHAT_MIN_HEIGHT) return parsed
  } catch {
    // Storage can be unavailable; the default applies.
  }
  return CHAT_DEFAULT_HEIGHT
}

function loadTheme(): 'dark' | 'light' {
  try {
    return localStorage.getItem(THEME_KEY) === 'light' ? 'light' : 'dark'
  } catch {
    return 'dark'
  }
}

function Console({ username }: { username: string }) {
  const inputRef = useRef<HTMLTextAreaElement>(null)
  const conversation = useConversation(inputRef)
  const health = useIntentHealth()
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [theme, setTheme] = useState(loadTheme)
  const toggleTheme = () => {
    setTheme((current) => {
      const next = current === 'dark' ? 'light' : 'dark'
      try {
        localStorage.setItem(THEME_KEY, next)
      } catch {
        // The theme still changes when storage is unavailable.
      }
      return next
    })
  }

  // Divider position between the workflow canvas and the conversation.
  const [chatExpanded, setChatExpanded] = useState(true)
  const [chatHeight, setChatHeight] = useState(loadChatHeight)
  const consoleRef = useRef<HTMLElement>(null)
  const [consoleHeight, setConsoleHeight] = useState(0)
  useEffect(() => {
    const el = consoleRef.current
    if (!el) return
    const measure = () => setConsoleHeight(el.clientHeight)
    measure()
    if (typeof ResizeObserver === 'undefined') {
      window.addEventListener('resize', measure)
      return () => window.removeEventListener('resize', measure)
    }
    const observer = new ResizeObserver(measure)
    observer.observe(el)
    return () => observer.disconnect()
  }, [])
  const chatMaxHeight = consoleHeight > 0 ? consoleHeight - CANVAS_MIN_HEIGHT - DIVIDER_HEIGHT : CHAT_DEFAULT_HEIGHT + 600
  const clampChatHeight = useCallback(
    (value: number) => Math.min(chatMaxHeight, Math.max(CHAT_MIN_HEIGHT, value)),
    [chatMaxHeight],
  )
  const safeChatHeight = clampChatHeight(chatHeight)
  const applyChatHeight = useCallback((value: number) => setChatHeight(clampChatHeight(value)), [clampChatHeight])
  const persistChatHeight = useCallback(
    (value: number) => {
      const clamped = clampChatHeight(value)
      setChatHeight(clamped)
      try {
        localStorage.setItem(CHAT_HEIGHT_KEY, String(Math.round(clamped)))
      } catch {
        // Storage can be unavailable; the size just is not remembered.
      }
    },
    [clampChatHeight],
  )
  const hasConversation = conversation.entries.length > 0

  return (
    <div className="app-shell" data-theme={theme}>
      <Navigation
        health={health.status}
        theme={theme}
        username={username}
        onToggleTheme={toggleTheme}
        onToggleSidebar={() => setSidebarOpen((open) => !open)}
        onLogout={logout}
      />
      <div className="workspace">
        <Sidebar
          open={sidebarOpen}
          health={health}
          activeStage={activeStage(conversation.entries)}
          streaming={conversation.streaming}
          threadId={conversation.threadId}
          onClose={() => setSidebarOpen(false)}
          onNewThread={conversation.newThread}
        />
        {sidebarOpen && (
          <button className="sidebar-scrim" aria-label="Close navigation" onClick={() => setSidebarOpen(false)} />
        )}
        <main className="operator-console" ref={consoleRef}>
          <MainArea entries={conversation.entries} pending={conversation.streaming} health={health} />
          {chatExpanded && hasConversation && (
            <ResizeHandle
              height={safeChatHeight}
              min={CHAT_MIN_HEIGHT}
              max={chatMaxHeight}
              resetValue={CHAT_DEFAULT_HEIGHT}
              onResize={applyChatHeight}
              onResizeEnd={persistChatHeight}
            />
          )}
          <ConversationPanel
            conversation={conversation}
            inputRef={inputRef}
            expanded={chatExpanded}
            onExpandedChange={setChatExpanded}
            height={safeChatHeight}
          />
        </main>
      </div>
    </div>
  )
}

export default function App() {
  const credentials = useSyncExternalStore(subscribeCredentials, getCredentials, () => null)

  if (!credentials) {
    const notice =
      signOutReason() === 'refused' ? 'The supervisor refused the credentials; sign in again.' : undefined
    return <Login notice={notice} />
  }

  return <Console username={credentials.username} />
}
