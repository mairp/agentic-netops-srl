"""One JSON object per line to standard output (T080; data-model.md §27, NFR-014, FR-079).

Fields: ``ts`` (UTC, RFC 3339), ``level`` (``debug``/``info``/``warn``/``error``), ``component``,
``msg``, and when there is one ``kind``/``namespace``/``name``, ``correlation_id`` and
``thread_id``. Every value passes :func:`common.guards.redaction.redact` before it is written.

Import it as ``from common import logging as tier_logging``; inside this module ``logging`` is the
standard library (absolute imports).
"""

from __future__ import annotations

import json
import logging
import sys
from contextvars import ContextVar
from datetime import UTC, datetime
from typing import Any, TextIO

from common.guards.redaction import RedactingFilter, redact

LEVELS = {
    logging.DEBUG: "debug",
    logging.INFO: "info",
    logging.WARNING: "warn",
    logging.ERROR: "error",
    logging.CRITICAL: "error",
}
OPTIONAL_FIELDS = ("kind", "namespace", "name", "correlation_id", "thread_id")
_HANDLER_MARK = "_agentic_netops_json"


def level_name(levelno: int) -> str:
    if levelno >= logging.ERROR:
        return "error"
    if levelno >= logging.WARNING:
        return "warn"
    if levelno >= logging.INFO:
        return "info"
    return "debug"


def _clean(value: Any) -> Any:
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, dict):
        return {str(k): _clean(v) for k, v in value.items()}
    if isinstance(value, list | tuple):
        return [_clean(v) for v in value]
    if value is None or isinstance(value, bool | int | float):
        return value
    return redact(str(value))


_BOUND_CORRELATION_ID: ContextVar[str | None] = ContextVar("agentic_netops_log_correlation_id",
                                                            default=None)


def bind_correlation_id(correlation_id: str | None) -> None:
    """Name the correlation id of the request the current task serves: every line written from
    this context on — and from the tasks it starts — carries it, where no span is attached (the
    supervisor holds its request span unattached across the yields of its stream)."""
    _BOUND_CORRELATION_ID.set(correlation_id)


def _current_correlation_id() -> str | None:
    bound = _BOUND_CORRELATION_ID.get()
    if bound:
        return bound
    try:
        from opentelemetry import trace
    except ImportError:  # pragma: no cover - the tier always carries the SDK
        return None
    ctx = trace.get_current_span().get_span_context()
    return format(ctx.trace_id, "032x") if ctx.is_valid else None


# Libraries that write their own lines past the root handler: their handlers are removed and their
# records propagate to the one JSON handler, so no line of theirs leaves a workload unshaped (§27).
FOREIGN_LOGGERS = ("LiteLLM", "LiteLLM Router", "LiteLLM Proxy", "httpx", "httpcore",
                   "uvicorn", "uvicorn.error", "uvicorn.access")


def adopt_foreign_loggers() -> None:
    for name in FOREIGN_LOGGERS:
        logger = logging.getLogger(name)
        for handler in list(logger.handlers):
            logger.removeHandler(handler)
        logger.propagate = True
        logger.disabled = False  # a dictConfig elsewhere (disable_existing_loggers) never mutes it
    for name in ("LiteLLM", "LiteLLM Router", "LiteLLM Proxy", "httpcore"):
        logging.getLogger(name).setLevel(logging.WARNING)
    # uvicorn's access line is written outside the request, where its correlation id is not known,
    # and uvicorn decides per connection whether to write it from hasHandlers() — which the
    # propagate=True above turns back on after uvicorn.run(access_log=False) muted it (observed
    # T147 r5: supervisor access lines without correlation_id). Muted by level instead, which
    # nothing here resets; the request's own first line ("request accepted: ...") carries the id.
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)


class JsonFormatter(logging.Formatter):
    """Renders a record as the §27 log object."""

    def __init__(self, component: str) -> None:
        super().__init__()
        self.component = component

    def format(self, record: logging.LogRecord) -> str:
        ts = datetime.fromtimestamp(record.created, tz=UTC)
        obj: dict[str, Any] = {
            "ts": ts.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "level": level_name(record.levelno),
            "component": getattr(record, "component", None) or self.component,
            "msg": record.getMessage(),
        }
        for name in OPTIONAL_FIELDS:
            # ``name`` is the LogRecord's own logger name: the resource name travels as obj_name.
            value = getattr(record, "obj_name" if name == "name" else name, None)
            if value not in (None, ""):
                obj[name] = value
        if "correlation_id" not in obj:
            # Every line of a request carries its correlation id (§27, NFR-014) — a library's own
            # line (an HTTP client's, the model client's) included: the correlation id is the
            # request's trace id, so the span current where the line is written names it.
            cid = _current_correlation_id()
            if cid:
                obj["correlation_id"] = cid
        if record.exc_info:
            obj["error"] = self.formatException(record.exc_info)
        return json.dumps(_clean(obj), ensure_ascii=False, separators=(",", ":"))


def configure(component: str, *, stream: TextIO | None = None,
              level: int = logging.INFO) -> logging.Handler:
    """Install the one JSON handler on the root logger (idempotent); return it."""
    root = logging.getLogger()
    for handler in list(root.handlers):
        if getattr(handler, _HANDLER_MARK, False):
            root.removeHandler(handler)
    handler = logging.StreamHandler(stream or sys.stdout)
    setattr(handler, _HANDLER_MARK, True)
    handler.setFormatter(JsonFormatter(component))
    handler.addFilter(RedactingFilter())
    root.addHandler(handler)
    root.setLevel(level)
    adopt_foreign_loggers()
    return handler


class TierLogger(logging.LoggerAdapter):
    """A logger whose calls take the §27 optional fields as keyword arguments."""

    def process(self, msg: Any, kwargs: Any) -> tuple[Any, Any]:
        extra = dict(self.extra or {})
        for name in (*OPTIONAL_FIELDS, "component"):
            if name in kwargs:
                extra["obj_name" if name == "name" else name] = kwargs.pop(name)
        kwargs["extra"] = {**extra, **kwargs.get("extra", {})}
        return msg, kwargs


def get_logger(component: str, name: str | None = None) -> TierLogger:
    return TierLogger(logging.getLogger(name or f"agentic_netops.{component}"),
                      {"component": component})


__all__ = ["JsonFormatter", "TierLogger", "adopt_foreign_loggers", "bind_correlation_id",
           "configure", "get_logger", "level_name"]
