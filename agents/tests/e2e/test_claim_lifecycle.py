"""T173 — every claim of a submitted service has one release owner (SC-046; quickstart.md §26a).

Live, against the running lab and the running intent tier; nothing here is a fake. The order is
the task's: the two negative controls first, then the lifecycle cases. Every observation is written
to the run's evidence directory through ``conftest.record`` (``t173-*.json``).

``T173_NEGATIVE_CONTROL=1`` turns the first case into the negative control that
``evidence_negative_control`` runs: the adoption check is run unguarded against a service
whose VLAN claim was relabelled by hand, so the run MUST fail; every other case is skipped
in that mode.
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from typing import Any

import pytest
import tierflow as tf
from conftest import CONTEXT, INTENT_NS, REPO, kjson, kubectl, record, wait_for

NEGATIVE = os.environ.get("T173_NEGATIVE_CONTROL") == "1"
PROVIDER_NS = "agentic-netops-system"
NETWORKS = "networks.fabric.agentic-netops.io"
CLAIMS = "identifierclaims.fabric.agentic-netops.io"
ALLOCATION_BAND = (1000, 4000)
NAMING_BAND = (100, 999)
MACVRF = "Create a mac-vrf for tenant acme on leaf01 ethernet-1/1 and leaf02 ethernet-1/1"
NAMED_VLAN = 861
MACVRF_NAMED = (f"Create a mac-vrf for tenant acme with VLAN {NAMED_VLAN} on leaf01 "
                "ethernet-1/1 and leaf02 ethernet-1/1")
IPVRF = "Create an ip-vrf for tenant acme on leaf01 ethernet-1/1 with prefix 10.20.0.0/24"
COPY_NAMED_VLAN = 947  # the VNI-only copy's own, naming-band VLAN (claims nothing)

# module state shared by the ordered cases
S: dict[str, Any] = {}
CREATED: set[str] = set()  # every Network this suite made, removed at teardown whatever happened


@pytest.fixture(scope="module", autouse=True)
def _cleanup() -> Any:
    yield
    for name in sorted(CREATED):
        kubectl("-n", INTENT_NS, "delete", NETWORKS, name, "--ignore-not-found", "--wait=false",
                check=False)
    for name in sorted(CREATED):
        try:
            tf.wait_gone(name, timeout=180)
        except AssertionError as exc:  # reported, never silently left behind
            print(f"cleanup: {exc}")
    record("t173-cleanup", {"removed": sorted(CREATED),
                            "left": sorted(n for n in CREATED if tf.network(n))})


def _only_positive() -> None:
    if NEGATIVE:
        pytest.skip("negative-control mode runs only the relabelled-claim case")


# ---- helpers -------------------------------------------------------------------------------


def role_of(claim_name: str) -> str:
    return claim_name.rsplit(".", 1)[-1]


def is_vlan(claim: dict[str, Any]) -> bool:
    return role_of(claim["metadata"]["name"]).startswith("vlan-")


def is_vni(claim: dict[str, Any]) -> bool:
    return role_of(claim["metadata"]["name"]).startswith(("l2vni-", "l3vni-"))


def value_of(claim: dict[str, Any]) -> int | None:
    v = (claim.get("status") or {}).get("value")
    return None if v is None else int(v)


def names(items: list[dict[str, Any]]) -> list[str]:
    return sorted(c["metadata"]["name"] for c in items)


def claim_refs(network: str) -> list[dict[str, Any]]:
    net = tf.network(network) or {}
    return list((net.get("status") or {}).get("claimRefs") or [])


def condition(network: str, ctype: str) -> dict[str, Any] | None:
    net = tf.network(network) or {}
    for c in (net.get("status") or {}).get("conditions") or []:
        if c["type"] == ctype:
            return c
    return None


def adoption_check(network: str, cid: str) -> dict[str, Any]:
    """The SC-046 check: the claim selector on the correlation label returns the service's VLAN
    claim and its VNI claim, each named by the deterministic rule, and both sit in the Network's
    status.claimRefs as ``adopted`` with the value the claim reports."""
    found = tf.claims_of(cid)
    vlans = [c for c in found if is_vlan(c)]
    vnis = [c for c in found if is_vni(c)]
    refs = {r["name"]: r for r in claim_refs(network)}
    obs = {"network": network, "correlation_id": cid, "selector": names(found),
           "claimRefs": sorted(refs.values(), key=lambda r: r["name"])}
    assert vlans, f"the selector on {cid} returns no VLAN claim: {obs}"
    assert vnis, f"the selector on {cid} returns no VNI claim: {obs}"
    for c in vlans + vnis:
        name = c["metadata"]["name"]
        assert name.startswith(f"{INTENT_NS}.{network}."), f"{name} is not {network}'s: {obs}"
        ref = refs.get(name)
        assert ref is not None, f"claim {name} is not in {network}'s status.claimRefs: {obs}"
        assert ref["origin"] == "adopted", f"claim {name} is {ref['origin']}, not adopted: {obs}"
        assert int(ref["value"]) == value_of(c), f"claim {name} value disagrees: {obs}"
    for name, ref in refs.items():  # and every VLAN/VNI claimRef is one the selector returns
        assert name in names(found), f"claimRef {name} is not under the label {cid}: {obs}"
        assert ref["origin"] == "adopted", f"claimRef {name} is {ref['origin']}: {obs}"
    return obs


def wait_adopted(network: str, cid: str, timeout: float = 120) -> dict[str, Any]:
    last: list[Any] = [None]

    def ok() -> bool:
        try:
            last[0] = adoption_check(network, cid)
            return True
        except AssertionError as exc:
            last[0] = str(exc)
            return False

    try:
        wait_for(f"{network} to adopt its claims", ok, timeout=timeout, every=2)
    except AssertionError as exc:
        raise AssertionError(f"{exc}; last: {last[0]}") from None
    return last[0]


def wait_selector_empty(cid: str, timeout: float = 60) -> float:
    start = time.monotonic()
    wait_for(f"the selector on {cid} to be empty", lambda: not tf.claims_of(cid),
             timeout=timeout, every=1)
    return round(time.monotonic() - start, 1)


def bd_vlan(network: str) -> int:
    spec = (tf.network(network) or {})["spec"]
    return int(spec["bridgeDomains"][0]["vlan"])


def provision(prompt: str) -> tf.Service:
    svc = tf.provision(prompt)
    assert svc.network, f"no Network named in the approval turn:\n{svc.turns[-1].text()}"
    CREATED.add(svc.network)
    return svc


def copy_of(source: str, name: str, *, bd_vlan_value: int, attach: dict[str, Any]) -> dict:
    """A hand-made Network carrying ``source``'s correlation label and its VNI."""
    src = tf.network(source)
    assert src, f"{source} is gone"
    bd = src["spec"]["bridgeDomains"][0]
    return {
        "apiVersion": "fabric.agentic-netops.io/v1alpha1", "kind": "Network",
        "metadata": {"name": name, "namespace": INTENT_NS,
                     "labels": {tf.CORRELATION_LABEL:
                                src["metadata"]["labels"][tf.CORRELATION_LABEL]}},
        "spec": {"description": f"T173 negative control: a copy of {source}'s label",
                 "bridgeDomains": [{"name": bd["name"], "vlan": bd_vlan_value,
                                    "l2vni": bd["l2vni"]}],
                 "attachments": [attach]},
    }


def apply(obj: dict[str, Any]) -> None:
    proc = subprocess.run(["kubectl", "--context", CONTEXT, "apply", "-f", "-"],  # noqa: S603, S607
                          input=json.dumps(obj), capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"apply {obj['metadata']['name']}: {proc.stderr.strip()}"
    CREATED.add(obj["metadata"]["name"])


def refuse_copy(copy: dict[str, Any], source: str, cid: str) -> dict[str, Any]:
    """Apply the copy and prove it adopts nothing of ``source``'s: Accepted=False
    AllocationConflict, no claimRef naming any of the source's claims, the source untouched."""
    before = names(tf.claims_of(cid))
    name = copy["metadata"]["name"]
    apply(copy)
    wait_for(f"{name} to be answered", lambda: condition(name, "Accepted") is not None,
             timeout=90, every=1)
    accepted = condition(name, "Accepted") or {}
    refs = claim_refs(name)
    obs = {"copy": name, "copied_from": source, "correlation_id": cid,
           "copy_spec": copy["spec"], "accepted": accepted, "copy_claimRefs": refs,
           "source_claims_before": before}
    kubectl("-n", INTENT_NS, "delete", NETWORKS, name, "--wait=false")
    tf.wait_gone(name, timeout=120)
    CREATED.discard(name)
    obs["source_claims_after_copy_deleted"] = names(tf.claims_of(cid))
    obs["source_adoption_after"] = adoption_check(source, cid)
    assert accepted.get("status") == "False" and accepted.get("reason") == "AllocationConflict", \
        f"the copy was not refused AllocationConflict: {obs}"
    adopted = {r["name"] for r in refs}
    assert not adopted & set(before), f"the copy adopted a claim of {source}: {obs}"
    assert not [r for r in refs if r.get("origin") == "adopted"], f"the copy adopted: {obs}"
    assert obs["source_claims_after_copy_deleted"] == before, \
        f"deleting the copy changed {source}'s claims: {obs}"
    return obs


def translator_check(assignment: dict[str, Any]) -> dict[str, Any]:
    binary = REPO / "bin" / "migration-translator"
    proc = subprocess.run([str(binary), "--file", "-"], input=json.dumps(assignment),  # noqa: S603
                          capture_output=True, text=True, timeout=60)
    return {"command": f"{binary} --file -", "exit": proc.returncode,
            "stdout": proc.stdout, "stderr": proc.stderr}


class Watch:
    """Polls a Network and its claims while something else runs — what was seen, in order."""

    def __init__(self, network: str, cid: str, every: float = 0.5) -> None:
        self.network, self.cid, self.every = network, cid, every
        self.seen: list[dict[str, Any]] = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                net = tf.network(self.network)
                self.seen.append({
                    "t": time.time(), "network": net is not None,
                    "deleting": bool(net and net["metadata"].get("deletionTimestamp")),
                    "claims": names(tf.claims_of(self.cid))})
            except AssertionError:
                pass
            self._stop.wait(self.every)

    def __enter__(self) -> Watch:
        self._thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self._stop.set()
        self._thread.join(timeout=30)


# ---- the two negative controls first ------------------------------------------------------


def test_negative_control_relabelled_claim_fails_the_check() -> None:
    svc = provision(MACVRF)
    S["first"] = svc
    net, cid = svc.network, svc.correlation_id
    obs: dict[str, Any] = {"network": net, "correlation_id": cid,
                           "before": wait_adopted(net, cid)}
    vlan_claim = next(c for c in tf.claims_of(cid) if is_vlan(c))["metadata"]["name"]
    foreign = "0" * 32
    kubectl("-n", tf.ALLOCATION_NS, "label", CLAIMS, vlan_claim,
            f"{tf.CORRELATION_LABEL}={foreign}", "--overwrite")
    obs["relabelled"] = {"claim": vlan_claim, "to": foreign}
    try:
        if NEGATIVE:
            record("t173-negative-control-relabelled", obs)
            adoption_check(net, cid)  # MUST fail: this is the negative control's run
        with pytest.raises(AssertionError) as caught:
            adoption_check(net, cid)
        obs["check_failed_with"] = str(caught.value)
    finally:
        kubectl("-n", tf.ALLOCATION_NS, "label", CLAIMS, vlan_claim,
                f"{tf.CORRELATION_LABEL}={cid}", "--overwrite")
        if NEGATIVE:
            tf.delete_with_kubectl(net)
            tf.wait_gone(net)
            CREATED.discard(net)
            wait_selector_empty(cid)
    obs["after_restore"] = adoption_check(net, cid)
    record("t173-negative-control-relabelled", obs)


def test_negative_control_copied_label_adopts_nothing() -> None:
    _only_positive()
    svc: tf.Service = S["first"]
    copy = copy_of(svc.network, f"t173-copy-vni-{svc.correlation_id[:8]}",
                   bd_vlan_value=COPY_NAMED_VLAN,
                   attach={"node": "leaf01", "attachment": "ethernet-1/1",
                           "vlan": COPY_NAMED_VLAN})
    obs = refuse_copy(copy, svc.network, svc.correlation_id)
    record("t173-negative-control-copied-label-same-vni", obs)


# ---- the lifecycle -----------------------------------------------------------------------


def test_first_mac_vrf_adopts_vlan_and_vni_in_allocation_band() -> None:
    _only_positive()
    svc: tf.Service = S["first"]
    obs = adoption_check(svc.network, svc.correlation_id)
    vlan = bd_vlan(svc.network)
    obs["allocated_vlan"] = vlan
    obs["assignment"] = svc.assignment
    obs["translator"] = translator_check(svc.assignment or {})
    record("t173-first-mac-vrf", obs)
    assert ALLOCATION_BAND[0] <= vlan <= ALLOCATION_BAND[1], f"allocated VLAN {vlan} off-band"
    assert obs["translator"]["exit"] == 0, f"the translator refused: {obs['translator']}"
    assert f"vlan: {vlan}" in obs["translator"]["stdout"]
    assert condition(svc.network, "Ready")["status"] == "True"  # converged, so it passed


def test_attachment_removed_keeps_vlan_claim_adopted() -> None:
    _only_positive()
    svc: tf.Service = S["first"]
    net, cid = svc.network, svc.correlation_id
    spec = tf.network(net)["spec"]
    idx = next(i for i, a in enumerate(spec["attachments"]) if a["node"] == "leaf02")
    removed = spec["attachments"][idx]
    kubectl("-n", INTENT_NS, "patch", NETWORKS, net, "--type=json",
            "-p", json.dumps([{"op": "remove", "path": f"/spec/attachments/{idx}"}]))

    def settled() -> bool:
        n = tf.network(net) or {}
        ready = condition(net, "Ready") or {}
        return (n.get("status", {}).get("observedGeneration") == n["metadata"]["generation"]
                and ready.get("status") == "True"
                and ready.get("observedGeneration") == n["metadata"]["generation"])

    wait_for(f"{net} to converge without {removed}", settled, timeout=180, every=2)
    obs = {"removed_attachment": removed, "after": adoption_check(net, cid)}
    vlan_ref = next(r for r in claim_refs(net) if r["indexKind"] == "vlan")
    obs["vlan_claimRef"] = vlan_ref
    # the full copy — the same VLAN and the same VNI — on the subinterface the patch freed
    copy = copy_of(net, f"t173-copy-full-{cid[:8]}", bd_vlan_value=int(vlan_ref["value"]),
                   attach={"node": removed["node"], "attachment": removed["attachment"],
                           "vlan": int(vlan_ref["value"])})
    obs["full_copy"] = refuse_copy(copy, net, cid)
    record("t173-attachment-removed", obs)
    assert vlan_ref["origin"] == "adopted"


def test_first_removed_through_the_tier() -> None:
    _only_positive()
    svc: tf.Service = S["first"]
    net, cid = svc.network, svc.correlation_id
    before = names(tf.claims_of(cid))
    with Watch(net, cid) as watch:
        turns = tf.remove(net)
        tf.wait_gone(net, timeout=300)
        lag = wait_selector_empty(cid)
    CREATED.discard(net)
    final = turns[-1].last()
    stages = sorted({c.get("stage") for t in turns for c in t.chunks if c.get("stage")})
    live_loss = [s for s in watch.seen if s["network"] and not s["deleting"]
                 and s["claims"] != before]
    obs = {"network": net, "correlation_id": cid, "claims_before": before,
           "final": final, "stages": stages, "selector_empty_after_gone_s": lag,
           "claims_lost_while_network_live": live_loss, "watch": watch.seen}
    record("t173-removed-through-tier", obs)
    assert final.get("status") == "COMPLETED", f"removal did not complete: {turns[-1].text()}"
    assert "allocator" not in stages, f"the removal reached the allocator (a release): {stages}"
    assert not live_loss, "a claim vanished while the Network was live — not the finalizer's"


def test_second_removed_with_kubectl_delete() -> None:
    _only_positive()
    svc = provision(MACVRF)
    net, cid = svc.network, svc.correlation_id
    obs = {"adoption": wait_adopted(net, cid), "allocated_vlan": bd_vlan(net)}
    tf.delete_with_kubectl(net)
    tf.wait_gone(net)
    CREATED.discard(net)
    obs["selector_empty_after_gone_s"] = wait_selector_empty(cid)
    record("t173-second-kubectl-delete", obs)
    assert ALLOCATION_BAND[0] <= obs["allocated_vlan"] <= ALLOCATION_BAND[1]


def test_third_deleted_at_apply_with_provider_killed() -> None:
    _only_positive()
    svc = tf.request_to_confirmation(MACVRF)
    tf.confirm_interpretation(svc)
    cid = svc.correlation_id
    selector = f"{tf.CORRELATION_LABEL}={cid}"
    seen: dict[str, Any] = {}
    done = threading.Event()

    def approve() -> None:
        try:
            seen["turn"] = tf.approve_deployment(svc)
        finally:
            done.set()

    worker = threading.Thread(target=approve, daemon=True)
    worker.start()
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline and not done.is_set():
        items = kjson("-n", INTENT_NS, "get", NETWORKS, "-l", selector)["items"]
        if items:
            obj = items[0]
            name = obj["metadata"]["name"]
            CREATED.add(name)
            base = ["kubectl", "--context", CONTEXT]
            procs = [subprocess.Popen([*base, "-n", INTENT_NS, "delete", NETWORKS, name,  # noqa: S603
                                       "--wait=false"], stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True),
                     subprocess.Popen([*base, "-n", PROVIDER_NS, "delete", "pod", "-l",  # noqa: S603
                                       "app.kubernetes.io/name=srl-provider", "--wait=false"],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      text=True)]
            outs = [p.communicate(timeout=60) for p in procs]
            seen.update(name=name, at_delete={
                "status": obj.get("status") or {}, "finalizers": obj["metadata"].get("finalizers"),
                "claims": names(tf.claims_of(cid))},
                delete=[{"rc": p.returncode, "out": o[0], "err": o[1]}
                        for p, o in zip(procs, outs, strict=True)])
            break
        time.sleep(0.2)
    assert "name" in seen, "the Network never appeared while the deployer ran"
    worker.join(timeout=900)
    kubectl("-n", PROVIDER_NS, "rollout", "status", "deploy/srl-provider", "--timeout=300s",
            timeout=320)
    tf.wait_gone(seen["name"], timeout=300)
    CREATED.discard(seen["name"])
    lag = wait_selector_empty(cid, timeout=120)
    status_at_delete = seen["at_delete"]["status"]
    turn = seen.get("turn")
    obs = {"network": seen["name"], "correlation_id": cid, "delete": seen["delete"],
           "at_delete": seen["at_delete"],
           # recorded, not asserted (AD-44): did the deletion beat the first reconcile?
           "deletion_beat_first_reconcile": not status_at_delete.get("conditions")
                                             and not status_at_delete.get("claimRefs"),
           "approval_final": turn.last() if turn else None,
           "selector_empty_after_gone_s": lag}
    record("t173-third-delete-at-apply", obs)
    assert all(d["rc"] == 0 for d in seen["delete"]), seen["delete"]
    assert "fabric.agentic-netops.io/finalizer" in (seen["at_delete"]["finalizers"] or []), \
        "the applied Network carried no finalizer"


def test_named_vlan_in_naming_band_claims_no_vlan() -> None:
    _only_positive()
    svc = provision(MACVRF_NAMED)
    net, cid = svc.network, svc.correlation_id
    vlan = bd_vlan(net)
    found = tf.claims_of(cid)
    obs = {"network": net, "correlation_id": cid, "named_vlan": vlan,
           "selector": names(found), "claimRefs": claim_refs(net)}
    tf.delete_with_kubectl(net)
    tf.wait_gone(net)
    CREATED.discard(net)
    obs["selector_empty_after_gone_s"] = wait_selector_empty(cid)
    record("t173-named-vlan", obs)
    assert vlan == NAMED_VLAN and NAMING_BAND[0] <= vlan <= NAMING_BAND[1], obs
    assert not [c for c in found if is_vlan(c)], f"a named VLAN was claimed: {obs}"
    assert [c for c in found if is_vni(c)], f"no VNI claim: {obs}"


def test_ip_vrf_without_vlan_claims_no_vlan() -> None:
    _only_positive()
    fabric = kjson("-n", PROVIDER_NS, "get", "fabrics.fabric.agentic-netops.io")["items"][0]
    untagged = {i["node"]: i.get("untaggedAccessPorts") or [] for i in fabric["spec"]["inventory"]}
    obs: dict[str, Any] = {"untaggedAccessPorts": untagged}
    port = next(((n, p[0]) for n, p in sorted(untagged.items()) if p), None)
    if port is None:
        turn = tf.ask(IPVRF)
        obs.update(prompt=IPVRF, final=turn.last(), correlation_id=turn.correlation_id,
                   vlan_claims=names([c for c in tf.claims_of(turn.correlation_id)
                                      if is_vlan(c)]))
        record("t173-ip-vrf", obs)
        pytest.fail("cannot run on this lab: Fabric fabric01 declares no untaggedAccessPorts, so "
                    "an ip-vrf attachment naming no VLAN (the untagged subinterface) is refused "
                    f"by the mapper before any allocation: {turn.last().get('message')!r}")
    node, p = port
    svc = provision(f"Create an ip-vrf for tenant acme on {node} {p} with prefix 10.20.0.0/24")
    net, cid = svc.network, svc.correlation_id
    found = tf.claims_of(cid)
    spec = tf.network(net)["spec"]
    obs.update(network=net, correlation_id=cid, selector=names(found), spec=spec,
               claimRefs=claim_refs(net))
    tf.delete_with_kubectl(net)
    tf.wait_gone(net)
    CREATED.discard(net)
    record("t173-ip-vrf", obs)
    assert all(a.get("vlan") is None for a in spec["attachments"]), obs
    assert not [c for c in found if is_vlan(c)], f"an ip-vrf got a VLAN claim: {obs}"
    assert [c for c in found if is_vni(c) and role_of(c["metadata"]["name"]).startswith("l3vni-")]
