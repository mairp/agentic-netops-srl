#!/usr/bin/env bash
# Walkthrough tooling suite (T157, T158, T161; contracts/readme-and-walkthrough.md §3).
#
# Offline properties of testautomation/video/ that the take depends on:
#   frozen      the driver's three prompts equal docs/DEMO_VIDEO.md's frozen table, in order, with
#               constructs vlan, ip-vrf, mac-vrf; a doc one byte off is reported as drift
#   predecessor the table's predecessor column is the predecessor's wording, and A and C differ from
#               it only in the port name (B is the one forced change)
#   inventory   every prompt names only native (node, port) pairs: leaf01/leaf02 ethernet-1/1
#   read-only   every leaf read is `docker exec <leaf> sr_cli "info from state …"` — no redis-cli,
#               vtysh, bridge, no candidate/set/delete — and the driver runs no mutating kubectl
#   doc         every leaf command line leafproof.py types is written in docs/DEMO_VIDEO.md
#   judge       a read shows its fact only when its pattern matches, its forbidden pattern does not,
#               and it exited 0 (a vlan instance that holds a vxlan-interface is not shown)
#   login       the driver logs in before ffmpeg starts and never logs, prints or writes the password
#   accept      accept.py deletes a failed take and writes the evidence file only on a pass
#   thread      a new conversation keeps the transcript (Conversation.tsx newThread): only outcome
#               and error cards after the last thread divider, or added after Enter, are this prompt's
#   pins        ffmpeg, Xvfb and ttyd are recorded host tools in versions.lock.yaml
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
V="$ROOT/testautomation/video"
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }
check() { local name="$1"; shift; local out; if out="$("$@" 2>&1)"; then pass "$name"; else fail "$name" "$out"; fi; }

py() { PYTHONPATH="$V" python3 -c "$1"; }

check "frozen: driver prompts equal docs/DEMO_VIDEO.md, constructs vlan/ip-vrf/mac-vrf" py '
import prompts as p
assert p.drift_from_doc() == [], p.drift_from_doc()
rows = p.frozen_from_doc()
assert [r[0] for r in rows] == ["A", "B", "C"], rows
assert [r[1] for r in rows] == ["vlan", "ip-vrf", "mac-vrf"], rows'

check "frozen: a doc one byte off is drift" py '
import prompts as p, tempfile, pathlib
t = p.DOC.read_text(); i = t.rindex("for tenant blue`")
s = t[:i] + "for tenant blue `" + t[i + len("for tenant blue`"):]
f = pathlib.Path(tempfile.mkdtemp()) / "d.md"; f.write_text(s)
assert p.drift_from_doc(f), "no drift reported"'

check "predecessor: A and C differ only in the port name and the third-take identifiers (R-41); B keeps construct, leaves, tenant" py '
import prompts as p
r = {x[0]: x for x in p.frozen_from_doc()}
retake = {"A": ("vlan 170", "vlan 172"), "C": ("vlan152", "vlan154")}
for k in ("A", "C"):
    assert r[k][2].replace("ethernet1", "ethernet-1/1").replace(*retake[k]) == r[k][3], r[k]
b = r["B"][3]
for w in ("ip-vrf", "leaf01", "leaf02", "tenant initech"):
    assert w in b and w in r["B"][2], w
assert "prefix 10.53.0.0/24" in r["B"][2] and b.endswith("prefix 10.55.0.0/24"), b
assert "wan1" in r["B"][2] and "wan1" not in b'

check "inventory: prompts name only leaf01/leaf02 ethernet-1/1" py '
import prompts as p
for k in p.ORDER:
    e = p.endpoints(p.PROMPTS[k]); assert e, k
    assert set(e) <= {("leaf01", "ethernet-1/1"), ("leaf02", "ethernet-1/1")}, e'

check "read-only: every leaf read is sr_cli info from state" py '
import leafproof as lp, re
rs = lp.reads("vlan", "migr-abc", vlan="172") + lp.reads("ip-vrf", "migr-abc", vlan="255", vni=10001, prefix="10.55.0.0/24") \
   + lp.reads("mac-vrf", "migr-abc", vlan="154", vni=10002, vteps={"leaf01": "10.0.0.1", "leaf02": "10.0.0.2"})
cmds = [r.cmd for r in rs] + [lp.vtep_read("leaf01")] + [c for _, c in lp.free_reads(["172"])]
for c in cmds:
    assert re.fullmatch(r"docker exec clab-agentic-netops-fabric-leaf0[12] sr_cli \"info from state [^\";|&]+\"", c), c
    assert not re.search(r"redis-cli|vtysh|\bbridge\s|candidate|\bset\b|\bdelete\b|commit", c), c'

check "read-only: the driver and acceptance run no mutating kubectl" bash -c \
  "! grep -nE \"kubectl[^\\\"]*\\b(apply|delete|patch|edit|create|replace|scale|annotate|label)\\b|\\\"(apply|delete|patch|edit|create|replace|scale|annotate|label)\\\"\" '$V/record.py' '$V/accept.py' '$V/leafproof.py'"

check "doc: every leaf command line is written in docs/DEMO_VIDEO.md" py '
import leafproof as lp, prompts as p, re
doc = p.DOC.read_text()
def norm(c):  # the doc names placeholders where the take has values
    c = re.sub(r"clab-agentic-netops-fabric-leaf0[12]", "LEAF", c)
    return re.sub(r"(vlan|ipvrf|macvrf)-abc", r"\1-<sid>", c).replace("10099", "<vni>")
docn = re.sub(r"clab-agentic-netops-fabric-(leaf0[12]|<leaf>)", "LEAF", doc)
rs = lp.reads("vlan", "migr-abc", vlan="172") + lp.reads("ip-vrf", "migr-abc", vlan="255", vni=10099, prefix="10.55.0.0/24") \
   + lp.reads("mac-vrf", "migr-abc", vlan="154", vni=10099)
missing = [norm(r.cmd) for r in rs if norm(r.cmd) not in docn]
assert not missing, missing'

check "judge: facts shown only by a matching read that exited 0" py '
import leafproof as lp
v = lp.reads("vlan", "migr-abc", vlan="172")
ok, _ = lp.judge(v[0], 0, "    network-instance vlan-abc {\n        oper-state up\n    }"); assert ok
ok, _ = lp.judge(v[0], 0, "oper-state down"); assert not ok
ok, _ = lp.judge(v[0], 1, "oper-state up"); assert not ok
ok, _ = lp.judge(v[1], 0, "    interface ethernet-1/1.172 {\n        oper-state up\n    }"); assert ok
# the vxlan-interface list of a vlan: empty on 25.7.1 is the proof; any vxlan0.N fails it
nv = [r for r in v if "vxlan-interface *" in r.cmd][0]
assert lp.judge(nv, 0, "")[0]
ok, why = lp.judge(nv, 0, "    vxlan-interface vxlan0.10001 {\n        oper-state up\n    }"); assert not ok and "forbidden" in why
# output shapes observed on 25.7.1 during T160 take 2 (the tunnel is NOT listed under interface *)
m = lp.reads("mac-vrf", "migr-abc", vlan="154", vni=10001, vteps={"leaf01": "10.0.0.1", "leaf02": "10.0.0.2"})
sub = [r for r in m if r.cmd.endswith("interface *\"") and "vxlan-interface" not in r.cmd and r.leaf == "leaf01"][0]
assert lp.judge(sub, 0, "    interface ethernet-1/1.154 {\n        oper-state up\n        index 18\n    }")[0]
tun = [r for r in m if "vxlan-interface *" in r.cmd and r.leaf == "leaf01"][0]
assert lp.judge(tun, 0, "    vxlan-interface vxlan0.10001 {\n        oper-state up\n    }")[0]
assert not lp.judge(tun, 0, "    interface ethernet-1/1.154 {\n        oper-state up\n    }")[0]
vt = [r for r in m if "multicast-destinations" in r.cmd and r.leaf == "leaf01"][0]
obs = "    multicast-limit {\n        maximum-entries 768\n        current-usage 1\n    }\n    destination 10.0.0.2 vni 10001 {\n        multicast-forwarding BUM\n    }"
assert lp.judge(vt, 0, obs)[0]
assert not lp.judge(vt, 0, obs.replace("10.0.0.2", "10.0.0.9"))[0]
ip = lp.reads("ip-vrf", "migr-abc", vlan="255", vni=10000, prefix="10.55.0.0/24")
it = [r for r in ip if "vxlan-interface *" in r.cmd and r.leaf == "leaf02"][0]
assert lp.judge(it, 0, "    vxlan-interface vxlan0.10000 {\n        oper-state up\n    }")[0]
assert lp.parse_vtep("address 10.0.0.2/32 {") == "10.0.0.2"'

check "accept: the provisioning capture prints \`username: <name>\` and is parsed to the name" bash -c \
  "grep -q \"(?:username:\\\\\\\\s\\*)?\" '$V/accept.py' && grep -q 'username:' '$ROOT/scripts/ci/verify_readme.sh'"

check "login: before ffmpeg, the password never logged, printed or written" py '
import re, pathlib
s = pathlib.Path("'"$V"'/record.py").read_text()
run = s[s.index("    def run(self):"):]
assert run.index("self.login(u)") < run.index("self.start_ffmpeg(out)"), "login after recording starts"
for m in re.finditer(r"(log|print)\([^\n]*", s):
    assert "password" not in m.group(0), m.group(0)
assert not re.search(r"meta\[[^\]]*\]\s*=\s*password|write_text\([^)]*password", s)'

check "accept: a failed take is deleted; evidence written only on a pass" py '
import pathlib
s = pathlib.Path("'"$V"'/accept.py").read_text()
tail = s[s.index("    evidence[\"accept_pass\"] = not failures"):]
assert "if not failures:" in tail and "EVIDENCE.write_text" in tail.split("if not failures:")[1].split("return 0")[0]
assert "video.unlink()" in tail
assert "\"accept_pass\"" in s and "\"failures\"" in s'

check "thread: stale-card check counts only cards after the last divider; outcome waits for a new card" py '
import pathlib
s = pathlib.Path("'"$V"'/record.py").read_text()
js = s[s.index("FINALS_AFTER_DIVIDER_JS = ("):s.index("def finals_after_divider")]
assert "thread-divider" in js and "DOCUMENT_POSITION_FOLLOWING" in js, js
rp = s[s.index("    def run_prompt("):s.index("    def smoke_checks(")]
assert "self.finals_after_divider(u) != 0" in rp
assert "u.get_by_test_id(\"final\").count() != 0" not in rp, "whole-transcript stale check is back"
assert rp.index("n_final = u.get_by_test_id(\"final\").count()") < rp.index("u.get_by_test_id(\"prompt-send\").click()")
assert "final.count() > n_final and self.idle(u)" in rp and "count() > n_err" in rp'

check "pins: ffmpeg, Xvfb and ttyd are recorded host tools" python3 -c '
import yaml
d = yaml.safe_load(open("'"$ROOT"'/versions.lock.yaml"))
tools = {c["tool"]: c["version"] for c in d["hostTooling"]["capture"]}
assert {"ffmpeg", "Xvfb", "ttyd"} <= set(tools), tools
assert all(str(v).strip() for v in tools.values()), tools'

if ((fails)); then echo "video_tooling_test: $fails case(s) failed"; exit 1; fi
echo "video_tooling_test: all cases passed"
