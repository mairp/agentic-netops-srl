# Fabric render goldens: provisional until G12 (T047)

`spine01.json`, `spine02.json`, `leaf01.json`, `leaf02.json` are the per-node priority-10 fabric
documents (native `srl_nokia` JSON_IETF at `/`) rendered by `internal/render/srl` for the default
`Fabric` of data-model.md §3a with its claims bound as `tests/unit/render/fabric_render_test.go`
(`defaultInput`) states.

They are **provisional until G12 (T047)**: the identityref serialization they use
(`srl_nokia-common:evpn`, `srl_nokia-network-instance:default`, …) follows RFC 7951 and has not
been observed from a real device Get (evidence/02-evpn-constructs.md §2.5, plan.md G12, R-36).
T047 compares them with `tests/gate/observed/serialization.json`, switches the form in the one
place it is decided (`qualifyIdentityrefs` in `internal/render/srl/fabric.go`) if needed,
regenerates with `go test ./tests/unit/render/ -run TestFabricGoldens -update`, and deletes this
file. `TestFabricGoldensAreProvisional` fails while G12 has not run and this marker is missing.
