"""The mapper's published output (T081; data-model.md §8, contracts/interpretation.schema.json).

Strict: unknown fields rejected on every object, no coercion, the construct enum closed (a retired
service-provider name is never a ``service_type``), the conditional rules of the schema's
``allOf`` enforced. ``missing_fields`` and ``unsupported_properties`` are each terminal and
mutually exclusive (data-model.md §8).
"""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import Field, model_validator

from common.schemas._base import DNS_LABEL, PORT_RANGE, PROTOCOL_NAMES, StrictModel

Construct = Literal["vlan", "mac-vrf", "ip-vrf", "acl"]
SourceServiceType = Literal["VPLS", "VPWS", "L3VPN", "L2L3-IRB"]
Protocol = Literal[PROTOCOL_NAMES] | Annotated[int, Field(ge=0, le=255)]

MARKER = "MAPPED_JSON"  # the mapped-JSON comment marker — compatibility only (D-29)


class EndpointIntent(StrictModel):
    site_or_node: str = Field(min_length=1)
    attachment: str = Field(min_length=1)
    # A floor of 0 and no upper bound on purpose: the mapper states both bands (AD-61).
    vlan: Annotated[int, Field(ge=0)] | None = None


class AnycastGatewayIntent(StrictModel):
    ipv4: str | None = None
    ipv6: str | None = None

    @model_validator(mode="after")
    def _one_family(self) -> AnycastGatewayIntent:
        # JSON Schema anyOf required: the key must be present (it may be null).
        if not ({"ipv4", "ipv6"} & self.model_fields_set):
            raise ValueError("anycast_gateway needs at least one family: ipv4 or ipv6")
        return self


class AclRuleIntent(StrictModel):
    name: str = Field(min_length=1)
    priority: int = Field(ge=1, le=65534)
    action: Literal["permit", "deny"]
    protocol: Protocol | None = Field(default=None)
    source_prefix: str | None = None
    destination_prefix: str | None = None
    source_port: Annotated[str, Field(pattern=PORT_RANGE)] | None = None
    destination_port: Annotated[str, Field(pattern=PORT_RANGE)] | None = None
    description: Annotated[str, Field(max_length=255)] | None = None

    @model_validator(mode="before")
    @classmethod
    def _protocol_not_null(cls, data: object) -> object:
        # The schema's protocol is anyOf string-enum | integer: present means non-null.
        if isinstance(data, dict) and "protocol" in data and data["protocol"] is None:
            raise ValueError("protocol: null is not a protocol; omit the field instead")
        return data


class AclIntent(StrictModel):
    name: str | None = None
    stage: Literal["ingress", "egress"]
    type: Literal["ipv4", "ipv6"]
    default_action: Literal["permit", "deny"] | None = None
    evaluation_order: Literal["ascending-first-match"] = "ascending-first-match"
    unmatched_traffic: Literal["accept-platform-default", "permit", "deny"] | None = None
    rules: list[AclRuleIntent] = Field(min_length=1)

    @model_validator(mode="before")
    @classmethod
    def _non_nullable(cls, data: object) -> object:
        if isinstance(data, dict):
            for key in ("evaluation_order", "unmatched_traffic"):
                if key in data and data[key] is None:
                    raise ValueError(f"{key}: null is not allowed; omit the field instead")
        return data


class Interpretation(StrictModel):
    service_id: str = Field(min_length=1, max_length=15, pattern=DNS_LABEL)
    service_type: Construct
    source_service_type: SourceServiceType | None = None
    tenant: str = Field(pattern=DNS_LABEL)
    endpoints: list[EndpointIntent] = Field(min_length=1)
    anycast_gateway: AnycastGatewayIntent | None = None
    acl: AclIntent | None = None
    ipv4_prefixes: list[str] = Field(default_factory=list)
    ipv6_prefixes: list[str] = Field(default_factory=list)
    bandwidth: str | None = None
    sla: str | None = None
    missing_fields: list[str] = Field(default_factory=list)
    unsupported_properties: list[str] = Field(default_factory=list)

    @model_validator(mode="before")
    @classmethod
    def _non_nullable_lists(cls, data: object) -> object:
        if isinstance(data, dict):
            for key in ("ipv4_prefixes", "ipv6_prefixes", "missing_fields",
                        "unsupported_properties"):
                if key in data and data[key] is None:
                    raise ValueError(f"{key}: null is not a list")
        return data

    @model_validator(mode="after")
    def _per_construct(self) -> Interpretation:
        if self.service_type == "acl" and "acl" not in self.model_fields_set:
            raise ValueError("an acl interpretation requires acl")
        if self.service_type in ("acl", "ip-vrf", "vlan") and self.anycast_gateway is not None:
            raise ValueError(f"anycast_gateway is only for mac-vrf, not {self.service_type}")
        return self

    @property
    def is_clarification(self) -> bool:
        return bool(self.missing_fields)

    @property
    def is_rejection(self) -> bool:
        return bool(self.unsupported_properties)

    def terminal_conflict(self) -> str | None:
        """data-model.md §8: the two lists are mutually exclusive."""
        if self.missing_fields and self.unsupported_properties:
            return "missing_fields and unsupported_properties are mutually exclusive"
        return None


__all__ = ["MARKER", "AclIntent", "AclRuleIntent", "AnycastGatewayIntent", "Construct",
           "EndpointIntent", "Interpretation"]
