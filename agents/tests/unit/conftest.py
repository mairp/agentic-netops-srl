"""Shared fakes of the supervisor suites (T077, T079): fake workers over the in-memory SLIM
stand-in, a fake cluster behind the fake deployer, a fake clock, a counting model client, and the
mounted inputs (operator credentials, agent cards, site inventory, qualification record)."""

from __future__ import annotations

import base64
import json
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import pytest

import common.transport as t
from common import telemetry
from config.settings import Settings, load_settings

CARD_IDS = {
    "mapper": ("devnet/provisioning/network-mapping", "map-network-request"),
    "allocator": ("devnet/provisioning/network-allocator", "allocate-network-service"),
    "deployer": ("devnet/provisioning/network-deployer", "deploy-network-service"),
}
GATEWAY_CREDENTIALS = ("slim-gw", "gw-pass-123")

INTERPRETATION = {
    "service_id": "3f2b9c0d1e4a5b6",
    "service_type": "mac-vrf",
    "tenant": "blue",
    "endpoints": [
        {"site_or_node": "leaf01", "attachment": "ethernet-1/1", "vlan": 100},
        {"site_or_node": "leaf02", "attachment": "ethernet-1/1", "vlan": 100},
    ],
}
ASSIGNMENT = {
    "serviceId": "3f2b9c0d1e4a5b6",
    "type": "mac-vrf",
    "tenant": "blue",
    "routeTargets": {"importRT": ["target:65000:10021"], "exportRT": ["target:65000:10021"]},
    "l2vni": 10021,
    "endpoints": [
        {"node": "leaf01", "attachment": "ethernet-1/1", "vlan": 100},
        {"node": "leaf02", "attachment": "ethernet-1/1", "vlan": 100},
    ],
}
NETWORK = "Network/migr-3f2b9c0d1e4a5b6"
INVENTORY = {
    "nodes": [
        {"name": "spine01", "role": "spine", "accessPorts": []},
        {"name": "leaf01", "role": "leaf",
         "accessPorts": ["ethernet-1/1", "ethernet-1/2", "ethernet-1/3", "ethernet-1/4"]},
        {"name": "leaf02", "role": "leaf",
         "accessPorts": ["ethernet-1/1", "ethernet-1/2", "ethernet-1/3", "ethernet-1/4"]},
    ]
}
QUALIFIED = ["vlan", "vlan.bridged-subinterface", "mac-vrf", "mac-vrf.anycast-gateway-ipv4",
             "ip-vrf", "ip-vrf.evpn-type5-ipv4", "acl", "acl.ingress-ipv4", "acl.ingress-ipv6"]
UNQUALIFIED = ["acl.egress", "mac-vrf.anycast-gateway-ipv6", "ip-vrf.evpn-type5-ipv6"]


class Killed(BaseException):
    """Stands for the supervisor process dying mid-request."""


class FakeClock:
    def __init__(self, start: float = 1000.0) -> None:
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class FakeLLM:
    def __init__(self) -> None:
        self.calls: list[list[dict[str, Any]]] = []

    def complete(self, messages: list[dict[str, Any]]) -> dict[str, Any]:
        self.calls.append(messages)
        return {"choices": [{"message": {"role": "assistant",
                                         "content": "The constructs are vlan, mac-vrf, ip-vrf "
                                                    "and acl."}}]}


@dataclass
class FakeCluster:
    """What the fake deployer submits into: one Network per idempotency key."""

    networks: dict[str, str] = field(default_factory=dict)  # key -> Network name
    creations: list[str] = field(default_factory=list)

    def apply(self, key: str, name: str) -> None:
        if key not in self.networks:
            self.networks[key] = name
            self.creations.append(name)


def progress(status: str, ready: str | None, reason: str | None = None,
             resource: str = NETWORK) -> dict[str, Any]:
    event: dict[str, Any] = {"status": status, "resource": resource}
    if ready is not None:
        event["ready"] = ready
    if reason is not None:
        event["reason"] = reason
    return event


def resource_ref(ready: str | None = "True", reason: str | None = "Converged") -> dict[str, Any]:
    return {"apiVersion": "fabric.agentic-netops.io/v1alpha1", "kind": "Network",
            "namespace": "agentic-netops-intent", "name": NETWORK.split("/", 1)[1],
            "ready": ready, "reason": reason}


def completed_report() -> dict[str, Any]:
    return {"operation": "create", "status": "COMPLETED", "resources": [resource_ref()],
            "progress": [progress("CONFIGURED", "Unknown", "VerificationFailed"),
                         progress("VERIFIED", "True", "Converged")]}


def removal_in_progress_report() -> dict[str, Any]:
    return {"operation": "remove", "status": "PROVISIONING",
            "resources": [resource_ref("False", "Deleting")],
            "progress": [progress("PROVISIONING", "False", "Deleting")],
            "message": "removal in progress: waiting on leaf02 (TargetUnreachable); it completes "
                       "when the target returns"}


def continue_report() -> dict[str, Any]:
    return {"operation": "create", "status": "PROVISIONING", "watch": "continue",
            "resources": [resource_ref("False", "NotConverged")],
            "progress": [progress("PROVISIONING", "False", "NotConverged")]}


class FakeWorkers:
    """Mapper, allocator and deployer registered on an in-memory gateway, scriptable."""

    def __init__(self, gateway: t.InMemoryGateway, clock: FakeClock | None = None,
                 cluster: FakeCluster | None = None) -> None:
        self.gateway = gateway
        self.clock = clock or FakeClock()
        self.cluster = cluster or FakeCluster()
        self.interpretation: dict[str, Any] = dict(INTERPRETATION)
        self.assignment: dict[str, Any] = dict(ASSIGNMENT)
        self.deployer_script: list[dict[str, Any] | str] = []
        self.deployer_default: Callable[[], dict[str, Any]] = completed_report
        self.advance: dict[str, float] = {"mapper": 0.0, "allocator": 0.0, "deployer": 0.0}
        self.requests: dict[str, list[t.StageMessage]] = {"mapper": [], "allocator": [],
                                                          "deployer": []}
        self.kill_deployer = False

    async def start(self, *names: str) -> None:
        handlers = {"mapper": self._mapper, "allocator": self._allocator,
                    "deployer": self._deployer}
        for name in names or tuple(handlers):
            card_id, skill = CARD_IDS[name]
            backend = self.gateway.connect(GATEWAY_CREDENTIALS, identity=card_id)
            await t.serve({"id": card_id, "x-agentic-netops-worker": name,
                           "skills": [{"id": skill}]}, handlers[name], backend)

    async def _mapper(self, request: t.StageMessage) -> Any:
        self.requests["mapper"].append(request)
        self.clock.advance(self.advance["mapper"])
        return t.reply_ok("Mapped your request.", self.interpretation)

    async def _allocator(self, request: t.StageMessage) -> Any:
        self.requests["allocator"].append(request)
        self.clock.advance(self.advance["allocator"])
        return t.reply_ok("Allocated.", self.assignment)

    async def _deployer(self, request: t.StageMessage) -> Any:
        self.requests["deployer"].append(request)
        self.clock.advance(self.advance["deployer"])
        assert request.idempotency_key, "a submission always carries its idempotency key"
        if (request.operation or "create") == "create":
            self.cluster.apply(request.idempotency_key, NETWORK)
        if self.kill_deployer:
            self.kill_deployer = False
            raise Killed
        step = self.deployer_script.pop(0) if self.deployer_script else self.deployer_default()
        if isinstance(step, str):
            return t.reply_failed(step)
        return t.reply_ok("deployment report", step)


@dataclass
class Env:
    root: Path
    credentials: Path
    cards: Path
    inventory: Path
    qualification: Path
    checkpoint: Path
    gateway_dir: Path

    def settings(self, **env: str) -> Settings:
        base = {
            "OPERATOR_CREDENTIALS_DIR": str(self.credentials),
            "AGENT_CARDS_DIR": str(self.cards),
            "SITE_INVENTORY_DIR": str(self.inventory),
            "FABRIC_QUALIFICATION_DIR": str(self.qualification),
            "SUPERVISOR_CHECKPOINT_PATH": str(self.checkpoint),
            "SLIM_GATEWAY_DIR": str(self.gateway_dir),
            "LLM_PROVIDER_DIR": str(self.root / "no-llm"),
        }
        base.update(env)
        return load_settings(base)

    def set_operator(self, username: str, password: str) -> None:
        (self.credentials / "username").write_text(username)
        (self.credentials / "password").write_text(password)


def basic(username: str, password: str) -> dict[str, str]:
    token = base64.b64encode(f"{username}:{password}".encode()).decode()
    return {"Authorization": f"Basic {token}"}


@pytest.fixture
def env(tmp_path: Path) -> Env:
    root = tmp_path
    credentials = root / "operator-credentials"
    cards = root / "agent-cards"
    inventory = root / "site-inventory"
    qualification = root / "fabric-qualification"
    gateway_dir = root / "slim-gateway"
    for d in (credentials, cards, inventory, qualification, gateway_dir):
        d.mkdir()
    (gateway_dir / "username").write_text(GATEWAY_CREDENTIALS[0])
    (gateway_dir / "password").write_text(GATEWAY_CREDENTIALS[1])
    for name, (card_id, skill) in CARD_IDS.items():
        (cards / f"{name}.json").write_text(json.dumps({
            "id": card_id, "x-agentic-netops-worker": name, "name": name,
            "description": name, "version": "0.1.0", "capabilities": {"streaming": False},
            "skills": [{"id": skill, "name": skill, "description": skill, "tags": []}]}))
    (inventory / "inventory.json").write_text(json.dumps(INVENTORY))
    for key in QUALIFIED:
        (qualification / key).write_text("qualified")
    for key in UNQUALIFIED:
        (qualification / key).write_text("unqualified")
    e = Env(root, credentials, cards, inventory, qualification, root / "checkpoints.sqlite",
            gateway_dir)
    e.set_operator("alice", "alice-pass-1")
    return e


@pytest.fixture
def fresh_telemetry() -> Iterator[telemetry.Telemetry]:
    telemetry.reset_for_tests()
    tel = telemetry.init_telemetry("supervisor", otlp=False)
    yield tel
    telemetry.reset_for_tests()


def span_events(tel: telemetry.Telemetry, prefix: str = "audit.") -> list[tuple[str, dict]]:
    return [(e.name, dict(e.attributes or {})) for s in tel.finished_spans() for e in s.events
            if e.name.startswith(prefix)]
