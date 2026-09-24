"""Exactly one OTLP exporter per process (T080; R-24, AD-18).

Tier agents emit **once**, to the tier collector at ``OTEL_EXPORTER_OTLP_ENDPOINT`` (OTLP over
HTTP), which fans out to the analytics store. This module owns the one :class:`Telemetry` bundle of
a process — a module-level singleton: its tracer provider (the request span and its audit span
events, :mod:`common.tracing`) and its meter provider (the tier series, :mod:`common.metrics`) both
export through the single OTLP HTTP exporter pipeline created here, and a second
:func:`init_telemetry` returns the first bundle instead of creating another.

The global OpenTelemetry providers are deliberately not replaced: the pinned SDK stack installs
instrumentations of its own, and a second global exporter is exactly what R-24 forbids. Tier code
obtains its tracer and meter from :func:`get_telemetry`.

Beside the exporter, the meter provider carries an in-process :class:`InMemoryMetricReader` — a
reader, not an exporter — so :func:`common.metrics.value` can read a counter back in tests and in
the process itself. ``init_telemetry(otlp=False)`` (the unit tests) swaps the OTLP pipeline for an
in-memory span exporter and exports nothing.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass
from typing import Any

from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import InMemoryMetricReader, PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

SERVICE_NAMESPACE = "agentic-netops-agents"

_lock = threading.Lock()
_telemetry: Telemetry | None = None
# How many OTLP exporter pipelines this process has ever created. R-24: at most one.
exporters_created = 0


@dataclass
class Telemetry:
    component: str
    endpoint: str | None
    tracer_provider: TracerProvider
    meter_provider: MeterProvider
    metric_reader: InMemoryMetricReader
    span_exporter: Any  # the one span exporter: OTLP HTTP, or in-memory under otlp=False
    otlp: bool

    def tracer(self, name: str = "agentic-netops") -> Any:
        return self.tracer_provider.get_tracer(name)

    def meter(self, name: str = "agentic-netops") -> Any:
        return self.meter_provider.get_meter(name)

    def finished_spans(self) -> list[Any]:
        """Spans already ended — only under ``otlp=False`` (the in-memory exporter)."""
        if isinstance(self.span_exporter, InMemorySpanExporter):
            return list(self.span_exporter.get_finished_spans())
        return []

    def shutdown(self) -> None:
        self.tracer_provider.shutdown()
        self.meter_provider.shutdown()


def init_telemetry(component: str | None = None, *, endpoint: str | None = None,
                   otlp: bool = True) -> Telemetry:
    """Create the process's telemetry once; every later call returns the same bundle."""
    global _telemetry, exporters_created
    with _lock:
        if _telemetry is not None:
            return _telemetry
        if component is None or (otlp and endpoint is None):
            from config.settings import load_settings

            settings = load_settings()
            component = component or settings.component
            endpoint = endpoint or settings.otlp_endpoint
        resource = Resource.create(
            {"service.name": component, "service.namespace": SERVICE_NAMESPACE}
        )
        tracer_provider = TracerProvider(resource=resource)
        reader = InMemoryMetricReader()
        readers: list[Any] = [reader]
        if otlp:
            from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
            from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

            base = (endpoint or "").rstrip("/")
            span_exporter: Any = OTLPSpanExporter(endpoint=f"{base}/v1/traces")
            tracer_provider.add_span_processor(BatchSpanProcessor(span_exporter))
            readers.append(
                PeriodicExportingMetricReader(OTLPMetricExporter(endpoint=f"{base}/v1/metrics"))
            )
            exporters_created += 1
        else:
            span_exporter = InMemorySpanExporter()
            tracer_provider.add_span_processor(SimpleSpanProcessor(span_exporter))
        meter_provider = MeterProvider(resource=resource, metric_readers=readers)
        _telemetry = Telemetry(component, endpoint if otlp else None, tracer_provider,
                               meter_provider, reader, span_exporter, otlp)
        return _telemetry


def get_telemetry() -> Telemetry:
    """The process's telemetry; created on first use (in-memory when none was initialised)."""
    if _telemetry is not None:
        return _telemetry
    return init_telemetry("agent", otlp=False)


def reset_for_tests() -> None:
    """Drop the singleton so a test starts from zero. Never called by the tier itself."""
    global _telemetry, exporters_created
    with _lock:
        if _telemetry is not None:
            try:
                _telemetry.shutdown()
            except Exception:  # noqa: S110 — a test reset must not fail on a closed exporter
                pass
        _telemetry = None
        exporters_created = 0


__all__ = ["Telemetry", "get_telemetry", "init_telemetry", "reset_for_tests"]
