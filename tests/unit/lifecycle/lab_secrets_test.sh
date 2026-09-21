#!/usr/bin/env bash
# lab_secrets_test.sh — scripts/lib/lab_secrets.sh against a fake kubectl (T037; FR-019, FR-096,
# AD-50). Offline: tests/unit/lifecycle/fakes.sh.
#
# Asserts: srl-credentials in sdc-system (username/password/ca from the containerlab CA); namespace
# monitoring created with the ownership label; the collector's copy in monitoring; grafana-admin
# with a generated (non-default, >= 24 char) password preserved across re-runs; every object
# labelled; no credential value in argv or the log; an unowned monitoring / Secret refused; the
# removal deletes exactly the owned objects and is idempotent.
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
CL=agentic-netops

setup() {
  W="$T/$1"; rm -rf "$W"; mkdir -p "$W"
  fakes::install "$W"
  export FAKE_STATE="$W/state" PATH="$W/bin:$ORIG_PATH" CLUSTER_NAME="$CL"
  unset KUBE_CONTEXT SRL_USER SRL_PASS GRAFANA_ADMIN_USER || true
  export LAB_SECRETS_CA_FILE="$W/ca.pem"
  printf -- '-----BEGIN CERTIFICATE-----\nTEFCLUNBLUZJWFRVUkU=\n-----END CERTIFICATE-----\n' >"$LAB_SECRETS_CA_FILE"
  fakes::cluster "$CL" "$CL"
  fakes::k8s "$CL" _ namespace sdc-system "$CL"
}
run_ls() { # <fn> [VAR=v…]
  local fn="$1"; shift
  : >"$FAKE_STATE/calls.log"
  set +e
  out="$( ( for kv in "$@"; do export "${kv?}"; done; source "$ROOT/scripts/lib/lab_secrets.sh"; "$fn" ) 2>&1 )"
  rc=$?
  set -e
}
obj() { printf '%s' "$FAKE_STATE/k8s/$CL/$1/$2/$3.json"; }  # <ns|_> <kind> <name>
b64d() { jq -r --arg k "$2" '.data[$k] // empty' "$1" | base64 -d; }
owner_of() { jq -r '.metadata.labels["agentic-netops.io/owned-by"] // ""' "$1"; }

# ------------------------------------------------------------------ ensure
setup fresh
run_ls lab_secrets::ensure
check "ensure: exits 0" '[[ $rc -eq 0 ]]'
S1="$(obj sdc-system secret srl-credentials)"
check "ensure: srl-credentials exists in sdc-system" '[[ -f "$S1" ]]'
check "ensure: username is the containerlab default (admin)" '[[ "$(b64d "$S1" username)" == admin ]]'
check "ensure: password is the containerlab default" '[[ "$(b64d "$S1" password)" == "NokiaSrl1!" ]]'
check "ensure: ca is the containerlab-generated CA PEM" '[[ "$(b64d "$S1" ca)" == "$(cat "$LAB_SECRETS_CA_FILE")" && "$(b64d "$S1" ca.crt)" == "$(cat "$LAB_SECRETS_CA_FILE")" ]]'
check "ensure: srl-credentials carries the ownership label" '[[ "$(owner_of "$S1")" == "$CL" ]]'
NS="$(obj _ namespace monitoring)"
check "ensure: namespace monitoring created" '[[ -f "$NS" ]]'
check "ensure: monitoring carries the ownership label" '[[ "$(owner_of "$NS")" == "$CL" ]]'
S2="$(obj monitoring secret srl-credentials)"
check "ensure: the collector copy exists in monitoring with the same credentials" \
  '[[ "$(b64d "$S2" username)" == admin && "$(b64d "$S2" password)" == "NokiaSrl1!" && "$(b64d "$S2" ca)" == "$(cat "$LAB_SECRETS_CA_FILE")" ]]'
G="$(obj monitoring secret grafana-admin)"
GP1="$(b64d "$G" admin-password)"
check "ensure: grafana-admin exists with admin-user" '[[ "$(b64d "$G" admin-user)" == admin ]]'
check "ensure: grafana-admin password is generated (>= 24 chars, not a default)" \
  '[[ ${#GP1} -ge 24 && "$GP1" != admin && "$GP1" != "NokiaSrl1!" && "$GP1" != prom-operator ]]'
check "ensure: every object is labelled" '[[ "$(owner_of "$S2")" == "$CL" && "$(owner_of "$G")" == "$CL" ]]'
check "ensure: applied server-side, never with a value in argv" \
  'grep -q "apply --server-side" "$FAKE_STATE/calls.log" && ! grep -Fq "NokiaSrl1!" "$FAKE_STATE/calls.log" && ! grep -Fq "$GP1" "$FAKE_STATE/calls.log"'
check "ensure: no credential value in the log" '! grep -Fq "NokiaSrl1!" <<<"$out" && ! grep -Fq "$GP1" <<<"$out"'
check "ensure: the context is kind-<cluster>" '! grep -q "^kubectl " "$FAKE_STATE/calls.log" || ! grep -v -- "--context kind-$CL" "$FAKE_STATE/calls.log" | grep -q "^kubectl"'

run_ls lab_secrets::ensure
check "ensure (re-run): exits 0" '[[ $rc -eq 0 ]]'
check "ensure (re-run): the Grafana password is preserved, not rotated" '[[ "$(b64d "$(obj monitoring secret grafana-admin)" admin-password)" == "$GP1" ]]'

run_ls lab_secrets::ensure SRL_USER=labop SRL_PASS='S3cret!x'
check "ensure: SRL_USER / SRL_PASS override the defaults" \
  '[[ $rc -eq 0 && "$(b64d "$S1" username)" == labop && "$(b64d "$S1" password)" == "S3cret!x" && "$(b64d "$S2" password)" == "S3cret!x" ]]'

setup two
run_ls lab_secrets::ensure
GPA="$(b64d "$(obj monitoring secret grafana-admin)" admin-password)"
setup three
run_ls lab_secrets::ensure
GPB="$(b64d "$(obj monitoring secret grafana-admin)" admin-password)"
check "ensure: two fresh labs get different generated passwords" '[[ -n "$GPA" && "$GPA" != "$GPB" ]]'

# ------------------------------------------------------------------ refusals
setup no-ca
rm -f "$LAB_SECRETS_CA_FILE"
run_ls lab_secrets::ensure
check "refuse: a missing containerlab CA fails naming it" '[[ $rc -ne 0 ]] && grep -q "containerlab CA" <<<"$out"'
check "refuse: nothing was applied without the CA" '! grep -q " apply " "$FAKE_STATE/calls.log"'

setup no-sdc-ns
rm -f "$(obj _ namespace sdc-system)"
run_ls lab_secrets::ensure
check "refuse: no sdc-system namespace → fails naming AppsReady" '[[ $rc -ne 0 ]] && grep -q "sdc-system does not exist" <<<"$out"'

setup foreign-monitoring
fakes::k8s "$CL" _ namespace monitoring -
run_ls lab_secrets::ensure
check "refuse: an unowned monitoring namespace is never adopted" '[[ $rc -ne 0 ]] && grep -q "namespace/monitoring: not owned" <<<"$out"'
check "refuse: nothing written into the unowned monitoring" '[[ ! -f "$(obj monitoring secret grafana-admin)" && ! -f "$(obj monitoring secret srl-credentials)" ]]'

setup foreign-secret
fakes::k8s "$CL" sdc-system secret srl-credentials -
run_ls lab_secrets::ensure
check "refuse: an unowned srl-credentials is not overwritten" '[[ $rc -ne 0 ]] && [[ "$(owner_of "$(obj sdc-system secret srl-credentials)")" == "" ]]'

# ------------------------------------------------------------------ remove
setup remove
run_ls lab_secrets::ensure
fakes::k8s "$CL" monitoring secret someone-elses -
run_ls lab_secrets::remove
check "remove: exits 0" '[[ $rc -eq 0 ]]'
check "remove: the three Secrets are gone" \
  '[[ ! -f "$(obj sdc-system secret srl-credentials)" && ! -f "$(obj monitoring secret srl-credentials)" && ! -f "$(obj monitoring secret grafana-admin)" ]]'
check "remove: the owned monitoring namespace is gone" '[[ ! -f "$(obj _ namespace monitoring)" ]]'
check "remove: sdc-system itself is not this step's to delete" '[[ -f "$(obj _ namespace sdc-system)" ]]'
run_ls lab_secrets::remove
check "remove (re-run): success no-op" '[[ $rc -eq 0 ]] && ! grep -q " delete " "$FAKE_STATE/calls.log"'

setup remove-foreign
fakes::k8s "$CL" sdc-system secret srl-credentials -
run_ls lab_secrets::remove
check "remove: an unowned srl-credentials is refused and kept" '[[ $rc -ne 0 && -f "$(obj sdc-system secret srl-credentials)" ]]'

printf '\nlab_secrets_test: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
