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
	verify-acl \
	test-acl-conflict \
	test-acl-enforcement \
	show-bgp \
	show-evpn \
	show-allocations \
	show-rendered-config \
	test-traffic \
	test-traffic-gateway \
	test-reverify \
	test-boundary \
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

test-idempotence: ## T064: zero Config generation advance and no new device commit on a second apply (SC-006)
	tests/integration/idempotence.sh

test-managed-drift: ## T064: managed-path drift restored under the revertive policy, as G13 observed (SC-007)
	bash tests/integration/managed_drift.sh run

test-unmanaged-path: ## T064: an unmanaged path is left alone
	bash tests/integration/unmanaged_path.sh run

test-target-failure: ## T064: one leaf cut → Ready=Unknown/Degraded=True VerificationFailed within two intervals (SC-008)
	bash tests/integration/target_failure.sh run

test-service-delete: ## T064: deletion removes every Config and device object, read back
	tests/integration/service_delete.sh

test-delete-unreachable: ## T064: deletion blocks on an unreachable target; FORCE_RELEASE=1 adds the force-release mode (SC-043)
	bash tests/integration/delete_unreachable.sh run $(if $(FORCE_RELEASE),--force-release)

test-provider-claims: ## T172: provider claims per VNI before any Config; AllocationConflict for VNI and VLAN (SC-045)
	tests/integration/provider_claims.sh

test-acceptance:
	$(not_implemented)

# --- Build
build-migration-cli: ## T096: the translator CLI → bin/migration-translator (quickstart.md §5–§7)
	go build -o bin/migration-translator ./cmd/migration-translator

# --- Bring-up and readiness waits
sdc-onboard: ## T036: onboarding manifests (no drift-policy statement) applied; four Targets discovered
	scripts/lib/sdc_onboard.sh

wait-targets: ## T036: every discovered Target Ready
	scripts/lib/wait_targets.sh

wait-fabric: ## T051: the default Fabric reports Ready=True
	tests/integration/fabric_verify.sh wait-fabric

wait-services: ## T064: every Network under examples/constructs/ reports Ready=True
	tests/integration/wait_services.sh

wait-observability: ## T134: Prometheus, Grafana, the collector and gNMIc rolled out, Prometheus ready, the ten alert rules loaded (bounded)
	bash scripts/lib/observability_phase.sh wait

# --- Fabric and service verification
verify-fabric-control-plane: ## T051: sessions + EVPN family, loopbacks, reflector config integrity, reflection probe
	tests/integration/fabric_verify.sh verify-fabric-control-plane

verify-services: ## T064: SC-004 route half, keyed per service, after its declarative negative control
	tests/integration/verify_services.sh

verify-acl: ## T114: keyed per-node ACL read-back, running + state, after its negative control (ACL_NETWORKS="<ns>/<name>…")
	tests/integration/acl_verify.sh $(ACL_NETWORKS)

test-acl-conflict: ## T114: a second list on a held (node, port, subinterface, direction, family) is refused by admission, nothing created (ACL_HOLDER=<ns>/<name>)
	tests/integration/acl_conflict.sh $(ACL_HOLDER)

test-acl-enforcement: ## T114: SC-041 denied/permitted probes per qualified direction, exactly those entries' counters moved
	tests/integration/acl_enforcement_probe.sh run

# --- Operator read-outs
show-bgp: ## T051: BGP sessions per node
	tests/integration/fabric_verify.sh show-bgp

show-evpn: ## T051: EVPN family state and received routes (reported, not asserted)
	tests/integration/fabric_verify.sh show-evpn

show-allocations: ## T051: the Fabric's allocations and the authority's claims
	tests/integration/fabric_verify.sh show-allocations

show-rendered-config: ## T051/T064: the generated fabric Configs, then every service's Configs
	tests/integration/fabric_verify.sh show-rendered-config
	tests/integration/show_rendered_config.sh

test-traffic: ## T065: cross-leaf L2, intra-ip-vrf L3, isolation, MTU boundary; three clean runs (SC-005)
	bash tests/integration/traffic.sh run

test-traffic-gateway: ## T118: US8 anycast gateway answers from both attached ports, both families, one anycast MAC (lab-macvrf-gateway)
	bash tests/integration/traffic.sh gateway

# --- Scheduled re-verification and offline suites (FR-107, FR-020)
test-reverify: ## T167: scheduled re-verification, maintenance and cannot-run halves (SC-044)
	bash tests/integration/reverify.sh run

test-boundary: ## T066/T073/T076: the intent tier's denial probes on the lab, no agent deployed (SC-028, SC-029); boundary applied first
	bash scripts/lib/rbac.sh boundary

test-envtest: ## T025: setup-envtest at the go.mod pin, then go test -tags envtest ./tests/envtest/...
	scripts/ci/test_envtest.sh

test-agents: ## T025: the intent tier's unit tests
	cd agents && uv run pytest tests/unit

test-ui: ## T025: the chat surface's unit tests
	cd ui && npm test

# --- Observability (SC-034 to SC-037, quickstart.md §21)
verify-metrics: ## T134: target health per job incl. gnmic-self, zero duplicate series, stale → absent, telemetry outage and one-sink-down halves
	bash tests/integration/observability_verify.sh run

verify-topology-view: ## T134: physical view identifiers == containerlab inventory == metric labels, normal and under a forced link failure
	bash tests/integration/topology_parity.sh physical

verify-evpn-service-view: ## T134: the EVPN service-path view's leaves, VTEPs, VNI and ACL filters == the Network's rendered objects (TP_NETWORK=<name>)
	bash tests/integration/topology_parity.sh service-path

test-alerts: ## T134: the rule unit test first, then the alerts fired and cleared live (FR-108 fault-making suite; SC-035)
	bash tests/integration/alerts_fire.sh run
