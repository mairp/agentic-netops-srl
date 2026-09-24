"""The root request span and the span-event helper (T080; data-model.md §7, §16, AD-57)."""

from __future__ import annotations

import re
from typing import Any

import pytest

from common import telemetry, tracing

pytestmark = pytest.mark.usefixtures("fresh_telemetry")


def test_the_trace_id_is_the_correlation_id(fresh_telemetry: Any) -> None:
    with tracing.request_span("supervisor.request") as span:
        assert re.fullmatch(r"[0-9a-f]{32}", span.correlation_id)
        assert tracing.current_correlation_id() == span.correlation_id
    (finished,) = fresh_telemetry.finished_spans()
    assert tracing.format_trace_id(finished.context.trace_id) == span.correlation_id
    assert finished.attributes["correlation_id"] == span.correlation_id


def test_a_continued_thread_keeps_its_correlation_id(fresh_telemetry: Any) -> None:
    with tracing.request_span() as first:
        pass
    with tracing.request_span(correlation_id=first.correlation_id, attach=False) as second:
        pass
    assert second.correlation_id == first.correlation_id
    spans = fresh_telemetry.finished_spans()
    assert len({s.context.trace_id for s in spans}) == 1
    assert len({s.context.span_id for s in spans}) == 2


@pytest.mark.parametrize("bad", ["ABC", "0" * 32, "g" * 32, "4BF92F3577B34DA6A3CE929D0E0E4736"])
def test_a_malformed_correlation_id_is_refused(bad: str) -> None:
    with pytest.raises(ValueError, match="correlation"), tracing.request_span(correlation_id=bad):
        pass


def test_span_events_are_redacted_and_land_on_the_request_span(fresh_telemetry: Any) -> None:
    with tracing.request_span() as span:
        tracing.emit_span_event("audit.confirm", {"audit.principal": "alice",
                                                  "note": "token=supersecretvalue",
                                                  "resources": ["Network/migr-x"],
                                                  "none": None})
        span.event("audit.decline", {"audit.principal": "bob"})
    (finished,) = fresh_telemetry.finished_spans()
    events = {e.name: dict(e.attributes) for e in finished.events}
    assert events["audit.confirm"]["audit.principal"] == "alice"
    assert "supersecretvalue" not in events["audit.confirm"]["note"]
    assert "none" not in events["audit.confirm"]
    assert events["audit.decline"]["audit.principal"] == "bob"


def test_spans_ride_the_one_telemetry_bundle() -> None:
    first = telemetry.get_telemetry()
    assert telemetry.init_telemetry("mapper", otlp=False) is first
