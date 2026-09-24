// One pipeline stage as a distinct, labelled step with its structured payload readable
// (T125; FR-080). The stage is named in operator terms (Interpretation, Assignment, Deployment).

import type { StageChunk } from '../api/stream.ts'
import { CorrelationChip } from './CorrelationChip.tsx'
import { stageLabel, statusWords } from './format.ts'

function isPlain(value: unknown): boolean {
  return value === null || ['string', 'number', 'boolean'].includes(typeof value)
}

function Value({ value }: { value: unknown }) {
  if (value === null) return <span className="value-null">none</span>
  if (typeof value === 'string') return <span className="value-text">{value}</span>
  if (typeof value === 'number' || typeof value === 'boolean') {
    return <span className="value-text">{String(value)}</span>
  }
  if (Array.isArray(value) && value.every(isPlain)) {
    return <span className="value-text">{value.map((v) => (v === null ? 'none' : String(v))).join(', ')}</span>
  }
  return <pre className="value-json">{JSON.stringify(value, null, 2)}</pre>
}

export function Payload({ payload }: { payload: Record<string, unknown> }) {
  const keys = Object.keys(payload)
  if (keys.length === 0) return <p className="muted">no details</p>
  return (
    <dl className="payload" data-testid="stage-payload">
      {keys.map((key) => (
        <div className="payload-row" key={key}>
          <dt>{key}</dt>
          <dd>
            <Value value={payload[key]} />
          </dd>
        </div>
      ))}
    </dl>
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
      className={`card stage-card stage-${chunk.stage}`}
      data-testid="stage-card"
      data-stage={chunk.stage}
      data-status={chunk.status}
      aria-label={`${label} step`}
    >
      <header className="card-head">
        <h3>{label}</h3>
        <span className="badge">{statusWords(chunk.status)}</span>
      </header>
      <OutOfBandNote value={chunk.out_of_band} />
      {chunk.message ? <p className="stage-message">{chunk.message}</p> : null}
      {chunk.resource ? (
        <p className="resource">
          Resource <code>{chunk.resource}</code>
        </p>
      ) : null}
      {chunk.resources && chunk.resources.length > 0 ? (
        <ul className="resources" data-testid="stage-resources">
          {chunk.resources.map((r) => (
            <li key={`${r.kind}/${r.name}`}>
              <code>
                {r.kind}/{r.name}
              </code>
            </li>
          ))}
        </ul>
      ) : null}
      {chunk.payload ? <Payload payload={chunk.payload} /> : null}
      <footer className="card-foot">
        <CorrelationChip id={chunk.correlation_id} />
      </footer>
    </section>
  )
}

export default StageCard
