"""HTTP Basic against the mounted ``operator-credentials`` Secret (T085; FR-102, CD-01, SC-042,
contracts/supervisor-http.md "Authentication").

* The Secret's ``username`` and ``password`` files are read from the read-only volume on **every**
  request, so a rotated Secret takes effect without a restart.
* Both the username and the password are compared with :func:`hmac.compare_digest` — both, always,
  so a wrong username costs what a wrong password costs.
* A failed attempt costs a fixed delay (``OPERATOR_AUTH_FAILURE_DELAY_SECONDS``, default 1 s) and
  is answered ``401`` with ``WWW-Authenticate: Basic realm="agentic-netops"`` and the fixed body —
  decided before any thread identifier exists, so it creates no thread, calls no model, claims
  nothing and emits no audit event; it writes one structured log line and increments
  ``agentic_netops_agent_auth_refusals_total``.
* The authenticated username is the **only** principal, and it is the one of the request that
  carries each decision.

These are lab credentials over loopback HTTP and are not production-safe (FR-019).
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import hmac
import logging
from collections.abc import Awaitable, Callable
from pathlib import Path

from fastapi import Request
from fastapi.responses import JSONResponse

from common import metrics

log = logging.getLogger("agentic_netops.supervisor.auth")

REALM = 'Basic realm="agentic-netops"'
REFUSAL = {"type": "error", "status": "FAILED", "reason": "authentication required"}


def refusal_response() -> JSONResponse:
    return JSONResponse(REFUSAL, status_code=401, headers={"WWW-Authenticate": REALM})


def parse_basic(header: str | None) -> tuple[str, str] | None:
    if not header:
        return None
    scheme, _, token = header.strip().partition(" ")
    if scheme.lower() != "basic" or not token:
        return None
    try:
        decoded = base64.b64decode(token.strip(), validate=True).decode("utf-8")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None
    username, sep, password = decoded.partition(":")
    if not sep:
        return None
    return username, password


class OperatorAuthenticator:
    def __init__(self, credentials_dir: Path, *, delay_seconds: float,
                 sleep: Callable[[float], Awaitable[None]] = asyncio.sleep) -> None:
        self.credentials_dir = Path(credentials_dir)
        self.delay_seconds = delay_seconds
        self.sleep = sleep

    def _stored(self) -> tuple[str, str] | None:
        """The Secret as mounted now — re-read on every request (rotation without restart)."""
        try:
            username = (self.credentials_dir / "username").read_text(encoding="utf-8").strip()
            password = (self.credentials_dir / "password").read_text(encoding="utf-8").strip()
        except OSError:
            return None
        if not username or not password:
            return None
        return username, password

    def verify(self, header: str | None) -> str | None:
        """The authenticated username, or None. Both parts compared in constant time."""
        given = parse_basic(header)
        stored = self._stored()
        given_user, given_pass = given or ("", "")
        stored_user, stored_pass = stored or ("\x00", "\x00")
        user_ok = hmac.compare_digest(given_user.encode(), stored_user.encode())
        pass_ok = hmac.compare_digest(given_pass.encode(), stored_pass.encode())
        if given is None or stored is None or not (user_ok & pass_ok):
            return None
        return given_user

    async def authenticate(self, request: Request) -> str | JSONResponse:
        """The principal of this request, or the 401 to answer it with."""
        username = self.verify(request.headers.get("authorization"))
        if username is not None:
            return username
        metrics.record_auth_refusal()
        log.warning("authentication refused: %s %s (no or wrong operator credential)",
                    request.method, request.url.path)
        await self.sleep(self.delay_seconds)
        return refusal_response()


__all__ = ["REALM", "REFUSAL", "OperatorAuthenticator", "parse_basic", "refusal_response"]
