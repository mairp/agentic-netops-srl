// A stage failure in operator terms (T125; FR-082): which step failed, the reason in words and the
// correlation id to retrieve the full trace — never a stack trace.

import type { ErrorChunk } from '../api/stream.ts'
import { CorrelationChip } from './CorrelationChip.tsx'
import { OutOfBandNote } from './StageCard.tsx'
import { readableReason, stageLabel } from './format.ts'

export function ErrorCard({ chunk }: { chunk: ErrorChunk }) {
  const title = chunk.client
    ? 'The chat surface could not complete this turn'
    : `The ${stageLabel(chunk.stage)} step failed`
  return (
    <section
      className="card error-card"
      data-testid="error-card"
      data-stage={chunk.stage}
      data-client={chunk.client ? 'true' : undefined}
      role="alert"
    >
      <header className="card-head">
        <h3>{title}</h3>
      </header>
      <OutOfBandNote value={chunk.out_of_band} />
      <p className="error-reason" data-testid="error-reason">
        {readableReason(chunk.reason)}
      </p>
      {chunk.retryable ? (
        <p className="muted">The thread stays open: you can retry or amend the request.</p>
      ) : null}
      <footer className="card-foot">
        <CorrelationChip id={chunk.correlation_id} />
      </footer>
    </section>
  )
}

export default ErrorCard
