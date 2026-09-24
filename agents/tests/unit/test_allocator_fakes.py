"""A fake Kubernetes API for the allocator suites (T093, T091's mapper half), and its self-tests.

:class:`FakeKube` is an :class:`httpx.MockTransport` implementing an in-memory claim store for
**both** allocation authorities — first-party ``identifierclaims`` (``spec.poolRef.name``,
``spec.requested``, ``status.value``, ``Ready``) and kuid ``vlanclaims``/``genidclaims``
(``spec.index``, ``spec.id``, ``status.id``) — with the pool arbitration the authority performs:
the lowest free value of the pool's range for a dynamic claim, a stated value refused naming its
holder, exhaustion stated with the pool and its range. It fails the test on any request whose path
names ``networks`` (FR-075: the allocator never reads a ``Network``) and on any verb the claim-only
identity does not hold.
"""

from __future__ import annotations

import asyncio
import json
import re
from dataclasses import dataclass, field
from typing import Any

import httpx
import pytest

from provisioning.allocator.kuid_adapter import (
    FIRST_PARTY,
    KUID,
    VLAN,
    VNI,
    AuthorityConfig,
    AuthorityUnreachable,
    ClaimAdapter,
    KubeClient,
)

CLAIM_PATH = re.compile(
    r"^/apis/(?P<group>[^/]+)/v1alpha1/namespaces/(?P<ns>[^/]+)/(?P<plural>[a-z]+)"
    r"(?:/(?P<name>[^/]+))?$")
PLURALS = {"identifierclaims": FIRST_PARTY, "vlanclaims": KUID, "genidclaims": KUID}
GROUPS = {"identifierclaims": "fabric.agentic-netops.io", "vlanclaims": "vlan.be.kuid.dev",
          "genidclaims": "genid.be.kuid.dev"}


class NetworkReadError(AssertionError):
    """The allocator touched a ``networks`` path."""


@dataclass
class FakeKube:
    authority: str = FIRST_PARTY
    namespace: str | None = None
    pools: dict[str, tuple[int, int]] = field(default_factory=lambda: {
        "fabric01-vlan": (1000, 4000), "fabric01-vni": (10000, 20000)})
    objects: dict[tuple[str, str], dict[str, Any]] = field(default_factory=dict)
    held: dict[str, dict[int, str]] = field(default_factory=dict)  # pool -> value -> claim
    requests: list[tuple[str, str]] = field(default_factory=list)
    down: int = 0  # the next N requests fail to connect
    always_down: bool = False
    server_errors: int = 0  # the next N requests answer 503
    pending_reads: int = 0  # a new claim reads as pending this many GETs before it binds

    def __post_init__(self) -> None:
        if self.namespace is None:
            self.namespace = ("agentic-netops-allocation" if self.authority == FIRST_PARTY
                              else "kuid-system")
        self._pending: dict[tuple[str, str], int] = {}

    # ---- wiring -----------------------------------------------------------------------------

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handle)

    def adapter(self, sleeps: list[float] | None = None, **kwargs: Any) -> ClaimAdapter:
        async def sleep(seconds: float) -> None:
            if sleeps is not None:
                sleeps.append(seconds)
            await asyncio.sleep(0)

        config = AuthorityConfig.from_env({"ALLOCATION_AUTHORITY": self.authority})
        kube = KubeClient(base_url="https://kube.test", transport=self.transport())
        return ClaimAdapter(config, kube, sleep=sleep, **kwargs)

    # ---- views ------------------------------------------------------------------------------

    def claims(self) -> list[dict[str, Any]]:
        return [o for _, o in sorted(self.objects.items())]

    def pool_of(self, obj: dict[str, Any]) -> str:
        spec = obj.get("spec") or {}
        return spec["poolRef"]["name"] if "poolRef" in spec else spec["index"]

    def vlan_claims(self) -> list[dict[str, Any]]:
        return [o for o in self.claims() if self.pool_of(o) == "fabric01-vlan"]

    def vni_claims(self) -> list[dict[str, Any]]:
        return [o for o in self.claims() if self.pool_of(o) == "fabric01-vni"]

    def creates(self) -> int:
        return sum(1 for m, _ in self.requests if m == "POST")

    # ---- the API ----------------------------------------------------------------------------

    def handle(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        self.requests.append((request.method, path))
        if "networks" in path:
            raise NetworkReadError(f"the allocator issued {request.method} {path}")
        if self.always_down or self.down > 0:
            self.down = max(0, self.down - 1)
            raise httpx.ConnectError("connection refused", request=request)
        if self.server_errors > 0:
            self.server_errors -= 1
            return httpx.Response(503, json={"message": "service unavailable"})
        if request.method not in ("GET", "POST", "DELETE"):
            raise AssertionError(f"verb {request.method} is not the claim-only identity's")
        m = CLAIM_PATH.match(path)
        if m is None or m["plural"] not in PLURALS or PLURALS[m["plural"]] != self.authority:
            raise AssertionError(f"path {path} is not a claim resource of {self.authority}")
        assert GROUPS[m["plural"]] == m["group"]
        assert m["ns"] == self.namespace, f"namespace {m['ns']}"
        plural, name = m["plural"], m["name"]
        if request.method == "POST" and name is None:
            return self._create(plural, json.loads(request.content))
        if request.method == "GET" and name is None:
            return self._list(plural, request.url.params.get("labelSelector", ""))
        if request.method == "GET":
            return self._get(plural, name)
        if request.method == "DELETE" and name is not None:
            return self._delete(plural, name)
        raise AssertionError(f"unexpected {request.method} {path}")

    def _create(self, plural: str, body: dict[str, Any]) -> httpx.Response:
        name = body["metadata"]["name"]
        if (plural, name) in self.objects:
            return httpx.Response(409, json={"reason": "AlreadyExists",
                                             "message": f'{plural} "{name}" already exists'})
        body = json.loads(json.dumps(body))
        body["metadata"]["namespace"] = self.namespace
        self.objects[(plural, name)] = body
        self._arbitrate(plural, name)
        if self.pending_reads:
            self._pending[(plural, name)] = self.pending_reads
        created = json.loads(json.dumps(body))
        created.pop("status", None)  # the apiserver answers a create before any controller ran
        return httpx.Response(201, json=created)

    def _get(self, plural: str, name: str) -> httpx.Response:
        obj = self.objects.get((plural, name))
        if obj is None:
            return httpx.Response(404, json={"reason": "NotFound"})
        left = self._pending.get((plural, name), 0)
        if left:
            self._pending[(plural, name)] = left - 1
            pending = json.loads(json.dumps(obj))
            pending.pop("status", None)
            return httpx.Response(200, json=pending)
        return httpx.Response(200, json=obj)

    def _list(self, plural: str, selector: str) -> httpx.Response:
        want = dict(p.split("=", 1) for p in selector.split(",") if p)
        items = [o for (pl, _), o in sorted(self.objects.items()) if pl == plural and all(
            (o["metadata"].get("labels") or {}).get(k) == v for k, v in want.items())]
        return httpx.Response(200, json={"items": items})

    def _delete(self, plural: str, name: str) -> httpx.Response:
        obj = self.objects.pop((plural, name), None)
        if obj is None:
            return httpx.Response(404, json={"reason": "NotFound"})
        pool = self.pool_of(obj)
        for value, holder in list(self.held.get(pool, {}).items()):
            if holder == name:
                del self.held[pool][value]  # freed synchronously (G11 (f))
        return httpx.Response(200, json={"status": "Success"})

    # ---- the authority's arbitration --------------------------------------------------------

    def _arbitrate(self, plural: str, name: str) -> None:
        obj = self.objects[(plural, name)]
        pool = self.pool_of(obj)
        lo, hi = self.pools[pool]
        held = self.held.setdefault(pool, {})
        spec = obj["spec"]
        stated = spec.get("requested", spec.get("id"))
        where = f"pool {self.namespace}/{pool} (range {lo}-{hi})"
        if stated is not None:
            value = int(stated)
            if not lo <= value <= hi:
                return self._refuse(obj, "OutOfRange", f"value {value} is outside {where}")
            if value in held:
                return self._refuse(obj, "Conflict", f"value {value} is held by claim "
                                    f"{self.namespace}/{held[value]}; no other value is tried")
        else:
            free = next((v for v in range(lo, hi + 1) if v not in held), None)
            if free is None:
                return self._refuse(obj, "Exhausted",
                                    f"{where} is exhausted: all {hi - lo + 1} values are held")
            value = free
        held[value] = name
        cond = {"type": "Ready", "status": "True", "reason": "Bound",
                "message": f"value {value} bound from pool {self.namespace}/{pool}"}
        obj["status"] = ({"value": str(value), "conditions": [cond]}
                         if self.authority == FIRST_PARTY
                         else {"id": value, "conditions": [cond]})
        return None

    def _refuse(self, obj: dict[str, Any], reason: str, message: str) -> None:
        obj["status"] = {"conditions": [{"type": "Ready", "status": "False", "reason": reason,
                                         "message": message}]}


# --------------------------------------------------------------------------------------------------
# self-tests of the fake (so the suites that use it rest on something checked)
# --------------------------------------------------------------------------------------------------

LABELS = {"agentic-netops.io/correlation-id": "a" * 32, "agentic-netops.io/tier": "intent"}


@pytest.mark.parametrize("authority", [FIRST_PARTY, KUID])
async def test_fake_binds_lowest_free_and_refuses_a_held_stated_value(authority: str) -> None:
    kube = FakeKube(authority=authority)
    adapter = kube.adapter()
    first = await adapter.wait_bound(await adapter.create(VLAN, "x.a.vlan-1", LABELS))
    second = await adapter.wait_bound(await adapter.create(VLAN, "x.b.vlan-1", LABELS))
    assert (first.value, second.value) == (1000, 1001)
    held = await adapter.wait_bound(await adapter.create(VNI, "x.c.l2vni", LABELS, stated=10007))
    assert held.value == 10007 and held.stated == 10007
    refused = await adapter.wait_bound(await adapter.create(VNI, "x.d.l2vni", LABELS,
                                                            stated=10007))
    assert refused.ready is False and "10007" in refused.message and "x.c.l2vni" in refused.message
    assert await adapter.delete(VNI, "x.c.l2vni") is True
    again = await adapter.wait_bound(await adapter.create(VNI, "x.e.l2vni", LABELS, stated=10007))
    assert again.value == 10007  # freed synchronously


async def test_fake_counts_the_bounded_retry_and_fails_a_network_path() -> None:
    kube = FakeKube(always_down=True)
    sleeps: list[float] = []
    adapter = kube.adapter(sleeps)
    with pytest.raises(AuthorityUnreachable, match="allocation authority unreachable"):
        await adapter.get(VLAN, "x")
    assert len(kube.requests) == 3 and sleeps == [1.0, 2.0]
    with pytest.raises(NetworkReadError):
        kube.handle(httpx.Request("GET", "https://kube.test/apis/fabric.agentic-netops.io/"
                                  "v1alpha1/namespaces/agentic-netops-intent/networks"))
