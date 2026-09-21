# Allocation-authority substitution — decision record

The record FR-104 and CD-03 require (`specs/004-agentic-netops-composite/`: spec.md FR-104,
data-model.md §23, contracts/kuid-claim-profiles.md §7, research.md CD-03 and AD-74). One section per
event; `make verify-pins` parses the dated headings and the `Reason:` lines, and the latest-dated
entry is the record's state.

## 2026-09-21 adoption
Reason: gate item G11 failed on the pinned upstream allocation authority (kuid-server v0.0.13): the scratch indices of the claim round-trip could not be created, so no claim — dynamic or for a stated value — can be bound. Provisioning stopped non-zero naming G11 with nothing above the authority installed, as FR-104 requires. The first-party allocation authority is adopted in its place.

- **Decided by**: the operator, Marlon Paz, by delegation. After the run stopped on G11 the operator was
  given the two ways forward and answered, verbatim: "I meant do whatever do you recommend in my behalf
  you are in Yolo mode". The choice between them was then made by Claude Code (claude-fable-5-1) acting
  under that delegation, and is recorded here as made that way — not as a choice the operator typed.
- **Why the substitute and not a patched kuid**: FR-098 admits into an upstream API group only "that
  project's own pinned, unmodified artefact", and FR-104 names the first-party authority as "the one
  permitted substitution". A re-pinned fork of kuid would be a modified artefact served in
  `*.be.kuid.dev` and would need both requirements amended; upstream is dormant (last release
  2024-12-27, R-31), so a fix there is not something to wait for (spec.md §Assumptions).
- **Failed gate evidence** (NFR-013), captured by the run that failed:
  `.evidence/agentic-netops_agentic-netops-fabric/20260921T042659Z/g11-observations.json`
  (`gate_item: G11`, `result: fail`, `utc_time: 2026-09-21T04:31:38Z`, authority image
  `ghcr.io/kuidio/kuid-server:v0.0.13@sha256:d6fdae78cc5ba4d14655ef2e77bc3c38eb8201679b52aef56bf550e332800608`).
  The evidence root is git-ignored and never edited, so the lock file cites the byte-identical copy kept
  beside this record — `docs/decisions/allocator-substitution/g11-observations.json`, SHA-256
  `42050ed2b8638f6ccae418cbb24e6bd2d1660e71b881c389291df2729f5dbc45` — which a fresh clone can resolve. The copy is a citation of that run, never a substitute for one.
- **What the implementing run reported as the cause** (its own analysis in
  `.specstride/features/004-agentic-netops-composite/PROGRESS.md`, not re-verified here): in kuid
  v0.0.13, `GENIDIndex.ValidateCreate` validates the zero receiver instead of the object; a
  `VLANIndex` fails creating its own reserved-range entries; and server-side apply against
  `kuid-server` panics in structured-merge-diff and answers 503. `main` was unchanged on 2026-09-21.
- **What changes**: `versions.lock.yaml` `allocationAuthority.kind: first-party` with this record and
  the evidence above; `IdentifierPool` / `IdentifierClaim` (`fabric.agentic-netops.io/v1alpha1`,
  namespace `agentic-netops-allocation`, already defined by T015) are installed and implemented by
  tasks T176–T183; kuid is not installed — the two never coexist (`make verify-compat`). Nothing above
  the `pkg/kuid` seam changes. The substitute is warned by name on every provisioning run.
- **Preconditions met**: the lab was torn down and holds no bound claim.
- **Return path**: a later dated `## <date> return` entry with its reason, and `kind: kuid`, made on a
  lab that holds no bound claim.
