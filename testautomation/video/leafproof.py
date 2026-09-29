"""The on-screen leaf proof of the walkthrough, and the check of what each read printed.

Ported from the predecessor's recording tooling (/root/agentic-netops/testautomation/video/):
its `redis-cli` / `vtysh` / `bridge` reads are replaced by read-only SR Linux `sr_cli`
`info from state` reads (contracts/readme-and-walkthrough.md §3.2) — the one thing the platform
forces. Every command here is a read. The driver (record.py) types these exact strings on screen;
the acceptance script (accept.py) re-runs them from the host and decides each fact from the
output, never from a frame.

The command lines are written in docs/DEMO_VIDEO.md §"Leaf proof", fixed from what each printed on
the pinned release (T159); tests/unit/video/video_tooling_test.sh keeps the two from drifting.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

LAB = "agentic-netops-fabric"
LEAF1 = f"clab-{LAB}-leaf01"
LEAF2 = f"clab-{LAB}-leaf02"
LEAVES = {"leaf01": LEAF1, "leaf02": LEAF2}
PORT = "ethernet-1/1"  # the one access port each leaf has (native name, lab/topology.clab.yml)
TUNNEL = "vxlan0"


def srl(leaf: str, path: str) -> str:
    """One read-only `info from state` read inside the leaf, as typed on screen."""
    return f'docker exec {leaf} sr_cli "info from state {path}"'


@dataclass(frozen=True)
class Read:
    leaf: str  # leaf01 | leaf02
    cmd: str
    fact: str  # what the read is run to show
    pattern: str  # regex the output must match for the fact to hold
    absent: str = ""  # regex the output must NOT match (e.g. no vxlan-interface on a vlan)


def service_id(network_name: str) -> str:
    return network_name.removeprefix("migr-")


def reads(construct: str, network_name: str, vlan: str = "", vni: int | None = None,
          prefix: str = "", vteps: dict[str, str] | None = None) -> list[Read]:
    """The leaf reads for one service, in the order they are typed.

    vteps maps leaf -> that leaf's own system0.0 address (the remote VTEP the other leaf shows).
    """
    sid = service_id(network_name)
    sub = f"{PORT}.{vlan}" if vlan else ""
    out: list[Read] = []
    if construct == "vlan":
        ni = f"vlan-{sid}"
        out += [
            Read("leaf01", srl(LEAF1, f"network-instance {ni} oper-state"),
                 f"{ni} (the bridged network instance of the vlan) is up", r"oper-state up"),
            Read("leaf01", srl(LEAF1, f"network-instance {ni} interface *"),
                 f"{ni} holds {sub}", rf"interface {re.escape(sub)}\b"),
            # 25.7.1 lists tunnel interfaces under vxlan-interface, never under interface (T160 take 2):
            # an empty list is the proof, so the pattern matches anything and `absent` decides.
            Read("leaf01", srl(LEAF1, f"network-instance {ni} vxlan-interface *"),
                 f"{ni} has no vxlan-interface", r"", absent=r"vxlan0\.\d+"),
            Read("leaf01", srl(LEAF1, f"interface {PORT} subinterface {vlan} oper-state"),
                 f"subinterface {sub} is up", r"oper-state up"),
        ]
    elif construct == "ip-vrf":
        ni = f"ipvrf-{sid}"
        for leaf in ("leaf01", "leaf02"):
            c = LEAVES[leaf]
            out += [
                Read(leaf, srl(c, f"network-instance {ni} oper-state"),
                     f"{leaf}: {ni} is up", r"oper-state up"),
                Read(leaf, srl(c, f"network-instance {ni} interface *"),
                     f"{leaf}: {ni} holds routed {sub}", rf"interface {re.escape(sub)}\b"),
                Read(leaf, srl(c, f"network-instance {ni} vxlan-interface *"),
                     f"{leaf}: {ni} holds {TUNNEL}.{vni}", rf"vxlan-interface {TUNNEL}\.{vni}\b"),
            ]
            if leaf == "leaf01":
                out.append(Read(leaf, srl(c, f"tunnel-interface {TUNNEL} vxlan-interface {vni}"),
                                f"{leaf}: {TUNNEL}.{vni} is routed with ingress VNI {vni}",
                                rf"(?s)(?=.*type (?:srl_nokia-interfaces:)?routed)(?=.*vni {vni}\b)"))
            out.append(Read(leaf, srl(c, f"network-instance {ni} route-table ipv4-unicast route {prefix} "
                                          f"id * route-type * route-owner * origin-network-instance * active"),
                            f"{leaf}: {prefix} is an active route in {ni}'s route table",
                            rf"(?s)(?=.*{re.escape(prefix)})(?=.*active true)"))
        out.append(Read("leaf02",
                        srl(LEAF2, f"network-instance default bgp-rib afi-safi evpn evpn rib-in-out "
                                   f"rib-in-post ip-prefix-route * ethernet-tag-id * "
                                   f"ip-prefix-length {prefix.rsplit('/', 1)[-1]} ip-prefix {prefix} "
                                   f"neighbor * path-id *"),
                        f"leaf02: the EVPN IP-prefix (Type-5) route for {prefix} is received",
                        rf"{re.escape(prefix)}"))
    elif construct == "mac-vrf":
        ni = f"macvrf-{sid}"
        for leaf in ("leaf01", "leaf02"):
            c = LEAVES[leaf]
            other = "leaf02" if leaf == "leaf01" else "leaf01"
            remote = (vteps or {}).get(other, "")
            out += [
                Read(leaf, srl(c, f"network-instance {ni} oper-state"),
                     f"{leaf}: {ni} is up", r"oper-state up"),
                Read(leaf, srl(c, f"network-instance {ni} interface *"),
                     f"{leaf}: {ni} holds {sub}", rf"interface {re.escape(sub)}\b"),
                Read(leaf, srl(c, f"network-instance {ni} vxlan-interface *"),
                     f"{leaf}: {ni} holds {TUNNEL}.{vni}", rf"vxlan-interface {TUNNEL}\.{vni}\b"),
                Read(leaf, srl(c, f"network-instance {ni} protocols bgp-evpn bgp-instance 1"),
                     f"{leaf}: the EVPN instance of {ni} carries evi {vni}",
                     rf"evi {vni}\b"),
                Read(leaf, srl(c, f"tunnel-interface {TUNNEL} vxlan-interface {vni} bridge-table "
                                  f"multicast-destinations"),
                     f"{leaf}: the remote VTEP {remote or '(the other leaf)'} is a flooding destination",
                     rf"destination {re.escape(remote)} vni {vni}\b" if remote
                     else rf"destination \d+\.\d+\.\d+\.\d+ vni {vni}\b"),
            ]
    return out


def vtep_read(leaf: str) -> str:
    """The leaf's own VTEP address (system0.0), read once to name the other leaf's remote VTEP."""
    return srl(LEAVES[leaf], "interface system0 subinterface 0 ipv4 address *")


def parse_vtep(output: str) -> str:
    m = re.search(r"address (\d+\.\d+\.\d+\.\d+)/32", output)
    return m.group(1) if m else ""


def judge(read: Read, rc: int, output: str) -> tuple[bool, str]:
    """Whether the read showed the fact it was run for."""
    if rc != 0:
        return False, f"rc={rc}"
    if not re.search(read.pattern, output):
        return False, f"pattern {read.pattern!r} not in output"
    if read.absent and re.search(read.absent, output):
        return False, f"forbidden {read.absent!r} present"
    return True, "ok"


def free_reads(vlans: list[str]) -> list[tuple[str, str]]:
    """Smoke: each single-use VLAN has no subinterface on either leaf yet."""
    return [(leaf, srl(c, f"interface {PORT} subinterface {v}")) for v in vlans for leaf, c in LEAVES.items()]
