// The conversation's state (T125; FR-080, FR-081, FR-082): an append-only transcript fed chunk by
// chunk from POST /agent/prompt/stream, the thread it continues, the open confirmation and the
// suggested prompts. Shared by the console's conversation panel, canvas and sidebar.

import { useCallback, useEffect, useRef, useState, type FormEvent, type RefObject } from 'react'
import {
  AuthError,
  HttpError,
  clientError,
  fetchSuggestedPrompts,
  streamPrompt,
  type SuggestedPrompt,
} from '../api/stream.ts'
import type { FetchLike } from '../auth/credentials.ts'
import type { Answer } from './Confirmation.tsx'
import { DECLINE_NOTICE, openConfirmation, type Answers, type Entry, type EntryInit } from './conversation.ts'

export interface ConversationState {
  entries: Entry[]
  answers: Answers
  threadId: string | undefined
  streaming: boolean
  input: string
  setInput: (value: string) => void
  suggestions: SuggestedPrompt[]
  suggestionNote: string | undefined
  /** The confirmation entry whose buttons are usable now, if any. */
  active: number | null
  submit: (event?: FormEvent) => void
  onAnswer: (entryId: number, answer: Answer) => void
  newThread: () => void
}

/**
 * The conversation's state and actions. `inputRef` is the composer the hook focuses after a
 * decline or a new thread; the panel that renders the composer owns it.
 */
export function useConversation(inputRef: RefObject<HTMLTextAreaElement | null>, fetchImpl?: FetchLike): ConversationState {
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
    [append, fetchImpl, inputRef],
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

  const newThread = () => {
    if (streaming) return
    threadRef.current = undefined
    setThreadId(undefined)
    if (entries.length > 0) append({ kind: 'divider' })
    inputRef.current?.focus()
  }

  const active = streaming ? null : openConfirmation(entries, answers)

  return {
    entries,
    answers,
    threadId,
    streaming,
    input,
    setInput,
    suggestions,
    suggestionNote,
    active,
    submit,
    onAnswer,
    newThread,
  }
}
