// A confirmation point as an explicit, refusable action (T125; FR-081, FR-055): Confirm sends
// "yes" and Decline sends "no" on the same thread. The first confirmation of a request carrying
// an access list states the evaluation order, the usable priority range and what happens to
// unmatched traffic; that statement is also set apart as an "Access list" note.

import type { ConfirmationRequestChunk } from '../api/stream.ts'
import { CorrelationChip } from './CorrelationChip.tsx'
import { aclStatement, stageLabel } from './format.ts'

export type Answer = 'confirmed' | 'declined'

export interface ConfirmationProps {
  chunk: ConfirmationRequestChunk
  /** The interpretation this confirmation is about carries an access list. */
  acl?: boolean
  /** The operator's answer, once given. */
  answer?: Answer
  /** Whether the buttons can be used now (the latest open question, no turn streaming). */
  active?: boolean
  onConfirm?: () => void
  onDecline?: () => void
}

export function Confirmation({ chunk, acl = false, answer, active = false, onConfirm, onDecline }: ConfirmationProps) {
  const label = stageLabel(chunk.stage)
  const statement = aclStatement(chunk.prompt)
  const disabled = !active || answer !== undefined
  return (
    <section
      className={`card confirmation${answer ? ` answered answered-${answer}` : ''}`}
      data-testid="confirmation"
      data-stage={chunk.stage}
      data-answer={answer ?? ''}
      aria-label={`${label} confirmation`}
    >
      <header className="card-head">
        <h3>Confirm — {label}</h3>
      </header>
      <p className="confirm-prompt" data-testid="confirmation-prompt">
        {chunk.prompt}
      </p>
      {acl || statement ? (
        <aside className="acl-note" data-testid="acl-note">
          <strong>Access list</strong>
          <span>
            {statement ??
              'This request carries an access list; the supervisor did not state its evaluation order here.'}
          </span>
        </aside>
      ) : null}
      <div className="actions">
        <button
          type="button"
          className="btn btn-primary"
          data-testid="confirm-button"
          disabled={disabled}
          onClick={onConfirm}
        >
          Confirm
        </button>
        {chunk.refusable !== false ? (
          <button
            type="button"
            className="btn btn-secondary"
            data-testid="decline-button"
            disabled={disabled}
            onClick={onDecline}
          >
            Decline
          </button>
        ) : null}
        {answer ? (
          <span className="answer" data-testid="confirmation-answer">
            {answer === 'confirmed' ? 'You confirmed.' : 'You declined.'}
          </span>
        ) : null}
      </div>
      <footer className="card-foot">
        <CorrelationChip id={chunk.correlation_id} />
      </footer>
    </section>
  )
}

export default Confirmation
