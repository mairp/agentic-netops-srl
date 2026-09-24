"""The allocator's output — the one contract the translator consumes (T081; data-model.md §9,
contracts/normalized-service-intent.schema.json).

Strictness must match the Go side: extra fields forbidden on every object, no coercion, and no
explicit ``null`` anywhere (the schema admits none — an absent field is absent). The per-construct
``allOf`` rules are enforced: ``mac-vrf`` needs ``l2vni`` and ``routeTargets`` (and ``l3vni`` with a
gateway), ``ip-vrf`` needs ``l3vni``, ``routeTargets`` and ``addressFamilies`` and forbids
``l2vni``/``anycastGateway``, ``acl`` needs ``acl`` and forbids every VNI, route target and
gateway, ``vlan`` forbids them too.
"""

from __future__ import annotations

from typing import Annotated, Any, Literal

from pydantic import Field, model_validator

from common.schemas._base import DNS_LABEL, PORT_RANGE, PROTOCOL_NAMES, StrictModel

Construct = Literal["vlan", "mac-vrf", "ip-vrf", "acl"]
Protocol = Literal[PROTOCOL_NAMES] | Annotated[int, Field(ge=0, le=255)]

MARKER = "DEPLOYMENT_JSON"  # the deployment-JSON comment marker — compatibility only (D-29)


class _NoNulls(StrictModel):
    """No field of this contract is nullable: an explicit null is refused, naming the field."""

    @model_validator(mode="before")
    @classmethod
    def _refuse_nulls(cls, data: object) -> object:
        if isinstance(data, dict):
            nulls = sorted(k for k, v in data.items() if v is None)
            if nulls:
                raise ValueError(f"null is not allowed for {', '.join(nulls)}; omit the field")
        return data


class RouteTargets(_NoNulls):
    importRT: list[str] = Field(min_length=1)
    exportRT: list[str] = Field(min_length=1)


class AddressFamilies(_NoNulls):
    ipv4Prefixes: list[str] | None = None
    ipv6Prefixes: list[str] | None = None


class AnycastGateway(_NoNulls):
    ipVrf: Annotated[str, Field(min_length=1)] | None = None
    gatewayIPv4: Annotated[str, Field(min_length=1)] | None = None
    gatewayIPv6: Annotated[str, Field(min_length=1)] | None = None

    @model_validator(mode="after")
    def _one_family(self) -> AnycastGateway:
        if not ({"gatewayIPv4", "gatewayIPv6"} & self.model_fields_set):
            raise ValueError("anycastGateway needs gatewayIPv4 or gatewayIPv6")
        return self


class AclRule(_NoNulls):
    name: str = Field(min_length=1)
    priority: int = Field(ge=1, le=65534)
    action: Literal["permit", "deny"]
    protocol: Protocol | None = None
    sourcePrefix: Annotated[str, Field(min_length=1)] | None = None
    destinationPrefix: Annotated[str, Field(min_length=1)] | None = None
    sourcePort: Annotated[str, Field(pattern=PORT_RANGE)] | None = None
    destinationPort: Annotated[str, Field(pattern=PORT_RANGE)] | None = None
    description: Annotated[str, Field(max_length=255)] | None = None


class Acl(_NoNulls):
    name: Annotated[str, Field(min_length=1)] | None = None
    stage: Literal["ingress", "egress"]
    type: Literal["ipv4", "ipv6"]
    defaultAction: Literal["permit", "deny"] | None = None
    evaluationOrder: Literal["ascending-first-match"] | None = None
    unmatchedTraffic: Literal["accept-platform-default", "permit", "deny"] | None = None
    rules: list[AclRule] = Field(min_length=1)


class Endpoint(_NoNulls):
    node: str = Field(min_length=1)
    attachment: str = Field(min_length=1)
    vlan: Annotated[int, Field(ge=1, le=4094)] | None = None
    vrf: Annotated[str, Field(min_length=1)] | None = None


class Policies(_NoNulls):
    vpwsLimitedEquivalence: bool | None = None


class NormalizedServiceIntent(_NoNulls):
    serviceId: str = Field(min_length=1, max_length=15, pattern=DNS_LABEL)
    type: Construct
    tenant: str = Field(min_length=1, pattern=DNS_LABEL)
    routeTargets: RouteTargets | None = None
    l2vni: Annotated[int, Field(ge=1, le=65535)] | None = None
    l3vni: Annotated[int, Field(ge=1, le=65535)] | None = None
    addressFamilies: AddressFamilies | None = None
    anycastGateway: AnycastGateway | None = None
    acl: Acl | None = None
    endpoints: list[Endpoint] = Field(min_length=1)
    policies: Policies | None = None
    unsupported: dict[str, Any] | None = None

    @model_validator(mode="after")
    def _per_construct(self) -> NormalizedServiceIntent:
        present = {k for k in self.model_fields_set if getattr(self, k) is not None}

        def need(*names: str) -> None:
            missing = [n for n in names if n not in present]
            if missing:
                raise ValueError(f"{self.type} requires {', '.join(missing)}")

        def forbid(*names: str) -> None:
            found = [n for n in names if n in present]
            if found:
                raise ValueError(f"{', '.join(found)} is forbidden on {self.type}")

        match self.type:
            case "mac-vrf":
                need("l2vni", "routeTargets")
                if "anycastGateway" in present:
                    need("l3vni")
            case "ip-vrf":
                need("l3vni", "routeTargets", "addressFamilies")
                forbid("l2vni", "anycastGateway")
            case "acl":
                need("acl")
                forbid("l2vni", "l3vni", "routeTargets", "anycastGateway")
            case "vlan":
                forbid("l2vni", "l3vni", "routeTargets", "anycastGateway")
        return self

    @property
    def network_name(self) -> str:
        return f"migr-{self.serviceId}"


__all__ = ["MARKER", "Acl", "AclRule", "AddressFamilies", "AnycastGateway", "Endpoint",
           "NormalizedServiceIntent", "Policies", "RouteTargets"]
