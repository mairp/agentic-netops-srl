"""The operator stream's NDJSON chunks (T081; contracts/supervisor-http.md, data-model.md §17).

One object per line, ``Content-Type: application/x-ndjson``. Every chunk carries the correlation
identifier and a status drawn **only** from the closed set of data-model.md §17. A ``progress``
chunk's ``ready`` is the ``Ready`` condition's status string — ``"True"``/``"False"``/``"Unknown"``
— never a boolean, and it is passed through from the deployer unaltered with its ``reason``
(AD-62).

:class:`DeploymentReport` is the deployer's data part: its ``progress`` entries are what the
supervisor streams as ``progress`` chunks.
"""

from __future__ import annotations

import json
from typing import Annotated, Any, Literal

from pydantic import Field, TypeAdapter, model_validator

from common.provisioning_states import StatusLiteral
from common.schemas._base import StrictModel
from common.schemas.audit import CORRELATION_ID_PATTERN, Ready, ResourceRef

Stage = Literal["supervisor", "mapper", "allocator", "deployer"]
OutOfBand = Literal["modified", "deleted"]
CorrelationId = Annotated[str, Field(pattern=CORRELATION_ID_PATTERN)]


class _Chunk(StrictModel):
    correlation_id: CorrelationId
    status: StatusLiteral
    thread_id: str | None = None

    def line(self) -> bytes:
        """The chunk as one NDJSON line."""
        body = self.model_dump(mode="json", exclude_none=True)
        ordered = {"type": body.pop("type"), **body}
        return (json.dumps(ordered, ensure_ascii=False, separators=(",", ":")) + "\n").encode()


class StatusChunk(_Chunk):
    type: Literal["status"] = "status"
    stage: Stage
    message: str | None = None


class ResourceName(StrictModel):
    kind: str = Field(min_length=1)
    name: str = Field(min_length=1)


class StageChunk(_Chunk):
    type: Literal["stage"] = "stage"
    stage: Stage
    payload: dict[str, Any] | None = None
    resources: list[ResourceName] | None = None
    resource: str | None = None
    out_of_band: OutOfBand | None = None
    message: str | None = None


class ConfirmationRequestChunk(_Chunk):
    type: Literal["confirmation_request"] = "confirmation_request"
    stage: Stage
    prompt: str = Field(min_length=1)
    refusable: bool = True


class ProgressChunk(_Chunk):
    type: Literal["progress"] = "progress"
    resource: str = Field(min_length=1)
    ready: Ready | None = None
    reason: str | None = None


class FinalChunk(_Chunk):
    type: Literal["final"] = "final"
    message: str | None = None


class ErrorChunk(_Chunk):
    type: Literal["error"] = "error"
    stage: Stage
    reason: str = Field(min_length=1)
    retryable: bool = False
    out_of_band: OutOfBand | None = None


Chunk = Annotated[
    StatusChunk | StageChunk | ConfirmationRequestChunk | ProgressChunk | FinalChunk | ErrorChunk,
    Field(discriminator="type"),
]
_CHUNK = TypeAdapter(Chunk)


def parse_chunk(data: dict[str, Any] | str | bytes) -> _Chunk:
    """Validate one chunk (a decoded object or an NDJSON line) strictly."""
    if isinstance(data, str | bytes):
        data = json.loads(data)
    return _CHUNK.validate_python(data, strict=True)


def build_chunk(**fields: Any) -> _Chunk:
    """Build and validate a chunk from keyword fields (``type`` selects the model)."""
    return parse_chunk({k: v for k, v in fields.items() if v is not None})


# --------------------------------------------------------------------------------------------------
# the deployer's data part
# --------------------------------------------------------------------------------------------------


class ProgressEvent(StrictModel):
    status: StatusLiteral
    resource: str = Field(min_length=1)
    ready: Ready | None = None
    reason: str | None = None


class DeploymentReport(StrictModel):
    """The deployer's answer to a submission or removal request.

    ``status``: ``COMPLETED`` (observed converged — or, for a removal, observed gone),
    ``PROVISIONING`` (a removal still ``Deleting`` at the bound, or — with ``watch: continue`` —
    a watch that goes on in the next call), ``FAILED`` (with ``message``). ``STATUS_UNKNOWN`` is
    the supervisor's to conclude, never reported as success.
    """

    operation: Literal["create", "remove"] = "create"
    status: StatusLiteral
    resources: list[ResourceRef] = Field(default_factory=list)
    progress: list[ProgressEvent] = Field(default_factory=list)
    message: str | None = None
    watch: Literal["done", "continue"] = "done"
    out_of_band: OutOfBand | None = None
    submitted: bool = True

    @model_validator(mode="after")
    def _removal_never_configured(self) -> DeploymentReport:
        if self.operation == "remove" and any(
            p.status in ("CONFIGURED", "VERIFIED") for p in self.progress
        ):
            raise ValueError("a removal never reports CONFIGURED or VERIFIED (AD-63)")
        if self.status == "COMPLETED" and self.operation == "create" and self.progress:
            last = self.progress[-1]
            if last.ready != "True":
                raise ValueError(
                    f"COMPLETED with the last Ready={last.ready!r}: only Ready=True converges"
                )
        return self


__all__ = [
    "Chunk",
    "ConfirmationRequestChunk",
    "DeploymentReport",
    "ErrorChunk",
    "FinalChunk",
    "ProgressChunk",
    "ProgressEvent",
    "ResourceName",
    "Stage",
    "StageChunk",
    "StatusChunk",
    "build_chunk",
    "parse_chunk",
]
