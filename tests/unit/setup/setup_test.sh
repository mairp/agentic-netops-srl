#!/usr/bin/env bash
# Phase 1 (Setup) structural suite — T001…T007, T165.
#
# Reads the tree through independent paths (the filesystem, `go list`, the TOML
# and JSON parsers, `make` itself) rather than trusting what wrote it. Needs no
# lab, no cluster and no network beyond the module cache `go list -m` reads.
# Every check prints PASS/FAIL; the suite exits non-zero on the first summary
# with any FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

# --- T001: directory skeleton and .gitignore
for d in api/fabric/v1alpha1 api/v1alpha1 \
  cmd/srl-provider cmd/migration-translator cmd/intent-translator \
  controllers/fabric controllers/network controllers/migration \
  pkg/migration pkg/fabricapi pkg/register pkg/sdc pkg/kuid \
  internal/model internal/render/srl/acl internal/verify internal/webhook \
  internal/topologyview internal/status internal/telemetry \
  config/crd config/rbac config/kind lab/bootstrap lab/clients \
  deploy/cert-manager deploy/kuid deploy/sdc deploy/rbac deploy/agentic-netops \
  deploy/observability deploy/agents agents ui docker \
  examples/fabric examples/constructs examples/migrations \
  tests/unit tests/golden tests/envtest tests/gate tests/integration tests/e2e tests/lib \
  scripts/lib scripts/ci docs/decisions docs/images docs/media docs/reference \
  docs/operations testautomation/video; do
  check "T001 dir $d" test -d "$d"
done
for pat in 'bin/' '.evidence/' 'testautomation/video/takes/' 'testautomation/video/shots/' \
  'testautomation/video/snap/' '*.log' '.env'; do
  check "T001 .gitignore has '$pat'" grep -qxF "$pat" .gitignore
done

# --- T002: go.mod, toolchain, matrix libraries, tools.go
check "T002 module path" grep -qx 'module github.com/mairp/agentic-netops-srl' go.mod
check "T002 go directive present" grep -qE '^go 1\.[0-9]+(\.[0-9]+)?$' go.mod
check "T002 toolchain directive present" grep -qE '^toolchain go1\.[0-9]+\.[0-9]+$' go.mod
check "T002 predecessor 1.22.5 not inherited" bash -c '! grep -qE "^(go 1\.22\.5|toolchain go1\.22\.5)$" go.mod'
for m in sigs.k8s.io/controller-runtime k8s.io/client-go k8s.io/apimachinery sigs.k8s.io/yaml \
  sigs.k8s.io/controller-tools sigs.k8s.io/controller-runtime/tools/setup-envtest; do
  check "T002 go.mod requires $m" grep -qE "^[[:space:]]+$m v" go.mod
done
check "T002 tools.go build tag" grep -qx '//go:build tools' tools.go
check "T002 tools.go pins controller-gen" grep -qF '"sigs.k8s.io/controller-tools/cmd/controller-gen"' tools.go
check "T002 tools.go pins setup-envtest" grep -qF '"sigs.k8s.io/controller-runtime/tools/setup-envtest"' tools.go
if command -v go >/dev/null; then
  check "T002 go mod verify" go mod verify
  check "T002 go build ./..." go build ./...
fi

# --- T003: Python tier pins and lock
if command -v python3 >/dev/null; then
  check "T003 pyproject pins and playwright == uv.lock" python3 - <<'PY'
import sys, tomllib
p = tomllib.load(open("agents/pyproject.toml", "rb"))
lock = tomllib.load(open("agents/uv.lock", "rb"))
proj = p["project"]
assert proj["requires-python"] == ">=3.13,<4.0", proj["requires-python"]
deps = set(proj["dependencies"])
want = {"agntcy-app-sdk==0.4.5", "a2a-sdk==0.3.0", "langgraph>=0.4.1", "langgraph-supervisor",
        "langgraph-checkpoint-sqlite", "litellm[proxy]==1.75.3", "langchain-litellm>=0.3.0",
        "ioa-observe-sdk==1.0.24", "agntcy-identity-service-sdk==0.0.7", "pydantic>=2.11.4",
        "fastapi", "uvicorn", "starlette"}
missing = want - deps
assert not missing, missing
dev = p["dependency-groups"]["dev"]
for name in ("pytest", "pytest-asyncio", "ruff"):
    assert any(d == name or d.startswith(name + "=") or d.startswith(name + ">") for d in dev), name
pw = [d for d in dev if d.startswith("playwright")]
assert len(pw) == 1 and pw[0].startswith("playwright=="), pw
locked = {pk["name"]: pk["version"] for pk in lock["package"]}
assert pw[0].split("==")[1] == locked["playwright"], (pw, locked["playwright"])
for n, v in {"agntcy-app-sdk": "0.4.5", "a2a-sdk": "0.3.0", "litellm": "1.75.3",
             "ioa-observe-sdk": "1.0.24", "agntcy-identity-service-sdk": "0.0.7"}.items():
    assert locked[n] == v, (n, locked[n])
PY
fi
if command -v uv >/dev/null; then
  check "T003 uv.lock consistent with pyproject" bash -c 'cd agents && uv lock --check'
fi

# --- T004: browser app and its tracked lock
for f in ui/package.json ui/vite.config.ts ui/index.html ui/src/main.tsx ui/src/App.tsx ui/package-lock.json; do
  check "T004 file $f" test -f "$f"
done
check "T004 package.json is Vite + React" python3 -c '
import json; p=json.load(open("ui/package.json")); a={**p.get("dependencies",{}),**p.get("devDependencies",{})}
assert {"vite","react","react-dom","@vitejs/plugin-react"} <= a.keys()'
check "T004 package-lock matches package.json name" python3 -c '
import json; l=json.load(open("ui/package-lock.json")); p=json.load(open("ui/package.json"))
assert l["name"]==p["name"] and l["lockfileVersion"]>=2'

# --- T005: lint and format configuration
check "T005 .golangci.yml" grep -q '^version: "2"' .golangci.yml
check "T005 [tool.ruff] in agents/pyproject.toml" grep -qx '\[tool.ruff\]' agents/pyproject.toml
check "T005 ui/eslint.config.js" test -f ui/eslint.config.js
check "T005 .editorconfig root" grep -qx 'root = true' .editorconfig

# --- T006: Makefile interface; negative case: an unbuilt target never passes
targets=(verify-pins verify-upstream-artefacts verify-render-schema verify-compat verify-boundaries
  verify-provenance-headers verify-evidence verify-readme test-static test-idempotence
  test-managed-drift test-unmanaged-path test-target-failure test-service-delete
  test-delete-unreachable test-provider-claims test-acceptance build-migration-cli sdc-onboard
  wait-targets wait-fabric wait-services wait-observability verify-fabric-control-plane
  verify-services show-bgp show-evpn show-allocations show-rendered-config test-reverify
  test-envtest test-agents test-ui verify-metrics verify-topology-view verify-evpn-service-view
  test-alerts)
for t in "${targets[@]}"; do
  if ! grep -qE "^${t}:" Makefile; then fail "T006 target $t declared"; continue; fi
  pass "T006 target $t declared"
  # A target whose recipe is still the stub must fail, naming itself.
  if awk -v t="$t" '$0 ~ "^"t":" {getline; print; exit}' Makefile | grep -qF '$(not_implemented)'; then
    out="$(make -s "$t" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && grep -qxF "not implemented: $t" <<<"$out"; then
      pass "T006 unbuilt $t fails with 'not implemented: $t'"
    else
      fail "T006 unbuilt $t fails with 'not implemented: $t' (rc=$rc)"
    fi
  fi
done

# --- T007: CI workflow
wf=.github/workflows/ci.yaml
check "T007 workflow parses with jobs go/agents/ui" python3 -c '
import yaml; d=yaml.safe_load(open(".github/workflows/ci.yaml")); assert set(d["jobs"])=={"go","agents","ui"}'
check "T007 go build ./..." grep -qF 'run: go build ./...' "$wf"
check "T007 offline make gates" grep -qF 'make test-static test-envtest verify-render-schema verify-pins verify-boundaries verify-provenance-headers verify-upstream-artefacts' "$wf"
check "T007 Prometheus pulled by locked digest" grep -qF 'docker pull "${refs[0]}"' "$wf"
check "T007 make test-agents" grep -qF 'run: make test-agents' "$wf"
check "T007 npm ci" grep -qF 'run: npm ci' "$wf"
check "T007 make test-ui" grep -qF 'run: make test-ui' "$wf"
check "T007 npm run build" grep -qF 'run: npm run build' "$wf"
check "T007 actions pinned by SHA" bash -c '! grep -E "uses: [^ ]+@" '"$wf"' | grep -vqE "@[0-9a-f]{40} "'

# --- T165: PR template and CODEOWNERS
pr=.github/pull_request_template.md
for h in '## Operator-facing rationale' '## Tests run' '## `make verify-pins` result' '## Docs and dashboards'; do
  check "T165 template section '$h'" grep -qxF "$h" "$pr"
done
check "T165 template safety checkbox" grep -qF -- '- [ ] This PR changes confirmations, refusal logic or transaction phases → operator review requested and lab run attached' "$pr"
for p in /agents/supervisors/provisioning/graph/ /agents/common/guards/ /agents/provisioning/deployer/ /deploy/rbac/ /.specify/memory/constitution.md; do
  check "T165 CODEOWNERS $p" grep -qE "^${p//./\\.}[[:space:]]+@" .github/CODEOWNERS
done
check "T165 owner handle is a marked stop-and-ask placeholder" grep -qF 'STOP-AND-ASK' .github/CODEOWNERS

echo "setup_test: $fails failure(s)"
[ "$fails" -eq 0 ]
