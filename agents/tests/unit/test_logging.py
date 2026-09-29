"""The log record (T080; data-model.md §27, NFR-014, FR-079)."""

from __future__ import annotations

import io
import json
import logging
import re
from collections.abc import Iterator

import pytest

from common import logging as tier_logging

RFC3339_UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")


@pytest.fixture
def stream() -> Iterator[io.StringIO]:
    buffer = io.StringIO()
    handler = tier_logging.configure("supervisor", stream=buffer, level=logging.DEBUG)
    yield buffer
    logging.getLogger().removeHandler(handler)


def _lines(buffer: io.StringIO) -> list[dict[str, object]]:
    return [json.loads(line) for line in buffer.getvalue().splitlines()]


def test_one_json_object_per_line_with_the_required_fields(stream: io.StringIO) -> None:
    log = tier_logging.get_logger("supervisor")
    log.info("request received")
    log.warning("worker unreachable: mapper", correlation_id="a" * 32, thread_id="t-1")
    log.error("submission failed", kind="Network", namespace="agentic-netops-intent",
              name="migr-svc1")
    log.debug("detail")
    lines = _lines(stream)
    assert [line["level"] for line in lines] == ["info", "warn", "error", "debug"]
    for line in lines:
        assert RFC3339_UTC.match(str(line["ts"])), line["ts"]
        assert line["component"] == "supervisor"
        assert isinstance(line["msg"], str)
    assert lines[1]["correlation_id"] == "a" * 32 and lines[1]["thread_id"] == "t-1"
    assert (lines[2]["kind"], lines[2]["namespace"], lines[2]["name"]) == (
        "Network", "agentic-netops-intent", "migr-svc1")
    assert "kind" not in lines[0] and "correlation_id" not in lines[0]


def test_every_value_is_redacted(stream: io.StringIO) -> None:
    log = tier_logging.get_logger("mapper")
    log.info("calling https://user:s3cret@gateway.example/v1?api_key=abcdef123",
             name="Authorization: Bearer abcdefghijklmnop")
    logging.getLogger("third.party").warning("token=supersecretvalue in a library line")
    text = stream.getvalue()
    assert "s3cret" not in text and "abcdef123" not in text
    assert "abcdefghijklmnop" not in text and "supersecretvalue" not in text
    assert "gateway.example" in text  # the host stays named
    for line in _lines(stream):
        assert line["component"] in ("mapper", "supervisor")


def test_standard_library_levels_map_to_the_four(stream: io.StringIO) -> None:
    assert tier_logging.level_name(logging.CRITICAL) == "error"
    assert tier_logging.level_name(logging.WARNING) == "warn"
    assert tier_logging.level_name(5) == "debug"


def test_a_library_line_inside_a_request_carries_its_correlation_id() -> None:
    """§27/NFR-014 (T147 live): an HTTP client's own line written while a request's span is
    current, or after the supervisor bound the request's correlation id, carries it."""
    import io
    import logging as std

    from common import logging as tl
    from common import tracing

    out = io.StringIO()
    tl.configure("deployer", stream=out)
    # importing LiteLLM (another test module) lowers httpx's own level to WARNING; this test is
    # about the correlation id on a library line, so it states the level it writes at
    httpx_logger = std.getLogger("httpx")
    saved = httpx_logger.level
    httpx_logger.setLevel(std.INFO)
    with tracing.request_span() as rs:
        std.getLogger("httpx").info('HTTP Request: GET https://k/api "HTTP/1.1 200 OK"')
    tl.bind_correlation_id("ab" * 16)
    std.getLogger("httpx").info('HTTP Request: POST https://k/api "HTTP/1.1 201"')
    tl.bind_correlation_id(None)
    httpx_logger.setLevel(saved)
    first, second = (json.loads(line) for line in out.getvalue().splitlines())
    assert first["correlation_id"] == rs.correlation_id
    assert second["correlation_id"] == "ab" * 16


def test_foreign_library_handlers_are_removed_so_every_line_is_json() -> None:
    import io
    import logging as std

    from common import logging as tl

    noisy = std.getLogger("LiteLLM")
    noisy.addHandler(std.StreamHandler(io.StringIO()))
    tl.configure("mapper", stream=io.StringIO())
    assert noisy.handlers == [] and noisy.propagate and noisy.level == std.WARNING


def test_uvicorn_access_line_stays_muted_after_foreign_loggers_are_adopted() -> None:
    """The access line has no correlation id; adopting foreign loggers (every model call does)
    must never turn it back on (T147 r5 log-shape finding)."""
    import logging as std_logging

    from common import logging as tier_logging

    access = std_logging.getLogger("uvicorn.access")
    access.setLevel(std_logging.NOTSET)
    access.propagate = False  # what uvicorn.run(access_log=False) leaves
    tier_logging.adopt_foreign_loggers()
    assert access.propagate is True
    assert not access.isEnabledFor(std_logging.INFO)
    assert access.isEnabledFor(std_logging.WARNING)
