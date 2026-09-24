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
