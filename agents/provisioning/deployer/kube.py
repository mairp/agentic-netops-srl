"""The deployer's minimal in-cluster REST client (T100; contracts/kubernetes-objects.md).

It speaks to exactly what the writer identity ``intent-deployer`` may touch —
``networks.fabric.agentic-netops.io`` and core ``v1`` Events, in ``agentic-netops-intent`` and
nowhere else — over ``httpx`` with the pod's service-account token and CA. The transport is
injectable (``httpx.MockTransport`` in the unit tests).

Errors are classed for the submission contract (step 4, AD-52, NFR-010):

* :class:`ClusterUnavailableError` — the cluster API could not answer: no connection, a 502/503/
  504, or a 500 whose message is the API server's *failed calling webhook* — the fail-closed
  admission webhook unreachable. It names the dependency; it is **never** a refusal.
* :class:`KubeAPIError` — the API server answered with a refusal (schema, CEL rule, admission
  denial, conflict, forbidden). ``message`` is the server's own.
"""

from __future__ import annotations

import json
import os
import re
from collections.abc import Mapping
from pathlib import Path
from typing import Any
from urllib.parse import quote

import httpx

GROUP = "fabric.agentic-netops.io"
VERSION = "v1alpha1"
API_VERSION = f"{GROUP}/{VERSION}"
KIND = "Network"
PLURAL = "networks"
INTENT_NAMESPACE = "agentic-netops-intent"
FIELD_MANAGER = "agentic-netops-intent-deployer"
# The provider's finalizer (controllers/network/network_controller.go:71), set at apply (AD-32).
FINALIZER = "fabric.agentic-netops.io/finalizer"
WEBHOOK_NAME = "networks.fabric.agentic-netops.io"

SA_DIR = Path("/var/run/secrets/kubernetes.io/serviceaccount")
DEFAULT_TIMEOUT_SECONDS = 20.0

_WEBHOOK_UNREACHABLE = re.compile(r"failed calling webhook", re.IGNORECASE)
_WEBHOOK_NAMED = re.compile(r'failed calling webhook\s+"([^"]+)"', re.IGNORECASE)


class KubeError(Exception):
    """A cluster API call did not succeed."""


class ClusterUnavailableError(KubeError):
    """The cluster API dependency could not answer (NFR-010) — never a refusal of the request.

    ``dependency`` names it: ``cluster API`` or ``cluster API: admission webhook <name>``."""

    def __init__(self, dependency: str, detail: str) -> None:
        super().__init__(f"{dependency} unavailable: {detail}")
        self.dependency = dependency
        self.detail = detail

    @property
    def webhook(self) -> bool:
        return "admission webhook" in self.dependency


class KubeAPIError(KubeError):
    """The API server refused the request; ``message`` is its own words."""

    def __init__(self, status: int, reason: str, message: str) -> None:
        super().__init__(f"HTTP {status} {reason}: {message}")
        self.status = status
        self.reason = reason
        self.message = message


def _body_message(response: httpx.Response) -> tuple[str, str]:
    try:
        body = response.json()
    except (ValueError, json.JSONDecodeError):
        return "", (response.text or "").strip()[:2000] or f"HTTP {response.status_code}"
    if isinstance(body, dict):
        return str(body.get("reason") or ""), str(body.get("message") or body)[:2000]
    return "", str(body)[:2000]


def classify(response: httpx.Response) -> KubeError:
    """The error a non-2xx answer is: the webhook or the API unreachable, or a refusal."""
    reason, message = _body_message(response)
    if _WEBHOOK_UNREACHABLE.search(message):
        named = _WEBHOOK_NAMED.search(message)
        webhook = named.group(1) if named else WEBHOOK_NAME
        return ClusterUnavailableError(f"cluster API: admission webhook {webhook}",
                                       f"the admission webhook could not be reached: {message}")
    if response.status_code in (502, 503, 504) or (
            response.status_code == 500 and reason in ("", "InternalError", "ServiceUnavailable")
            and "denied the request" not in message):
        return ClusterUnavailableError("cluster API", f"HTTP {response.status_code}: {message}")
    return KubeAPIError(response.status_code, reason, message)


class KubeClient:
    """Networks and Events in the intent namespace — nothing else."""

    def __init__(self, base_url: str, *, token: str | None = None,
                 verify: bool | str = True, transport: httpx.AsyncBaseTransport | None = None,
                 namespace: str = INTENT_NAMESPACE,
                 timeout: float = DEFAULT_TIMEOUT_SECONDS) -> None:
        headers = {"Accept": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        self.namespace = namespace
        self._client = httpx.AsyncClient(base_url=base_url.rstrip("/"), headers=headers,
                                         verify=verify, transport=transport, timeout=timeout)

    @classmethod
    def in_cluster(cls, env: Mapping[str, str] | None = None, *,
                   sa_dir: Path = SA_DIR) -> KubeClient:
        """The pod's own identity: the mounted token and CA, the API server from the env."""
        env = os.environ if env is None else env
        host = env.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc")
        port = env.get("KUBERNETES_SERVICE_PORT", "443")
        if ":" in host and not host.startswith("["):
            host = f"[{host}]"
        try:
            token = (sa_dir / "token").read_text(encoding="utf-8").strip()
        except OSError as exc:
            raise ClusterUnavailableError(
                "cluster API", f"no service-account token at {sa_dir}/token: {exc}") from None
        ca = sa_dir / "ca.crt"
        return cls(f"https://{host}:{port}", token=token,
                   verify=str(ca) if ca.is_file() else True)

    async def aclose(self) -> None:
        await self._client.aclose()

    # ----------------------------------------------------------------------------------------

    def _collection(self) -> str:
        return f"/apis/{GROUP}/{VERSION}/namespaces/{quote(self.namespace, safe='')}/{PLURAL}"

    def _object(self, name: str) -> str:
        return f"{self._collection()}/{quote(name, safe='')}"

    async def _send(self, method: str, url: str, **kwargs: Any) -> httpx.Response:
        try:
            response = await self._client.request(method, url, **kwargs)
        except httpx.TransportError as exc:
            raise ClusterUnavailableError(
                "cluster API", f"{method} {url}: {type(exc).__name__}: {exc}") from None
        return response

    @staticmethod
    def _json(response: httpx.Response) -> dict[str, Any]:
        if response.status_code // 100 != 2:
            raise classify(response)
        body = response.json()
        if not isinstance(body, dict):
            raise KubeAPIError(response.status_code, "", "the API server returned a non-object")
        return body

    async def get_network(self, name: str) -> dict[str, Any] | None:
        response = await self._send("GET", self._object(name))
        if response.status_code == 404:
            return None
        return self._json(response)

    async def list_networks(self, label_selector: str | None = None) -> list[dict[str, Any]]:
        params = {"labelSelector": label_selector} if label_selector else None
        response = await self._send("GET", self._collection(), params=params)
        body = self._json(response)
        return [i for i in body.get("items", []) if isinstance(i, dict)]

    async def apply_network(self, manifest: Mapping[str, Any], *,
                            dry_run: bool) -> dict[str, Any]:
        """Server-side apply (field manager ``agentic-netops-intent-deployer``); with
        ``dry_run`` the API server runs every admission step and persists nothing."""
        name = str(manifest["metadata"]["name"])
        params = {"fieldManager": FIELD_MANAGER}
        if dry_run:
            params["dryRun"] = "All"
        response = await self._send(
            "PATCH", self._object(name), params=params,
            headers={"Content-Type": "application/apply-patch+yaml"},
            content=json.dumps(manifest, separators=(",", ":")).encode())
        return self._json(response)

    async def delete_network(self, name: str) -> bool:
        """Delete (background propagation). ``False`` when it was already gone."""
        response = await self._send(
            "DELETE", self._object(name),
            headers={"Content-Type": "application/json"},
            content=json.dumps({"kind": "DeleteOptions", "apiVersion": "v1",
                                "propagationPolicy": "Background"}).encode())
        if response.status_code == 404:
            return False
        self._json(response)
        return True

    async def create_event(self, event: Mapping[str, Any]) -> dict[str, Any]:
        url = f"/api/v1/namespaces/{quote(self.namespace, safe='')}/events"
        response = await self._send("POST", url, json=dict(event))
        return self._json(response)


__all__ = [
    "API_VERSION",
    "FIELD_MANAGER",
    "FINALIZER",
    "GROUP",
    "INTENT_NAMESPACE",
    "KIND",
    "PLURAL",
    "ClusterUnavailableError",
    "KubeAPIError",
    "KubeClient",
    "KubeError",
    "classify",
]
