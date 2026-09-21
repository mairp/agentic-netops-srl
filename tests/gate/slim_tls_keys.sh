#!/usr/bin/env bash
# tests/gate/slim_tls_keys.sh — T166: the TLS and client-CA key names the PINNED transport gateway
# (ghcr.io/agntcy/slim, versions.lock.yaml platform.slim) accepts for a cert-bearing server, and
# whether client-certificate verification is exposed at all (research Open item 13, D-28, R-14).
# R-14's fallback (server-side TLS + gateway password + NetworkPolicy) is RECORDED when client-CA
# verification is not exposed, never assumed either way.
#
# A throwaway Pod of the pinned image in the gate-labelled scratch namespace vt-scratch-slim-tls,
# started with a cert-bearing server config written with the key names the pinned release's
# source declares (data-plane core/config tls server: cert_file, key_file, client_ca_file). A
# throwaway CA, server and client certificate are made with openssl on the host (under /tmp; no
# credential of the platform). Then, through a port-forward, openssl s_client observes:
#   - the server presents the configured certificate  ⇒ cert_file / key_file are the accepted names
#   - a client WITHOUT a certificate is refused, one WITH a CA-signed certificate is accepted
#                                                     ⇒ client_ca_file is honoured: verification exposed
# The namespace and the Pod are removed and the removal read back.
# Writes $EVIDENCE_DIR/gate/qualifications/slim_tls_keys.json. The qualification passes when the
# observation was made; what it observed is data (published in the qualification record).
set -euo pipefail
GATE_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gate.sh
source "$GATE_HERE/lib/gate.sh"
evidence::ensure_dir
mkdir -p "$EVIDENCE_DIR/gate/qualifications" "$EVIDENCE_DIR/gate/manifests"
GATE_ITEM=SLIM
NS="vt-scratch-slim-tls"
OUT="$EVIDENCE_DIR/gate/qualifications/slim_tls_keys.json"
PORT=46357
KEY_CERT=cert_file; KEY_KEY=key_file; KEY_CA=client_ca_file
TMPD="$(mktemp -d)"; chmod 700 "$TMPD"
PF_PID=""
cleanup() {
  if [[ -n "$PF_PID" ]]; then kill "$PF_PID" 2>/dev/null || true; fi
  rm -rf "$TMPD"
}
trap cleanup EXIT

IMG="$(gate::lock_image platform.slim.pinned)"

# throwaway PKI (openssl on the host)
( cd "$TMPD"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=vt-scratch-slim-ca" -keyout ca.key -out ca.pem 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=vt-scratch-slim" -keyout server.key -out server.csr 2>/dev/null
  printf 'subjectAltName=DNS:vt-scratch-slim,DNS:localhost,IP:127.0.0.1\n' >san.ext
  openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 1 -extfile san.ext -out server.pem 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=vt-scratch-slim-client" -keyout client.key -out client.csr 2>/dev/null
  openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 1 -out client.pem 2>/dev/null ) || {
  jq -n '{name: "slim_tls_keys", status: "fail", reason: "openssl could not make the throwaway PKI on the host"}' >"$OUT"; exit 1; }

MF="$(gate::manifest slim-tls.yaml)"
cat >"$MF" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels: {${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}", agentic-netops.io/owned-by: "${CLUSTER_NAME}"}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: vt-scratch-slim-config, namespace: ${NS}, labels: {${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}}
data:
  config.yaml: |
    tracing:
      log_level: debug
    runtime:
      n_cores: 0
      drain_timeout: 10s
    services:
      slim/0:
        dataplane:
          servers:
          - endpoint: "0.0.0.0:${PORT}"
            tls:
              ${KEY_CERT}: /tls/server.pem
              ${KEY_KEY}: /tls/server.key
              ${KEY_CA}: /tls/ca.pem
          clients: []
---
apiVersion: v1
kind: Pod
metadata: {name: vt-scratch-slim, namespace: ${NS}, labels: {app: vt-scratch-slim, ${LAB_GATE_LABEL_KEY}: "${LAB_GATE_LABEL_VALUE}"}}
spec:
  restartPolicy: Never
  containers:
  - name: slim
    image: ${IMG}
    command: ["/slim"]
    args: ["--config", "/config/config.yaml"]
    ports: [{containerPort: ${PORT}}]
    volumeMounts:
    - {name: cfg, mountPath: /config}
    - {name: tls, mountPath: /tls}
  volumes:
  - {name: cfg, configMap: {name: vt-scratch-slim-config}}
  - {name: tls, secret: {secretName: vt-scratch-slim-tls}}
YAML

status=pass; reason=""; started=false
gate::run SLIM.apply --attach gate/manifests/slim-tls.yaml -- lab::kubectl apply -f "$MF" >/dev/null || { status=fail; reason="apply failed"; }
# the TLS material as a Secret: file paths on argv, never their content
gate::run SLIM.tls-secret -- lab::kubectl -n "$NS" create secret generic vt-scratch-slim-tls \
  --from-file=server.pem="$TMPD/server.pem" --from-file=server.key="$TMPD/server.key" --from-file=ca.pem="$TMPD/ca.pem" >/dev/null || { status=fail; reason="secret failed"; }
if gate::run SLIM.ready -- lab::kubectl -n "$NS" wait --for=condition=Ready pod/vt-scratch-slim --timeout=180s >/dev/null 2>&1; then
  started=true
fi
sleep 5
logs="$(gate::run SLIM.logs -- lab::kubectl -n "$NS" logs vt-scratch-slim --tail=200 2>/dev/null || true)"
phase="$(lab::kubectl -n "$NS" get pod vt-scratch-slim -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)"

presented=false; nocert="not-observed"; withcert="not-observed"
if [[ "$started" == true && "$phase" == Running ]]; then
  lp=$((20000 + RANDOM % 20000))
  lab::kubectl -n "$NS" port-forward pod/vt-scratch-slim "${lp}:${PORT}" >"$TMPD/pf.log" 2>&1 &
  PF_PID=$!
  sleep 4
  a="$(gate::run SLIM.handshake-no-client-cert -- sh -c "echo | timeout 10 openssl s_client -connect 127.0.0.1:${lp} -servername vt-scratch-slim -alpn h2 -CAfile '$TMPD/ca.pem' -showcerts 2>&1; true" 2>/dev/null || true)"
  b="$(gate::run SLIM.handshake-client-cert -- sh -c "echo | timeout 10 openssl s_client -connect 127.0.0.1:${lp} -servername vt-scratch-slim -alpn h2 -CAfile '$TMPD/ca.pem' -cert '$TMPD/client.pem' -key '$TMPD/client.key' 2>&1; true" 2>/dev/null || true)"
  grep -qE 'subject=.*CN *= *vt-scratch-slim([^-]|$)' <<<"$a" && presented=true
  if grep -qiE 'alert (certificate required|handshake failure|bad certificate)|certificate required|peer did not return a certificate' <<<"$a"; then nocert=refused
  elif grep -q 'Verify return code: 0' <<<"$a"; then nocert=accepted
  else nocert=unclear; fi
  if grep -q 'Verify return code: 0' <<<"$b" && ! grep -qiE 'alert (certificate required|handshake failure|bad certificate)' <<<"$b"; then withcert=accepted
  else withcert=refused; fi
else
  status=fail; reason="the pinned slim Pod did not run with the cert-bearing config (phase ${phase}); see SLIM.logs"
fi

# removal, read back
gate::run SLIM.teardown -- lab::kubectl delete namespace "$NS" --wait=true --timeout=180s >/dev/null 2>&1 || true
removed=false; gate::wait_ns_gone "$NS" 180 >/dev/null 2>&1 && removed=true
[[ "$removed" == true ]] || { status=fail; reason="${reason:+$reason; }scratch namespace $NS not removed"; }

exposed=false
[[ "$nocert" == refused && "$withcert" == accepted ]] && exposed=true
jq -n --arg s "$status" --arg r "$reason" --arg img "$IMG" --argjson started "$started" --argjson p "$presented" \
  --arg nc "$nocert" --arg wc "$withcert" --argjson e "$exposed" --argjson rm "$removed" \
  --arg kc "$KEY_CERT" --arg kk "$KEY_KEY" --arg ka "$KEY_CA" \
  --arg logerr "$(grep -iE 'error|unknown field|invalid' <<<"$logs" | head -5 || true)" '
  {name: "slim_tls_keys", status: $s, reason: (if $r == "" then null else $r end), image: $img,
   config_keys_tried: {server_certificate: $kc, server_key: $kk, client_ca: $ka},
   server_started_with_tls_config: $started,
   server_presented_configured_certificate: $p,
   accepted_key_names: (if $started and $p then {server_certificate: $kc, server_key: $kk} else {} end
                        + (if $e then {client_ca: $ka} else {} end)),
   client_without_certificate: $nc, client_with_ca_signed_certificate: $wc,
   client_certificate_verification_exposed: $e,
   r14_fallback: (if $e then null else "server-side TLS + gateway password + NetworkPolicy (R-14): client-CA verification not observed on the pinned release" end),
   log_errors: ($logerr | split("\n") | map(select(length > 0))),
   scratch_namespace_removed: $rm}' >"$OUT"
log::info "[SLIM] started=$started presented=$presented no-client-cert=$nocert with-client-cert=$withcert exposed=$exposed removed=$removed"
[[ "$status" == pass ]]
