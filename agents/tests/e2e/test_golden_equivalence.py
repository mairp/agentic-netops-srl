"""T103 — the agent-produced normalized intent translates to the hand-authored goldens
(quickstart.md §17; SC-012, SC-016).

For each construct ``test_constructs_e2e.py`` kept what the allocator assigned. This suite:

1. translates that assignment through the **one** translator — the ``intent-translator`` sidecar of
   the running deployer pod, over a port-forward to its pod-local ``127.0.0.1:8090`` — and asserts
   the ``spec:`` it emits equals the ``spec`` of the ``Network`` the deployer applied;
2. re-keys the assignment onto the hand-authored fixture's identifiers — the random service
   identifier and the allocated VNI are the only values an operator's words cannot fix — asserts the
   re-keyed intent **equals** the fixture ``tests/unit/testdata/migration/construct_*.json``, and
   asserts the translator's ``spec:`` for it is **byte-identical** to
   ``construct_*.spec.golden.yaml``.
"""

from __future__ import annotations

import contextlib
import json
import socket
import subprocess
import time
import urllib.request
import uuid
from collections.abc import Iterator
from typing import Any

import pytest
import yaml
from conftest import AGENTS_NS, CONTEXT, REPO, kjson, record
from test_constructs_e2e import assignments_dir

FIXTURES = REPO / "tests" / "unit" / "testdata" / "migration"
FILES = {"vlan": "construct_vlan", "mac-vrf": "construct_macvrf", "ip-vrf": "construct_ipvrf"}


@contextlib.contextmanager
def translator() -> Iterator[str]:
    pods = kjson("-n", AGENTS_NS, "get", "pods", "-l", "app.kubernetes.io/name=deployer")["items"]
    if not pods:
        pods = [p for p in kjson("-n", AGENTS_NS, "get", "pods")["items"]
                if p["metadata"]["name"].startswith("deployer-")]
    pod = pods[0]["metadata"]["name"]
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        local = sock.getsockname()[1]
    proc = subprocess.Popen(  # noqa: S603
        ["kubectl", "--context", CONTEXT, "-n", AGENTS_NS, "port-forward",  # noqa: S607
         f"pod/{pod}", f"{local}:8090", "--address", "127.0.0.1"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(3)
        yield f"http://127.0.0.1:{local}/v1/translate"
    finally:
        proc.terminate()
        proc.wait(timeout=10)


def translate(url: str, intent: dict[str, Any]) -> dict[str, Any]:
    request = urllib.request.Request(url, data=json.dumps(intent).encode(), method="POST",  # noqa: S310
                                     headers={"content-type": "application/json",
                                              # each translation is a request: its sidecar lines
                                              # carry a correlation id like the deployer's (NFR-014)
                                              "X-Correlation-Id": uuid.uuid4().hex})
    with urllib.request.urlopen(request, timeout=30) as resp:  # noqa: S310
        return json.loads(resp.read())


def spec_block(document: str) -> str:
    """The ``spec:`` block of one emitted YAML document, byte for byte."""
    lines = document.splitlines(keepends=True)
    start = next(i for i, line in enumerate(lines) if line.startswith("spec:"))
    end = next((i for i in range(start + 1, len(lines))
                if lines[i] and not lines[i].startswith((" ", "-", "\n"))), len(lines))
    return "".join(lines[start:end])


def rekey(assignment: dict[str, Any], fixture: dict[str, Any]) -> dict[str, Any]:
    text = json.dumps(assignment)
    text = text.replace(assignment["serviceId"], fixture["serviceId"])
    for key in ("l2vni", "l3vni"):
        if key in assignment and key in fixture:
            text = text.replace(str(assignment[key]), str(fixture[key]))
    return json.loads(text)


@pytest.mark.parametrize("construct", list(FILES))
def test_agent_intent_translates_to_the_golden(construct: str) -> None:
    kept = assignments_dir() / f"{construct}.json"
    assert kept.exists(), f"{kept} missing — run test_constructs_e2e.py first"
    got = json.loads(kept.read_text())
    assignment = got["assignment"]
    fixture = json.loads((FIXTURES / f"{FILES[construct]}.json").read_text())
    golden = (FIXTURES / f"{FILES[construct]}.spec.golden.yaml").read_text()

    with translator() as url:
        own = translate(url, assignment)
        rekeyed = rekey(assignment, fixture)
        canonical = translate(url, rekeyed)

    # 1. the translator's spec for the agent's own intent is the spec the deployer applied
    own_spec = yaml.safe_load(spec_block(own["yaml"]))["spec"]
    assert own_spec == got["live_spec"], (own_spec, got["live_spec"])
    # 2. the agent's intent, re-keyed, is the hand-authored fixture …
    assert rekeyed == fixture, (rekeyed, fixture)
    # … and its emitted spec: is byte-identical to the golden
    emitted = spec_block(canonical["yaml"])
    assert emitted == golden, f"--- emitted\n{emitted}\n--- golden\n{golden}"
    record(f"t103-golden-{construct}", {
        "construct": construct, "network": got["network"],
        "agent_assignment": assignment, "rekeyed_equals_fixture": True,
        "emitted_spec_equals_golden_bytes": True, "golden": str(
            (FIXTURES / f"{FILES[construct]}.spec.golden.yaml").relative_to(REPO)),
        "translator_spec_equals_live_spec": True})
