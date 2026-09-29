#!/usr/bin/env bash
# port-forward hygiene suite (tests/lib/lab.sh lab::port_forward / lab::port_forward_stop;
# tests/integration/lib/obs.sh obs::_grafana_forward; tests/gate/slim_tls_keys.sh).
#
# The defect: observability_verify.sh started `kubectl port-forward svc/grafana 13301:3000` from
# inside $(…) (obs::dashboard) as a backgrounded function — a bash subshell with kubectl as its
# child, inheriting the caller's descriptors, its PID registered on an exit trap that lived in
# the $(…) subshell only. After the script exited the forward was still running and held the
# caller's stdout pipe, so a `| tee` upstream never saw EOF.
#
# Offline: a fake kubectl (a loopback HTTP server answering /api/health, as Grafana would, or a
# plain sleeper) records its PID. Each driver exits; the suite asserts
#   * a pipe reader downstream of the driver sees EOF promptly (well under the fake's lifetime);
#   * no port-forward process remains;
#   * the forward held none of the driver's descriptors beyond 0-2 (fd 3 is a dup of the pipe);
#   * obs.sh reuses one forward across $(…) calls.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 25 | sed 's/^/    /'; }

command -v python3 >/dev/null 2>&1 || { echo "port_forward_test: python3 is required"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "port_forward_test: curl is required"; exit 2; }

TMP="$(mktemp -d)"
# shellcheck disable=SC2317,SC2013  # invoked from the EXIT trap; PIDs are words
cleanup() {
  local p
  for p in $(cat "$TMP"/*.fakepids 2>/dev/null); do kill -KILL "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# the fake kubectl: records its PID and its open descriptors, then serves (http) or sleeps
mkdir -p "$TMP/bin"
cat >"$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$$" >>"${FAKE_PIDS:?}"
# No pipeline here: while bash builds `ls | sort | paste` this shell itself holds the pipe
# ends (3, 4, 5…), and ls would sometimes list THOSE as "inherited" — a race that failed CI.
# A plain command with its redirection applied in the child leaves this shell's table clean.
ls /proc/$$/fd >"${FAKE_FDS:?}.$$" 2>/dev/null
sort -n "${FAKE_FDS}.$$" | paste -sd' ' >>"${FAKE_FDS}"; rm -f "${FAKE_FDS}.$$"
port=""
for a in "$@"; do [[ "$a" =~ ^([0-9]+):[0-9]+$ ]] && port="${BASH_REMATCH[1]}"; done
if [[ "${FAKE_MODE:-sleep}" == http && -n "$port" ]]; then
  exec python3 -c '
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"[]" if self.path.startswith("/api/search") else b"{}"
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()' "$port"
fi
exec sleep 120
EOF
chmod +x "$TMP/bin/kubectl"

# run_piped <name> <driver> — runs the driver with its stdout into a pipe read by `cat`; prints
# the seconds until the reader saw EOF. Only the reader is capped (30 s) and the driver (60 s,
# --foreground: never its process group) — a leaked forward is left alive for the checks below.
run_piped() {
  local name="$1" drv="$2" t0 t1
  t0="$(date +%s.%N)"
  ( cd "$ROOT" && PATH="$TMP/bin:$PATH" KUBECTL="$TMP/bin/kubectl" CLUSTER_NAME=fake \
      FAKE_PIDS="$TMP/$name.fakepids" FAKE_FDS="$TMP/$name.fakefds" TMPDIR="$TMP" \
      bash -c "timeout --foreground 60 bash '$drv' 2>'$TMP/$name.err' | timeout 30 cat >'$TMP/$name.out'" )
  t1="$(date +%s.%N)"
  python3 -c "print(round($t1 - $t0, 1))"
}

check_run() {  # check_run <name> <secs> <max-secs> <expected forwards>
  local name="$1" secs="$2" max="$3" want="$4" p live="" n
  if python3 -c "import sys; sys.exit(0 if $secs < $max else 1)"; then
    pass "$name: the pipe reader saw EOF ${secs}s after the start (the fake would live 120s)"
  else
    fail "$name: the pipe reader saw EOF only after ${secs}s — a port-forward held the caller's pipe" "$(cat "$TMP/$name.err" 2>/dev/null)"
  fi
  n="$(wc -l <"$TMP/$name.fakepids" 2>/dev/null || echo 0)"
  if [[ "$n" -eq "$want" ]]; then pass "$name: ${n} port-forward(s) started"
  else fail "$name: ${n} port-forward(s) started, expected ${want}" "$(cat "$TMP/$name.err" 2>/dev/null)"; fi
  # shellcheck disable=SC2013
  for p in $(cat "$TMP/$name.fakepids" 2>/dev/null); do
    kill -0 "$p" 2>/dev/null && live+=" $p($(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | cut -c1-60))"
  done
  if [[ -z "$live" ]]; then pass "$name: no port-forward remains after the script exited"
  else fail "$name: port-forward(s) still running after the script exited:${live}"; fi
  # the fake's own descriptors (listed by its shell): 0 1 2, and 255 (bash's script fd, its own)
  local bad
  bad="$(awk '{for (i = 1; i <= NF; i++) if ($i > 2 && $i != 255) print $i}' "$TMP/$name.fakefds" 2>/dev/null | sort -u | paste -sd' ')"
  if [[ -z "$bad" ]]; then pass "$name: the port-forward inherited no descriptor beyond stdin/stdout/stderr"
  else fail "$name: the port-forward inherited descriptor(s) ${bad} ($(cat "$TMP/$name.fakefds"))"; fi
}

# ------------------------------------------------------------------ obs.sh, as observability_verify.sh runs it
# suite.sh + obs.sh sourced, the suite's exit trap, fd 3/4 dups of the caller's stdout (anything a
# sourced helper may hold), the dashboard read from inside $(…) twice (ov::gap_queries,
# topology_parity.sh) — the second call reuses the forward.
port="$(free_port)"
cat >"$TMP/drv-obs.sh" <<EOF
set -uo pipefail
source "$ROOT/tests/integration/lib/suite.sh"
source "$ROOT/tests/integration/lib/obs.sh"
trap 'suite::_exit \$?' EXIT
exec 3>&1 4>&1
OBS_GF_PORT=$port OBS_GF_USER=u OBS_GF_PASS=p
export OBS_GF_PORT OBS_GF_USER OBS_GF_PASS
a="\$(obs::grafana_api health)" || { echo "first read failed" >&2; exit 1; }
b="\$(obs::grafana_api "search?type=dash-db" | cat)" || { echo "second read failed" >&2; exit 1; }
d="\$(obs::dashboard 'collector.?health' 2>/dev/null)" || true
echo "reads: \$a \$b"
EOF
secs="$(FAKE_MODE=http run_piped obs "$TMP/drv-obs.sh")"
check_run obs "$secs" 15 1
if grep -q 'reads: {} \[\]' "$TMP/obs.out"; then pass "obs: the Grafana API was read through the forward from inside \$(…)"
else fail "obs: the Grafana API reads failed" "$(cat "$TMP/obs.out" "$TMP/obs.err")"; fi
if compgen -G "$TMP/obs-grafana-pf.*" >/dev/null; then fail "obs: the forward's registry/log left behind: $(ls "$TMP"/obs-grafana-pf.*)"
else pass "obs: the forward's registry and log removed on exit"; fi

# the same driver interrupted (TERM) while the forward runs: the trap still stops it
cat >"$TMP/drv-obs-term.sh" <<EOF
set -uo pipefail
source "$ROOT/tests/integration/lib/suite.sh"
source "$ROOT/tests/integration/lib/obs.sh"
trap 'suite::_exit \$?' EXIT
trap 'exit 143' TERM
exec 3>&1
OBS_GF_PORT=$port OBS_GF_USER=u OBS_GF_PASS=p
x="\$(obs::grafana_api health)"
kill -TERM \$\$
sleep 30
EOF
secs="$(FAKE_MODE=http run_piped obs-term "$TMP/drv-obs-term.sh")"
check_run obs-term "$secs" 15 1

# ------------------------------------------------------------------ the bare helper (slim_tls_keys.sh's use)
cat >"$TMP/drv-bare.sh" <<EOF
set -uo pipefail
source "$ROOT/tests/lib/lab.sh"
D="\$(mktemp -d)"
trap 'lab::port_forward_stop "\$D/pf.pids"; rm -rf "\$D"' EXIT
exec 5>&1
lab::port_forward "\$D/pf.pids" "\$D/pf.log" -n ns pod/p 20001:46357
# started from a subshell too: the registry file is shared
( lab::port_forward "\$D/pf.pids" "\$D/pf2.log" -n ns pod/p 20002:46357 )
sleep 1
echo started
EOF
secs="$(FAKE_MODE="sleep" run_piped bare "$TMP/drv-bare.sh")"
check_run bare "$secs" 10 2

# ------------------------------------------------------------------ no raw background port-forward left
raw="$(grep -rnE 'port-forward' "$ROOT/tests" "$ROOT/scripts" --include='*.sh' \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -E '&[[:space:]]*$|&[[:space:]]*#' | grep -v '/tests/unit/' || true)"
if [[ -z "$raw" ]]; then pass "no shell script backgrounds a raw 'port-forward … &' (lab::port_forward only)"
else fail "raw backgrounded port-forward(s) remain" "$raw"; fi

echo
if [[ "$fails" -eq 0 ]]; then echo "port_forward_test: all checks passed"; exit 0; fi
echo "port_forward_test: ${fails} check(s) failed"; exit 1
