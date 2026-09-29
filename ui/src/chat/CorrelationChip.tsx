// The correlation identifier of a chunk, with a copy button (T125; FR-082): the key an operator
// hands over to retrieve the full trace. Shown short, in the predecessor console's style; the
// full id is the chip's title, its data attribute and what Copy puts on the clipboard.

import { useState } from 'react'
import { Check, Copy } from 'lucide-react'

/** `full` shows the whole id (a failure card, where the operator must hand it over); otherwise 8 chars. */
export function CorrelationChip({ id, full = false }: { id: string; full?: boolean }) {
  const [copied, setCopied] = useState(false)
  if (!id) {
    return (
      <span className="correlation-chip chip-empty" data-testid="correlation-chip" data-correlation-id="">
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
    <span className="correlation-chip" data-testid="correlation-chip" data-correlation-id={id} title={`correlation ${id}`}>
      <button type="button" className="chip-copy" onClick={copy} aria-label={`Copy correlation id ${id}`}>
        {copied ? <Check size={11} /> : <Copy size={11} />}
        <code className="chip-id">{full ? id : id.slice(0, 8)}</code>
      </button>
    </span>
  )
}

export default CorrelationChip
