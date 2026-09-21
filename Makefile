# Makefile — the stable operator and CI interface (plan.md §"Make targets are an
# interface", quickstart.md). Targets wrap scripts/ and the test suites; they
# never reimplement a provisioning phase.
#
# Every target starts out failing with `not implemented: <target>` (CR-007): an
# unbuilt gate can never pass silently. The task that builds a target replaces
# its recipe below; TARGETS stays the full interface.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# Fails the calling target, naming it, with a non-zero exit.
define not_implemented
	@echo "not implemented: $@" >&2; exit 2
endef

TARGETS := \
	verify-pins \
	verify-upstream-artefacts \
	verify-render-schema \
	verify-compat \
	verify-boundaries \
	verify-provenance-headers \
	verify-evidence \
	verify-readme \
	test-static \
	test-idempotence \
	test-managed-drift \
	test-unmanaged-path \
	test-target-failure \
	test-service-delete \
	test-delete-unreachable \
	test-provider-claims \
	test-acceptance \
	build-migration-cli \
	sdc-onboard \
	wait-targets \
	wait-fabric \
	wait-services \
	wait-observability \
	verify-fabric-control-plane \
	verify-services \
	show-bgp \
	show-evpn \
	show-allocations \
	show-rendered-config \
	test-reverify \
	test-envtest \
	test-agents \
	test-ui \
	verify-metrics \
	verify-topology-view \
	verify-evpn-service-view \
	test-alerts

.PHONY: help $(TARGETS)

help: ## List the targets of the interface.
	@echo "Targets (each fails with 'not implemented: <target>' until built):"
	@for t in $(TARGETS); do echo "  $$t"; done

# --- Pins, upstream artefacts, render schema, compatibility, boundaries (NFR-003, FR-098, FR-015, FR-017, SC-017)
verify-pins: ## T010: resolve every pin in versions.lock.yaml (VERIFY_PINS_FLAGS: --no-pending, --host-tooling)
	scripts/lib/verify_pins.sh $(VERIFY_PINS_FLAGS)

verify-upstream-artefacts: ## T035: no CRD/APIService of an upstream API group originates in this repository (FR-098)
	scripts/ci/verify_upstream_artefacts.sh

verify-render-schema: ## T047: validate every fabric golden offline against the pinned Schema (sdc-lite config validate)
	scripts/ci/verify_render_schema.sh

verify-compat: ## T050: published compatibility set = versions.lock.yaml; one allocation authority; first-party images by content hash
	scripts/ci/verify_compat.sh

verify-boundaries: ## T025: SC-017 three boundaries + reference-artefact checks, FR-108, FR-019/CR-008, FR-013
	scripts/ci/verify_boundaries.sh

verify-provenance-headers: ## T025: every vendored asset carries source, version and digest (SC-017b)
	scripts/ci/verify_provenance_headers.sh

# --- Evidence and README (NFR-013, SC-040, C-22)
verify-evidence: ## T012: verify one run's EVIDENCE_DIR (default: the newest under .evidence/)
	bash scripts/lib/verify_evidence.sh $(if $(EVIDENCE_DIR),"$(EVIDENCE_DIR)")

verify-readme:
	$(not_implemented)

# --- Offline and lab test suites (FR-020, AD-28) and reconciliation scenarios
test-static: ## T025: go vet, Go unit + golden tests, the path-register guard, every offline shell suite
	@pkgs="$$(go list ./... | grep -v '/node_modules/')"; \
	  echo "== go vet ./..."; go vet $$pkgs; \
	  echo "== go test ./... (unit + golden; envtest files are //go:build envtest)"; go test -count=1 $$pkgs
	@echo "== path-register guard (T022): go test ./pkg/register/ (guard_test.go)"; \
	  test -f pkg/register/guard_test.go || { echo "test-static: FAIL pkg/register/guard_test.go (the path-register guard) is missing" >&2; exit 1; }; \
	  go test -count=1 -v ./pkg/register/
	@echo "== offline shell suites: scripts/ci/test_shell.sh (tests/unit/**/*_test.sh)"
	scripts/ci/test_shell.sh

test-idempotence:
	$(not_implemented)

test-managed-drift:
	$(not_implemented)

test-unmanaged-path:
	$(not_implemented)

test-target-failure:
	$(not_implemented)

test-service-delete:
	$(not_implemented)

test-delete-unreachable:
	$(not_implemented)

test-provider-claims:
	$(not_implemented)

test-acceptance:
	$(not_implemented)

# --- Build
build-migration-cli:
	$(not_implemented)

# --- Bring-up and readiness waits
sdc-onboard: ## T036: onboarding manifests (no drift-policy statement) applied; four Targets discovered
	scripts/lib/sdc_onboard.sh

wait-targets: ## T036: every discovered Target Ready
	scripts/lib/wait_targets.sh

wait-fabric: ## T051: the default Fabric reports Ready=True
	tests/integration/fabric_verify.sh wait-fabric

wait-services:
	$(not_implemented)

wait-observability:
	$(not_implemented)

# --- Fabric and service verification
verify-fabric-control-plane: ## T051: sessions + EVPN family, loopbacks, reflector config integrity, reflection probe
	tests/integration/fabric_verify.sh verify-fabric-control-plane

verify-services:
	$(not_implemented)

# --- Operator read-outs
show-bgp: ## T051: BGP sessions per node
	tests/integration/fabric_verify.sh show-bgp

show-evpn: ## T051: EVPN family state and received routes (reported, not asserted)
	tests/integration/fabric_verify.sh show-evpn

show-allocations: ## T051: the Fabric's allocations and the authority's claims
	tests/integration/fabric_verify.sh show-allocations

show-rendered-config: ## T051: the generated fabric Configs
	tests/integration/fabric_verify.sh show-rendered-config

# --- Scheduled re-verification and offline suites (FR-107, FR-020)
test-reverify:
	$(not_implemented)

test-envtest: ## T025: setup-envtest at the go.mod pin, then go test -tags envtest ./tests/envtest/...
	scripts/ci/test_envtest.sh

test-agents: ## T025: the intent tier's unit tests
	cd agents && uv run pytest tests/unit

test-ui: ## T025: the chat surface's unit tests
	cd ui && npm test

# --- Observability (SC-034 to SC-037, quickstart.md §21)
verify-metrics:
	$(not_implemented)

verify-topology-view:
	$(not_implemented)

verify-evpn-service-view:
	$(not_implemented)

test-alerts:
	$(not_implemented)
