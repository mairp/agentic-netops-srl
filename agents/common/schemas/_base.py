"""Shared base of the strict contract models (T081; FR-058, FR-065).

Strictness matches the Go parser: unknown fields are rejected (``extra='forbid'``), no type is
coerced (``strict=True`` — a ``"100"`` is not a VLAN and ``True`` is not an integer), and models
are validated from plain JSON-decoded data before any use.
"""

from __future__ import annotations

import json
from typing import Any, Self

from pydantic import BaseModel, ConfigDict

DNS_LABEL = r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"
PORT_RANGE = r"^[0-9]{1,5}(-[0-9]{1,5})?$"

PROTOCOL_NAMES = (
    "any", "ipv6-hop", "icmp", "igmp", "ggp", "ipv4", "st", "tcp", "egp", "igp", "udp", "ipv6",
    "idrp", "rsvp", "gre", "esp", "ah", "icmp6", "icmpv6", "no-next-hdr", "ipv6-dest-opts",
    "eigrp", "ospf", "pim", "vrrp", "l2tp", "sctp", "mpls-in-ip", "rohc",
)


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=False,
                              validate_assignment=True, populate_by_name=False)

    @classmethod
    def parse(cls, data: Any) -> Self:
        """Validate JSON-decoded ``data`` (or a JSON string/bytes) strictly."""
        if isinstance(data, str | bytes | bytearray):
            data = json.loads(data)
        return cls.model_validate(data, strict=True)

    def to_wire(self) -> dict[str, Any]:
        """The JSON-ready object: fields that were set, nothing invented."""
        return self.model_dump(mode="json", by_alias=True, exclude_unset=True)
