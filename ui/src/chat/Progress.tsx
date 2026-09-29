// Convergence as it arrives (T125; FR-081, FR-054, AD-62, AD-63). A progress chunk's `ready` is
// the Ready condition's status string and is rendered by its three values:
//   "True"                      converged — the resource is ready (success)
//   "Unknown"                   readiness unknown, naming the target and the reason (neither
//                               success nor error: a re-verification that could not run)
//   "False", reason "Deleting"  removal in progress (neither success nor error)
//   "False", any other reason   not ready yet, still in progress
// A final chunk renders its redacted message rather than its status token; a removal's final at
// PROVISIONING is in progress with what is outstanding — never converged, never an error card.

import { Check, CircleAlert, CircleHelp, LoaderCircle } from 'lucide-react'
import type { FinalChunk, ProgressChunk } from '../api/stream.ts'
import { CorrelationChip } from './CorrelationChip.tsx'
import { finalView, progressView, type Tone } from './format.ts'

function ToneIcon({ tone }: { tone: Tone }) {
  if (tone === 'success') return <Check size={13} />
  if (tone === 'progress') return <LoaderCircle size={13} className="spin-slow" />
  if (tone === 'failure') return <CircleAlert size={13} />
  return <CircleHelp size={13} />
}

export function Progress({ chunk }: { chunk: ProgressChunk }) {
  const view = progressView(chunk)
  return (
    <div
      className={`feed-line progress tone-${view.tone}`}
      data-testid="progress"
      data-ready={chunk.ready ?? ''}
      data-reason={chunk.reason ?? ''}
      data-tone={view.tone}
      role="status"
    >
      <ToneIcon tone={view.tone} />
      <span className="progress-title">{view.title}</span>
      <span className="progress-detail">{view.detail}</span>
    </div>
  )
}

export function FinalOutcome({ chunk }: { chunk: FinalChunk }) {
  const view = finalView(chunk)
  return (
    <section className={`event-card final-event tone-${view.tone}`} data-testid="final" data-status={chunk.status} data-tone={view.tone}>
      <header className="event-card-heading">
        <ToneIcon tone={view.tone} />
        <h3 className="event-stage">{view.title}</h3>
        <CorrelationChip id={chunk.correlation_id} />
      </header>
      <p className="final-message" data-testid="final-message">
        {view.text}
      </p>
    </section>
  )
}

export default Progress
