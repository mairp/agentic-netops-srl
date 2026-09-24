"""The allocator's claim adapter (T099; contracts/kuid-claim-profiles.md §3-§7; data-model.md
§23, §25).

A minimal in-cluster Kubernetes REST client over ``httpx`` — the service-account token and CA
mounted at ``/var/run/secrets/kubernetes.io/serviceaccount``, the API server at
``KUBERNETES_SERVICE_HOST``/``KUBERNETES_SERVICE_PORT`` — with an injectable transport for tests,
and on it the claim operations of **both** allocation authorities, selected by
``ALLOCATION_AUTHORITY`` (the ``allocation-authority`` ConfigMap):

======================  ===========================================  ===============================
authority               VLAN claim / VNI claim                       stated value · allocated value
======================  ===========================================  ===============================
``first-party``         ``identifierclaims.fabric.agentic-netops.io``  ``spec.requested`` ·
                        (``spec.poolRef.name`` = VLAN_POOL / VNI_POOL)  ``status.value``, ``Ready``
``kuid``                ``vlanclaims.vlan.be.kuid.dev`` /              ``spec.id`` · ``status.id``
                        ``genidclaims.genid.be.kuid.dev`` (``spec.index``)
======================  ===========================================  ===============================

Verbs used: ``create``, ``get``, ``list`` (by ``metadata.labels`` selector) and ``delete`` — the
claim-only identity's, and nothing else; no ``update``/``patch`` and no path outside the claim
resources (the allocator never reads a ``Network``, FR-075).

An authority that cannot be reached — a connection error, a timeout, a 5xx — is retried by the
worker-call rule of data-model.md §25 (2 retries, backoff from 1 s) and then raised as
:class:`AuthorityUnreachable` naming the authority. There is no local lease, pool or fallback.
"""

from __future__ import annotations

import asyncio
import os
import time
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx

FIRST_PARTY = "first-party"
KUID = "kuid"
AUTHORITIES = (FIRST_PARTY, KUID)
DEFAULT_NAMESPACES = {FIRST_PARTY: "agentic-netops-allocation", KUID: "kuid-system"}
DEFAULT_VLAN_POOL = "fabric01-vlan"
DEFAULT_VNI_POOL = "fabric01-vni"
VLAN = "vlan"
VNI = "vni"
SA_DIR = Path("/var/run/secrets/kubernetes.io/serviceaccount")

# (group, version, plural, kind) per authority and claim kind
RESOURCES: dict[str, dict[str, tuple[str, str, str, str]]] = {
    FIRST_PARTY: {
        VLAN: ("fabric.agentic-netops.io", "v1alpha1", "identifierclaims", "IdentifierClaim"),
        VNI: ("fabric.agentic-netops.io", "v1alpha1", "identifierclaims", "IdentifierClaim"),
    },
    KUID: {
        VLAN: ("vlan.be.kuid.dev", "v1alpha1", "vlanclaims", "VLANClaim"),
        VNI: ("genid.be.kuid.dev", "v1alpha1", "genidclaims", "GENIDClaim"),
    },
}


class AllocationError(Exception):
    """A terminal allocation failure; the message is operator-facing."""


class AuthorityUnreachable(AllocationError):
    """The allocation authority did not answer (after the bounded retry)."""


class AuthorityRefused(AllocationError):
    """The authority answered with a refusal of the request itself (4xx other than 404/409)."""


class ClaimExists(AllocationError):
    """A create found a claim of that name already present."""

    def __init__(self, name: str) -> None:
        super().__init__(f"claim {name} already exists")
        self.name = name


@dataclass(frozen=True)
class AuthorityConfig:
    authority: str = FIRST_PARTY
    namespace: str = DEFAULT_NAMESPACES[FIRST_PARTY]
    vlan_pool: str = DEFAULT_VLAN_POOL
    vni_pool: str = DEFAULT_VNI_POOL

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> AuthorityConfig:
        authority = (env.get("ALLOCATION_AUTHORITY") or FIRST_PARTY).strip()
        if authority not in AUTHORITIES:
            raise AllocationError(
                f"ALLOCATION_AUTHORITY={authority!r} is neither {FIRST_PARTY!r} nor {KUID!r}")
        return cls(authority=authority,
                    namespace=(env.get("ALLOCATION_NAMESPACE") or "").strip()
                    or DEFAULT_NAMESPACES[authority],
                    vlan_pool=(env.get("VLAN_POOL") or "").strip() or DEFAULT_VLAN_POOL,
                    vni_pool=(env.get("VNI_POOL") or "").strip() or DEFAULT_VNI_POOL)

    def pool(self, kind: str) -> str:
        return self.vlan_pool if kind == VLAN else self.vni_pool

    def describe(self) -> str:
        return f"the {self.authority} allocation authority in {self.namespace}"


@dataclass(frozen=True)
class Claim:
    kind: str
    name: str
    labels: dict[str, str]
    pool: str
    stated: int | None
    value: int | None
    ready: bool | None  # True bound · False refused · None pending
    reason: str = ""
    message: str = ""
    raw: dict[str, Any] = field(default_factory=dict, compare=False, repr=False)


# --------------------------------------------------------------------------------------------------
# the Kubernetes REST client
# --------------------------------------------------------------------------------------------------


class KubeClient:
    """Bearer-token REST calls against the API server. The token is re-read on every call (a
    projected token rotates)."""

    def __init__(self, *, base_url: str | None = None, token_path: Path | None = None,
                 ca_path: Path | None = None, transport: httpx.AsyncBaseTransport | None = None,
                 timeout: float = 10.0, env: Mapping[str, str] | None = None) -> None:
        env = os.environ if env is None else env
        if base_url is None:
            host = env.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc")
            port = env.get("KUBERNETES_SERVICE_PORT", "443")
            host = f"[{host}]" if ":" in host else host
            base_url = f"https://{host}:{port}"
        self.base_url = base_url
        self.token_path = token_path or SA_DIR / "token"
        ca = ca_path or SA_DIR / "ca.crt"
        verify: Any = str(ca) if transport is None and Path(ca).exists() else True
        self._client = httpx.AsyncClient(base_url=base_url, transport=transport, verify=verify,
                                         timeout=timeout)

    def _headers(self) -> dict[str, str]:
        headers = {"Accept": "application/json"}
        try:
            token = Path(self.token_path).read_text(encoding="utf-8").strip()
        except OSError:
            token = ""
        if token:
            headers["Authorization"] = f"Bearer {token}"
        return headers

    async def request(self, method: str, path: str, *, json: Any = None,
                      params: Mapping[str, str] | None = None) -> httpx.Response:
        return await self._client.request(method, path, json=json, params=params,
                                          headers=self._headers())

    async def aclose(self) -> None:
        await self._client.aclose()


# --------------------------------------------------------------------------------------------------
# the claim adapter
# --------------------------------------------------------------------------------------------------


def _int(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(str(value))
    except ValueError:
        return None


def _ready(conditions: Any) -> tuple[bool | None, str, str]:
    for cond in conditions or []:
        if isinstance(cond, dict) and cond.get("type") == "Ready":
            status = cond.get("status")
            ok = True if status == "True" else False if status == "False" else None
            return ok, str(cond.get("reason") or ""), str(cond.get("message") or "")
    return None, "", ""


class ClaimAdapter:
    """Claim create/get/list/delete on the selected authority, with the bounded retry."""

    def __init__(self, config: AuthorityConfig, kube: KubeClient, *, retries: int = 2,
                 backoff: float = 1.0,
                 sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
                 bind_timeout: float = 30.0, poll_interval: float = 0.5,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self.config = config
        self.kube = kube
        self.retries = retries
        self.backoff = backoff
        self.sleep = sleep
        self.bind_timeout = bind_timeout
        self.poll_interval = poll_interval
        self.clock = clock
        self.attempts = 0  # every HTTP attempt, retries included

    # ---- paths and shapes -------------------------------------------------------------------

    def collection(self, kind: str) -> str:
        group, version, plural, _ = RESOURCES[self.config.authority][kind]
        return f"/apis/{group}/{version}/namespaces/{self.config.namespace}/{plural}"

    def kinds_to_list(self) -> tuple[str, ...]:
        """One resource under first-party serves both kinds; kuid has two."""
        return (VLAN,) if self.config.authority == FIRST_PARTY else (VLAN, VNI)

    def body(self, kind: str, name: str, labels: Mapping[str, str],
             stated: int | None = None) -> dict[str, Any]:
        group, version, _, k = RESOURCES[self.config.authority][kind]
        spec: dict[str, Any]
        if self.config.authority == FIRST_PARTY:
            spec = {"poolRef": {"name": self.config.pool(kind)}}
            if stated is not None:
                spec["requested"] = str(stated)
        else:
            spec = {"index": self.config.pool(kind)}
            if stated is not None:
                spec["id"] = stated
        return {"apiVersion": f"{group}/{version}", "kind": k,
                "metadata": {"name": name, "namespace": self.config.namespace,
                             "labels": dict(labels)},
                "spec": spec}

    def parse(self, obj: dict[str, Any], kind: str | None = None) -> Claim:
        meta = obj.get("metadata") or {}
        spec = obj.get("spec") or {}
        status = obj.get("status") or {}
        if self.config.authority == FIRST_PARTY:
            pool = str((spec.get("poolRef") or {}).get("name") or "")
            kind = kind or (VNI if pool == self.config.vni_pool else VLAN)
            stated, value = _int(spec.get("requested")), _int(status.get("value"))
        else:
            pool = str(spec.get("index") or "")
            kind = kind or (VLAN if obj.get("kind") == "VLANClaim" else VNI)
            stated, value = _int(spec.get("id")), _int(status.get("id"))
        ready, reason, message = _ready(status.get("conditions"))
        if ready is None and self.config.authority == KUID and value is not None:
            ready = True  # the pinned kuid reports status.id once bound
        if ready is True and value is None:
            ready = None  # never proceed on an unknown identifier (§4)
        return Claim(kind, str(meta.get("name") or ""), dict(meta.get("labels") or {}), pool,
                     stated, value, ready, reason, message, obj)

    def is_kind(self, claim: Claim, kind: str) -> bool:
        return claim.pool == self.config.pool(kind)

    # ---- the transport with its bounded retry -----------------------------------------------

    async def _call(self, method: str, path: str, *, json: Any = None,
                    params: Mapping[str, str] | None = None) -> httpx.Response:
        cause = ""
        for attempt in range(1 + self.retries):
            self.attempts += 1
            try:
                response = await self.kube.request(method, path, json=json, params=params)
            except httpx.HTTPError as exc:
                cause = f"{type(exc).__name__}: {exc}" if str(exc) else type(exc).__name__
            else:
                if response.status_code < 500:
                    return response
                cause = f"HTTP {response.status_code}"
            if attempt < self.retries:
                await self.sleep(self.backoff * (2 ** attempt))
        raise AuthorityUnreachable(
            f"allocation authority unreachable: {self.config.describe()} did not answer "
            f"{method} after {1 + self.retries} attempts ({cause}); nothing was claimed locally "
            "and no local lease exists")

    def _refused(self, response: httpx.Response, what: str) -> AuthorityRefused:
        try:
            detail = response.json().get("message") or response.text
        except ValueError:
            detail = response.text
        return AuthorityRefused(f"{self.config.describe()} refused {what}: "
                                f"HTTP {response.status_code} {detail}".strip())

    # ---- verbs ------------------------------------------------------------------------------

    async def create(self, kind: str, name: str, labels: Mapping[str, str],
                     stated: int | None = None) -> Claim:
        response = await self._call("POST", self.collection(kind),
                                    json=self.body(kind, name, labels, stated))
        if response.status_code == 409:
            raise ClaimExists(name)
        if response.status_code >= 400:
            raise self._refused(response, f"the create of claim {name}")
        return self.parse(response.json(), kind)

    async def get(self, kind: str, name: str) -> Claim | None:
        response = await self._call("GET", f"{self.collection(kind)}/{name}")
        if response.status_code == 404:
            return None
        if response.status_code >= 400:
            raise self._refused(response, f"the read of claim {name}")
        return self.parse(response.json(), kind)

    async def list(self, selector: Mapping[str, str]) -> list[Claim]:
        """Every claim (both kinds) whose ``metadata.labels`` match ``selector``."""
        if not selector:
            raise AllocationError("an empty label selector would list every claim")
        label_selector = ",".join(f"{k}={v}" for k, v in sorted(selector.items()))
        claims: list[Claim] = []
        for kind in self.kinds_to_list():
            response = await self._call("GET", self.collection(kind),
                                        params={"labelSelector": label_selector})
            if response.status_code >= 400:
                raise self._refused(response, "the list of claims")
            for item in response.json().get("items") or []:
                claims.append(self.parse(item, kind if self.config.authority == KUID else None))
        return claims

    async def delete(self, kind: str, name: str) -> bool:
        response = await self._call("DELETE", f"{self.collection(kind)}/{name}")
        if response.status_code == 404:
            return False
        if response.status_code >= 400:
            raise self._refused(response, f"the delete of claim {name}")
        return True

    async def wait_bound(self, claim: Claim) -> Claim:
        """Poll until the claim is bound (value in status) or refused; bounded."""
        deadline = self.clock() + self.bind_timeout
        while claim.ready is None:
            if self.clock() >= deadline:
                raise AllocationError(
                    f"claim {claim.name} reported no allocated value within "
                    f"{self.bind_timeout:g} s; the request never proceeds on an unknown identifier")
            await self.sleep(self.poll_interval)
            current = await self.get(claim.kind, claim.name)
            if current is None:
                raise AllocationError(f"claim {claim.name} disappeared before it was bound")
            claim = current
        return claim


__all__ = ["AUTHORITIES", "FIRST_PARTY", "KUID", "VLAN", "VNI", "AllocationError",
           "AuthorityConfig", "AuthorityRefused", "AuthorityUnreachable", "Claim", "ClaimAdapter",
           "ClaimExists", "KubeClient"]
