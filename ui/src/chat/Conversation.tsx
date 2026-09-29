// The conversation (T125; FR-080, FR-081, FR-082): the operator's requests and the pipeline's
// answer to each, chunk by chunk as it streams — stages as labelled steps, both confirmations as
// explicit Confirm/Decline actions on the same thread, convergence live without a reload, failures
// named by stage with their correlation id.
//
// The state lives in useConversation (useConversation.ts) so the console's canvas and sidebar follow the same stream;
// ConversationPanel is the predecessor console's chat panel (agentic-netops ui/src/components/Chat):
// a collapsible, zoomable transcript above a rounded composer with a suggested-prompts menu.

import { useEffect, useRef, type CSSProperties, type KeyboardEvent, type RefObject } from 'react'
import { ChevronDown, LoaderCircle, MessageSquarePlus, Send } from 'lucide-react'
import { useSectionZoom } from '../console/useSectionZoom.ts'
import ZoomControls from '../console/ZoomControls.tsx'
import { Confirmation, type Answer } from './Confirmation.tsx'
import { ErrorCard } from './ErrorCard.tsx'
import { FinalOutcome, Progress } from './Progress.tsx'
import { StageCard } from './StageCard.tsx'
import { SuggestedPrompts } from './SuggestedPrompts.tsx'
import { aclBefore, type Answers, type Entry } from './conversation.ts'
import type { ConversationState } from './useConversation.ts'

export interface TranscriptProps {
  entries: readonly Entry[]
  answers?: Answers
  /** The confirmation entry whose buttons are usable, if any. */
  active?: number | null
  onAnswer?: (entryId: number, answer: Answer) => void
}

export function Transcript({ entries, answers = {}, active = null, onAnswer }: TranscriptProps) {
  return (
    <ol className="transcript event-feed" data-testid="transcript" aria-live="polite">
      {entries.map((entry, index) => {
        let body
        switch (entry.kind) {
          case 'operator':
            body = (
              <div className="user-message" data-testid="operator-message">
                <span>You</span>
                <p>{entry.text}</p>
              </div>
            )
            break
          case 'notice':
            body = (
              <p className="cancelled-message" data-testid={entry.testId}>
                {entry.text}
              </p>
            )
            break
          case 'divider':
            body = (
              <div className="divider" data-testid="thread-divider">
                <span>New conversation</span>
              </div>
            )
            break
          case 'chunk': {
            const chunk = entry.chunk
            switch (chunk.type) {
              case 'status':
                body = (
                  <div className="feed-line muted status-line" data-testid="status-line" data-stage={chunk.stage} data-status={chunk.status}>
                    {chunk.status} · {chunk.stage}
                    {chunk.message ? <span className="status-message"> — {chunk.message}</span> : null}
                  </div>
                )
                break
              case 'stage':
                body = <StageCard chunk={chunk} />
                break
              case 'confirmation_request':
                body = (
                  <Confirmation
                    chunk={chunk}
                    acl={aclBefore(entries, index)}
                    answer={answers[entry.id]}
                    active={active === entry.id}
                    onConfirm={() => onAnswer?.(entry.id, 'confirmed')}
                    onDecline={() => onAnswer?.(entry.id, 'declined')}
                  />
                )
                break
              case 'progress':
                body = <Progress chunk={chunk} />
                break
              case 'final':
                body = <FinalOutcome chunk={chunk} />
                break
              case 'error':
                body = <ErrorCard chunk={chunk} />
                break
            }
            break
          }
        }
        return (
          <li key={entry.id} className={`entry entry-${entry.kind}`}>
            {body}
          </li>
        )
      })}
    </ol>
  )
}

/** The conversation scales independently of every other section (80%–150%). */
const CHAT_ZOOM = { min: 0.8, max: 1.5, step: 0.1 }

export interface ConversationPanelProps {
  conversation: ConversationState
  /** The composer textarea (shared with useConversation, which focuses it). */
  inputRef: RefObject<HTMLTextAreaElement | null>
  /** Whether the transcript is expanded (owned by the console so the divider can react). */
  expanded: boolean
  onExpandedChange: (expanded: boolean) => void
  /** Divider-controlled panel height in px (applied while expanded with a transcript). */
  height: number
}

export function ConversationPanel({ conversation: c, inputRef, expanded, onExpandedChange, height }: ConversationPanelProps) {
  const { zoom, zoomIn, zoomOut, resetZoom } = useSectionZoom('agentic-netops-zoom-chat', CHAT_ZOOM)
  const zoomStyle = { zoom } as CSSProperties
  const endRef = useRef<HTMLDivElement | null>(null)
  const menuRef = useRef<HTMLDetailsElement | null>(null)
  const hasConversation = c.entries.length > 0
  const sized = hasConversation && expanded
  const latest = [...c.entries].reverse().find((e) => e.kind === 'chunk' && e.chunk.correlation_id)
  const latestCorrelation = latest && latest.kind === 'chunk' ? latest.chunk.correlation_id : undefined

  useEffect(() => {
    endRef.current?.scrollIntoView?.({ block: 'end' })
  }, [c.entries])

  // The draft grows with its content (typed or picked from the menu) up to a readable cap.
  useEffect(() => {
    const el = inputRef.current
    if (!el) return
    el.style.height = 'auto'
    el.style.height = `${Math.min(el.scrollHeight, 160)}px`
  }, [c.input, inputRef])

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault()
      onExpandedChange(true)
      c.submit()
    }
  }

  const zoomControls = (
    <ZoomControls label="conversation" zoom={zoom} min={CHAT_ZOOM.min} max={CHAT_ZOOM.max} onZoomIn={zoomIn} onZoomOut={zoomOut} onReset={resetZoom} />
  )

  return (
    <section
      className={`chat-panel conversation ${sized ? 'expanded sized' : ''}`}
      style={sized ? { height: `${Math.round(height)}px` } : undefined}
      aria-label="Agent conversation"
      data-testid="conversation"
      data-streaming={c.streaming ? 'true' : 'false'}
    >
      {hasConversation && (
        <div className="chat-header" style={zoomStyle}>
          <button type="button" className="chat-title" onClick={() => onExpandedChange(!expanded)} aria-expanded={expanded}>
            <ChevronDown size={16} className={expanded ? '' : 'collapsed'} />
            <span>Agent conversation</span>
            {latestCorrelation ? <code>{latestCorrelation.slice(0, 8)}</code> : null}
          </button>
          <div className="chat-header-tools">
            {c.streaming ? (
              <span className="streaming" data-testid="streaming-indicator">
                <LoaderCircle size={12} className="spin" /> receiving…
              </span>
            ) : null}
            {zoomControls}
          </div>
        </div>
      )}

      {hasConversation && (
        <div className="conversation-body" style={zoomStyle} hidden={!expanded}>
          <Transcript entries={c.entries} answers={c.answers} active={c.active} onAnswer={c.onAnswer} />
          <div ref={endRef} />
        </div>
      )}

      <div className="composer-wrap" style={zoomStyle}>
        <div className="composer-meta">
          <div className="composer-meta-tools">
            <details className="prompt-menu" ref={menuRef}>
              <summary className="prompt-select">
                Suggested prompts <ChevronDown size={14} />
              </summary>
              <div className="prompt-menu-list">
                <SuggestedPrompts
                  prompts={c.suggestions}
                  note={c.suggestionNote}
                  disabled={c.streaming}
                  onPick={(p) => {
                    c.setInput(p)
                    if (menuRef.current) menuRef.current.open = false
                    inputRef.current?.focus()
                  }}
                />
              </div>
            </details>
            <button
              type="button"
              className="secondary-button"
              data-testid="new-thread"
              onClick={c.newThread}
              disabled={c.streaming}
              title="Start a new thread (the transcript is kept)"
            >
              <MessageSquarePlus size={14} /> New conversation
            </button>
          </div>
          <div className="composer-meta-tools">
            {!hasConversation && zoomControls}
            <span className="thread-label">
              Thread:{' '}
              <code data-testid="thread-id" title="The thread every message of this conversation continues">
                {c.threadId ? c.threadId.slice(0, 8) : 'new'}
              </code>
            </span>
          </div>
        </div>
        <form
          className="composer"
          onSubmit={(event) => {
            onExpandedChange(true)
            c.submit(event)
          }}
        >
          <textarea
            ref={inputRef}
            data-testid="prompt-input"
            aria-label="Service request"
            placeholder="Describe the service you want on the fabric…"
            value={c.input}
            rows={1}
            onChange={(e) => c.setInput(e.target.value)}
            onKeyDown={onKeyDown}
          />
          <button type="submit" data-testid="prompt-send" disabled={c.streaming} title="Send intent" aria-label="Send intent">
            {c.streaming ? <LoaderCircle className="spin" size={18} /> : <Send size={18} />}
          </button>
        </form>
      </div>
    </section>
  )
}

export default ConversationPanel
