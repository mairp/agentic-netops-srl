// The correlation identifier of a chunk, with a copy button (T125; FR-082): the key an operator
// hands over to retrieve the full trace.

import { useState } from 'react'

export function CorrelationChip({ id }: { id: string }) {
  const [copied, setCopied] = useState(false)
  if (!id) {
    return (
      <span className="chip chip-empty" data-testid="correlation-chip" data-correlation-id="">
        no correlation id
      </span>
    )
  }
  const copy = () => {
    const clipboard = typeof navigator !== 'undefined' ? navigator.clipboard : undefined
    if (!clipboard) return
    clipboard.writeText(id).then(
      () => setCopied(true),
      () => setCopied(false),
    )
  }
  return (
    <span className="chip" data-testid="correlation-chip" data-correlation-id={id}>
      <span className="chip-label">correlation</span>
      <code className="chip-id">{id}</code>
      <button type="button" className="chip-copy" onClick={copy} aria-label={`Copy correlation id ${id}`}>
        {copied ? 'Copied' : 'Copy'}
      </button>
    </span>
  )
}

export default CorrelationChip
