"""The supervisor's prompt texts (T102; FR-026, FR-085, contracts/construct-vocabulary.md).

* ConfigMap ``supervisor-prompts`` (deploy/agents/supervisor-prompts.yaml) carries exactly the
  packaged ``prompts/*.md`` files, byte for byte, and is mounted read-only into the supervisor at
  the directory ``SUPERVISOR_PROMPTS_DIR`` names;
* every prompt is in construct vocabulary only: no retired service name (the ``retired-service``
  rows of scripts/ci/boundaries.denylist) appears in any of them;
* the loader reads the configured directory, falls back to the packaged default file by file, and
  every prompt the supervisor renders exists with exactly the fields it is rendered with.
"""

from __future__ import annotations

import ast
import re
import string
from pathlib import Path

import pytest
import yaml

from supervisors.provisioning import prompts

AGENTS = Path(__file__).resolve().parents[2]
REPO = AGENTS.parent
CONFIGMAP = REPO / "deploy" / "agents" / "supervisor-prompts.yaml"
SUPERVISOR = REPO / "deploy" / "agents" / "supervisor.yaml"
DENYLIST = REPO / "scripts" / "ci" / "boundaries.denylist"
PACKAGED = sorted(prompts.PACKAGED_PROMPTS.glob("*.md"))


def retired_patterns() -> list[re.Pattern[str]]:
    rows = [line.split(None, 1) for line in DENYLIST.read_text(encoding="utf-8").splitlines()
            if line.startswith("retired-service")]
    found = [re.compile(r[1].strip(), re.IGNORECASE) for r in rows]
    assert found, "no retired-service rows in the deny-list"
    # FR-085's list, also as the composite spellings an operator might have met.
    return [*found, re.compile(r"\bEVPN-VPLS\b", re.IGNORECASE)]


def test_there_are_packaged_prompts() -> None:
    assert {p.name for p in PACKAGED} >= {"informational.md", "confirm-interpretation.md",
                                          "confirm-assignment.md", "confirm-removal-1.md",
                                          "confirm-removal-2.md", "declined.md", "refused.md"}


def test_configmap_equals_the_packaged_prompts_byte_for_byte() -> None:
    doc = yaml.safe_load(CONFIGMAP.read_text(encoding="utf-8"))
    assert doc["kind"] == "ConfigMap" and doc["metadata"]["name"] == "supervisor-prompts"
    data = doc["data"]
    assert sorted(data) == [p.name for p in PACKAGED]
    for path in PACKAGED:
        assert data[path.name].encode("utf-8") == path.read_bytes(), path.name


def test_the_configmap_is_mounted_read_only_at_the_prompts_dir() -> None:
    docs = [d for d in yaml.safe_load_all(SUPERVISOR.read_text(encoding="utf-8")) if d]
    deployment = next(d for d in docs if d["kind"] == "Deployment")
    pod = deployment["spec"]["template"]["spec"]
    volume = next(v for v in pod["volumes"] if v.get("configMap", {}).get("name")
                  == "supervisor-prompts")
    assert volume["configMap"].get("optional") is False
    container = pod["containers"][0]
    mount = next(m for m in container["volumeMounts"] if m["name"] == volume["name"])
    assert mount.get("readOnly") is True and "subPath" not in mount
    env = {e["name"]: e.get("value") for e in container["env"]}
    assert env[prompts.PROMPTS_ENV] == mount["mountPath"]


@pytest.mark.parametrize("path", PACKAGED, ids=lambda p: p.name)
def test_construct_vocabulary_only(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    for pattern in retired_patterns():
        assert not pattern.search(text), f"{path.name}: {pattern.pattern}"


def test_the_configured_directory_wins_and_the_package_backs_it(
        tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    (tmp_path / "confirm-interpretation.md").write_text("Confirm the {construct} reading?\n")
    monkeypatch.setenv(prompts.PROMPTS_ENV, str(tmp_path))
    assert prompts.render("confirm-interpretation", construct="vlan") == "Confirm the vlan reading?"
    # Not configured: the packaged default.
    assert prompts.load_prompt("confirm-assignment") == \
        (prompts.PACKAGED_PROMPTS / "confirm-assignment.md").read_text().rstrip("\n")
    monkeypatch.delenv(prompts.PROMPTS_ENV)
    assert prompts.prompts_dir() == prompts.PACKAGED_PROMPTS
    with pytest.raises(FileNotFoundError):
        prompts.load_prompt("no-such-prompt")


def _render_calls() -> dict[str, set[str]]:
    """Every ``render("<name>", field=…)`` under agents/supervisors: name -> the fields given."""
    calls: dict[str, set[str]] = {}
    for path in (AGENTS / "supervisors").rglob("*.py"):
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                    and node.func.id == "render" and node.args
                    and isinstance(node.args[0], ast.Constant)):
                calls.setdefault(node.args[0].value, set()).update(
                    k.arg for k in node.keywords if k.arg)
    return calls


def test_every_rendered_prompt_exists_with_its_fields() -> None:
    calls = _render_calls()
    assert calls, "the supervisor renders no prompt"
    names = {p.stem for p in PACKAGED}
    assert set(calls) <= names
    assert names <= set(calls), f"unused prompt files: {names - set(calls)}"
    for name, given in calls.items():
        fields = {f for _, f, _, _ in string.Formatter().parse(prompts.load_prompt(name)) if f}
        assert fields == given, (name, fields, given)
