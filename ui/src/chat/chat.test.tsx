// T125 (FR-080 to FR-082, AD-62, AD-63): the conversation's cards rendered to static markup.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { renderToStaticMarkup } from 'react-dom/server'
import type {
  ConfirmationRequestChunk,
  ErrorChunk,
  FinalChunk,
  ProgressChunk,
  StageChunk,
} from '../api/stream.ts'
import { Confirmation } from './Confirmation.tsx'
import { Transcript } from './Conversation.tsx'
import { CorrelationChip } from './CorrelationChip.tsx'
import { ErrorCard } from './ErrorCard.tsx'
import { FinalOutcome, Progress } from './Progress.tsx'
import { StageCard } from './StageCard.tsx'
import { SuggestedPrompts } from './SuggestedPrompts.tsx'
import { DECLINE_NOTICE, openConfirmation, type Entry } from './conversation.ts'
import { readableReason } from './format.ts'

const CID = '4bf92f3577b34da6a3ce929d0e0e4736'
const TRACEBACK = /Traceback \(most recent call last\)|File "[^"]+", line \d+|\bat [\w.$<>]+ \([^)]*:\d+:\d+\)/

/** The visible text of markup (tags dropped, entities decoded). */
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, ' ')
    .replace(/&quot;/g, '"')
    .replace(/&#x27;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim()

const progress = (ready: ProgressChunk['ready'], reason?: string): ProgressChunk => ({
  type: 'progress',
  correlation_id: CID,
  status: ready === 'True' ? 'VERIFIED' : 'PROVISIONING',
  resource: 'Network/migr-svc1',
  ...(ready ? { ready } : {}),
  ...(reason ? { reason } : {}),
})

test('Progress "True" is converged/ready', () => {
  const html = renderToStaticMarkup(<Progress chunk={progress('True')} />)
  assert.match(html, /data-testid="progress"/)
  assert.match(html, /data-ready="True"/)
  assert.match(html, /data-tone="success"/)
  assert.match(text(html), /Converged/)
  assert.match(text(html), /Network\/migr-svc1 is ready/)
})

test('Progress "Unknown" is readiness unknown naming the target and reason — not success, not error', () => {
  const html = renderToStaticMarkup(<Progress chunk={progress('Unknown', 'VerificationFailed')} />)
  assert.match(html, /data-ready="Unknown"/)
  assert.match(html, /data-reason="VerificationFailed"/)
  assert.match(html, /data-tone="warning"/)
  assert.match(text(html), /readiness unknown for Network\/migr-svc1: VerificationFailed/)
  assert.doesNotMatch(html, /tone-success|tone-failure|error-card/)
  assert.doesNotMatch(text(html), /Converged|ready\./)
})

test('Progress "False"/"Deleting" is a removal in progress — not success, not error', () => {
  const html = renderToStaticMarkup(<Progress chunk={progress('False', 'Deleting')} />)
  assert.match(html, /data-ready="False"/)
  assert.match(html, /data-reason="Deleting"/)
  assert.match(html, /data-tone="progress"/)
  assert.match(text(html), /removal in progress/i)
  assert.doesNotMatch(html, /tone-success|tone-failure|error-card/)
})

test('Progress "False" with another reason is not ready yet, in progress', () => {
  const html = renderToStaticMarkup(<Progress chunk={progress('False', 'TargetUnreachable')} />)
  assert.match(html, /data-tone="progress"/)
  assert.match(text(html), /not ready yet: TargetUnreachable/)
  assert.doesNotMatch(html, /tone-success|tone-failure/)
})

test('final PROVISIONING is in progress with what is outstanding — never converged, never an error card', () => {
  const chunk: FinalChunk = {
    type: 'final',
    correlation_id: CID,
    status: 'PROVISIONING',
    message: 'removal in progress: waiting on leaf02 (TargetUnreachable); it completes when the target returns',
  }
  const html = renderToStaticMarkup(<FinalOutcome chunk={chunk} />)
  assert.match(html, /data-testid="final"/)
  assert.match(html, /data-status="PROVISIONING"/)
  assert.match(html, /data-tone="progress"/)
  assert.doesNotMatch(html, /error-card|tone-success|tone-failure/)
  const t = text(html)
  assert.match(t, /In progress/)
  assert.match(t, /waiting on leaf02 \(TargetUnreachable\)/)
  assert.doesNotMatch(t, /Converged|Completed|PROVISIONING/)

  // inside a transcript it is not wrapped by an error card either
  const entries: Entry[] = [{ id: 1, kind: 'chunk', chunk }]
  assert.doesNotMatch(renderToStaticMarkup(<Transcript entries={entries} />), /error-card/)
})

test('final renders the redacted message rather than the status token', () => {
  const done = renderToStaticMarkup(
    <FinalOutcome chunk={{ type: 'final', correlation_id: CID, status: 'COMPLETED', message: 'mac-vrf Network/migr-7 is ready on leaf01 and leaf02' }} />,
  )
  assert.match(done, /data-status="COMPLETED"/)
  assert.match(done, /data-tone="success"/)
  assert.match(text(done), /mac-vrf Network\/migr-7 is ready on leaf01 and leaf02/)
  assert.doesNotMatch(text(done), /COMPLETED/)
  const bare = renderToStaticMarkup(<FinalOutcome chunk={{ type: 'final', correlation_id: CID, status: 'COMPLETED' }} />)
  assert.doesNotMatch(text(bare), /COMPLETED/)

  const unknown = renderToStaticMarkup(
    <FinalOutcome chunk={{ type: 'final', correlation_id: CID, status: 'STATUS_UNKNOWN', message: 'the watch lost the cluster' }} />,
  )
  assert.match(unknown, /data-tone="warning"/)
  assert.match(text(unknown), /Outcome unknown/)
  assert.match(text(unknown), /the watch lost the cluster/)
  assert.doesNotMatch(unknown, /tone-success/)
  assert.doesNotMatch(text(unknown), /STATUS_UNKNOWN/)

  const declined = renderToStaticMarkup(
    <FinalOutcome chunk={{ type: 'final', correlation_id: CID, status: 'FAILED', message: 'declined at the assignment of the mac-vrf request: nothing was submitted' }} />,
  )
  assert.match(text(declined), /Declined/)
  assert.doesNotMatch(text(declined), /FAILED/)
})

test('ErrorCard names the stage in operator terms with the reason and the correlation id', () => {
  const chunk: ErrorChunk = {
    type: 'error',
    correlation_id: CID,
    stage: 'allocator',
    status: 'FAILED',
    reason: 'validation failed: endpoints[1].vlan is required for mac-vrf',
    retryable: false,
  }
  const html = renderToStaticMarkup(<ErrorCard chunk={chunk} />)
  assert.match(html, /data-testid="error-card"/)
  assert.match(html, /data-stage="allocator"/)
  assert.match(text(html), /The Assignment step failed/)
  assert.match(text(html), /endpoints\[1\]\.vlan is required for mac-vrf/)
  assert.match(html, new RegExp(`data-testid="correlation-chip" data-correlation-id="${CID}"`))
  assert.match(text(html), new RegExp(CID))
  const deploy = renderToStaticMarkup(<ErrorCard chunk={{ ...chunk, stage: 'deployer' }} />)
  assert.match(text(deploy), /The Deployment step failed/)
})

test('ErrorCard never shows a stack trace — only its last line', () => {
  const py = [
    'Traceback (most recent call last):',
    '  File "/app/deployer/apply.py", line 88, in apply',
    '    raise AdmissionRefused(msg)',
    'deployer.errors.AdmissionRefused: admission refused: leaf01 ethernet-1/1 vlan 110 is held by lab-vlan',
  ].join('\n')
  const html = renderToStaticMarkup(
    <ErrorCard chunk={{ type: 'error', correlation_id: CID, stage: 'deployer', status: 'FAILED', reason: py, retryable: false }} />,
  )
  assert.doesNotMatch(text(html), TRACEBACK)
  assert.match(text(html), /held by lab-vlan/)
  assert.doesNotMatch(text(html), /raise AdmissionRefused/)

  const js = 'TypeError: cannot read x\n    at apply (/srv/app.js:10:5)\n    at run (/srv/app.js:20:3)'
  assert.equal(readableReason(js), 'TypeError: cannot read x')
  assert.equal(readableReason('plain reason'), 'plain reason')
})

test('StageCard is a labelled step with its payload readable', () => {
  const chunk: StageChunk = {
    type: 'stage',
    correlation_id: CID,
    stage: 'mapper',
    status: 'MAPPED',
    payload: { service_type: 'mac-vrf', vlan: 100, tenant: 'blue', endpoints: [{ node: 'leaf01', port: 'ethernet-1/1' }] },
  }
  const html = renderToStaticMarkup(<StageCard chunk={chunk} />)
  assert.match(html, /data-testid="stage-card"/)
  assert.match(html, /data-stage="mapper"/)
  const t = text(html)
  assert.match(t, /Interpretation/)
  assert.match(t, /service_type mac-vrf/)
  assert.match(t, /vlan 100/)
  assert.match(t, /"node": "leaf01"/)
  assert.match(html, /<dl class="payload"/)
  assert.match(html, /data-correlation-id="4bf92f/)

  const deployer = renderToStaticMarkup(
    <StageCard
      chunk={{ type: 'stage', correlation_id: CID, stage: 'deployer', status: 'VERIFIED', resources: [{ kind: 'Network', name: 'migr-svc1' }], out_of_band: 'modified' }}
    />,
  )
  assert.match(text(deployer), /Deployment/)
  assert.match(text(deployer), /Network\/migr-svc1/)
  assert.match(text(deployer), /Modified outside the intent tier/)
  const allocator = renderToStaticMarkup(<StageCard chunk={{ ...chunk, stage: 'allocator', status: 'ALLOCATED' }} />)
  assert.match(text(allocator), /Assignment/)
})

const ACL_PROMPT =
  'Confirm this vlan interpretation? Rules are evaluated in ascending priority number, first match wins; priorities 1–65534 are usable and 65535 is reserved for the default action; unmatched traffic is dropped by the declared default action, a terminal deny entry at the reserved position 65535.'

test('the first confirmation with an ACL states evaluation order, priority range and unmatched traffic', () => {
  const chunk: ConfirmationRequestChunk = {
    type: 'confirmation_request',
    correlation_id: CID,
    stage: 'mapper',
    status: 'MAPPED',
    prompt: ACL_PROMPT,
    refusable: true,
  }
  const html = renderToStaticMarkup(<Confirmation chunk={chunk} acl active />)
  assert.match(html, /data-testid="confirmation"/)
  assert.match(html, /data-stage="mapper"/)
  assert.match(html, /data-testid="acl-note"/)
  const note = text(/<aside[\s\S]*?<\/aside>/.exec(html)?.[0] ?? '')
  assert.match(note, /^Access list/)
  assert.match(note, /ascending priority number, first match wins/)
  assert.match(note, /1–65534/)
  assert.match(note, /unmatched traffic is dropped/)
  assert.match(html, /data-testid="confirm-button"/)
  assert.match(html, /data-testid="decline-button"/)
  assert.doesNotMatch(html, /disabled/)

  const plain = renderToStaticMarkup(<Confirmation chunk={{ ...chunk, prompt: 'Confirm this vlan interpretation?' }} active />)
  assert.doesNotMatch(plain, /acl-note/)

  const answered = renderToStaticMarkup(<Confirmation chunk={chunk} answer="declined" active />)
  assert.equal((answered.match(/disabled=""/g) ?? []).length, 2)
  assert.match(text(answered), /You declined/)
})

test('a transcript marks the mapper ACL on its confirmation and keeps a decline amendable', () => {
  const entries: Entry[] = [
    { id: 1, kind: 'operator', text: 'Create vlan 140 on leaf01 ethernet-1/4 with an acl' },
    { id: 2, kind: 'chunk', chunk: { type: 'stage', correlation_id: CID, stage: 'mapper', status: 'MAPPED', payload: { service_type: 'vlan', acl: { rules: [] } } } },
    { id: 3, kind: 'chunk', chunk: { type: 'confirmation_request', correlation_id: CID, stage: 'mapper', status: 'MAPPED', prompt: 'Confirm this vlan interpretation?', refusable: true } },
  ]
  assert.equal(openConfirmation(entries, {}), 3)
  assert.equal(openConfirmation(entries, { 3: 'declined' }), null)
  const html = renderToStaticMarkup(<Transcript entries={entries} active={3} />)
  assert.match(html, /data-testid="acl-note"/)
  const declined: Entry[] = [
    ...entries,
    { id: 4, kind: 'operator', text: 'Decline (no)' },
    { id: 5, kind: 'chunk', chunk: { type: 'final', correlation_id: CID, status: 'FAILED', message: 'declined at the interpretation of the vlan request: nothing was submitted' } },
    { id: 6, kind: 'notice', text: DECLINE_NOTICE, testId: 'decline-notice' },
  ]
  const after = renderToStaticMarkup(<Transcript entries={declined} answers={{ 3: 'declined' }} active={openConfirmation(declined, { 3: 'declined' })} />)
  assert.match(text(after), /Declined — nothing was submitted; you can amend the request/)
  assert.match(after, /data-testid="decline-notice"/)
})

test('CorrelationChip shows the id with a copy button', () => {
  const html = renderToStaticMarkup(<CorrelationChip id={CID} />)
  assert.match(html, new RegExp(`data-correlation-id="${CID}"`))
  assert.match(html, /<button[^>]*>Copy<\/button>/)
})

test('SuggestedPrompts lists each prompt as a button', () => {
  const html = renderToStaticMarkup(
    <SuggestedPrompts
      prompts={[
        { shape: 'vlan', construct: 'vlan', prompt: 'Create vlan 120 on leaf01 ethernet-1/2 for tenant acme' },
        { shape: 'acl', construct: 'acl', prompt: 'Add an ingress ipv4 acl on leaf01 ethernet-1/2 vlan 120' },
      ]}
      onPick={() => {}}
    />,
  )
  assert.equal((html.match(/data-testid="suggested-prompt"/g) ?? []).length, 2)
  assert.match(text(html), /Create vlan 120 on leaf01 ethernet-1\/2 for tenant acme/)
})
