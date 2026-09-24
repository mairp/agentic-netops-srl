// The supervisor's suggested prompts (GET /suggested-prompts; FR-084): the constructs on the site's
// real inventory. Clicking one fills the input; nothing is sent until the operator sends it.

import type { SuggestedPrompt } from '../api/stream.ts'

export interface SuggestedPromptsProps {
  prompts: SuggestedPrompt[]
  note?: string
  onPick: (prompt: string) => void
  disabled?: boolean
}

export function SuggestedPrompts({ prompts, note, onPick, disabled = false }: SuggestedPromptsProps) {
  if (prompts.length === 0 && !note) return null
  return (
    <section className="suggested" aria-label="Suggested prompts">
      <h2>Suggested prompts</h2>
      {note ? <p className="muted">{note}</p> : null}
      <ul>
        {prompts.map((p) => (
          <li key={`${p.shape}:${p.prompt}`}>
            <button
              type="button"
              className="suggested-prompt"
              data-testid="suggested-prompt"
              data-shape={p.shape}
              data-construct={p.construct}
              disabled={disabled}
              onClick={() => onPick(p.prompt)}
            >
              <span className="construct-tag">{p.construct}</span>
              <span>{p.prompt}</span>
            </button>
          </li>
        ))}
      </ul>
    </section>
  )
}

export default SuggestedPrompts
