"""Credential and secret redaction — the tier's FR-079 pattern set (T074; FR-079, FR-106, SC-048).

Redaction happens where text is produced: prompts, log records, trace attributes and chat
transcripts all pass through this module before they leave the process, so nothing downstream —
the audit export of FR-078 included — depends on a second pass.

The provisioning scripts carry their own implementation (``scripts/lib/intent_secrets.sh`` and the
in-cluster generator Job, T072), written in shell because this library does not exist where they
run. The two must stay equal (AD-67); what keeps them equal is one shared fixture and one shared
rule set:

* URL userinfo ``scheme://user:pass@host`` becomes ``scheme://***@host`` — the host stays named;
* a query parameter named ``key``, ``api_key``, ``apikey``, ``token``, ``access_token``,
  ``secret``, ``password``, ``sig`` or ``signature`` keeps its name and loses its value:
  ``name=***``;
* the marker is always ``***``.

On top of that shared set the tier also redacts ``Authorization`` headers (any scheme), bare
bearer tokens, ``name=value`` / ``name: value`` pairs whose name is a credential, well-known key
formats (``sk-…``, AWS access keys, GitHub and Slack tokens, JWTs) and PEM private-key blocks.
Redaction is idempotent, and :func:`find_credentials` is the scan the negative controls run: it
reports exactly the spans :func:`redact` would change.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Iterable, Mapping
from typing import Any

MARKER = "***"

# The query-parameter names shared with scripts/lib/intent_secrets.sh (AD-67).
QUERY_PARAMS = ("key", "api_key", "apikey", "token", "access_token", "secret", "password", "sig",
                "signature")

_CRED_NAME = (
    r"(?:api[_-]?key|apikey|access[_-]?key|secret[_-]?access[_-]?key|access[_-]?token"
    r"|refresh[_-]?token|auth[_-]?token|id[_-]?token|token|client[_-]?secret|secret"
    r"|password|passwd|pwd|passphrase|private[_-]?key|signature)"
)

# (name, compiled pattern, replacement). Order matters: whole blocks and headers first.
_PATTERNS: tuple[tuple[str, re.Pattern[str], str], ...] = (
    (
        "pem-private-key",
        re.compile(
            r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"
            r".*?-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----",
            re.DOTALL,
        ),
        MARKER,
    ),
    (
        "authorization-header",
        re.compile(
            r"(?i)(\b(?:proxy-)?authorization[\"']?\s*[:=]\s*[\"']?"
            r"(?:(?:bearer|basic|digest|token|negotiate|apikey|aws4-hmac-sha256)\s+)?)"
            r"[^\s\"',;]+"
        ),
        r"\1" + MARKER,
    ),
    (
        "bearer-token",
        re.compile(r"(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}"),
        r"\1" + MARKER,
    ),
    (
        "url-userinfo",
        re.compile(r"(?i)(\b[a-z][a-z0-9+.-]*://)[^/\s@?#\"']+@"),
        r"\1" + MARKER + "@",
    ),
    (
        "query-parameter",
        re.compile(r"(?i)([?&;](?:" + "|".join(QUERY_PARAMS) + r")=)[^&#\s\"'<>]*"),
        r"\1" + MARKER,
    ),
    (
        "credential-pair",
        re.compile(
            r"(?i)(\b[\w-]*?" + _CRED_NAME + r"\b[\"']?\s*[=:]\s*[\"']?)[^\s\"'&,;<>]+"
        ),
        r"\1" + MARKER,
    ),
    ("openai-style-key", re.compile(r"\bsk-[A-Za-z0-9_-]{16,}"), MARKER),
    ("aws-access-key-id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), MARKER),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"), MARKER),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"), MARKER),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), MARKER),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]+"), MARKER),
)

# Mapping keys whose whole value is a credential, whatever it looks like.
_SENSITIVE_KEY = re.compile(
    r"(?i)(?:^|[._-])(?:authorization|proxy-authorization|cookie|set-cookie|credentials?"
    r"|x-api-key|" + _CRED_NAME + r")$"
)


def redact(text: str) -> str:
    """Return ``text`` with every credential and secret replaced by ``***``."""
    for _name, pattern, replacement in _PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def find_credentials(text: str) -> list[tuple[str, str]]:
    """Scan ``text``; return ``(pattern name, matched text)`` for every unredacted credential.

    Empty on redacted text, non-empty on the same text before redaction — the negative control.
    """
    found: list[tuple[str, str]] = []
    for name, pattern, replacement in _PATTERNS:
        for match in pattern.finditer(text):
            if match.expand(replacement) != match.group(0):
                found.append((name, match.group(0)))
        text = pattern.sub(replacement, text)
    return found


def _redact_value(value: Any) -> Any:
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, bytes):
        return redact(value.decode("utf-8", "replace"))
    if isinstance(value, Mapping):
        return redact_mapping(value)
    if isinstance(value, list | tuple):
        return type(value)(_redact_value(v) for v in value)
    return value


def redact_mapping(mapping: Mapping[str, Any]) -> dict[str, Any]:
    """Redact a trace-attribute or log-record mapping, recursively, without mutating it.

    A key that names a credential has its whole value replaced; every other string is passed
    through :func:`redact`.
    """
    out: dict[str, Any] = {}
    for key, value in mapping.items():
        if isinstance(key, str) and _SENSITIVE_KEY.search(key) and value not in (None, ""):
            if isinstance(value, str) and redact(value) != value:
                out[key] = redact(value)  # keeps the scheme of an Authorization value
            else:
                out[key] = MARKER
        else:
            out[key] = _redact_value(value)
    return out


def redact_transcript(messages: Iterable[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Redact a chat transcript: a sequence of message mappings (role, content, ...)."""
    return [redact_mapping(message) for message in messages]


class RedactingFilter(logging.Filter):
    """A logging filter that redacts the rendered message and any string ``extra`` attributes.

    Attach it to every handler (T080's ``logging.py`` does) so no record leaves unredacted.
    """

    _STANDARD = frozenset(logging.makeLogRecord({}).__dict__) | {"message", "asctime"}

    def filter(self, record: logging.LogRecord) -> bool:
        record.msg = redact(record.getMessage())
        record.args = None
        if record.exc_info and not record.exc_text:
            record.exc_text = logging.Formatter().formatException(record.exc_info)
        if record.exc_text:
            record.exc_text = redact(record.exc_text)
        for name, value in list(record.__dict__.items()):
            if name not in self._STANDARD:
                record.__dict__[name] = _redact_value(value)
        return True
