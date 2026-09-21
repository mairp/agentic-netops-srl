"""Intent-tier project sanity (T025, FR-020): the pins the tier is built on.

The first unit suite of `make test-agents`. It reads agents/pyproject.toml and
agents/uv.lock with the standard library and asserts what later tasks rely on:
the Python floor, the exact pins of the agent framework libraries, that every
exact pin is what uv.lock resolved, and that the test tooling is declared.
"""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path

AGENTS = Path(__file__).resolve().parents[2]
PROJECT = tomllib.loads((AGENTS / "pyproject.toml").read_text())
LOCK = tomllib.loads((AGENTS / "uv.lock").read_text())
LOCKED = {p["name"]: p.get("version") for p in LOCK["package"]}

EXACT = re.compile(r"^([A-Za-z0-9_.-]+)(\[[^\]]+\])?==([^;,\s]+)$")


def _exact_pins(specs: list[str]) -> dict[str, str]:
    pins = {}
    for spec in specs:
        m = EXACT.match(spec)
        if m:
            pins[m.group(1).lower().replace("_", "-")] = m.group(3)
    return pins


def test_python_floor_is_313_and_running_interpreter_satisfies_it() -> None:
    assert PROJECT["project"]["requires-python"] == ">=3.13,<4.0"
    assert sys.version_info >= (3, 13)


def test_framework_libraries_are_pinned_exactly() -> None:
    pins = _exact_pins(PROJECT["project"]["dependencies"])
    assert pins == {
        "agntcy-app-sdk": "0.4.5",
        "a2a-sdk": "0.3.0",
        "litellm": "1.75.3",
        "ioa-observe-sdk": "1.0.24",
        "agntcy-identity-service-sdk": "0.0.7",
    }


def test_every_exact_pin_is_what_uv_lock_resolved() -> None:
    specs = PROJECT["project"]["dependencies"] + PROJECT["dependency-groups"]["dev"]
    for name, version in _exact_pins(specs).items():
        assert LOCKED.get(name) == version, (name, version, LOCKED.get(name))


def test_test_tooling_is_declared_and_locked() -> None:
    dev = " ".join(PROJECT["dependency-groups"]["dev"])
    for tool in ("pytest", "pytest-asyncio", "ruff"):
        assert re.search(rf"(^|\s){re.escape(tool)}($|[\s=<>])", dev), tool
        assert tool in LOCKED, tool
    assert PROJECT["tool"]["pytest"]["ini_options"]["testpaths"] == ["tests"]
