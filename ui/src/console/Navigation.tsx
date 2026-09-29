// The console's top bar (ported from the predecessor, agentic-netops
// ui/src/components/Navigation): brand, runtime readiness, theme switch, the signed-in operator
// and Log out (FR-102).

import { Activity, HelpCircle, LogOut, Menu, Moon, Network, Sun, UserRound } from 'lucide-react'
import type { HealthState } from './health.ts'

interface Props {
  health: HealthState['status']
  theme: 'dark' | 'light'
  username: string
  onToggleTheme: () => void
  onToggleSidebar: () => void
  onLogout: () => void
}

export default function Navigation({ health, theme, username, onToggleTheme, onToggleSidebar, onLogout }: Props) {
  return (
    <header className="topbar">
      <div className="brand-group">
        <button className="icon-button mobile-menu" onClick={onToggleSidebar} title="Open navigation" aria-label="Open navigation">
          <Menu size={19} />
        </button>
        <div className="brand-mark" aria-hidden="true">
          <Network size={21} strokeWidth={2} />
        </div>
        <div className="brand-name">
          <strong>agentic-netops</strong>
          <span>Autonomous intent-to-fabric operations</span>
        </div>
        <span className="product-pill">INTENT FABRIC · SR LINUX</span>
      </div>

      <div className="topbar-actions">
        <div className={`runtime-pill ${health}`} data-testid="runtime-pill">
          <Activity size={14} />
          <span>{health === 'ok' ? 'Runtime ready' : health === 'checking' ? 'Checking runtime' : `Runtime ${health}`}</span>
        </div>
        <span className="who" title="Signed-in operator">
          <UserRound size={14} />
          <strong>{username}</strong>
        </span>
        <button
          className="icon-button"
          onClick={onToggleTheme}
          title={`Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`}
          aria-label={`Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`}
        >
          {theme === 'dark' ? <Sun size={18} /> : <Moon size={18} />}
        </button>
        <a
          className="icon-button"
          href="https://github.com/mairp/agentic-netops-srl"
          target="_blank"
          rel="noreferrer"
          title="Open project documentation"
          aria-label="Open project documentation"
        >
          <HelpCircle size={18} />
        </a>
        <button className="icon-button" data-testid="logout" onClick={onLogout} title="Log out" aria-label="Log out">
          <LogOut size={17} />
        </button>
      </div>
    </header>
  )
}
