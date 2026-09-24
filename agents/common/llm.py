"""The model client (T080; FR-106, NFR-008, NFR-010, FR-079, AD-49, AD-67).

The interface is fixed by ``tests/unit/test_llm_endpoint.py`` (T168):

* :func:`load_endpoint` reads the read-only mounted ``llm-provider`` Secret — one file per key:
  ``LLM_MODEL``, ``API_KEY``, ``BASE_URL`` and, for a shared gateway, ``GATEWAY``. A declared
  gateway without a base URL is an :class:`EndpointError` naming the gateway.
* :class:`LLMClient` — construction is agent start-up: it loads the endpoint (so a gateway without
  a base URL refuses to start) and logs one line naming the effective endpoint, the base URL
  redacted, or the provider's own default stated as such.
* :meth:`LLMClient.complete` re-reads the Secret on **every** call, never a value cached at
  start-up. An agent whose Secret loses its base URL while it runs makes no further model call and
  raises :class:`EndpointError` naming the missing ``BASE_URL`` as its own dependency; an absent
  endpoint is never passed through to the library's default.

The provider is chosen by the model-name prefix (``openai/gpt-4o`` → ``openai``), which is also
how LiteLLM routes. The default transport is LiteLLM with ``api_base`` passed explicitly.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from common.exceptions import EndpointError
from common.guards.redaction import redact

log = logging.getLogger("agentic_netops.llm")

KEYS = ("LLM_MODEL", "API_KEY", "BASE_URL", "GATEWAY")

# Model-name prefixes of providers LiteLLM knows without a prefix.
_BARE_PREFIXES = (("gpt-", "openai"), ("o1", "openai"), ("o3", "openai"), ("o4", "openai"),
                  ("claude", "anthropic"), ("gemini", "gemini"), ("mistral", "mistral"),
                  ("command", "cohere"), ("llama", "ollama"))


@dataclass(frozen=True)
class Endpoint:
    model: str
    api_key: str
    base_url: str | None
    gateway: str | None
    provider: str

    def describe(self) -> str:
        """The effective endpoint, for the start-up line: redacted of any credential."""
        where = (f"base URL {redact(self.base_url)}" if self.base_url
                 else f"the {self.provider} provider's own default endpoint (no BASE_URL set)")
        via = f" through gateway {self.gateway}" if self.gateway else ""
        return f"model endpoint: {where}{via}; provider {self.provider}, model {self.model}"


def provider_for(model: str) -> str:
    """The provider a model name selects: its ``provider/`` prefix, or a known bare prefix."""
    if "/" in model:
        return model.split("/", 1)[0]
    lowered = model.lower()
    for prefix, provider in _BARE_PREFIXES:
        if lowered.startswith(prefix):
            return provider
    return "openai"


def _read(secret_dir: Path, key: str) -> str | None:
    path = secret_dir / key
    try:
        value = path.read_text(encoding="utf-8").strip()
    except (FileNotFoundError, NotADirectoryError):
        return None
    return value or None


def load_endpoint(secret_dir: Path) -> Endpoint:
    """Read the mounted ``llm-provider`` Secret. Raises :class:`EndpointError`."""
    secret_dir = Path(secret_dir)
    model = _read(secret_dir, "LLM_MODEL")
    gateway = _read(secret_dir, "GATEWAY")
    base_url = _read(secret_dir, "BASE_URL")
    if gateway and not base_url:
        raise EndpointError(
            f"the llm-provider Secret declares gateway {gateway!r} but carries no BASE_URL: "
            "refusing to call a model rather than fall back to the provider's default"
        )
    if not model:
        raise EndpointError("the llm-provider Secret carries no LLM_MODEL")
    return Endpoint(model=model, api_key=_read(secret_dir, "API_KEY") or "", base_url=base_url,
                    gateway=gateway, provider=provider_for(model))


def litellm_transport(*, base_url: str | None, model: str, api_key: str,
                      messages: list[dict[str, Any]]) -> Any:
    """The default transport: LiteLLM, the base URL passed explicitly as ``api_base``."""
    import litellm  # heavy; imported on the first real model call only

    kwargs: dict[str, Any] = {"model": model, "api_key": api_key or None, "messages": messages}
    if base_url:
        kwargs["api_base"] = base_url
    return litellm.completion(**kwargs)


class LLMClient:
    def __init__(self, secret_dir: Path, *,
                 transport: Callable[..., Any] | None = None) -> None:
        self.secret_dir = Path(secret_dir)
        self._transport = transport or litellm_transport
        endpoint = load_endpoint(self.secret_dir)
        # What start-up saw decides whether a later absence is a loss (AD-49).
        self._started_with_base_url = endpoint.base_url is not None
        self._started_with_gateway = endpoint.gateway is not None
        self.calls = 0
        log.info(endpoint.describe())

    def endpoint(self) -> Endpoint:
        """The endpoint as the mounted Secret states it *now*."""
        try:
            endpoint = load_endpoint(self.secret_dir)
        except EndpointError as exc:
            raise EndpointError(f"{exc} (missing BASE_URL)") from None
        if endpoint.base_url is None and (self._started_with_base_url or
                                          self._started_with_gateway):
            raise EndpointError(
                "the llm-provider Secret no longer carries BASE_URL: this agent makes no model "
                "call and fails the request naming its missing dependency, BASE_URL of the "
                "llm-provider Secret"
            )
        return endpoint

    def complete(self, messages: list[dict[str, Any]]) -> Any:
        endpoint = self.endpoint()  # re-read on every call — never cached (FR-106)
        self.calls += 1
        # one line per model call: the e2e suites (T089) count these (a refused request makes none)
        log.info("model call %d: %s", self.calls, endpoint.describe())
        return self._transport(base_url=endpoint.base_url, model=endpoint.model,
                               api_key=endpoint.api_key, messages=messages)


__all__ = ["Endpoint", "EndpointError", "LLMClient", "litellm_transport", "load_endpoint",
           "provider_for"]
