"""T089 — both surfaces require a login, live (quickstart.md §25; FR-102, SC-042, SC-024).

Against the running supervisor: every pipeline-reaching route is refused with no credential and
with a wrong one — ``401`` and the ``Basic`` challenge — and the before/after reads of the
supervisor's durable checkpointer (threads), its model-call log (model calls) and the cluster's
allocation claims (claim-selector diff) all move by **zero**; a body asserting a ``principal`` is
``400`` naming the field; the refusal counter moves in the analytics store; and every principal the
tier phase captured into the lab's evidence is the one operator username.
"""

from __future__ import annotations

import time

from conftest import (
    REPO,
    auth_refusals_total,
    claim_names,
    http,
    model_call_count,
    network_names,
    record,
    thread_count,
    wait_for,
)

CHALLENGE = 'Basic realm="agentic-netops"'
PROMPT = {"prompt": "Provision a vlan 121 on leaf01 ethernet-1/1 for tenant acme"}
ROUTES = (("GET", "/suggested-prompts", None), ("GET", "/transport/config", None),
          ("POST", "/agent/prompt/stream", PROMPT))


def _snapshot() -> dict:
    return {"threads": thread_count(), "model_calls": model_call_count(),
            "claims": sorted(claim_names()), "networks": sorted(network_names())}


def test_every_pipeline_route_refuses_without_or_with_a_wrong_credential(operator) -> None:
    user, _ = operator
    before = _snapshot()
    refusals_before = auth_refusals_total() or 0.0
    seen = []
    for method, path, body in ROUTES:
        for label, auth in (("none", None), ("wrong-password", (user, "wrong")),
                            ("wrong-user", ("intruder", "wrong"))):
            resp = http(method, path, auth=auth, body=body)
            seen.append({"route": f"{method} {path}", "credential_case": label,
                         "status": resp.status,
                         "www-authenticate": resp.headers.get("www-authenticate")})
            assert resp.status == 401, (path, label, resp.status, resp.body[:200])
            assert resp.headers.get("www-authenticate") == CHALLENGE, (path, label)
            assert b"thread" not in resp.body.lower(), "a refusal must not mention a thread"
    after = _snapshot()
    delta = {"threads": after["threads"] - before["threads"],
             "model_calls": after["model_calls"] - before["model_calls"],
             "claims_added": sorted(set(after["claims"]) - set(before["claims"])),
             "claims_removed": sorted(set(before["claims"]) - set(after["claims"])),
             "networks_added": sorted(set(after["networks"]) - set(before["networks"]))}
    record("auth-refusals", {"requests": seen, "before": before, "after": after, "delta": delta})
    assert delta == {"threads": 0, "model_calls": 0, "claims_added": [], "claims_removed": [],
                     "networks_added": []}

    # agentic_netops_agent_auth_refusals_total moved — read from the analytics store, where the
    # tier collector's metrics pipeline puts it (one export interval plus the batch processor).
    expected = refusals_before + len(seen)
    wait_for("the auth-refusal counter in the analytics store to reach "
             f"{expected:.0f}", lambda: (auth_refusals_total() or 0.0) >= expected, timeout=180,
             every=10)
    record("auth-refusal-counter", {"before": refusals_before, "after": auth_refusals_total(),
                                    "refused_requests": len(seen)})


def test_probe_routes_answer_without_a_credential() -> None:
    assert http("GET", "/health").status == 200
    assert http("GET", "/v1/health").status in (200, 503)


def test_a_body_carrying_principal_is_refused_naming_the_field(operator) -> None:
    before = thread_count()
    resp = http("POST", "/agent/prompt/stream", auth=operator,
                body={"prompt": "status", "principal": "someone-else"})
    assert resp.status == 400, resp.body[:300]
    assert b"principal" in resp.body
    assert thread_count() == before


def test_an_authenticated_request_is_served(operator) -> None:
    resp = http("GET", "/transport/config", auth=operator)
    assert resp.status == 200
    assert resp.json() == {"transport": "SLIM",
                           "endpoint": "http://slim.agentic-netops-agents.svc:46357"}
    prompts = http("GET", "/suggested-prompts", auth=operator)
    assert prompts.status == 200


def test_captured_usernames_are_the_one_operator(operator) -> None:
    """SC-042's reconciliation set: the ``operator-credentials`` usernames the tier phase
    captured through evidence_run on every provisioning run of this lab — one member, the
    operator's (the password is never among them)."""
    user, password = operator
    root = REPO / ".evidence"
    captures = sorted(root.glob("*/*/operator-username-*.stdout"))
    assert captures, f"no operator-username capture under {root}"
    names = set()
    for path in captures:
        text = path.read_text()
        assert password not in text, f"{path} carries the password"
        for line in text.splitlines():
            if line.startswith("username:"):
                names.add(line.split(":", 1)[1].strip())
    record("captured-usernames", {"captures": [str(p.relative_to(REPO)) for p in captures],
                                  "usernames": sorted(names), "at": time.time()})
    assert names == {user}
