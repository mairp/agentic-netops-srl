#!/usr/bin/env bash
# verify_readme suite (T156; NFR-011, NFR-013, SC-031…SC-033, CD-06;
# contracts/readme-and-walkthrough.md §6).
#
# Each case plants a miniature repository root in a scratch directory — a README that satisfies
# the contract, its lock file, docs/DEMO_VIDEO.md, the walkthrough evidence file, the four figures,
# the quickstart — then applies ONE mutation and runs scripts/ci/verify_readme.sh --root on it,
# asserting the verdict and the check it names (planted in scratch, never in the tree, so the
# planted deny-listed words are not themselves a finding of the scans that run on this repository):
#   good          the planted tree passes AND reports the asset-URL placeholder (never silently)
#   asset         the placeholder replaced by a GitHub asset URL passes with nothing reported;
#                 neither placeholder nor URL fails [placeholder]
#   sections      swapped sections, a missing SR Linux badge, a CI badge for an absent workflow, a
#                 merge-queue badge with no queue configured (and passing once .mergify.yml has one), an
#                 SRv6 row, --profile in Quickstart, a missing figure embed each fail [sections]
#   links         a dead relative link, a missing image file each fail [links]
#   versions      a version the lock file does not carry, a badge with another version, a digest not
#                 in the lock each fail [versions]
#   facts         the predecessor's MTU in place of 9412, no IPv6 anycast-gateway limitation fail [facts]
#   denylist      SONiC, vtysh, `latest`, raw.githubusercontent.com, a retired service name, a
#                 credential in a figure's alt text and in the evidence file each fail [denylist];
#                 the same predecessor term inside a labelled history block passes
#   evidence      no evidence file, accept_pass false, failures non-empty, an NFR-013 field missing
#                 each fail [evidence]
#   prompts       a prompt one byte off DEMO_VIDEO.md, the prompts reordered fail [prompts]
#   principal     a Network whose principal is not the generated operator username fails [principal]
#   timings       a Demo duration that is not the take's / 6, a seconds figure the evidence did not
#                 measure fail [timings]
#   quickstart    a Quickstart command quickstart.md does not carry fails [quickstart]
# Offline: python3 only (--no-cluster).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
VR="$ROOT/scripts/ci/verify_readme.sh"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    /'; }

DIGEST="sha256:6ab1250cbff4b536e0996e57d2d9c2a7bf3154028c21e4c978e13254add3c402"
PA='Provision a vlan 170 on leaf01 ethernet-1/1 for tenant acme'
PB='Deploy an ip-vrf between leaf01 ethernet-1/1 vlan 253 and leaf02 ethernet-1/1 vlan 253 for tenant initech with prefix 10.53.0.0/24'
PC='Extend vlan152 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 for tenant blue'

plant() {
  local d="$SCRATCH/$1"
  mkdir -p "$d/docs/images" "$d/docs/media" "$d/.github/workflows" "$d/specs/004-agentic-netops-composite" "$d/lab"
  for f in lab-topology grafana-fabric-telemetry agent-ui agent-ui-outcome; do printf 'png' >"$d/docs/images/$f.png"; done
  printf 'name: ci\n' >"$d/.github/workflows/ci.yaml"
  printf '# Tutorial\n' >"$d/TUTORIAL.md"
  printf 'name: agentic-netops-fabric\n' >"$d/lab/topology.clab.yml"
  cat >"$d/versions.lock.yaml" <<EOF
srlinux:
  image: ghcr.io/nokia/srlinux
  version: 25.7.1
  digest: "$DIGEST"
kubernetes: v1.33.1
containerlab: 0.79.0
EOF
  cat >"$d/docs/DEMO_VIDEO.md" <<EOF
# Walkthrough

## Frozen prompts

| # | Construct | Predecessor | This platform |
|---|---|---|---|
| A | \`vlan\` | \`Provision a vlan 170 on leaf01 ethernet1 for tenant acme\` | \`$PA\` |
| B | \`ip-vrf\` | \`Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.53.0.0/24\` | \`$PB\` |
| C | \`mac-vrf\` | \`Extend vlan152 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue\` | \`$PC\` |

## Procedure
EOF
  cat >"$d/specs/004-agentic-netops-composite/quickstart.md" <<'EOF'
MGMT_CIDR=172.25.25.0/24 ./scripts/provision.sh --cluster-name agentic-netops
make verify-fabric-control-plane
./scripts/off.sh --cluster-name agentic-netops
MGMT_CIDR=172.25.25.0/24 ./scripts/provision.sh --cluster-name agentic-netops --with-intent-tier
EOF
  python3 - "$d/docs/media/agentic-netops-srl-intent-tier-demo-evidence.json" "$DIGEST" "$PA" "$PB" "$PC" <<'PY'
import json, sys
out, digest, pa, pb, pc = sys.argv[1:]
prompts = [(i, p, c, s) for (i, p, c, s) in (("A", pa, "vlan", 212.4), ("B", pb, "ip-vrf", 305.0), ("C", pc, "mac-vrf", 250.2))]
ev = {"generated_utc": "2026-10-04T08:00:00.000+00:00", "take": "final",
      "run": {"command": "testautomation/video/accept.py --take final", "exit_status": 0,
              "device_image_digest": digest, "cluster": {"name": "agentic-netops", "uid": "u-1"},
              "lab": {"name": "agentic-netops-fabric", "topology_sha256": "0" * 64}},
      "video": {"width": 1920, "height": 1080, "duration": 2160.0},
      "operator_username": {"username": "operator", "evidence_record": ".evidence/x/y/operator-username-1.json"},
      "prompts": [{"id": i, "prompt": p, "construct": c, "correlation_id": "c" * 32, "network": f"migr-{i.lower()}",
                   "principal": "operator", "seconds_enter_to_deployed": s,
                   "ready_condition": {"type": "Ready", "status": "True"}} for i, p, c, s in prompts],
      "closing_listing": "", "failures": [], "accept_pass": True}
open(out, "w").write(json.dumps(ev, indent=1))
PY
  cat >"$d/README.md" <<EOF
# agentic-netops-srl - Autonomous intent-to-fabric operations.

[![CI](https://github.com/o/agentic-netops-srl/actions/workflows/ci.yaml/badge.svg)](https://github.com/o/agentic-netops-srl/actions/workflows/ci.yaml)
[![SR Linux](https://img.shields.io/badge/SR%20Linux-25.7.1-blue)](versions.lock.yaml)
[![SDC](https://img.shields.io/badge/SDC-config-blue)](versions.lock.yaml)
[![KUID](https://img.shields.io/badge/KUID-allocation-blue)](versions.lock.yaml)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.33.1-326ce5)](versions.lock.yaml)
[![containerlab](https://img.shields.io/badge/containerlab-nokia__srlinux-0a7bbb)](lab/topology.clab.yml)
[![Tutorial](https://img.shields.io/badge/docs-TUTORIAL.md-green)](TUTORIAL.md)

[![AGNTCY](https://img.shields.io/badge/AGNTCY-intent%20tier-6f42c1)](TUTORIAL.md)
[![LangGraph](https://img.shields.io/badge/LangGraph-supervisor-1c3c3c)](TUTORIAL.md)
[![A2A](https://img.shields.io/badge/A2A-agent%20to%20agent-0b8043)](TUTORIAL.md)
[![SLIM](https://img.shields.io/badge/SLIM-message%20bus-e37400)](TUTORIAL.md)
[![gNMI](https://img.shields.io/badge/gNMI-telemetry-00b3a4)](TUTORIAL.md)
[![Prometheus](https://img.shields.io/badge/Prometheus-metrics-e6522c)](TUTORIAL.md)
[![Grafana](https://img.shields.io/badge/Grafana-dashboards-f46800)](TUTORIAL.md)

Intent reaches a live SR Linux EVPN/VXLAN fabric through one southbound: the provider renders an SDC
\`Config\`, which SDC applies over gNMI.

## Demo

Full walkthrough (~6 min, 6x) — the intent tier end to end.

<!-- ASSET-URL-PLACEHOLDER: the operator uploads the 6x cut as a GitHub asset and replaces this line -->

Every "deployed" claim was re-verified; the evidence is in
[the evidence file](docs/media/agentic-netops-srl-intent-tier-demo-evidence.json). The vlan took 212.4 s.

## The lab

![Fabric topology](docs/images/lab-topology.png)
![Fabric telemetry](docs/images/grafana-fabric-telemetry.png)
![Operator console](docs/images/agent-ui.png)
![Deployment outcome](docs/images/agent-ui-outcome.png)

**What works and what does not:** observed.

## What you get

| Piece | What it is |
| --- | --- |
| Fabric | 2 spines, 2 leaves |

## Prerequisites

Host requirements.

## Quickstart

\`\`\`bash
MGMT_CIDR=172.25.25.0/24 ./scripts/provision.sh --cluster-name agentic-netops
make verify-fabric-control-plane   # the fabric converged
\`\`\`

## Known limitations — read before trusting a run

- IPv6 anycast gateway and IPv6 Type-5 origination are gate items.
- SRv6 is deferred.
- Operator credentials are lab credentials.

## Repository layout

\`\`\`
scripts/   provisioning
\`\`\`

## Policies enforced in CI

Jumbo MTU 9412 / 9398 / 9348; probes 9320 and 9300. \`make verify-pins\`. \`make verify-evidence\`.
EOF
  printf '%s' "$d"
}

mutate() {  # mutate <dir> <file> <python expression over s>
  python3 - "$1/$2" "$3" <<'PY'
import sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p).read()
s2 = eval(expr, {"s": s})
assert s2 != s, f"mutation changed nothing: {expr}"
open(p, "w").write(s2)
PY
}
mutate_ev() {  # mutate_ev <dir> <python statements over ev>
  python3 - "$1/docs/media/agentic-netops-srl-intent-tier-demo-evidence.json" "$2" <<'PY'
import json, sys
p = sys.argv[1]
ev = json.load(open(p))
exec(sys.argv[2])
open(p, "w").write(json.dumps(ev, indent=1))
PY
}

expect() {  # expect <name> <dir> <rc> <check-regex>
  local name="$1" d="$2" want="$3" rx="$4" out rc
  out="$(bash "$VR" --root "$d" --no-cluster 2>&1)"; rc=$?
  if [[ "$rc" -eq "$want" ]] && grep -qE -- "$rx" <<<"$out"; then pass "$name"; else fail "$name (rc=$rc want $want, /$rx/)" "$out"; fi
}

# good: passes and REPORTS the placeholder
d=$(plant good)
expect "good tree passes and reports the placeholder" "$d" 0 '^REPORT \[placeholder\] README.md:[0-9]+:'
expect "good tree names verify-readme PASS" "$d" 0 'verify-readme: PASS'

d=$(plant asset); mutate "$d" README.md 's.replace("<!-- ASSET-URL-PLACEHOLDER: the operator uploads the 6x cut as a GitHub asset and replaces this line -->", "https://github.com/user-attachments/assets/1568c5d4-9a05-4028-9c70-200ce6b6cd2b")'
out="$(bash "$VR" --root "$d" --no-cluster 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && ! grep -q 'REPORT \[placeholder\]' <<<"$out"; then pass "asset URL supplied: passes, nothing reported"; else fail "asset URL supplied" "$out"; fi
d=$(plant noasset); mutate "$d" README.md 's.replace("<!-- ASSET-URL-PLACEHOLDER: the operator uploads the 6x cut as a GitHub asset and replaces this line -->", "")'
expect "neither placeholder nor asset URL fails" "$d" 1 'FAIL \[placeholder\]'

# sections
d=$(plant swap); mutate "$d" README.md 's.replace("## What you get", "## TMP").replace("## Prerequisites", "## What you get").replace("## TMP", "## Prerequisites")'
expect "sections out of order fail" "$d" 1 'FAIL \[sections\] README.md: ## sections'
d=$(plant nosrl); mutate "$d" README.md 's.replace("[![SR Linux]", "[![Platform]")'
expect "badge row 1 without SR Linux fails" "$d" 1 "FAIL \[sections\].*lacks 'SR Linux'"
d=$(plant ciabsent); rm "$d/.github/workflows/ci.yaml"
expect "CI badge for an absent workflow fails" "$d" 1 'FAIL \[sections\].*CI badge for workflow ci.yaml'
d=$(plant mq); mutate "$d" README.md 's.replace("[![SR Linux]", "[![Mergify](https://img.shields.io/endpoint.svg?url=https://api.mergify.com/v1/badges/o/agentic-netops-srl)](https://mergify.com)\n[![SR Linux]", 1)'
expect "a merge-queue badge with no queue configured fails" "$d" 1 'FAIL \[sections\].*merge-queue badge'
printf 'queue_rules:\n  - name: default\n' >"$d/.mergify.yml"
expect "a merge-queue badge with .mergify.yml queue_rules passes" "$d" 0 'verify-readme: PASS'
d=$(plant srv6); mutate "$d" README.md 's.replace("| Fabric | 2 spines, 2 leaves |", "| Fabric | 2 spines, 2 leaves |\n| SRv6 | services |")'
expect "an SRv6 row in What you get fails" "$d" 1 'FAIL \[sections\].*SRv6 row'
d=$(plant profile); mutate "$d" README.md 's.replace("--cluster-name agentic-netops\nmake", "--cluster-name agentic-netops --profile x\nmake")'
expect "--profile in Quickstart fails" "$d" 1 'FAIL \[sections\].*--profile'
d=$(plant nofig); mutate "$d" README.md 's.replace("![Operator console](docs/images/agent-ui.png)\n", "")'
expect "a missing figure embed fails" "$d" 1 'FAIL \[sections\].*The lab embeds'

# links
d=$(plant deadlink); mutate "$d" README.md 's.replace("Host requirements.", "Host requirements in [deps](docs/DEPENDENCIES.md).")'
expect "a dead relative link fails" "$d" 1 'FAIL \[links\] README.md:[0-9]+: docs/DEPENDENCIES.md does not resolve'
d=$(plant noimg); rm "$d/docs/images/agent-ui-outcome.png"
expect "a missing image file fails" "$d" 1 'FAIL \[links\].*agent-ui-outcome.png does not resolve'

# versions
d=$(plant ver); mutate "$d" README.md 's.replace("Host requirements.", "Host requirements: containerlab 0.71.0.")'
expect "a version the lock does not carry fails" "$d" 1 "FAIL \[versions\].*'0.71.0'"
d=$(plant badgever); mutate "$d" README.md 's.replace("SR%20Linux-25.7.1-blue", "SR%20Linux-25.3.2-blue")'
expect "a badge with another version fails" "$d" 1 "FAIL \[versions\].*'25.3.2'"
d=$(plant digest); mutate "$d" README.md 's.replace("Host requirements.", "Image sha256:" + "a"*64 + ".")'
expect "a digest not in the lock fails" "$d" 1 'FAIL \[versions\].*digest sha256:aaaa'

# facts
d=$(plant mtu); mutate "$d" README.md 's.replace("Jumbo MTU 9412", "Jumbo MTU 9216")'
expect "the predecessor MTU in place of 9412 fails" "$d" 1 "FAIL \[facts\].*'9412'"
d=$(plant noipv6); mutate "$d" README.md 's.replace("- IPv6 anycast gateway and IPv6 Type-5 origination are gate items.\n", "")'
expect "no IPv6 anycast-gateway limitation fails" "$d" 1 'FAIL \[facts\].*IPv6 anycast-gateway'

# denylist
for t in "SONiC" "vtysh" "latest" "raw.githubusercontent.com" "VPLS"; do
  d=$(plant "deny-$t"); mutate "$d" README.md "s.replace('Host requirements.', 'Host requirements $t.')"
  expect "deny-list: $t fails" "$d" 1 "FAIL \[denylist\] README.md:[0-9]+:"
done
d=$(plant hist); mutate "$d" README.md 's.replace("Host requirements.", "Host requirements.\n\n<!-- history -->\nHistory: the predecessor ran SONiC.\n<!-- /history -->")'
expect "a predecessor term in a labelled history block passes" "$d" 0 'verify-readme: PASS'
d=$(plant alt); mutate "$d" README.md 's.replace("![Operator console]", "![Operator console, password: hunter22]")'
expect "a credential in a figure alt text fails" "$d" 1 'FAIL \[denylist\].*alt text'
d=$(plant evcred); mutate_ev "$d" 'ev["closing_listing"] = "Authorization: Basic b3BlcmF0b3I6aHVudGVyMg=="'
expect "a credential in the evidence file fails" "$d" 1 'FAIL \[denylist\].*evidence file'

# evidence
d=$(plant noev); rm "$d/docs/media/agentic-netops-srl-intent-tier-demo-evidence.json"
expect "no evidence file fails" "$d" 1 'FAIL \[evidence\].*missing'
d=$(plant accfalse); mutate_ev "$d" 'ev["accept_pass"] = False'
expect "accept_pass false fails" "$d" 1 'FAIL \[evidence\].*accept_pass'
d=$(plant failures); mutate_ev "$d" 'ev["failures"] = ["A Ready=True: False"]'
expect "failures non-empty fails" "$d" 1 'FAIL \[evidence\].*failures is not empty'
d=$(plant nfr013); mutate_ev "$d" 'del ev["run"]["cluster"]["uid"]'
expect "an NFR-013 field missing fails" "$d" 1 'FAIL \[evidence\].*run.cluster.uid'

# prompts
d=$(plant byte); mutate_ev "$d" 'ev["prompts"][1]["prompt"] = ev["prompts"][1]["prompt"] + " "'
expect "a prompt one byte off DEMO_VIDEO.md fails" "$d" 1 'FAIL \[prompts\].*byte for byte'
d=$(plant order); mutate_ev "$d" 'ev["prompts"] = [ev["prompts"][1], ev["prompts"][0], ev["prompts"][2]]'
expect "prompts reordered fail" "$d" 1 'FAIL \[prompts\]'

# principal
d=$(plant principal); mutate_ev "$d" 'ev["prompts"][2]["principal"] = "admin"'
expect "a Network principal not the generated username fails" "$d" 1 'FAIL \[principal\].*C: Network migr-c'

# timings
d=$(plant minutes); mutate "$d" README.md 's.replace("~6 min", "~9 min")'
expect "a Demo duration not the take's / 6 fails" "$d" 1 'FAIL \[timings\].*~9 min'
d=$(plant secs); mutate "$d" README.md 's.replace("took 212.4 s", "took 99 s")'
expect "a seconds figure the evidence did not measure fails" "$d" 1 "FAIL \[timings\].*'99 s'"

# quickstart
d=$(plant qs); mutate "$d" README.md 's.replace("make verify-fabric-control-plane   # the fabric converged", "make verify-everything")'
expect "a Quickstart command quickstart.md does not carry fails" "$d" 1 "FAIL \[quickstart\].*make verify-everything"

if ((fails)); then echo "verify_readme_test: $fails case(s) failed"; exit 1; fi
echo "verify_readme_test: all cases passed"
