#!/usr/bin/env bash
# infra_libs_test.sh — scripts/lib/{docker_net,kind,containerlab}.sh: idempotent and
# ownership-checked (T034; FR-008, FR-010, FR-108). Offline: tests/unit/lifecycle/fakes.sh.
#
# Asserts: the management network is created labelled on MGMT_CIDR with the dynamic range kept off
# the fixed lab addresses, a re-run changes nothing, an unowned or mis-sized one is refused; the
# cluster is created from config/kind/cluster.yaml with its name and ownership label rendered, not
# recreated on a re-run, an unowned one refused, every node attached once; the lab deploys onto
# the owned network with the ownership label and MGMT prefix exported, a re-run is a no-op, a
# partial lab is reconfigured, an unowned container refused; the gNMI wait is a credential-less
# accept of 57400 on the four devices, bounded; no device client appears in the libraries.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=fakes.sh
source "$ROOT/tests/unit/lifecycle/fakes.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; [[ -n "${out:-}" ]] && printf '%s\n' "$out" | tail -n 12 | sed 's/^/    | /'; fi; }
ORIG_PATH="$PATH"
CL=agentic-netops NET=agentic-netops-mgmt LAB=agentic-netops-fabric

setup() {
  W="$T/$1"; rm -rf "$W"; mkdir -p "$W"
  fakes::install "$W"
  export FAKE_STATE="$W/state" PATH="$W/bin:$ORIG_PATH" CLUSTER_NAME="$CL" CLAB_LABDIR_BASE="$W/labdir"
  unset MGMT_CIDR CLAB_MGMT_PREFIX FAKE_CURRENT_CONTEXT FAKE_KIND_CONFIG_COPY CONTAINERLAB_ACCEPT_PROBE || true
}
run_lib() { # <lib> <cmd…> — in a subshell; sets rc/out
  local lib="$1"; shift
  : >"$FAKE_STATE/calls.log"
  set +e
  out="$( ( source "$ROOT/scripts/lib/$lib.sh"; "$@" ) 2>&1 )"
  rc=$?
  set -e
}
calls() { cat "$FAKE_STATE/calls.log"; }
netj() { cat "$FAKE_STATE/docker/networks/$NET.json"; }

# ------------------------------------------------------------------ docker_net
setup net
run_lib docker_net docker_net::ensure "$NET" 172.25.25.0/24
check "net: created" '[[ $rc -eq 0 && -f "$FAKE_STATE/docker/networks/$NET.json" ]]'
check "net: labelled agentic-netops.io/owned-by=<cluster>" '[[ "$(netj | jq -r ".Labels[\"agentic-netops.io/owned-by\"]")" == "$CL" ]]'
check "net: on MGMT_CIDR, gateway .1, dynamic range the upper half (off .11–.32)" \
  'calls | grep -q -- "--subnet 172.25.25.0/24 --gateway 172.25.25.1 --ip-range 172.25.25.128/25"'
check "net: no MTU option is set (R-12)" '! calls | grep -qi mtu'
run_lib docker_net docker_net::ensure "$NET" 172.25.25.0/24
check "net: re-run is a no-op" '[[ $rc -eq 0 ]] && ! calls | grep -q "network create"'
run_lib docker_net docker_net::ensure "$NET" 172.26.0.0/24
check "net: an owned network on another CIDR is refused naming it" '[[ $rc -ne 0 ]] && grep -q "exists on .172.25.25.0/24." <<<"$out"'
setup net-foreign
fakes::network "$NET" 172.25.25.0/24 -
run_lib docker_net docker_net::ensure "$NET" 172.25.25.0/24
check "net: an unowned network of the name is refused, not adopted" '[[ $rc -ne 0 ]] && ! calls | grep -q "network create"'
run_lib docker_net docker_net::remove "$NET"
check "net: remove refuses an unowned network" '[[ $rc -ne 0 && -f "$FAKE_STATE/docker/networks/$NET.json" ]]'
setup net-remove
fakes::network "$NET" 172.25.25.0/24 "$CL"
fakes::container other-thing x linux -
docker network connect "$NET" other-thing
run_lib docker_net docker_net::remove "$NET"
check "net: remove refuses while containers are attached, naming them" '[[ $rc -ne 0 ]] && grep -q "other-thing" <<<"$out" && ! calls | grep -q "network disconnect"'
setup net-remove2
fakes::network "$NET" 172.25.25.0/24 "$CL"
run_lib docker_net docker_net::remove "$NET"
check "net: remove deletes the owned network" '[[ $rc -eq 0 && ! -f "$FAKE_STATE/docker/networks/$NET.json" ]]'
run_lib docker_net docker_net::remove "$NET"
check "net: remove of an absent network is success" '[[ $rc -eq 0 ]] && ! calls | grep -q "network rm"'
run_lib docker_net docker_net::ensure "$NET" 10.1.0.0/16
check "net: a /16 gets the upper-half dynamic range" '[[ $rc -eq 0 ]] && calls | grep -q -- "--gateway 10.1.0.1 --ip-range 10.1.128.0/17"'

# ------------------------------------------------------------------ kind
setup kind
export FAKE_KIND_CONFIG_COPY="$W/rendered.yaml" FAKE_CURRENT_CONTEXT=kind-agentflow-005
run_lib kind kind::ensure_cluster "$CL"
check "kind: created" '[[ $rc -eq 0 && -f "$FAKE_STATE/kind/$CL" ]]'
check "kind: from the declarative config (pinned node image by digest)" \
  'grep -q "image: docker.io/kindest/node:v1.32.2@sha256:f226345927d7e348497136874b6d207e0b32cc52154ad8323129352923a3142f" "$W/rendered.yaml"'
check "kind: the operator's previous kubectl context is restored" 'calls | grep -q "kubectl config use-context kind-agentflow-005"'
run_lib kind kind::ensure_cluster "$CL"
check "kind: re-run does not recreate" '[[ $rc -eq 0 ]] && ! calls | grep -q "create cluster"'
run_lib kind kind::ensure_cluster agentic-netops-b
check "kind: --cluster-name renders name and ownership label" \
  '[[ $rc -eq 0 ]] && grep -q "^name: agentic-netops-b$" "$W/rendered.yaml" && grep -q "agentic-netops.io/owned-by: agentic-netops-b$" "$W/rendered.yaml"'
fakes::network "$NET" 172.25.25.0/24 "$CL"
run_lib kind kind::attach_mgmt "$CL" "$NET"
check "kind: every node attached to the management network" \
  '[[ $rc -eq 0 ]] && jq -e ".Containers[\"$CL-control-plane\"]" "$FAKE_STATE/docker/networks/$NET.json" >/dev/null'
run_lib kind kind::attach_mgmt "$CL" "$NET"
check "kind: attach is idempotent" '[[ $rc -eq 0 ]] && ! calls | grep -q "network connect"'
run_lib kind kind::isolate_dns "$CL"
check "kind: isolate_dns strips the host search domain, keeps nameserver and options" \
  '[[ $rc -eq 0 ]] && ! grep -q "^search" "$FAKE_STATE/docker/resolv/$CL-control-plane" && grep -q "^nameserver 172.30.0.1$" "$FAKE_STATE/docker/resolv/$CL-control-plane" && grep -q "^options ndots:0$" "$FAKE_STATE/docker/resolv/$CL-control-plane"'
check "kind: isolate_dns restarts CoreDNS after a change" 'calls | grep -q "rollout restart deployment/coredns"'
run_lib kind kind::isolate_dns "$CL"
check "kind: isolate_dns is idempotent (no rewrite, no restart)" \
  '[[ $rc -eq 0 ]] && ! calls | grep -q "sh -c cat > /etc/resolv.conf" && ! calls | grep -q "rollout restart"'
setup kind-foreign
fakes::cluster "$CL" -
run_lib kind kind::ensure_cluster "$CL"
check "kind: an existing unowned cluster is refused" '[[ $rc -ne 0 ]] && grep -q "Kind cluster $CL: not owned" <<<"$out"'
run_lib kind kind::delete_cluster "$CL"
check "kind: delete refuses an unowned cluster" '[[ $rc -ne 0 && -f "$FAKE_STATE/kind/$CL" ]] && ! calls | grep -q "delete cluster"'
fakes::network "$NET" 172.25.25.0/24 -
run_lib kind kind::attach_mgmt "$CL" "$NET"
check "kind: attach refuses an unowned network" '[[ $rc -ne 0 ]] && ! calls | grep -q "network connect"'
setup kind-nocontext
fakes::cluster "$CL" "$CL"
touch "$FAKE_STATE/kind/$CL.nocontext"   # kind create interrupted before the kubeconfig was written
export FAKE_CURRENT_CONTEXT=kind-agentflow-005
run_lib kind kind::delete_cluster "$CL"
check "kind: an owned cluster whose context was never written is read after re-exporting it" \
  '[[ $rc -eq 0 && ! -f "$FAKE_STATE/kind/$CL" ]] && calls | grep -q "kind export kubeconfig --name $CL"'
check "kind: the re-export restores the operator's previous context" 'calls | grep -q "kubectl config use-context kind-agentflow-005"'
setup kind-nocontext-foreign
fakes::cluster "$CL" -
touch "$FAKE_STATE/kind/$CL.nocontext"
run_lib kind kind::delete_cluster "$CL"
check "kind: re-exporting the context of an unowned cluster still refuses it (label decides)" \
  '[[ $rc -ne 0 && -f "$FAKE_STATE/kind/$CL" ]] && ! calls | grep -q "delete cluster"'
setup kind-delete
fakes::cluster "$CL" "$CL"
run_lib kind kind::delete_cluster "$CL"
check "kind: delete removes the owned cluster" '[[ $rc -eq 0 && ! -f "$FAKE_STATE/kind/$CL" ]]'
run_lib kind kind::delete_cluster "$CL"
check "kind: delete of an absent cluster is success" '[[ $rc -eq 0 ]] && ! calls | grep -q "delete cluster"'

# ------------------------------------------------------------------ containerlab
setup clab
run_lib containerlab containerlab::deploy
check "clab: deploy without the management network is refused (NetworkReady not met)" '[[ $rc -ne 0 ]] && ! calls | grep -q "containerlab deploy"'
fakes::network "$NET" 172.25.25.0/24 "$CL"
run_lib containerlab containerlab::deploy
check "clab: deploys the topology" '[[ $rc -eq 0 ]] && calls | grep -q "containerlab deploy -t $ROOT/lab/topology.clab.yml$"'
check "clab: six containers, all labelled for this cluster" \
  '[[ "$(ls "$FAKE_STATE"/docker/containers/clab-$LAB-*.json | wc -l)" -eq 6 ]] && [[ "$(jq -r ".Config.Labels[\"agentic-netops.io/owned-by\"]" "$FAKE_STATE"/docker/containers/clab-$LAB-*.json | sort -u)" == "$CL" ]]'
run_lib containerlab containerlab::deploy
check "clab: re-run is a no-op" '[[ $rc -eq 0 ]] && ! calls | grep -q "containerlab deploy"'
rm -f "$FAKE_STATE/docker/containers/clab-$LAB-leaf02.json"
run_lib containerlab containerlab::deploy
check "clab: a partial lab is redeployed with --reconfigure" '[[ $rc -eq 0 ]] && calls | grep -q "containerlab deploy .*--reconfigure"'
fakes::container "clab-$LAB-leaf02" "$LAB" nokia_srlinux -
run_lib containerlab containerlab::deploy
check "clab: an unowned lab container is refused, nothing redeployed" '[[ $rc -ne 0 ]] && ! calls | grep -q "containerlab deploy"'
run_lib containerlab containerlab::destroy
check "clab: destroy refuses when a lab container is unowned" '[[ $rc -ne 0 ]] && ! calls | grep -q "containerlab destroy"'

setup clab-cidr
fakes::network "$NET" 10.77.3.0/24 "$CL"
( export MGMT_CIDR=10.77.3.0/24
  run_lib containerlab containerlab::deploy
  [[ $rc -eq 0 ]] && jq -e '.NetworkSettings.Networks["agentic-netops-mgmt"].IPAddress == "10.77.3.21"' \
    "$FAKE_STATE/docker/containers/clab-$LAB-leaf01.json" >/dev/null ) \
  && ok "clab: MGMT_CIDR moves the fixed addresses (CLAB_MGMT_PREFIX exported)" \
  || bad "clab: MGMT_CIDR moves the fixed addresses (CLAB_MGMT_PREFIX exported)"
out="$(MGMT_CIDR=10.77.3.0/24 bash -c "source '$ROOT/scripts/lib/containerlab.sh'; containerlab::device_addresses")"
check "clab: device addresses are .11/.12 spines, .21/.22 leaves of MGMT_CIDR" \
  '[[ "$out" == $'"'"'spine01 10.77.3.11\nspine02 10.77.3.12\nleaf01 10.77.3.21\nleaf02 10.77.3.22'"'"' ]]'

# accept wait
printf '#!/usr/bin/env bash\necho "$1:$2" >>"$FAKE_STATE/probed"\nexit 0\n' >"$W/bin/probe-ok"
printf '#!/usr/bin/env bash\necho "$1:$2" >>"$FAKE_STATE/probed"\n[[ "$1" != *.22 ]]\n' >"$W/bin/probe-leaf02-down"
chmod +x "$W/bin"/probe-*
run_lib containerlab env CONTAINERLAB_ACCEPT_PROBE="$W/bin/probe-ok" bash -c "source '$ROOT/scripts/lib/containerlab.sh'; containerlab::wait_gnmi_accept 5"
check "wait: all four devices accept on 57400 → success" \
  '[[ $rc -eq 0 ]] && [[ "$(sort -u "$FAKE_STATE/probed" | tr "\n" " ")" == "172.25.25.11:57400 172.25.25.12:57400 172.25.25.21:57400 172.25.25.22:57400 " ]]'
run_lib containerlab env CONTAINERLAB_ACCEPT_PROBE="$W/bin/probe-leaf02-down" CONTAINERLAB_GNMI_INTERVAL=1 bash -c "source '$ROOT/scripts/lib/containerlab.sh'; containerlab::wait_gnmi_accept 2"
check "wait: bounded — a device that never accepts fails naming it" '[[ $rc -ne 0 ]] && grep -q "leaf02 (172.25.25.22:57400) does not accept yet" <<<"$out"'
# the real probe against a local listener: a bare TCP accept, no client, no credentials
if command -v python3 >/dev/null 2>&1; then
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  python3 -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1',$port)); s.listen(5); time.sleep(4)" &
  lp=$!
  sleep 0.5
  set +e
  bash -c "source '$ROOT/scripts/lib/containerlab.sh'; containerlab::accept_probe 127.0.0.1 $port"; r1=$?
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  bash -c "source '$ROOT/scripts/lib/containerlab.sh'; containerlab::accept_probe 127.0.0.1 $port"; r2=$?
  set -e
  check "probe: the built-in accept probe succeeds on a listening port" '[[ $r1 -eq 0 ]]'
  check "probe: and fails on a closed one" '[[ $r2 -ne 0 ]]'
fi

setup clab-destroy
fakes::network "$NET" 172.25.25.0/24 "$CL"
run_lib containerlab containerlab::deploy
run_lib containerlab containerlab::destroy
check "clab: destroy removes the owned lab and its directory" \
  '[[ $rc -eq 0 ]] && ! ls "$FAKE_STATE/docker/containers" | grep -q clab- && [[ ! -e "$CLAB_LABDIR_BASE/clab-$LAB" ]]'
run_lib containerlab containerlab::destroy
check "clab: destroy of an absent lab is success" '[[ $rc -eq 0 ]] && ! calls | grep -q "containerlab destroy"'

# ------------------------------------------------------------------ static
check "static: no device client or device session in the libraries (FR-108)" \
  '! grep -nE "(^|[[:space:];|&(])(gnmic|gnmi_cli|sr_cli|sshpass)([[:space:]]|$)|docker[^#]*exec[^#]*clab-|s_client" "$ROOT"/scripts/lib/{preflight,docker_net,kind,containerlab,lab_secrets}.sh | grep -vE "^[^:]+:[0-9]+:[[:space:]]*#"'
check "static: the topology never sets a management MTU" '! grep -nE "^[[:space:]]*mtu:" "$ROOT/lab/topology.clab.yml"'
check "static: every client MTU is 9348 in setup.sh" 'grep -q "CLIENT_MTU:-9348" "$ROOT/lab/clients/setup.sh"'

printf '\ninfra_libs_test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
