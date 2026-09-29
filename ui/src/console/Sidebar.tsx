// The console's navigation column (ported from the predecessor, agentic-netops
// ui/src/components/Sidebar): the agent network with each worker's readiness from /v1/health, the
// A2A transport, and the session's thread.

import type { CSSProperties } from 'react'
import { Bot, Braces, Check, Circle, MessageSquarePlus, Network, Route, ServerCog, ShieldCheck, X } from 'lucide-react'
import type { Stage } from '../api/stream.ts'
import type { HealthState } from './health.ts'
import { useSectionZoom } from './useSectionZoom.ts'
import ZoomControls from './ZoomControls.tsx'

interface Props {
  open: boolean
  health: HealthState
  activeStage: Stage | ''
  streaming: boolean
  threadId: string | undefined
  onClose: () => void
  onNewThread: () => void
}

/** The sidebar scales independently of every other section (80%–150%). */
const SIDEBAR_ZOOM = { min: 0.8, max: 1.5, step: 0.1 }

const stages = [
  { id: 'supervisor', label: 'Supervisor', detail: 'Intent routing', icon: Bot },
  { id: 'mapper', label: 'Mapper', detail: 'Service interpretation', icon: Route },
  { id: 'allocator', label: 'Allocator', detail: 'Identifier claims', icon: Braces },
  { id: 'deployer', label: 'Deployer', detail: 'Resource submission', icon: ServerCog },
] as const

export default function Sidebar({ open, health, activeStage, streaming, threadId, onClose, onNewThread }: Props) {
  const { zoom, zoomIn, zoomOut, resetZoom } = useSectionZoom('agentic-netops-zoom-sidebar', SIDEBAR_ZOOM)
  const zoomStyle = { zoom } as CSSProperties
  const workers = Object.values(health.workers)
  const readyWorkers = workers.filter((w) => w === 'ok').length + (health.status === 'ok' ? 1 : 0)

  return (
    <aside className={`sidebar ${open ? 'open' : ''}`} style={zoomStyle} aria-label="Agent navigation">
      <button className="sidebar-close" onClick={onClose} aria-label="Close navigation">
        <X size={18} />
      </button>

      <section className="sidebar-section conversation-section">
        <span className="section-label">CONVERSATION</span>
        <div className="conversation-title">Network provisioning</div>
        <div className="selected-nav-item">
          <Network size={16} /> Agent to Agent
        </div>
      </section>

      <section className="sidebar-section">
        <div className="section-heading">
          <span className="section-label">AGENT NETWORK</span>
          <span className="section-count">{health.status === 'checking' ? '--' : `${readyWorkers}/${stages.length}`}</span>
        </div>
        <div className="agent-list">
          {stages.map(({ id, label, detail, icon: Icon }) => {
            const ready = id === 'supervisor' ? health.status === 'ok' : health.workers[id] === 'ok'
            const active = streaming && activeStage === id
            return (
              <div className={`agent-list-item ${active ? 'active' : ''}`} key={id} data-agent={id}>
                <div className="agent-list-icon">
                  <Icon size={16} />
                </div>
                <div className="agent-list-copy">
                  <strong>{label}</strong>
                  <span>{detail}</span>
                </div>
                <span
                  className={`status-dot ${active ? 'active' : ready ? 'ready' : 'muted'}`}
                  title={active ? 'Active' : ready ? 'Ready' : 'Unavailable'}
                />
              </div>
            )
          })}
        </div>
      </section>

      <section className="sidebar-section">
        <span className="section-label">TRANSPORT</span>
        <div className="transport-summary">
          <div className="transport-icon">
            <ShieldCheck size={17} />
          </div>
          <div>
            <strong>A2A over {health.transport || 'SLIM'}</strong>
            <span>{health.status === 'ok' ? 'AGNTCY SLIM · TLS channel ready' : 'Waiting for runtime'}</span>
          </div>
          {health.status === 'ok' ? <Check size={15} className="ready-icon" /> : <Circle size={14} className="muted-icon" />}
        </div>
      </section>

      <section className="sidebar-section session-section">
        <div className="section-heading">
          <span className="section-label">SESSION</span>
          <span className="section-heading-tools">
            <ZoomControls
              label="navigation sidebar"
              zoom={zoom}
              min={SIDEBAR_ZOOM.min}
              max={SIDEBAR_ZOOM.max}
              onZoomIn={zoomIn}
              onZoomOut={zoomOut}
              onReset={resetZoom}
            />
            <button
              className="mini-icon-button"
              onClick={onNewThread}
              disabled={streaming}
              title="New conversation"
              aria-label="New conversation"
            >
              <MessageSquarePlus size={14} />
            </button>
          </span>
        </div>
        <div className="thread-id">
          <span>Thread</span>
          <code>{threadId ? threadId.slice(0, 12) : 'New session'}</code>
        </div>
      </section>
    </aside>
  )
}
