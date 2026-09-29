// One pipeline stage as a distinct, labelled step with its structured payload readable
// (T125; FR-080). The card names the agent that answered and its status; the payload is the
// stage's JSON, titled in operator terms (Interpretation, Assignment, Deployment).

import { Check } from 'lucide-react'
import type { StageChunk } from '../api/stream.ts'
import { CorrelationChip } from './CorrelationChip.tsx'
import { stageLabel } from './format.ts'

export function Payload({ payload, label }: { payload: Record<string, unknown>; label: string }) {
  if (Object.keys(payload).length === 0) return <p className="muted">no details</p>
  return (
    <details open>
      <summary>{label}</summary>
      <pre className="payload" data-testid="stage-payload" aria-label={`${label} JSON`}>
        {JSON.stringify(payload, null, 2)}
      </pre>
    </details>
  )
}

export function OutOfBandNote({ value }: { value: 'modified' | 'deleted' | undefined }) {
  if (!value) return null
  return (
    <p className="note note-warn" data-testid="out-of-band" data-out-of-band={value}>
      {value === 'modified' ? 'Modified outside the intent tier.' : 'Deleted outside the intent tier.'}
    </p>
  )
}

export function StageCard({ chunk }: { chunk: StageChunk }) {
  const label = stageLabel(chunk.stage)
  return (
    <section
      className={`event-card stage-event stage-${chunk.stage}`}
      data-testid="stage-card"
      data-stage={chunk.stage}
      data-status={chunk.status}
      aria-label={`${label} step`}
    >
      <header className="event-card-heading">
        <h3 className="event-stage">{chunk.stage}</h3>
        <span className="event-status">
          <Check size={12} />
          {chunk.status}
        </span>
        <CorrelationChip id={chunk.correlation_id} />
      </header>
      <OutOfBandNote value={chunk.out_of_band} />
      {chunk.message ? <p className="stage-message">{chunk.message}</p> : null}
      {chunk.resource ? (
        <p className="resource">
          Resource <code>{chunk.resource}</code>
        </p>
      ) : null}
      {chunk.resources && chunk.resources.length > 0 ? (
        <ul className="resources" data-testid="stage-resources" aria-label={`${label} resources`}>
          {chunk.resources.map((r) => (
            <li key={`${r.kind}/${r.name}`}>
              <code>
                {r.kind}/{r.name}
              </code>
            </li>
          ))}
        </ul>
      ) : null}
      {chunk.payload ? <Payload payload={chunk.payload} label={label} /> : <p className="stage-label">{label}</p>}
    </section>
  )
}

export default StageCard
