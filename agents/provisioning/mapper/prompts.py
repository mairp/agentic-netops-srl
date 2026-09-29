"""The mapper's model prompt (T098; FR-058, FR-077; data-model.md §8).

The instruction part is fixed here and built only from configuration — the construct catalogue and
the site inventory's names — never from request text. The operator's request reaches the model
only through :func:`common.guards.build_prompt`, neutralized, redacted and wrapped as ``<data>``.

The model's one job is structured extraction into the published Interpretation schema, in the
construct vocabulary only. Everything the platform *decides* — the service identifier, the naming
band, the site inventory, the tagging mode, the qualification record, the one-construct rule — is
decided afterwards by the mapper's own code (``agent.py``), whatever the model said.
"""

from __future__ import annotations

import json
from typing import Any

from common.guards import Prompt, build_prompt
from provisioning.mapper.catalogue import Catalogue

SCHEMA_SHAPE = """{
  "service_id": "",                       // leave empty: the platform generates it
  "service_type": "vlan" | "mac-vrf" | "ip-vrf" | "acl",
  "source_service_type": null | "VPLS" | "VPWS" | "L3VPN" | "L2L3-IRB",
  "tenant": "<lower-case RFC 1123 label>",
  "endpoints": [{"site_or_node": "<node>", "attachment": "<port>", "vlan": <integer> | null}],
  "anycast_gateway": null | {"ipv4": "<address/len>" | null, "ipv6": "<address/len>" | null},
  "acl": null | {"name": null | "<name>", "stage": "ingress" | "egress",
                 "type": "ipv4" | "ipv6" | "<as stated>",
                 "default_action": null | "permit" | "deny",
                 "rules": [{"name": "<label>" | null, "priority": <integer as stated> | null,
                            "action": "permit" | "deny",
                            "protocol": "<name>" | <0-255>, "source_prefix": "<prefix>",
                            "destination_prefix": "<prefix>", "source_port": "<n or lo-hi>",
                            "destination_port": "<n or lo-hi>"}]},
  "ipv4_prefixes": [], "ipv6_prefixes": [],
  "bandwidth": null, "sla": null,
  "missing_fields": [], "unsupported_properties": []
}"""

RULES = """Rules:
1. Answer with exactly one JSON object of the shape below and nothing else: no prose, no
   code fence. Unknown keys are forbidden. Omit a rule's optional keys rather than setting
   them to null.
2. service_type is one of the four constructs above, after folding an alias; a migration alias
   (VPLS, VPWS, E-LINE, L3VPN, IRB) is recorded in source_service_type. A service type that is not
   one of the four is never coerced: put "service_type: '<what was asked>' is not a construct; the
   constructs are vlan, mac-vrf, ip-vrf and acl" in unsupported_properties.
3. Copy every VLAN number exactly as the operator typed it, whatever its value — never correct,
   clamp or drop it. An endpoint whose VLAN the operator did not name has "vlan": null.
4. Never invent or default a value. When the tenant, a node, a port, an ACL stage or rule, or an
   ip-vrf's prefixes are not stated or are ambiguous, put the exact field path (for example
   "tenant", "endpoints[1].attachment", "acl.stage", "ipv4_prefixes") in missing_fields and use
   the placeholder "unknown" where the schema needs a string. An ip-vrf endpoint with no VLAN is
   the untagged subinterface and is NOT missing.
5. Anything the vocabulary cannot carry — traffic engineering, pseudowire OAM, control word,
   multicast VPN, complex QoS, service chaining, raw device CLI, an explicit VNI, route target or
   route distinguisher, an anycast gateway on anything but a mac-vrf — goes in
   unsupported_properties as a complete sentence beginning with the property path.
6. One construct per request. When the request asks for two or more constructs (an ACL riding on
   another construct's own endpoints is not a second construct), put
   "request: one construct per request — you asked for <a> and <b>; send one" in
   unsupported_properties.
7. Node and port names are the site's own; use the names listed below when the operator
   clearly meant one of them.
8. An access list's type and each rule's priority are copied exactly as the operator stated
   them (for example "l3", "mac" or 65535) — never corrected, re-numbered or dropped; the
   platform folds and judges them. A rule name or priority the operator did not state is null —
   never "unknown", never invented, and not a missing field: the platform labels the rule and,
   when no rule states a priority, orders the rules as they were stated.
   default_action is null unless the operator declared what happens to traffic no rule matches.
9. In an access-list rule, a number written right after the protocol ("udp 161", "tcp/22",
   "tcp port 443") is that rule's destination_port, copied exactly. A prefix, port or protocol the
   operator did not state is omitted — never "0.0.0.0/0", "::/0", "0-65535" or "unknown"."""


def instructions(catalogue: Catalogue, inventory: dict[str, Any] | None) -> str:
    """The fixed instruction part: vocabulary, site names, rules, output shape."""
    lines = ["You map an operator's datacenter network request onto a fixed construct vocabulary "
             "and answer with one JSON Interpretation object.", "", "The four constructs:"]
    for c in catalogue.constructs:
        lines.append(f"- {c['name']}: {c['description']}")
        for var, rule in (c.get("variables") or {}).items():
            lines.append(f"    {var}: {rule}")
        if c.get("forbidden"):
            lines.append(f"    not carried: {', '.join(c['forbidden'])}")
        for example in c.get("examples") or []:
            lines.append(f"    example: {example}")
    aliases = ", ".join(f"{k} -> {v['construct']}" for k, v in sorted(catalogue.aliases.items()))
    lines += ["", f"Accepted input aliases (folded, never emitted as a type): {aliases}."]
    if inventory:
        lines += ["", "This site's attachment nodes and their access ports:"]
        for node in inventory.get("nodes", []):
            if node.get("role") == "spine":
                continue
            lines.append(f"- {node.get('name')}: {', '.join(node.get('accessPorts') or [])}")
    lines += ["", RULES, "", "Output shape:", SCHEMA_SHAPE]
    return "\n".join(lines)


def build(catalogue: Catalogue, inventory: dict[str, Any] | None, text: str) -> Prompt:
    """The prompt: fixed instructions + the operator's text as delimited data."""
    return build_prompt(instructions(catalogue, inventory), operator_text=text)


def messages(prompt: Prompt) -> list[dict[str, Any]]:
    return [{"role": "system", "content": prompt.system},
            {"role": "user", "content": prompt.data}]


def retry_message(error: str) -> dict[str, Any]:
    """The one corrective turn after schema-invalid output. The error is the platform's own
    validation summary, never operator text."""
    return {"role": "user", "content": (
        "Your previous answer was not a valid Interpretation object: "
        f"{json.dumps(error)}. Answer again with only the corrected JSON object.")}


__all__ = ["RULES", "SCHEMA_SHAPE", "build", "instructions", "messages", "retry_message"]
