"""Fakes of the deployer suites (T092, T094): an in-memory API server behind
``httpx.MockTransport`` (networks in the intent namespace, server-side apply with ``dryRun=All``,
finalizer semantics, injectable admission rejections — the one-owner webhook's denial of a holder
in ``agentic-netops-services`` among them — and the fail-closed webhook unreachable), a fake
translator sidecar, and a fake clock whose ``sleep`` advances time and runs scheduled changes."""

from __future__ import annotations

import copy
import json
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any
from urllib.parse import parse_qs

import httpx
from a2a.types import DataPart

import common.transport as t
from common.schemas.stream import DeploymentReport
from config.settings import load_settings
from provisioning.deployer.agent import Deployer
from provisioning.deployer.kube import KubeClient

CID = "4bf92f3577b34da6a3ce929d0e0e4736"
OTHER_CID = "0af7651916cd43dd8448eb211c80319c"
THREAD = "3f2b0e8a-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
SID = "4b7e19c2a05d3f6"
NETWORK = f"migr-{SID}"
NS = "agentic-netops-intent"
SERVICES_NS = "agentic-netops-services"
NETWORKS_PATH = f"/apis/fabric.agentic-netops.io/v1alpha1/namespaces/{NS}/networks"
NOW = datetime(2026, 9, 24, 12, 0, 0, tzinfo=UTC)
CONFIRM = {"decided": "confirm", "principal": "alice", "at": "2026-09-24T12:00:00Z"}
WEBHOOK_DOWN = (
    'Internal error occurred: failed calling webhook "networks.fabric.agentic-netops.io": '
    'failed to call webhook: Post "https://srl-provider-webhook.agentic-netops-system.svc:443/'
    'validate-fabric-agentic-netops-io-v1alpha1-network?timeout=10s": dial tcp '
    "10.96.114.7:443: connect: connection refused")

ASSIGNMENT: dict[str, Any] = {
    "serviceId": SID,
    "type": "mac-vrf",
    "tenant": "blue",
    "routeTargets": {"importRT": ["target:65000:10021"], "exportRT": ["target:65000:10021"]},
    "l2vni": 10021,
    "endpoints": [
        {"node": "leaf01", "attachment": "ethernet-1/1", "vlan": 120},
        {"node": "leaf02", "attachment": "ethernet-1/1", "vlan": 120},
    ],
}

TRANSLATOR_ANNOTATIONS = {
    "agentic-netops.io/translator": "agentic-netops-migration-translator",
    "agentic-netops.io/translator-version": "v0.1.0",
    "agentic-netops.io/mapping-version": "v0.1.0",
    "agentic-netops.io/migration-input-hash": "ab" * 32,
    "agentic-netops.io/tenant": "blue",
    "agentic-netops.io/service-type": "mac-vrf",
}


def condition(ctype: str, status: str, reason: str, message: str = "",
              generation: int = 1) -> dict[str, Any]:
    return {"type": ctype, "status": status, "reason": reason, "message": message,
            "observedGeneration": generation, "lastTransitionTime": "2026-09-24T12:00:00Z"}


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0
        self.sleeps: list[float] = []
        self._due: list[tuple[float, Callable[[], None]]] = []

    def __call__(self) -> float:
        return self.now

    def at(self, when: float, action: Callable[[], None]) -> None:
        self._due.append((when, action))
        self._due.sort(key=lambda d: d[0])

    async def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds
        while self._due and self._due[0][0] <= self.now:
            _, action = self._due.pop(0)
            action()


def network_manifest(sid: str = SID, *, vlan: int = 120, name: str | None = None
                     ) -> dict[str, Any]:
    """What the translator sidecar emits: translator keys only, no description (the fake API
    server defaults one, so the dry-run's spec differs from the one sent)."""
    return {
        "apiVersion": "fabric.agentic-netops.io/v1alpha1",
        "kind": "Network",
        "metadata": {"name": name or f"migr-{sid}", "annotations": dict(TRANSLATOR_ANNOTATIONS)},
        "spec": {
            "bridgeDomains": [{"name": f"bd-{sid}", "vlan": vlan, "l2vni": 10021,
                               "evpn": {"routeTargets": {"import": ["target:65000:10021"],
                                                         "export": ["target:65000:10021"]}}}],
            "attachments": [{"node": "leaf01", "attachment": "ethernet-1/1", "vlan": vlan},
                            {"node": "leaf02", "attachment": "ethernet-1/1", "vlan": vlan}],
        },
    }


class FakeTranslator:
    def __init__(self, log: list[tuple[str, ...]]) -> None:
        self.log = log
        self.calls: list[Any] = []
        self.status = 200
        self.causes: list[str] = []
        self.extra: list[dict[str, Any]] = []

    def handle(self, request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/v1/translate"
        assert request.url.host == "127.0.0.1" and request.url.port == 8090
        body = json.loads(request.content)
        self.calls.append(body)
        self.log.append(("translate",))
        if self.status == 422:
            return httpx.Response(422, json={"error": "validation", "causes": self.causes})
        manifests = [network_manifest(body["serviceId"]), *copy.deepcopy(self.extra)]
        return httpx.Response(200, json={"manifests": manifests, "yaml": "…"})

    @property
    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handle)


def _status(code: int, reason: str, message: str) -> httpx.Response:
    return httpx.Response(code, json={"kind": "Status", "apiVersion": "v1", "status": "Failure",
                                      "reason": reason, "message": message, "code": code})


def _sub(a: dict[str, Any]) -> tuple[str, str, int]:
    return (a["node"], a["attachment"], int(a.get("vlan") or 0))


class FakeAPIServer:
    """An in-memory API server for Networks and Events in the intent namespace."""

    def __init__(self, log: list[tuple[str, ...]] | None = None) -> None:
        self.log: list[tuple[str, ...]] = log if log is not None else []
        self.networks: dict[str, dict[str, Any]] = {}
        self.services: list[dict[str, Any]] = []  # agentic-netops-services: webhook-visible only
        self.events: list[dict[str, Any]] = []
        self.requests: list[dict[str, Any]] = []
        self.reject: dict[str, str] = {}        # name -> denial on dry-run and apply
        self.reject_apply: dict[str, str] = {}  # name -> denial on the real apply only
        self.webhook_down = 0                   # how many admissions fail calling the webhook
        self.unreachable = False
        self.delete_refused: set[str] = set()
        self.provider_marks_deleting = True
        self._uid = 0

    # --- inspection -----------------------------------------------------------------------

    def network_writes(self) -> list[dict[str, Any]]:
        return [r for r in self.requests if r["method"] in ("POST", "PUT", "PATCH", "DELETE")
                and "/networks" in r["path"] and r.get("dryRun") != "All"]

    def calls(self, method: str, *, dry_run: bool | None = None) -> list[dict[str, Any]]:
        return [r for r in self.requests if r["method"] == method and "/networks" in r["path"]
                and (dry_run is None or (r.get("dryRun") == "All") == dry_run)]

    # --- the provider's side (what tests script) ----------------------------------------------

    def set_conditions(self, name: str, *conditions: dict[str, Any]) -> None:
        obj = self.networks[name]
        current = {c["type"]: c for c in obj.setdefault("status", {}).get("conditions", [])}
        for c in conditions:
            current[c["type"]] = c
        obj["status"]["conditions"] = list(current.values())

    def set_ready(self, name: str, status: str, reason: str, message: str = "") -> None:
        self.set_conditions(name, condition("Ready", status, reason, message))

    def finalize(self, name: str) -> None:
        """The provider's finalizer completes: the object goes."""
        self.networks.pop(name, None)

    def put(self, obj: dict[str, Any]) -> None:
        """An object created behind the tier's back (another request, cluster tooling)."""
        obj = copy.deepcopy(obj)
        self._uid += 1
        obj["metadata"].setdefault("namespace", NS)
        obj["metadata"].update(uid=f"uid-{self._uid}", resourceVersion="1", generation=1)
        self.networks[obj["metadata"]["name"]] = obj

    # --- the transport ------------------------------------------------------------------------

    @property
    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handle)

    def client(self) -> KubeClient:
        return KubeClient("https://kube.test", token="sa-token",  # noqa: S106 — a fake API server
                          transport=self.transport)

    def handle(self, request: httpx.Request) -> httpx.Response:
        params = {k: v[0] for k, v in parse_qs(request.url.query.decode()).items()}
        body = json.loads(request.content) if request.content else None
        record = {"method": request.method, "path": request.url.path, "body": body, **params}
        self.requests.append(record)
        self.log.append(("api", request.method, request.url.path.rsplit("/", 1)[-1],
                         params.get("dryRun", "")))
        if self.unreachable:
            raise httpx.ConnectError("connection refused", request=request)
        assert request.headers.get("authorization") == "Bearer sa-token"
        path = request.url.path
        if path == f"/api/v1/namespaces/{NS}/events" and request.method == "POST":
            self.events.append(body)
            return httpx.Response(201, json=body)
        assert path.startswith(NETWORKS_PATH), f"the deployer touched {path}"
        rest = path[len(NETWORKS_PATH):].strip("/")
        if request.method == "GET" and not rest:
            items = list(self.networks.values())
            if "labelSelector" in params:
                key, value = params["labelSelector"].split("=", 1)
                items = [o for o in items
                         if (o["metadata"].get("labels") or {}).get(key) == value]
            return httpx.Response(200, json={"kind": "NetworkList",
                                             "items": copy.deepcopy(items)})
        if request.method == "GET":
            obj = self.networks.get(rest)
            if obj is None:
                return _status(404, "NotFound", f'networks "{rest}" not found')
            return httpx.Response(200, json=copy.deepcopy(obj))
        if request.method == "PATCH":
            assert request.headers["content-type"] == "application/apply-patch+yaml"
            assert params.get("fieldManager") == "agentic-netops-intent-deployer"
            return self._apply(rest, body, dry_run=params.get("dryRun") == "All")
        if request.method == "DELETE":
            return self._delete(rest)
        return _status(405, "MethodNotAllowed", request.method)

    def _admit(self, name: str, obj: dict[str, Any], dry_run: bool) -> httpx.Response | None:
        if self.webhook_down > 0:
            self.webhook_down -= 1
            return _status(500, "InternalError", WEBHOOK_DOWN)
        others = [o for o in [*self.networks.values(), *self.services]
                  if o["metadata"]["name"] != name]
        for a in obj["spec"].get("attachments", []):
            for o in others:
                if any(_sub(b) == _sub(a) for b in o["spec"].get("attachments", [])):
                    key = f"{o['metadata'].get('namespace', NS)}/{o['metadata']['name']}"
                    return _status(403, "Forbidden", (
                        'admission webhook "networks.fabric.agentic-netops.io" denied the '
                        f"request: Network {NS}/{name} refused: subinterface {a['node']} "
                        f"{a['attachment']}.{a.get('vlan') or 0} is already owned by Network "
                        f"{key}: one owner per (node, port, vlan)"))
        if name in self.reject:
            return _status(422, "Invalid", self.reject[name])
        if not dry_run and name in self.reject_apply:
            return _status(422, "Invalid", self.reject_apply[name])
        return None

    def _apply(self, name: str, body: dict[str, Any], *, dry_run: bool) -> httpx.Response:
        assert body["metadata"]["name"] == name and body["metadata"]["namespace"] == NS
        denial = self._admit(name, body, dry_run)
        if denial is not None:
            return denial
        existing = self.networks.get(name)
        obj = copy.deepcopy(body)
        obj["spec"].setdefault("description", f"Service {name} (defaulted)")  # defaulting
        meta = obj["metadata"]
        if existing is not None:
            meta["uid"] = existing["metadata"]["uid"]
            gen = existing["metadata"]["generation"] + (existing["spec"] != obj["spec"])
            obj["status"] = existing.get("status", {})
        else:
            self._uid += 1
            meta["uid"] = f"uid-{self._uid}"
            gen = 1
        meta.update(generation=gen, resourceVersion=str(len(self.requests)),
                    creationTimestamp="2026-09-24T12:00:00Z",
                    managedFields=[{"manager": "agentic-netops-intent-deployer",
                                    "operation": "Apply"}])
        if not dry_run:
            self.networks[name] = obj
        return httpx.Response(200 if existing else 201, json=copy.deepcopy(obj))

    def _delete(self, name: str) -> httpx.Response:
        obj = self.networks.get(name)
        if obj is None:
            return _status(404, "NotFound", f'networks "{name}" not found')
        if name in self.delete_refused:
            return _status(403, "Forbidden", f'networks "{name}" is forbidden: delete refused')
        if obj["metadata"].get("finalizers"):
            # A finalizer blocks: the object stays with its deletion timestamp.
            obj["metadata"].setdefault("deletionTimestamp", "2026-09-24T12:00:05Z")
            if self.provider_marks_deleting:
                self.set_conditions(
                    name, condition("Ready", "False", "Deleting",
                                    "the Network is being removed and is no longer offered"),
                    condition("Deleting", "True", "RemovingConfiguration",
                              "finalization started: removing configuration"))
            return httpx.Response(200, json=copy.deepcopy(obj))
        del self.networks[name]
        return httpx.Response(200, json={"kind": "Status", "status": "Success"})


class Rig:
    """One deployer over the fakes."""

    def __init__(self, **env: str) -> None:
        self.log: list[tuple[str, ...]] = []
        self.api = FakeAPIServer(self.log)
        self.translator = FakeTranslator(self.log)
        self.clock = FakeClock()
        settings = load_settings({"AGENT_COMPONENT": "deployer", **env})
        self.deployer = Deployer(settings, kube_factory=self.api.client,
                                 translator_transport=self.translator.transport,
                                 clock=self.clock, sleep=self.clock.sleep, now=lambda: NOW,
                                 poll_seconds=5.0)

    async def call(self, payload: dict[str, Any], *, cid: str = CID,
                   thread: str = THREAD) -> DeploymentReport:
        message = await self.raw(payload, cid=cid, thread=thread)
        meta = (message.metadata or {}).get("x-agentic-netops") or {}
        assert meta.get("status") == "ok", meta
        (data,) = [p.root.data for p in message.parts if isinstance(p.root, DataPart)]
        return DeploymentReport.parse(data)

    async def raw(self, payload: dict[str, Any], *, cid: str = CID,
                  thread: str = THREAD) -> Any:
        request = t.StageMessage(kind="stage", skill="deploy-network-service",
                                 correlation_id=cid, thread_id=thread,
                                 idempotency_key=f"{thread}:{payload.get('operation')}",
                                 operation=str(payload.get("operation") or "create"),
                                 data=payload, text="")
        return await self.deployer.handle(request)

    async def create(self, **extra: Any) -> DeploymentReport:
        return await self.call({"operation": "create", "assignment": copy.deepcopy(ASSIGNMENT),
                                "principal": "alice", "confirmation_2": CONFIRM, **extra})

    async def remove(self, network: str = NETWORK, **extra: Any) -> DeploymentReport:
        return await self.call({"operation": "remove", "network": network, "principal": "alice",
                                "confirmation_2": CONFIRM, **extra})

    async def status(self, network: str = NETWORK, tier_removed: bool = False
                     ) -> DeploymentReport:
        return await self.call({"operation": "status", "network": network,
                                "tier_removed": tier_removed, "principal": "alice"})

    async def gate(self, *ids: str) -> DeploymentReport:
        return await self.call({"operation": "release_gate", "correlation_ids": list(ids)})

    def converge_at(self, when: float, name: str = NETWORK) -> None:
        self.clock.at(when, lambda: self.api.set_ready(name, "True", "Converged",
                                                       "every target read back"))

    def submitted(self) -> dict[str, Any]:
        """A converged, tier-submitted Network, created through the deployer."""
        return self.api.networks[NETWORK]
