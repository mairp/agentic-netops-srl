"""The three frozen walkthrough prompts (contracts/readme-and-walkthrough.md §3.1).

docs/DEMO_VIDEO.md is the authority: its "Frozen prompts" table carries, per row, the id, the
construct, the predecessor's wording and this platform's. The driver and the acceptance script
refuse to run when the strings below differ from that table by one byte — if a prompt's wording
must move, it moves in docs/DEMO_VIDEO.md with its reason, never silently here.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DOC = REPO / "docs" / "DEMO_VIDEO.md"

ORDER = ("A", "B", "C")
PROMPTS = {
    "A": "Provision a vlan 172 on leaf01 ethernet-1/1 for tenant acme",
    "B": ("Deploy an ip-vrf between leaf01 ethernet-1/1 vlan 255 and leaf02 ethernet-1/1 vlan 255 "
          "for tenant initech with prefix 10.55.0.0/24"),
    "C": "Extend vlan154 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 for tenant blue",
}
CONSTRUCT = {"A": "vlan", "B": "ip-vrf", "C": "mac-vrf"}
VLAN = {"A": "172", "B": "255", "C": "154"}
PREFIX = {"B": "10.55.0.0/24"}
TENANT = {"A": "acme", "B": "initech", "C": "blue"}
VLANS = [VLAN[p] for p in ORDER]

ROW = re.compile(r"^\|\s*([ABC])\s*\|\s*`([a-z-]+)`\s*\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|")


def frozen_from_doc(doc: Path = DOC) -> list[tuple[str, str, str, str]]:
    """(id, construct, predecessor, this platform) rows of the doc's Frozen prompts table, in order."""
    rows, inside = [], False
    for line in doc.read_text().splitlines():
        if line.startswith("## "):
            inside = line.strip().lower().startswith("## frozen prompts")
            continue
        m = ROW.match(line) if inside else None
        if m:
            rows.append(m.groups())
    return rows


def drift_from_doc(doc: Path = DOC) -> list[str]:
    rows = frozen_from_doc(doc)
    got = [(r[0], r[1], r[3]) for r in rows]
    want = [(p, CONSTRUCT[p], PROMPTS[p]) for p in ORDER]
    return [] if got == want else [f"doc={got!r}", f"driver={want!r}"]


def endpoints(prompt: str) -> list[tuple[str, str]]:
    """The (node, port) pairs a prompt names, in native naming."""
    return re.findall(r"\b(leaf\d\d) (ethernet-\d+/\d+)\b", prompt)


def normalized_intent(pid: str, asn: int = 65000) -> dict:
    """The normalized service intent each prompt must become, for the offline translator (smoke).
    VNIs are placeholders inside the allocation band; the take's are allocated by the authority."""
    ends = endpoints(PROMPTS[pid])
    vlan = int(VLAN[pid])
    sid = {"A": "0d0e0a0000000a1", "B": "0d0e0a0000000b1", "C": "0d0e0a0000000c1"}[pid]
    base = {"serviceId": sid, "type": CONSTRUCT[pid], "tenant": TENANT[pid],
            "endpoints": [{"node": n, "attachment": p, "vlan": vlan} for n, p in ends]}
    if pid == "B":
        base.update({"routeTargets": {"importRT": [f"target:{asn}:19991"], "exportRT": [f"target:{asn}:19991"]},
                     "l3vni": 19991, "addressFamilies": {"ipv4Prefixes": [PREFIX["B"]]}})
        for e in base["endpoints"]:
            e["vrf"] = f"vrf-{sid}"
    if pid == "C":
        base.update({"routeTargets": {"importRT": [f"target:{asn}:19992"], "exportRT": [f"target:{asn}:19992"]},
                     "l2vni": 19992})
    return base
