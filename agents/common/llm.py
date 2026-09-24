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

Every call is a ``model.call`` span in the request's trace (T135, NFR-009): provider, model, the
prompt and the response — redacted — and the token usage (and cost, when LiteLLM reports one),
beside the ``agentic_netops_agent_model_*`` series.

The provider is chosen by the model-name prefix (``openai/gpt-4o`` → ``openai``), which is also
how LiteLLM routes. The default transport is LiteLLM with ``api_base`` passed explicitly.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from common import metrics, tracing
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
        try:
            endpoint = self.endpoint()  # re-read on every call — never cached (FR-106)
        except EndpointError as exc:
            # No model call is made; the refusal is still on the trace, naming the dependency.
            with tracing.model_call_span(provider=None, model=None, messages=messages) as span:
                tracing.set_attributes(span, {tracing.ATTR_OUTCOME: "failed"})
                tracing.mark_failure(span, None, str(exc))
            raise
        self.calls += 1
        # one line per model call: the e2e suites (T089) count these (a refused request makes none)
        log.info("model call %d: %s", self.calls, endpoint.describe())
        with tracing.model_call_span(provider=endpoint.provider, model=endpoint.model,
                                     messages=messages) as span:
            try:
                response = self._transport(base_url=endpoint.base_url, model=endpoint.model,
                                           api_key=endpoint.api_key, messages=messages)
            except Exception as exc:
                tracing.set_attributes(span, {tracing.ATTR_OUTCOME: "failed"})
                tracing.mark_failure(span, None, f"{type(exc).__name__}: {exc}")
                metrics.record_model_call(endpoint.model, "failed")
                raise
            usage = response_usage(response)
            tracing.record_model_response(span, completion=response_text(response),
                                          model=usage.get("model"),
                                          input_tokens=usage.get("input_tokens"),
                                          output_tokens=usage.get("output_tokens"),
                                          cost=usage.get("cost"))
            metrics.record_model_call(endpoint.model, "succeeded",
                                      input_tokens=usage.get("input_tokens"),
                                      output_tokens=usage.get("output_tokens"),
                                      cost=usage.get("cost"))
        return response


def _get(obj: Any, key: str) -> Any:
    if isinstance(obj, dict):
        return obj.get(key)
    return getattr(obj, key, None)


def response_text(response: Any) -> str:
    """The assistant text of a response (a LiteLLM ``ModelResponse``, its dict form or a string);
    the whole response rendered when it has no such text."""
    if isinstance(response, str):
        return response
    try:
        return str(_get(_get(_get(response, "choices")[0], "message"), "content") or "")
    except (TypeError, KeyError, IndexError, AttributeError):
        return str(response)


def response_usage(response: Any) -> dict[str, Any]:
    """``{input_tokens, output_tokens, cost, model}`` as the response reports them (None when
    not reported). The cost is LiteLLM's ``response_cost`` hidden parameter."""
    usage = _get(response, "usage") if not isinstance(response, str) else None
    out: dict[str, Any] = {"input_tokens": None, "output_tokens": None, "cost": None,
                           "model": None}
    if usage is not None:
        for key, names in (("input_tokens", ("prompt_tokens", "input_tokens")),
                           ("output_tokens", ("completion_tokens", "output_tokens"))):
            for name in names:
                value = _get(usage, name)
                if isinstance(value, int) and not isinstance(value, bool):
                    out[key] = value
                    break
    hidden = getattr(response, "_hidden_params", None)
    cost = hidden.get("response_cost") if isinstance(hidden, dict) else None
    if cost is None and isinstance(response, dict):
        cost = response.get("response_cost")
    if isinstance(cost, int | float) and not isinstance(cost, bool):
        out["cost"] = float(cost)
    model = _get(response, "model") if not isinstance(response, str) else None
    out["model"] = model if isinstance(model, str) else None
    return out


__all__ = ["Endpoint", "EndpointError", "LLMClient", "litellm_transport", "load_endpoint",
           "provider_for", "response_text", "response_usage"]
