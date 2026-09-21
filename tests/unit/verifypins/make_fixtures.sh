#!/usr/bin/env bash
# make_fixtures.sh — (re)generate tests/unit/verifypins/testdata/ (T009).
#
# The committed fixtures are this script's output; the suite never regenerates them. Run it only
# to rebuild the set deliberately (for instance after the base lock's pins are re-resolved).
#
# testdata/base/                 a small valid tree: go.mod, go.sum, agents/{pyproject.toml,uv.lock},
#                                ui/package-lock.json and versions.lock.yaml — a copy of the
#                                repository's resolved lock with the dependency-lock hashes and
#                                host-tooling versions of THIS tree and THIS fixture host.
# testdata/host/                 a fixture host: a virtualenv holding playwright 1.63.0 (fixing
#                                chromium 1243), Playwright browser dirs, stub ffmpeg/Xvfb binaries.
# testdata/cases/<case>/         one defect each against base: lock.yaml (when the lock differs)
#                                and/or tree/ (files overlaid on the base tree).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TD="$HERE/testdata"
rm -rf "$TD"
mkdir -p "$TD/base" "$TD/cases" "$TD/host"

# ---- base tree ----------------------------------------------------------------------------------
B="$TD/base"
mkdir -p "$B/agents" "$B/ui"
cat > "$B/go.mod" <<'X'
module example.test/verifypins-fixture

go 1.25.0

toolchain go1.27.1
X
printf 'example.test/dep v1.0.0 h1:fixturefixturefixturefixturefixturefixture00=\n' > "$B/go.sum"
cat > "$B/agents/pyproject.toml" <<'X'
[project]
name = "fixture-agents"
version = "0.0.0"
requires-python = "==3.13.*"
dependencies = []

[dependency-groups]
dev = [
    "playwright==1.63.0",
]
X
cat > "$B/agents/uv.lock" <<'X'
version = 1
requires-python = "==3.13.*"

[[package]]
name = "playwright"
version = "1.63.0"
source = { registry = "https://pypi.org/simple" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/27/9c/103a5037789062bdab27c7dca53f3ca6b075b572ab2cd96eec825b3aec4e/playwright-1.63.0-py3-none-manylinux1_x86_64.whl", hash = "sha256:ad21bc07516b187965a7521c5cf0df0bd657b17482eaad74335272d35a2b07de", size = 48217159 },
]
X
printf '{\n  "name": "fixture-ui",\n  "lockfileVersion": 3,\n  "packages": {}\n}\n' > "$B/ui/package-lock.json"

cp "$ROOT/versions.lock.yaml" "$B/versions.lock.yaml"
L="$B/versions.lock.yaml"
gosum=$(sha256sum "$B/go.sum" | cut -d' ' -f1)
uvlock=$(sha256sum "$B/agents/uv.lock" | cut -d' ' -f1)
pkglock=$(sha256sum "$B/ui/package-lock.json" | cut -d' ' -f1)
GOSUM=$gosum UVLOCK=$uvlock PKGLOCK=$pkglock yq -i '
  (.firstPartyImages[].dependencyLocks[] | select(.path == "go.sum") | .sha256) = strenv(GOSUM) |
  (.firstPartyImages[].dependencyLocks[] | select(.path == "agents/uv.lock") | .sha256) = strenv(UVLOCK) |
  (.firstPartyImages[].dependencyLocks[] | select(.path == "ui/package-lock.json") | .sha256) = strenv(PKGLOCK) |
  .goToolchain.go = "1.25.0" | .goToolchain.toolchain = "go1.27.1" |
  .hostTooling.browserAutomation.version = "1.63.0" |
  .hostTooling.browserAutomation.browserRevision = "1243" |
  (.hostTooling.capture[] | select(.tool == "ffmpeg") | .version) = "7.1.5-0+deb13u1" |
  (.hostTooling.capture[] | select(.tool == "Xvfb") | .version) = "21.1.16"
' "$L"

# ---- fixture host -------------------------------------------------------------------------------
H="$TD/host"
sp="$H/venv/lib/python3.13/site-packages"
mkdir -p "$sp/playwright-1.63.0.dist-info" "$sp/playwright/driver/package"
printf 'Metadata-Version: 2.1\nName: playwright\nVersion: 1.63.0\n' > "$sp/playwright-1.63.0.dist-info/METADATA"
printf '{"browsers":[{"name":"chromium","revision":"1243","installByDefault":true}]}\n' \
  > "$sp/playwright/driver/package/browsers.json"
mkdir -p "$H/browsers/chromium-1243" "$H/browsers-other/chromium-1234"
touch "$H/browsers/chromium-1243/INSTALLATION_COMPLETE" "$H/browsers-other/chromium-1234/INSTALLATION_COMPLETE"
stub() { # stub <file> <line printed for -version>
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\necho "%s"\n' "$2" > "$1"; chmod +x "$1"
}
stub "$H/bin/ffmpeg" "ffmpeg version 7.1.5-0+deb13u1 Copyright (c) 2000-2025 the FFmpeg developers"
stub "$H/bin/Xvfb" "X.Org X Server 21.1.16"
stub "$H/bin-no-xvfb/ffmpeg" "ffmpeg version 7.1.5-0+deb13u1 Copyright (c) 2000-2025 the FFmpeg developers"
stub "$H/bin-other-ffmpeg/ffmpeg" "ffmpeg version 6.1.1-3ubuntu5 Copyright (c) 2000-2023 the FFmpeg developers"
stub "$H/bin-other-ffmpeg/Xvfb" "X.Org X Server 21.1.16"

# ---- cases --------------------------------------------------------------------------------------
# lockcase <case> <yq expression>: the base lock with one edit
lockcase() {
  mkdir -p "$TD/cases/$1"
  cp "$L" "$TD/cases/$1/lock.yaml"
  yq -i "$2" "$TD/cases/$1/lock.yaml"
}
# treefile <case> <path> — content on stdin
treefile() {
  mkdir -p "$(dirname "$TD/cases/$1/tree/$2")"
  cat > "$TD/cases/$1/tree/$2"
}

prom=$(yq '.observability.prometheus.digest' "$L")
graf=$(yq '.observability.grafana.digest' "$L")
py=$(yq '.firstPartyImages[] | select(.name == "supervisor") | .from[0].digest' "$L")
alpine=$(yq '.firstPartyImages[] | select(.name == "srl-provider") | .from[1].digest' "$L")
Z64=0000000000000000000000000000000000000000000000000000000000000000
H64=5f1d3c0e7a9b2d4f6e8a0c1b3d5f7e9a2c4e6b8d0f1a3c5e7b9d2f4a6c8e0b1d

# 1 placeholder / synthetic digest
lockcase placeholder-digest ".observability.prometheus.digest = \"sha256:$Z64\" |
  .observability.prometheus.pinned = \"quay.io/prometheus/prometheus:v3.14.0@sha256:$Z64\""
# 2 latest tag
lockcase latest-tag ".observability.grafana.tag = \"latest\" |
  .observability.grafana.pinned = \"docker.io/grafana/grafana:latest@$graf\""
# 3 floating minor tag
lockcase floating-minor-tag ".observability.prometheus.tag = \"v3.14\" |
  .observability.prometheus.pinned = \"quay.io/prometheus/prometheus:v3.14@$prom\""
# 4 branch ref inside the Schema CR's repository refs
lockcase schema-branch-ref '.compatibilitySet.schema.repositories[0].kind = "branch" |
  .compatibilitySet.schema.repositories[0].ref = "main"'
# 5 Grafana plugin with no version
lockcase grafana-plugin-no-version 'del(.observability.grafanaPlugins[0].version)'
# 6 topology generator with its version omitted
lockcase topology-generator-no-version 'del(.observability.topologyGenerator.tag) |
  .observability.topologyGenerator.pinned = "ghcr.io/srl-labs/clab-io-draw@" + .observability.topologyGenerator.digest'
# 7 a well-formed digest that does not resolve in its registry (the grafana image digest on slim)
lockcase digest-not-resolving ".platform.slim.digest = \"$graf\" |
  .platform.slim.pinned = \"ghcr.io/agntcy/slim:0.6.1@$graf\""

# 8 allocationAuthority first-party — the decision record exists and records an adoption; the
#   lock's references are what is wrong
adoption_record() {
  treefile "$1" docs/decisions/allocator-substitution.md <<'X'
# Allocator substitution

## 2026-10-01 adoption
Reason: G11 failed against kuid-server v0.0.13 (fixture).
X
  treefile "$1" evidence/g11-failed.json <<'X'
{"gate": "G11", "exit_status": 1, "fixture": true}
X
}
lockcase allocator-first-party-no-refs '.allocationAuthority = {"kind": "first-party"}'
adoption_record allocator-first-party-no-refs
lockcase allocator-first-party-no-evidence '.allocationAuthority = {"kind": "first-party",
  "decisionRecord": "docs/decisions/allocator-substitution.md"}'
adoption_record allocator-first-party-no-evidence
lockcase allocator-first-party-record-unresolvable '.allocationAuthority = {"kind": "first-party",
  "decisionRecord": "docs/decisions/allocator-substitution-missing.md",
  "failedGateEvidence": {"path": "evidence/g11-failed.json", "sha256": "EVSHA"}}'
adoption_record allocator-first-party-record-unresolvable
lockcase allocator-first-party-evidence-unresolvable '.allocationAuthority = {"kind": "first-party",
  "decisionRecord": "docs/decisions/allocator-substitution.md",
  "failedGateEvidence": {"path": "evidence/g11-missing.json", "sha256": "EVSHA"}}'
adoption_record allocator-first-party-evidence-unresolvable
lockcase allocator-first-party-evidence-hash-differs ".allocationAuthority = {\"kind\": \"first-party\",
  \"decisionRecord\": \"docs/decisions/allocator-substitution.md\",
  \"failedGateEvidence\": {\"path\": \"evidence/g11-failed.json\", \"sha256\": \"$Z64\"}}"
adoption_record allocator-first-party-evidence-hash-differs
lockcase allocator-first-party-ok '.allocationAuthority = {"kind": "first-party",
  "decisionRecord": "docs/decisions/allocator-substitution.md",
  "failedGateEvidence": {"path": "evidence/g11-failed.json", "sha256": "EVSHA"}}'
adoption_record allocator-first-party-ok
ev=$(sha256sum "$TD/cases/allocator-first-party-ok/tree/evidence/g11-failed.json" | cut -d' ' -f1)
for c in allocator-first-party-record-unresolvable allocator-first-party-evidence-unresolvable allocator-first-party-ok; do
  sed -i "s/EVSHA/$ev/" "$TD/cases/$c/lock.yaml"
done

# 9 the return path, recorded like the adoption (kind: kuid is the base lock's)
treefile allocator-return-missing docs/decisions/allocator-substitution.md <<'X'
# Allocator substitution

## 2026-10-01 adoption
Reason: G11 failed against kuid-server v0.0.13 (fixture).
X
treefile allocator-return-no-date docs/decisions/allocator-substitution.md <<'X'
# Allocator substitution

## 2026-10-01 adoption
Reason: G11 failed against kuid-server v0.0.13 (fixture).

## return
Reason: kuid-server v0.0.14 passes G11 (fixture).
X
treefile allocator-return-no-reason docs/decisions/allocator-substitution.md <<'X'
# Allocator substitution

## 2026-10-01 adoption
Reason: G11 failed against kuid-server v0.0.13 (fixture).

## 2026-11-15 return
X
treefile allocator-return-ok docs/decisions/allocator-substitution.md <<'X'
# Allocator substitution

## 2026-10-01 adoption
Reason: G11 failed against kuid-server v0.0.13 (fixture).

## 2026-11-15 return
Reason: kuid-server v0.0.14 passes G11 (fixture).
X

# 10 any other declared exception
lockcase exception-exceptions-field '.exceptions = [{"entry": "observability.grafana", "reason": "fixture"}]'
lockcase exception-allow-unpinned '.platform.clickhouse.allowUnpinned = true'
lockcase exception-skip-verify '.compatibilitySet.gnmic.image.skipVerify = true'

# 11 host tooling (run with --host-tooling)
lockcase host-browser-automation-ranged '.hostTooling.browserAutomation.version = ">=1.63.0"'
lockcase host-browser-revision-recorded-differs '.hostTooling.browserAutomation.browserRevision = "1234"'
mkdir -p "$TD/cases/host-browser-revision-installed-differs" "$TD/cases/host-capture-tool-missing" \
  "$TD/cases/host-capture-tool-different-version"
for c in host-browser-revision-installed-differs host-capture-tool-missing host-capture-tool-different-version; do
  cp "$L" "$TD/cases/$c/lock.yaml"   # the lock is the valid base; the defect is on the host
done

# 12 first-party images with Dockerfiles and manifests
good_supervisor() {
  treefile "$1" docker/Dockerfile.supervisor <<X
# fixture
FROM python:3.13.0-slim@$py AS build
WORKDIR /src
COPY . .
FROM build
CMD ["python", "-m", "supervisor"]
X
}
good_supervisor first-party-built-ok
treefile first-party-built-ok deploy/supervisor.yaml <<X
apiVersion: apps/v1
kind: Deployment
metadata: {name: supervisor}
spec:
  template:
    spec:
      containers:
      - name: supervisor
        image: supervisor:$H64
        imagePullPolicy: Never
X
treefile first-party-from-tag-only docker/Dockerfile.supervisor <<'X'
FROM python:3.13.0-slim
CMD ["python", "-m", "supervisor"]
X
treefile first-party-from-digest-differs docker/Dockerfile.supervisor <<X
FROM python:3.13.0-slim@$alpine
CMD ["python", "-m", "supervisor"]
X
lockcase first-party-dependency-lock-differs "(.firstPartyImages[] | select(.name == \"supervisor\") | .dependencyLocks[0].sha256) = \"$Z64\""
good_supervisor first-party-dependency-lock-differs
good_supervisor first-party-manifest-latest
treefile first-party-manifest-latest deploy/supervisor.yaml <<'X'
apiVersion: apps/v1
kind: Deployment
metadata: {name: supervisor}
spec:
  template:
    spec:
      containers:
      - name: supervisor
        image: supervisor:latest
X
good_supervisor first-party-manifest-mutable-tag
treefile first-party-manifest-mutable-tag deploy/supervisor.yaml <<'X'
apiVersion: apps/v1
kind: Deployment
metadata: {name: supervisor}
spec:
  template:
    spec:
      containers:
      - name: supervisor
        image: supervisor:v1.2.0
        imagePullPolicy: Never
X

# 13 Go toolchain differs from the fixture go.mod
lockcase go-toolchain-differs '.goToolchain.toolchain = "go1.26.3"'

# 14 pending (AD-71)
treefile pending-referenced-by-manifest deploy/mapper.yaml <<X
apiVersion: apps/v1
kind: Deployment
metadata: {name: mapper}
spec:
  template:
    spec:
      containers:
      - name: mapper
        image: mapper:$H64
        imagePullPolicy: Never
X
treefile pending-referenced-by-script scripts/build_images.sh <<'X'
#!/usr/bin/env bash
docker build -f docker/Dockerfile.allocator -t "allocator:${HASH}" agents
X
treefile pending-referenced-by-makefile Makefile <<'X'
images:
	docker build -f docker/Dockerfile.deployer -t deployer:$(HASH) agents
X
treefile pending-docker-dockerfile-without-entry docker/Dockerfile.telemetry-bridge <<X
FROM alpine:3.24.2@$alpine
X
lockcase pending-from-digest-unresolvable "(.firstPartyImages[] | select(.name == \"ui\") | .from[0].digest) = \"sha256:$Z64\""

echo "fixtures written to $TD"
