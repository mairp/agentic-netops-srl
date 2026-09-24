"""The strict contract models (T081; FR-058, FR-065, data-model.md §8, §9, §15, §16).

Three kinds of evidence that the pydantic models are the contract JSON Schemas:

1. **structure** — every object's property names, ``required`` set and ``additionalProperties:
   false``, every enum, pattern and length/number bound of the contract schema equals the one the
   model's own JSON Schema states;
2. **agreement** — a corpus of valid and invalid documents is judged by the contract schema (the
   ``jsonschema`` validator) and by the model, and the verdicts are equal, the conditional
   ``allOf`` rules included;
3. **round trip and rejection** — the examples survive ``parse`` → ``to_wire`` byte for byte, and
   the named rejections (unknown field, wrong enum, retired service name, a boolean for ``ready``,
   a status outside the closed set …) are refused.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

import jsonschema
import pytest
from pydantic import BaseModel, ValidationError

from common.provisioning_states import ALL_STATUSES
from common.schemas.audit import AuditEvent, ResourceRef
from common.schemas.interpretation import Interpretation
from common.schemas.normalized_service_intent import NormalizedServiceIntent
from common.schemas.stream import DeploymentReport, parse_chunk

REPO = Path(__file__).resolve().parents[3]
CONTRACTS = REPO / "specs" / "004-agentic-netops-composite" / "contracts"
INTERPRETATION_SCHEMA = json.loads((CONTRACTS / "interpretation.schema.json").read_text())
NSI_SCHEMA = json.loads((CONTRACTS / "normalized-service-intent.schema.json").read_text())

CID = "4bf92f3577b34da6a3ce929d0e0e4736"

# --------------------------------------------------------------------------------------------------
# examples
# --------------------------------------------------------------------------------------------------

INTERPRETATIONS: list[dict[str, Any]] = [
    {
        "service_id": "3f2b9c0d1e4a5b6",
        "service_type": "mac-vrf",
        "source_service_type": None,
        "tenant": "blue",
        "endpoints": [
            {"site_or_node": "leaf01", "attachment": "ethernet-1/1", "vlan": 100},
            {"site_or_node": "leaf02", "attachment": "ethernet-1/1", "vlan": 100},
        ],
        "anycast_gateway": {"ipv4": "10.1.0.1/24", "ipv6": None},
        "missing_fields": [],
        "unsupported_properties": [],
    },
    {
        "service_id": "a1b2c3d4e5f6a7b",
        "service_type": "ip-vrf",
        "source_service_type": "L3VPN",
        "tenant": "initech",
        "endpoints": [{"site_or_node": "leaf01", "attachment": "ethernet-1/2", "vlan": None}],
        "ipv4_prefixes": ["10.50.0.0/24"],
        "ipv6_prefixes": [],
    },
    {
        "service_id": "0a1b2c3d4e5f607",
        "service_type": "acl",
        "tenant": "acme",
        "endpoints": [{"site_or_node": "leaf01", "attachment": "ethernet-1/1", "vlan": 1500}],
        "acl": {
            "name": "web-only",
            "stage": "ingress",
            "type": "ipv4",
            "default_action": None,
            "evaluation_order": "ascending-first-match",
            "unmatched_traffic": "accept-platform-default",
            "rules": [
                {"name": "allow-https", "priority": 100, "action": "permit", "protocol": "tcp",
                 "source_prefix": "10.0.0.0/24", "destination_port": "443",
                 "description": None},
                {"name": "allow-ospf", "priority": 200, "action": "permit", "protocol": 89},
            ],
        },
    },
    {
        "service_id": "b00c",
        "service_type": "vlan",
        "tenant": "acme",
        "endpoints": [{"site_or_node": "leaf01", "attachment": "ethernet-1/1", "vlan": 120}],
        "bandwidth": None,
        "sla": None,
        "missing_fields": ["tenant"],
    },
]

NSI_EXAMPLES: list[dict[str, Any]] = NSI_SCHEMA["examples"] + [
    {
        "serviceId": "gw01",
        "type": "mac-vrf",
        "tenant": "blue",
        "routeTargets": {"importRT": ["target:65000:10030"], "exportRT": ["target:65000:10030"]},
        "l2vni": 10030,
        "l3vni": 10031,
        "anycastGateway": {"ipVrf": "vrf-gw01", "gatewayIPv4": "10.3.0.1/24"},
        "endpoints": [
            {"node": "leaf01", "attachment": "ethernet-1/1", "vlan": 130},
            {"node": "leaf02", "attachment": "ethernet-1/1", "vlan": 130},
        ],
        "policies": {"vpwsLimitedEquivalence": True},
    }
]


def _mutate(doc: dict[str, Any], path: str, value: Any) -> dict[str, Any]:
    """A deep copy with ``path`` (dot/index notation) set to ``value`` (``...`` deletes it)."""
    out = copy.deepcopy(doc)
    node: Any = out
    keys = [int(k) if k.isdigit() else k for k in path.split(".")]
    for key in keys[:-1]:
        node = node[key]
    if value is ...:
        del node[keys[-1]]
    else:
        node[keys[-1]] = value
    return out


# --------------------------------------------------------------------------------------------------
# 1. structure: the model's JSON Schema states what the contract states
# --------------------------------------------------------------------------------------------------

_BOUNDS = ("pattern", "minLength", "maxLength", "minimum", "maximum", "minItems")


def _deref(schema: dict[str, Any], root: dict[str, Any]) -> dict[str, Any]:
    while "$ref" in schema:
        name = schema["$ref"].rsplit("/", 1)[-1]
        schema = {**root["$defs"][name], **{k: v for k, v in schema.items() if k != "$ref"}}
    return schema


def _flatten(schema: dict[str, Any], root: dict[str, Any]) -> dict[str, Any]:
    """Collect the constraints of every non-null branch of ``schema``."""
    schema = _deref(schema, root)
    out: dict[str, Any] = {"types": set(), "enum": set(), "properties": None, "required": None,
                           "closed": None, "items": None}
    for bound in _BOUNDS:
        out[bound] = set()
    branches = [schema]
    if "anyOf" in schema and any(("type" in b or "$ref" in b or "enum" in b or "const" in b)
                                 for b in schema["anyOf"]):
        branches = [{**{k: v for k, v in schema.items() if k != "anyOf"}, **b}
                    for b in schema["anyOf"]]
    for branch in branches:
        branch = _deref(branch, root)
        types = branch.get("type")
        types = set(types) if isinstance(types, list) else ({types} if types else set())
        if types == {"null"}:
            continue
        out["types"] |= types - {"null"}
        if "enum" in branch:
            out["enum"] |= {v for v in branch["enum"] if v is not None}
        if "const" in branch and branch["const"] is not None:
            out["enum"].add(branch["const"])
        for bound in _BOUNDS:
            if bound in branch:
                out[bound].add(branch[bound])
        if "properties" in branch:
            out["properties"] = branch["properties"]
            out["required"] = set(branch.get("required", []))
            out["closed"] = branch.get("additionalProperties") is False
        if "items" in branch:
            out["items"] = branch["items"]
    return out


def _compare(contract: dict[str, Any], model: dict[str, Any], croot: dict[str, Any],
             mroot: dict[str, Any], where: str, problems: list[str]) -> None:
    c = _flatten(contract, croot)
    m = _flatten(model, mroot)
    if c["enum"] != m["enum"]:
        problems.append(f"{where}: enum {sorted(map(str, c['enum']))} != "
                        f"{sorted(map(str, m['enum']))}")
    for bound in _BOUNDS:
        if c[bound] != m[bound]:
            problems.append(f"{where}: {bound} {c[bound]} != {m[bound]}")
    if c["properties"] is not None:
        if m["properties"] is None:
            problems.append(f"{where}: the model is not an object")
            return
        if set(c["properties"]) != set(m["properties"]):
            problems.append(f"{where}: properties {sorted(c['properties'])} != "
                            f"{sorted(m['properties'])}")
        if c["required"] != m["required"]:
            problems.append(f"{where}: required {sorted(c['required'])} != "
                            f"{sorted(m['required'])}")
        if c["closed"] and not m["closed"]:
            problems.append(f"{where}: the model admits unknown fields")
        for name in set(c["properties"]) & set(m["properties"]):
            _compare(c["properties"][name], m["properties"][name], croot, mroot,
                     f"{where}.{name}", problems)
    if c["items"] is not None:
        if m["items"] is None:
            problems.append(f"{where}: the model is not an array")
        else:
            _compare(c["items"], m["items"], croot, mroot, f"{where}[]", problems)


@pytest.mark.parametrize(
    ("contract", "model"),
    [(INTERPRETATION_SCHEMA, Interpretation), (NSI_SCHEMA, NormalizedServiceIntent)],
    ids=["interpretation", "normalized-service-intent"],
)
def test_model_states_the_contract_constraints(contract: dict[str, Any],
                                               model: type[BaseModel]) -> None:
    mschema = model.model_json_schema()
    problems: list[str] = []
    _compare(contract, mschema, contract, mschema, model.__name__, problems)
    assert not problems, "\n".join(problems)


def test_structure_comparison_is_not_vacuous() -> None:
    """Negative control: a contract with one enum value added is reported."""
    changed = copy.deepcopy(INTERPRETATION_SCHEMA)
    changed["properties"]["service_type"]["enum"].append("VPLS")
    mschema = Interpretation.model_json_schema()
    problems: list[str] = []
    _compare(changed, mschema, changed, mschema, "Interpretation", problems)
    assert any("service_type: enum" in p for p in problems), problems


# --------------------------------------------------------------------------------------------------
# 2. agreement: the contract validator and the model give the same verdict
# --------------------------------------------------------------------------------------------------


def _schema_ok(schema: dict[str, Any], doc: Any) -> bool:
    return jsonschema.Draft202012Validator(schema).is_valid(doc)


def _model_ok(model: type[Any], doc: Any) -> bool:
    try:
        model.parse(doc)
    except ValidationError:
        return False
    return True


_I = INTERPRETATIONS
INTERPRETATION_CORPUS: list[tuple[str, dict[str, Any]]] = [
    *[(f"example-{n}", d) for n, d in enumerate(_I)],
    ("unknown-field", _mutate(_I[0], "principal", "alice")),
    ("unknown-endpoint-field", _mutate(_I[0], "endpoints.0.node", "leaf01")),
    ("retired-service-name", _mutate(_I[0], "service_type", "VPLS")),
    ("unknown-construct", _mutate(_I[0], "service_type", "evpn")),
    ("source-alias-unknown", _mutate(_I[1], "source_service_type", "EVPN")),
    ("service-id-too-long", _mutate(_I[0], "service_id", "a" * 16)),
    ("service-id-dot", _mutate(_I[0], "service_id", "a.b")),
    ("service-id-upper", _mutate(_I[0], "service_id", "Abc")),
    ("tenant-underscore", _mutate(_I[0], "tenant", "blue_team")),
    ("tenant-missing", _mutate(_I[0], "tenant", ...)),
    ("endpoints-empty", _mutate(_I[0], "endpoints", [])),
    ("vlan-string", _mutate(_I[0], "endpoints.0.vlan", "100")),
    ("vlan-bool", _mutate(_I[0], "endpoints.0.vlan", True)),
    ("vlan-negative", _mutate(_I[0], "endpoints.0.vlan", -1)),
    ("vlan-huge-accepted", _mutate(_I[0], "endpoints.0.vlan", 5000)),
    ("vlan-zero-accepted", _mutate(_I[0], "endpoints.0.vlan", 0)),
    ("attachment-empty", _mutate(_I[0], "endpoints.0.attachment", "")),
    ("gateway-empty", _mutate(_I[0], "anycast_gateway", {})),
    ("gateway-ipv6-null-only", _mutate(_I[0], "anycast_gateway", {"ipv6": None})),
    ("gateway-on-vlan", _mutate(_I[3], "anycast_gateway", {"ipv4": "10.0.0.1/24"})),
    ("gateway-on-ip-vrf", _mutate(_I[1], "anycast_gateway", {"ipv4": "10.0.0.1/24"})),
    ("gateway-null-on-ip-vrf", _mutate(_I[1], "anycast_gateway", None)),
    ("acl-construct-without-acl", _mutate(_I[2], "acl", ...)),
    ("acl-construct-acl-null", _mutate(_I[2], "acl", None)),
    ("acl-stage-wrong", _mutate(_I[2], "acl.stage", "both")),
    ("acl-type-mac", _mutate(_I[2], "acl.type", "mac")),
    ("acl-type-l3", _mutate(_I[2], "acl.type", "l3")),
    ("acl-rules-empty", _mutate(_I[2], "acl.rules", [])),
    ("acl-priority-reserved", _mutate(_I[2], "acl.rules.0.priority", 65535)),
    ("acl-priority-zero", _mutate(_I[2], "acl.rules.0.priority", 0)),
    ("acl-priority-string", _mutate(_I[2], "acl.rules.0.priority", "100")),
    ("acl-protocol-unknown", _mutate(_I[2], "acl.rules.0.protocol", "quic")),
    ("acl-protocol-256", _mutate(_I[2], "acl.rules.0.protocol", 256)),
    ("acl-protocol-icmpv6", _mutate(_I[2], "acl.rules.0.protocol", "icmpv6")),
    ("acl-protocol-null", _mutate(_I[2], "acl.rules.0.protocol", None)),
    ("acl-port-range", _mutate(_I[2], "acl.rules.0.destination_port", "1000-2000")),
    ("acl-port-bad", _mutate(_I[2], "acl.rules.0.destination_port", "https")),
    ("acl-description-long", _mutate(_I[2], "acl.rules.0.description", "x" * 256)),
    ("acl-order-other", _mutate(_I[2], "acl.evaluation_order", "last-match")),
    ("acl-unmatched-other", _mutate(_I[2], "acl.unmatched_traffic", "drop")),
    ("acl-default-null", _mutate(_I[2], "acl.default_action", None)),
    ("acl-unknown-field", _mutate(_I[2], "acl.rules.0.sequence", 10)),
    ("prefixes-not-list", _mutate(_I[1], "ipv4_prefixes", "10.0.0.0/24")),
    ("missing-fields-null", _mutate(_I[0], "missing_fields", None)),
]


@pytest.mark.parametrize(("case", "doc"), INTERPRETATION_CORPUS,
                         ids=[c for c, _ in INTERPRETATION_CORPUS])
def test_interpretation_agrees_with_contract(case: str, doc: dict[str, Any]) -> None:
    assert _model_ok(Interpretation, doc) == _schema_ok(INTERPRETATION_SCHEMA, doc), case


_N = NSI_EXAMPLES
NSI_CORPUS: list[tuple[str, dict[str, Any]]] = [
    *[(f"example-{n}", d) for n, d in enumerate(_N)],
    ("unknown-field", _mutate(_N[0], "routeDistinguisher", "65000:1")),
    ("unknown-endpoint-field", _mutate(_N[0], "endpoints.0.port", "e1-1")),
    ("retired-type", _mutate(_N[0], "type", "L2VPN")),
    ("retired-type-vpls", _mutate(_N[0], "type", "VPLS")),
    ("serviceId-long", _mutate(_N[0], "serviceId", "a" * 16)),
    ("tenant-empty", _mutate(_N[0], "tenant", "")),
    ("mac-vrf-without-l2vni", _mutate(_N[0], "l2vni", ...)),
    ("mac-vrf-without-rt", _mutate(_N[0], "routeTargets", ...)),
    ("mac-vrf-gateway-without-l3vni", _mutate(_N[4], "l3vni", ...)),
    ("rt-empty-import", _mutate(_N[0], "routeTargets.importRT", [])),
    ("rt-extra", _mutate(_N[0], "routeTargets.rd", "x")),
    ("l2vni-zero", _mutate(_N[0], "l2vni", 0)),
    ("l2vni-too-big", _mutate(_N[0], "l2vni", 65536)),
    ("l2vni-null", _mutate(_N[0], "l2vni", None)),
    ("l2vni-string", _mutate(_N[0], "l2vni", "10021")),
    ("vlan-4095", _mutate(_N[1], "endpoints.0.vlan", 4095)),
    ("vlan-0", _mutate(_N[1], "endpoints.0.vlan", 0)),
    ("vlan-bool", _mutate(_N[1], "endpoints.0.vlan", True)),
    ("vlan-with-l2vni", _mutate(_N[1], "l2vni", 10001)),
    ("vlan-with-rt", _mutate(_N[1], "routeTargets", _N[0]["routeTargets"])),
    ("ip-vrf-without-af", _mutate(_N[2], "addressFamilies", ...)),
    ("ip-vrf-with-l2vni", _mutate(_N[2], "l2vni", 10001)),
    ("ip-vrf-with-gateway", _mutate(_N[2], "anycastGateway", {"gatewayIPv4": "10.0.0.1/24"})),
    ("acl-without-acl", _mutate(_N[3], "acl", ...)),
    ("acl-with-l3vni", _mutate(_N[3], "l3vni", 10001)),
    ("acl-stage-wrong", _mutate(_N[3], "acl.stage", "both")),
    ("acl-name-empty", _mutate(_N[3], "acl.name", "")),
    ("acl-rule-priority-reserved", _mutate(_N[3], "acl.rules.0.priority", 65535)),
    ("acl-rule-prefix-empty", _mutate(_N[3], "acl.rules.0.sourcePrefix", "")),
    ("acl-rule-protocol-number", _mutate(_N[3], "acl.rules.0.protocol", 6)),
    ("acl-rule-snake-case", _mutate(_N[3], "acl.rules.0.source_prefix", "10.0.0.0/8")),
    ("gateway-no-family", _mutate(_N[4], "anycastGateway", {"ipVrf": "vrf-gw01"})),
    ("policies-string", _mutate(_N[4], "policies.vpwsLimitedEquivalence", "yes")),
    ("policies-extra", _mutate(_N[4], "policies.other", True)),
    ("unsupported-any-object", _mutate(_N[1], "unsupported", {"mtu": 9000})),
    ("unsupported-not-object", _mutate(_N[1], "unsupported", ["mtu"])),
    ("endpoints-empty", _mutate(_N[1], "endpoints", [])),
]


@pytest.mark.parametrize(("case", "doc"), NSI_CORPUS, ids=[c for c, _ in NSI_CORPUS])
def test_normalized_service_intent_agrees_with_contract(case: str, doc: dict[str, Any]) -> None:
    assert _model_ok(NormalizedServiceIntent, doc) == _schema_ok(NSI_SCHEMA, doc), case


def test_agreement_corpora_hold_both_verdicts() -> None:
    """The corpora are not vacuous: each has accepted and refused documents."""
    for schema, corpus in ((INTERPRETATION_SCHEMA, INTERPRETATION_CORPUS),
                           (NSI_SCHEMA, NSI_CORPUS)):
        verdicts = {_schema_ok(schema, d) for _, d in corpus}
        assert verdicts == {True, False}


# --------------------------------------------------------------------------------------------------
# 3. round trip and rejection
# --------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("doc", INTERPRETATIONS, ids=[d["service_type"] for d in INTERPRETATIONS])
def test_interpretation_round_trip(doc: dict[str, Any]) -> None:
    assert Interpretation.parse(doc).to_wire() == doc
    assert Interpretation.parse(json.dumps(doc)).to_wire() == doc


@pytest.mark.parametrize("doc", NSI_EXAMPLES, ids=[d["serviceId"] for d in NSI_EXAMPLES])
def test_normalized_service_intent_round_trip(doc: dict[str, Any]) -> None:
    model = NormalizedServiceIntent.parse(doc)
    assert model.to_wire() == doc
    assert model.network_name == f"migr-{doc['serviceId']}"


@pytest.mark.parametrize(
    ("model", "doc", "needle"),
    [
        (Interpretation, _mutate(_I[0], "principal", "alice"), "principal"),
        (Interpretation, _mutate(_I[0], "service_type", "VPLS"), "service_type"),
        (Interpretation, _mutate(_I[0], "service_type", "L3VPN"), "service_type"),
        (Interpretation, _mutate(_I[0], "endpoints.0.vlan", "100"), "vlan"),
        (NormalizedServiceIntent, _mutate(_N[0], "type", "VPWS"), "type"),
        (NormalizedServiceIntent, _mutate(_N[0], "routeDistinguisher", "x"), "routeDistinguisher"),
        (NormalizedServiceIntent, _mutate(_N[1], "l2vni", 10001), "l2vni"),
        (NormalizedServiceIntent, _mutate(_N[0], "l2vni", True), "l2vni"),
    ],
    ids=["unknown-field", "retired-vpls", "retired-l3vpn", "coerced-vlan", "retired-vpws",
         "route-distinguisher", "vni-on-vlan", "bool-vni"],
)
def test_rejections_name_the_field(model: type[Any], doc: dict[str, Any], needle: str) -> None:
    with pytest.raises(ValidationError) as caught:
        model.parse(doc)
    assert needle in str(caught.value)


# ResourceRef / AuditEvent


def _ref(**overrides: Any) -> dict[str, Any]:
    base = {"apiVersion": "fabric.agentic-netops.io/v1alpha1", "kind": "Network",
            "namespace": "agentic-netops-intent", "name": "migr-svc1", "uid": "u-1",
            "ready": "True", "reason": "Converged"}
    base.update(overrides)
    return base


@pytest.mark.parametrize("ready", ["True", "False", "Unknown", None])
def test_resource_ref_ready_is_the_status_string(ready: str | None) -> None:
    ref = ResourceRef.parse(_ref(ready=ready, reason="Deleting" if ready else None))
    assert ref.ready == ready
    assert ResourceRef.parse(ref.to_wire()) == ref


@pytest.mark.parametrize("bad", [True, False, "true", "Ready", 1])
def test_resource_ref_ready_never_a_boolean(bad: Any) -> None:
    with pytest.raises(ValidationError):
        ResourceRef.parse(_ref(ready=bad))


def test_resource_ref_reason_required_beside_false_or_unknown() -> None:
    with pytest.raises(ValidationError, match="reason"):
        ResourceRef.parse(_ref(ready="False", reason=None))
    with pytest.raises(ValidationError, match="reason"):
        ResourceRef.parse(_ref(ready="Unknown", reason=None))
    with pytest.raises(ValidationError):
        ResourceRef.parse(_ref(extra="x"))


def _event(**overrides: Any) -> dict[str, Any]:
    base = {"event_type": "confirm", "correlation_id": CID, "thread_id": "t-1",
            "principal": "alice", "at": "2026-09-24T10:00:00Z", "resources": [], "reason": None}
    base.update(overrides)
    return base


def test_audit_event_round_trip_and_span_event() -> None:
    event = AuditEvent.from_json(_event(event_type="submit", resources=[_ref()]))
    assert AuditEvent.from_json(event.model_dump_json()) == event
    name, attrs = event.span_event()
    assert name == "audit.submit"
    assert attrs["audit.principal"] == "alice"
    assert attrs["audit.correlation_id"] == CID


@pytest.mark.parametrize(
    "overrides",
    [
        {"event_type": "approve"},
        {"correlation_id": "4BF92F3577B34DA6A3CE929D0E0E4736"},
        {"correlation_id": "abc"},
        {"principal": ""},
        {"event_type": "refuse", "resources": [_ref()]},
        {"event_type": "decline", "resources": [_ref()]},
        {"source": "ui"},
        {"at": "yesterday"},
    ],
    ids=["unknown-type", "upper-hex", "short-id", "no-principal", "refuse-with-resources",
         "decline-with-resources", "unknown-field", "bad-time"],
)
def test_audit_event_rejections(overrides: dict[str, Any]) -> None:
    with pytest.raises(ValidationError):
        AuditEvent.from_json(_event(**overrides))


# stream chunks


CHUNKS: list[dict[str, Any]] = [
    {"type": "status", "correlation_id": CID, "status": "RECEIVED_REQUEST", "stage": "supervisor",
     "thread_id": "3f2b"},
    {"type": "stage", "correlation_id": CID, "stage": "mapper", "status": "MAPPED",
     "payload": INTERPRETATIONS[0]},
    {"type": "confirmation_request", "correlation_id": CID, "stage": "mapper", "status": "MAPPED",
     "prompt": "Confirm this interpretation?", "refusable": True},
    {"type": "stage", "correlation_id": CID, "stage": "deployer", "status": "PROVISIONING",
     "resources": [{"kind": "Network", "name": "migr-svc1"}]},
    {"type": "progress", "correlation_id": CID, "status": "VERIFIED",
     "resource": "Network/migr-svc1", "ready": "True"},
    {"type": "progress", "correlation_id": CID, "status": "PROVISIONING",
     "resource": "Network/migr-svc1", "ready": "False", "reason": "Deleting"},
    {"type": "final", "correlation_id": CID, "status": "PROVISIONING",
     "message": "removal in progress: waiting on leaf02 (TargetUnreachable)"},
    {"type": "error", "correlation_id": CID, "stage": "allocator", "status": "FAILED",
     "reason": "validation failed: endpoints[1].vlan is required for mac-vrf",
     "retryable": False},
    {"type": "stage", "correlation_id": CID, "stage": "deployer", "status": "VERIFIED",
     "out_of_band": "modified", "resource": "Network/migr-svc1", "payload": {}},
]


@pytest.mark.parametrize("chunk", CHUNKS, ids=[f"{c['type']}-{c['status']}" for c in CHUNKS])
def test_chunk_round_trip(chunk: dict[str, Any]) -> None:
    parsed = parse_chunk(chunk)
    line = parsed.line()
    assert line.endswith(b"\n") and line.count(b"\n") == 1
    assert json.loads(line) == chunk
    assert line.startswith(b'{"type":')


@pytest.mark.parametrize(
    ("chunk", "why"),
    [
        (_mutate(CHUNKS[4], "ready", True), "ready as a boolean"),
        (_mutate(CHUNKS[4], "ready", "true"), "ready lower-case"),
        (_mutate(CHUNKS[0], "status", "DONE"), "status outside the closed set"),
        (_mutate(CHUNKS[0], "status", "CONVERGED"), "status outside the closed set"),
        (_mutate(CHUNKS[0], "correlation_id", ...), "no correlation id"),
        (_mutate(CHUNKS[0], "status", ...), "no status"),
        (_mutate(CHUNKS[0], "principal", "alice"), "unknown field"),
        (_mutate(CHUNKS[0], "type", "websocket"), "unknown chunk type"),
        (_mutate(CHUNKS[8], "out_of_band", "drifted"), "out_of_band outside modified/deleted"),
        (_mutate(CHUNKS[1], "stage", "provisioner"), "unknown stage"),
    ],
    ids=lambda v: v if isinstance(v, str) else "",
)
def test_chunk_rejections(chunk: dict[str, Any], why: str) -> None:
    with pytest.raises(ValidationError):
        parse_chunk(chunk)


def test_every_status_of_the_closed_set_is_a_chunk_status_and_nothing_else() -> None:
    for status in ALL_STATUSES:
        parse_chunk({"type": "final", "correlation_id": CID, "status": status})
    assert len(ALL_STATUSES) == 11


def test_deployment_report_passes_ready_strings_and_refuses_removal_verified() -> None:
    report = DeploymentReport.parse({
        "operation": "remove", "status": "PROVISIONING",
        "progress": [{"status": "PROVISIONING", "resource": "Network/migr-svc1",
                      "ready": "False", "reason": "Deleting"}],
    })
    assert report.progress[0].ready == "False"
    with pytest.raises(ValidationError, match="AD-63"):
        DeploymentReport.parse({
            "operation": "remove", "status": "COMPLETED",
            "progress": [{"status": "VERIFIED", "resource": "Network/x", "ready": "True"}],
        })
    with pytest.raises(ValidationError, match="Ready=True"):
        DeploymentReport.parse({
            "status": "COMPLETED",
            "progress": [{"status": "VERIFIED", "resource": "Network/x", "ready": "Unknown",
                          "reason": "VerificationFailed"}],
        })
