"""T148 — the authentication audit on BOTH surfaces, live (SC-042, FR-102, AD-46, AD-55, AD-64).

The programmatic surface is the supervisor (``SUPERVISOR_URL``, loopback :19090); the chat
surface is the UI's same-origin proxy (``CHAT_URL``, loopback :13000, ``/api/<route>``), which is
what a browser reaches. On each: every pipeline-reaching route with no credential, a wrong
password and an unknown user → 100% ``401`` with the ``Basic`` challenge, and a thread count, a
model-call count and a claim-selector diff taken before and after all read **zero**; a body
carrying ``principal`` is refused ``400`` naming the field.

Then the reconciliation: every principal on an audit event in the analytics store is reconciled
against **the usernames the run used** — the ``operator-username-*`` captures T088 writes through
``evidence_run`` on every provisioning run, found under the lab's evidence root. The distinct set is
derived here, from those captures alone; its cardinality is recorded, and more than one member is
recorded as **invalidating** the measure (a failure, never reconciled away). This task never reads
``username_unchanged`` — that field lives only in the usernames record a down path's export writes,
and the record of the removal that will end this tier does not exist yet (AD-64); any
``usernames-*.json`` an earlier export left under the evidence root is a snapshot and is not read
here — T152's file-source run is where the field is read (AD-55).
"""

from __future__ import annotations

import os
import time

import pytest
from conftest import (
    REPO,
    SUPERVISOR_URL,
    claim_names,
    http,
    model_call_count,
    network_names,
    record,
    thread_count,
)
from tierflow import audit_events

CHAT_URL = os.environ.get("CHAT_URL", "http://127.0.0.1:13000/api")
SURFACES = {"programmatic": SUPERVISOR_URL, "chat": CHAT_URL}
CHALLENGE = 'Basic realm="agentic-netops"'
PROMPT = {"prompt": "Provision a vlan 121 on leaf01 ethernet-1/1 for tenant acme"}
ROUTES = (("GET", "/suggested-prompts", None), ("GET", "/transport/config", None),
          ("POST", "/agent/prompt/stream", PROMPT))
RESULTS: dict = {}


def _snapshot() -> dict:
    return {"threads": thread_count(), "model_calls": model_call_count(),
            "claims": sorted(claim_names()), "networks": sorted(network_names())}


@pytest.mark.parametrize("surface", sorted(SURFACES))
def test_every_pipeline_route_is_refused_with_zero_side_effects(surface: str, operator) -> None:
    user, _ = operator
    base = SURFACES[surface]
    before = _snapshot()
    seen = []
    for method, path, body in ROUTES:
        for label, auth in (("none", None), ("wrong-password", (user, "wrong")),
                            ("unknown-user", ("intruder", "wrong"))):
            resp = http(method, path, auth=auth, body=body, base=base)
            seen.append({"route": f"{method} {path}", "credential_case": label,
                         "status": resp.status,
                         "www-authenticate": resp.headers.get("www-authenticate")})
    after = _snapshot()
    delta = {"threads": after["threads"] - before["threads"],
             "model_calls": after["model_calls"] - before["model_calls"],
             "claims_added": sorted(set(after["claims"]) - set(before["claims"])),
             "claims_removed": sorted(set(before["claims"]) - set(after["claims"])),
             "networks_added": sorted(set(after["networks"]) - set(before["networks"]))}
    refused = sum(1 for s in seen if s["status"] == 401 and s["www-authenticate"] == CHALLENGE)
    RESULTS[surface] = {"base": base, "requests": seen, "refused": refused, "attempted": len(seen),
                        "before": before, "after": after, "delta": delta}
    record(f"t148-auth-{surface}", RESULTS[surface])
    assert refused == len(seen), seen
    assert delta == {"threads": 0, "model_calls": 0, "claims_added": [], "claims_removed": [],
                     "networks_added": []}, delta


@pytest.mark.parametrize("surface", sorted(SURFACES))
def test_a_principal_field_is_refused_by_name(surface: str, operator) -> None:
    before = thread_count()
    resp = http("POST", "/agent/prompt/stream", auth=operator, base=SURFACES[surface],
                body={"prompt": "status", "principal": "someone-else"})
    record(f"t148-principal-{surface}", {"status": resp.status, "body": resp.body[:400].decode()})
    assert resp.status == 400, resp.body[:300]
    assert b"principal" in resp.body
    assert thread_count() == before


def captured_usernames() -> tuple[set[str], list[str]]:
    """The distinct operator usernames the tier-phase captures of this lab record (T088)."""
    root = REPO / ".evidence"
    captures = sorted(root.glob("*/*/operator-username-*.stdout"))
    names: set[str] = set()
    for path in captures:
        for line in path.read_text().splitlines():
            if line.startswith("username:"):
                names.add(line.split(":", 1)[1].strip())
    return names, [str(p.relative_to(REPO)) for p in captures]


def test_every_audit_principal_is_a_username_the_run_used(operator) -> None:
    _, password = operator
    names, captures = captured_usernames()
    events = audit_events()
    principals: dict[str, int] = {}
    for e in events:
        p = e["attrs"].get("audit.principal")
        principals[p] = principals.get(p, 0) + 1
    unmatched = {p: n for p, n in principals.items() if p not in names}
    verdict = {"captures": captures, "usernames": sorted(names), "cardinality": len(names),
               "invalidating": len(names) > 1, "audit_events": len(events),
               "principals": principals, "unmatched": unmatched, "at": time.time(),
               "username_unchanged_read": False}
    record("t148-principal-reconciliation", verdict)
    assert captures, "no operator-username capture under the lab's evidence root"
    assert all(password not in (REPO / c).read_text() for c in captures), \
        "a capture carries the password"
    assert len(names) == 1, \
        f"{len(names)} usernames captured — the measure is invalidated: {sorted(names)}"
    assert events, "no audit event in the analytics store to reconcile"
    assert unmatched == {}, f"audit principals not among the captured usernames: {unmatched}"
