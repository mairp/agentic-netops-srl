// The conversation view (T125; FR-080, FR-081, FR-082): the operator's requests and the pipeline's
// answer to each, chunk by chunk as it streams — stages as labelled steps, both confirmations as
// explicit Confirm/Decline actions on the same thread, convergence live without a reload, failures
// named by stage with their correlation id.

import { useCallback, useEffect, useRef, useState, type FormEvent, type KeyboardEvent } from 'react'
import {
  AuthError,
  HttpError,
  clientError,
  fetchSuggestedPrompts,
  streamPrompt,
  type SuggestedPrompt,
} from '../api/stream.ts'
import type { FetchLike } from '../auth/credentials.ts'
import { Confirmation, type Answer } from './Confirmation.tsx'
import { ErrorCard } from './ErrorCard.tsx'
import { FinalOutcome, Progress } from './Progress.tsx'
import { StageCard } from './StageCard.tsx'
import { SuggestedPrompts } from './SuggestedPrompts.tsx'
import { DECLINE_NOTICE, aclBefore, openConfirmation, type Answers, type Entry, type EntryInit } from './conversation.ts'
import { stageLabel, statusWords } from './format.ts'

export interface TranscriptProps {
  entries: readonly Entry[]
  answers?: Answers
  /** The confirmation entry whose buttons are usable, if any. */
  active?: number | null
  onAnswer?: (entryId: number, answer: Answer) => void
}

export function Transcript({ entries, answers = {}, active = null, onAnswer }: TranscriptProps) {
  return (
    <ol className="transcript" data-testid="transcript">
      {entries.map((entry, index) => {
        let body
        switch (entry.kind) {
          case 'operator':
            body = (
              <div className="bubble operator" data-testid="operator-message">
                {entry.text}
              </div>
            )
            break
          case 'notice':
            body = (
              <p className="notice" data-testid={entry.testId}>
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
                  <div className="status-line" data-testid="status-line" data-stage={chunk.stage} data-status={chunk.status}>
                    <strong>{stageLabel(chunk.stage)}</strong> {chunk.message ?? statusWords(chunk.status)}
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

export interface ConversationProps {
  fetch?: FetchLike
}

export function Conversation({ fetch: fetchImpl }: ConversationProps) {
  const [entries, setEntries] = useState<Entry[]>([])
  const [answers, setAnswers] = useState<Answers>({})
  const [threadId, setThreadId] = useState<string | undefined>(undefined)
  const [streaming, setStreaming] = useState(false)
  const [input, setInput] = useState('')
  const [suggestions, setSuggestions] = useState<SuggestedPrompt[]>([])
  const [suggestionNote, setSuggestionNote] = useState<string | undefined>(undefined)
  const threadRef = useRef<string | undefined>(undefined)
  const nextId = useRef(1)
  const controller = useRef<AbortController | null>(null)
  const endRef = useRef<HTMLDivElement | null>(null)
  const inputRef = useRef<HTMLTextAreaElement | null>(null)

  const append = useCallback((entry: EntryInit) => {
    const id = nextId.current
    nextId.current += 1
    setEntries((prev) => [...prev, { ...entry, id } as Entry])
    return id
  }, [])

  useEffect(() => {
    const abort = new AbortController()
    fetchSuggestedPrompts({ fetch: fetchImpl, signal: abort.signal }).then(
      (result) => {
        setSuggestions(result.prompts)
        setSuggestionNote(result.note)
      },
      (err: unknown) => {
        if (err instanceof AuthError || abort.signal.aborted) return
        setSuggestionNote(err instanceof HttpError ? `Suggested prompts unavailable: ${err.reason}` : undefined)
      },
    )
    return () => abort.abort()
  }, [fetchImpl])

  useEffect(() => () => controller.current?.abort(), [])

  useEffect(() => {
    endRef.current?.scrollIntoView?.({ block: 'end' })
  }, [entries])

  const send = useCallback(
    async (text: string, answer?: Answer) => {
      const prompt = text.trim()
      if (!prompt || controller.current) return
      append({ kind: 'operator', text: answer ? (answer === 'confirmed' ? 'Confirm (yes)' : 'Decline (no)') : prompt })
      const abort = new AbortController()
      controller.current = abort
      setStreaming(true)
      let failed = false
      try {
        await streamPrompt(
          { prompt, threadId: threadRef.current },
          (chunk) => {
            if (chunk.thread_id) {
              threadRef.current = chunk.thread_id
              setThreadId(chunk.thread_id)
            }
            if (chunk.type === 'error') failed = true
            append({ kind: 'chunk', chunk })
          },
          { fetch: fetchImpl, signal: abort.signal },
        )
      } catch (err) {
        failed = true
        if (err instanceof AuthError || abort.signal.aborted) return
        const reason =
          err instanceof HttpError
            ? `the supervisor refused the request (${err.status}): ${err.reason}`
            : `the supervisor could not be reached: ${err instanceof Error ? err.message : String(err)}`
        append({ kind: 'chunk', chunk: clientError(reason, { threadId: threadRef.current }) })
      } finally {
        controller.current = null
        setStreaming(false)
      }
      if (answer === 'declined' && !failed) {
        append({ kind: 'notice', text: DECLINE_NOTICE, testId: 'decline-notice' })
        inputRef.current?.focus()
      }
    },
    [append, fetchImpl],
  )

  const onAnswer = useCallback(
    (entryId: number, answer: Answer) => {
      if (controller.current) return
      setAnswers((prev) => ({ ...prev, [entryId]: answer }))
      void send(answer === 'confirmed' ? 'yes' : 'no', answer)
    },
    [send],
  )

  const submit = (event?: FormEvent) => {
    event?.preventDefault()
    if (streaming || !input.trim()) return
    const text = input
    setInput('')
    void send(text)
  }

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault()
      submit()
    }
  }

  const newThread = () => {
    if (streaming) return
    threadRef.current = undefined
    setThreadId(undefined)
    if (entries.length > 0) append({ kind: 'divider' })
    inputRef.current?.focus()
  }

  const active = streaming ? null : openConfirmation(entries, answers)

  return (
    <div className="conversation" data-testid="conversation" data-streaming={streaming ? 'true' : 'false'}>
      <div className="thread-bar">
        <span className="thread-label">Thread</span>
        <code className="thread-id" data-testid="thread-id" title="The thread every message of this conversation continues">
          {threadId ?? 'new'}
        </code>
        <button type="button" className="btn btn-secondary" data-testid="new-thread" onClick={newThread} disabled={streaming}>
          New conversation
        </button>
        {streaming ? (
          <span className="streaming" data-testid="streaming-indicator">
            receiving…
          </span>
        ) : null}
      </div>
      {entries.length === 0 ? (
        <SuggestedPrompts
          prompts={suggestions}
          note={suggestionNote}
          onPick={(p) => {
            setInput(p)
            inputRef.current?.focus()
          }}
        />
      ) : null}
      <Transcript entries={entries} answers={answers} active={active} onAnswer={onAnswer} />
      <div ref={endRef} />
      <form className="composer" onSubmit={submit}>
        <textarea
          ref={inputRef}
          data-testid="prompt-input"
          aria-label="Request"
          placeholder="Describe the service, answer a question, or amend the request"
          value={input}
          rows={3}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={onKeyDown}
        />
        <button type="submit" className="btn btn-primary" data-testid="prompt-send" disabled={streaming}>
          Send
        </button>
      </form>
      {entries.length > 0 && suggestions.length > 0 ? (
        <details className="suggested-later">
          <summary>Suggested prompts</summary>
          <SuggestedPrompts prompts={suggestions} onPick={(p) => setInput(p)} disabled={streaming} />
        </details>
      ) : null}
    </div>
  )
}

export default Conversation
