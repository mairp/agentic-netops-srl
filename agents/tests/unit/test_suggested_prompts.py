"""T139 — the authored suggestion set ``supervisors/provisioning/suggested_prompts.json``
(FR-084, FR-097, R-30; contracts/supervisor-http.md §``GET /suggested-prompts``).

Asserts against the site's real inventory — the ``Fabric`` inventory of
``examples/fabric/default-fabric.yaml``, which provisioning applies and from which the tier phase
writes ``site-inventory`` — that every prompt's nodes and ports resolve there, in the device's own
naming, that every prompt names a construct, that the six shapes of the contract are covered, and
that nothing is offered that the qualification record does not show as qualified.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
import yaml

from common.guards.classifier import RequestClass, classify
from supervisors.provisioning.prompts import (
    CONSTRUCTS,
    SUGGESTED_PROMPTS_FILE,
    load_suggestions,
    suggested_prompts,
)

REPO = Path(__file__).resolve().parents[3]
DEFAULT_FABRIC = REPO / "examples" / "fabric" / "default-fabric.yaml"
QUALIFICATION_DOC = REPO / "docs" / "reference" / "qualification-record.md"
RETIRED = re.compile(r"\b(vpls|vpws|e-?line|l3vpn|l2l3-?irb|evpn-vpws)\b", re.IGNORECASE)
SHAPES = {
    "vlan": "vlan",
    "mac-vrf": "mac-vrf",
    "ip-vrf": "ip-vrf",
    "gateway": "mac-vrf",
    "acl": "acl",
    "acl-on-service": None,
}
NODE_PORT = re.compile(r"\b((?:leaf|spine)\d+)\s+(ethernet-\d+/\d+)\b")


def site_inventory() -> dict[str, dict[str, list[str]]]:
    """``node → {role, accessPorts}`` from the default ``Fabric``."""
    fabric = yaml.safe_load(DEFAULT_FABRIC.read_text(encoding="utf-8"))
    roles = {n["name"]: n["role"] for n in fabric["spec"]["nodes"]}
    return {
        e["node"]: {"role": roles[e["node"]], "accessPorts": list(e.get("accessPorts") or [])}
        for e in fabric["spec"]["inventory"]
    }


def documented_record() -> dict[str, str]:
    """The flat keys of the qualification record's documented shape (``key: qualified``)."""
    text = QUALIFICATION_DOC.read_text(encoding="utf-8")
    return dict(
        re.findall(
            r"^\s{2}([a-z0-9-]+(?:\.[a-z0-9-]+)?): (qualified|unqualified)\b", text, re.MULTILINE
        )
    )


def write_inputs(tmp_path: Path, record: dict[str, str]) -> tuple[Path, Path]:
    inv, qual = tmp_path / "site-inventory", tmp_path / "fabric-qualification"
    inv.mkdir()
    qual.mkdir()
    nodes = [
        {"name": n, "role": v["role"], "accessPorts": v["accessPorts"]}
        for n, v in site_inventory().items()
    ]
    (inv / "inventory.json").write_text(json.dumps({"nodes": nodes}))
    for key, value in record.items():
        (qual / key).write_text(value)
    return inv, qual


SUGGESTIONS = load_suggestions()


def test_the_file_is_the_one_served() -> None:
    assert SUGGESTED_PROMPTS_FILE.name == "suggested_prompts.json"
    assert SUGGESTED_PROMPTS_FILE.parent.name == "provisioning"
    assert len(SUGGESTIONS) == 6


def test_the_six_shapes_of_the_contract_are_covered() -> None:
    assert {s["shape"] for s in SUGGESTIONS} == set(SHAPES)
    for s in SUGGESTIONS:
        if SHAPES[s["shape"]] is not None:
            assert s["construct"] == SHAPES[s["shape"]], s
    on_service = next(s for s in SUGGESTIONS if s["shape"] == "acl-on-service")
    assert "acl" in on_service["requires"] and on_service["construct"] in CONSTRUCTS
    gateway = next(s for s in SUGGESTIONS if s["shape"] == "gateway")
    assert "mac-vrf.anycast-gateway-ipv4" in gateway["requires"]


@pytest.mark.parametrize("entry", SUGGESTIONS, ids=lambda e: e["shape"])
def test_every_prompt_names_a_construct(entry: dict) -> None:
    assert entry["construct"] in CONSTRUCTS
    words = re.findall(r"[a-z0-9-]+", entry["prompt"].lower())
    assert entry["construct"] in words, entry["prompt"]
    assert not RETIRED.search(entry["prompt"]), entry["prompt"]


@pytest.mark.parametrize("entry", SUGGESTIONS, ids=lambda e: e["shape"])
def test_every_node_and_port_resolves_in_the_site_inventory(entry: dict) -> None:
    inventory = site_inventory()
    named = NODE_PORT.findall(entry["prompt"])
    assert named, entry["prompt"]
    # every (node, port) the text names is declared, and every declared one is in the text
    assert set(named) == {(e["node"], e["port"]) for e in entry["endpoints"]}
    for node, port in named:
        assert node in inventory, f"{node} is not in the site inventory"
        assert inventory[node]["role"] == "leaf", f"{node} is a {inventory[node]['role']}"
        assert port in inventory[node]["accessPorts"], f"{node} has no access port {port}"


@pytest.mark.parametrize("entry", SUGGESTIONS, ids=lambda e: e["shape"])
def test_nothing_offered_that_the_record_does_not_show_qualified(entry: dict) -> None:
    record = documented_record()
    assert record, "qualification-record.md lists no flat keys"
    assert entry["construct"] in entry["requires"] or entry["shape"] == "acl-on-service"
    for key in entry["requires"]:
        assert record.get(key) == "qualified", (entry["shape"], key)
    assert "egress" not in entry["prompt"].lower()  # acl.egress is gated/unqualified
    assert "ipv6" not in entry["prompt"].lower()  # the IPv6 gateway and Type-5 are gated


@pytest.mark.parametrize("entry", SUGGESTIONS, ids=lambda e: e["shape"])
def test_every_prompt_is_provisionable(entry: dict) -> None:
    assert classify(entry["prompt"]).request_class == RequestClass.PROVISIONABLE


def test_served_on_the_real_inventory_with_the_documented_record(tmp_path: Path) -> None:
    inv, qual = write_inputs(tmp_path, documented_record())
    served = suggested_prompts(inv, qual)["prompts"]
    assert {p["shape"] for p in served} == set(SHAPES)
    assert all(set(p) == {"shape", "construct", "prompt"} for p in served)


def test_an_unqualified_property_withdraws_its_prompt(tmp_path: Path) -> None:
    record = documented_record()
    record["mac-vrf.anycast-gateway-ipv4"] = "unqualified"
    del record["ip-vrf"]  # absent is unqualified
    inv, qual = write_inputs(tmp_path, record)
    served = suggested_prompts(inv, qual)["prompts"]
    assert {p["shape"] for p in served} == {"vlan", "mac-vrf", "acl", "acl-on-service"}


def test_a_port_missing_from_the_inventory_withdraws_its_prompt(tmp_path: Path) -> None:
    inv, qual = write_inputs(tmp_path, documented_record())
    document = json.loads((inv / "inventory.json").read_text())
    for node in document["nodes"]:
        if node["name"] == "leaf02":
            node["accessPorts"] = ["ethernet-1/2"]
    (inv / "inventory.json").write_text(json.dumps(document))
    served = {p["shape"] for p in suggested_prompts(inv, qual)["prompts"]}
    # the two prompts across leaf01 and leaf02 name leaf02 ethernet-1/1, which no longer resolves
    assert served == {"vlan", "ip-vrf", "acl", "acl-on-service"}
