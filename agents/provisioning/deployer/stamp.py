"""Resource stamping and the submitted-spec hash (T100; contracts/kubernetes-objects.md
§"Resource stamping contract", FR-101, FR-105, CD-04).

**One owner per key, disjoint key sets, a fixed emission order**: the translator's keys first,
exactly as it emitted them, then the tier's — the correlation and tier labels, the thread,
principal and submitted-at annotations — and, **last of all**, the submitted-spec hash, which is
added between the dry-run and the apply and is the one key in which the two differ.

The hash is the SHA-256 of the **canonical JSON** of ``spec`` as the server-side dry-run returned
it: keys sorted, no insignificant whitespace, UTF-8, numbers in shortest round-trip form
(data-model.md §15, research.md CD-04).
"""

from __future__ import annotations

import copy
import hashlib
import json
from collections.abc import Mapping
from datetime import UTC, datetime
from typing import Any

from provisioning.deployer.kube import API_VERSION, FINALIZER, INTENT_NAMESPACE, KIND

CORRELATION_LABEL = "agentic-netops.io/correlation-id"
TIER_LABEL = "agentic-netops.io/tier"
TIER_VALUE = "intent"
THREAD_ANNOTATION = "agentic-netops.io/intent-thread-id"
PRINCIPAL_ANNOTATION = "agentic-netops.io/intent-principal"
SUBMITTED_AT_ANNOTATION = "agentic-netops.io/intent-submitted-at"
SPEC_HASH_ANNOTATION = "agentic-netops.io/intent-submitted-spec-sha256"
FORCE_RELEASE_ANNOTATION = "fabric.agentic-netops.io/force-release"

TIER_LABELS = (CORRELATION_LABEL, TIER_LABEL)
TIER_ANNOTATIONS = (THREAD_ANNOTATION, PRINCIPAL_ANNOTATION, SUBMITTED_AT_ANNOTATION,
                    SPEC_HASH_ANNOTATION)
# Keys the API server owns on a returned object: never part of what the tier sends.
SERVER_METADATA = ("uid", "resourceVersion", "generation", "creationTimestamp", "managedFields",
                   "selfLink", "deletionTimestamp", "deletionGracePeriodSeconds")


class StampError(ValueError):
    """The translator's output cannot be stamped (a key collision, a foreign Kind)."""


def canonical_json(value: Any) -> bytes:
    """Canonical JSON: sorted keys, no insignificant whitespace, UTF-8; Python's float repr is
    the shortest round-trip form."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                      allow_nan=False).encode("utf-8")


def spec_sha256(spec: Any) -> str:
    return hashlib.sha256(canonical_json(spec)).hexdigest()


def rfc3339(at: datetime) -> str:
    return at.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def stamp(manifest: Mapping[str, Any], *, correlation_id: str, thread_id: str, principal: str,
          submitted_at: datetime) -> dict[str, Any]:
    """The translator's manifest with the tier's keys added after its own, the namespace set to
    the intent namespace and the provider's finalizer set (AD-32). No hash yet."""
    if manifest.get("apiVersion") != API_VERSION or manifest.get("kind") != KIND:
        raise StampError(f"the translator emitted {manifest.get('apiVersion')}/"
                         f"{manifest.get('kind')}; only {API_VERSION} {KIND} is submitted")
    out = copy.deepcopy(dict(manifest))
    meta = out.get("metadata")
    if not isinstance(meta, dict) or not isinstance(meta.get("name"), str):
        raise StampError("the translator's manifest has no metadata.name")
    if not isinstance(out.get("spec"), dict):
        raise StampError(f"Network/{meta['name']}: the translator's manifest has no spec")
    labels = dict(meta.get("labels") or {})
    annotations = dict(meta.get("annotations") or {})
    clash = sorted((set(labels) & set(TIER_LABELS)) | (set(annotations) & set(TIER_ANNOTATIONS))
                   | ({FORCE_RELEASE_ANNOTATION} & set(annotations)))
    if clash:
        raise StampError(f"Network/{meta['name']}: the translator wrote tier-owned keys "
                         f"{', '.join(clash)}; the key sets must be disjoint (FR-101)")
    for key in SERVER_METADATA:
        meta.pop(key, None)
    translator_labels, translator_annotations = labels, annotations
    stamped_meta: dict[str, Any] = {"name": meta["name"], "namespace": INTENT_NAMESPACE}
    stamped_meta["labels"] = {**translator_labels, CORRELATION_LABEL: correlation_id,
                              TIER_LABEL: TIER_VALUE}
    stamped_meta["annotations"] = {**translator_annotations, THREAD_ANNOTATION: thread_id,
                                   PRINCIPAL_ANNOTATION: principal,
                                   SUBMITTED_AT_ANNOTATION: rfc3339(submitted_at)}
    finalizers = [f for f in meta.get("finalizers") or [] if f != FINALIZER]
    stamped_meta["finalizers"] = [*finalizers, FINALIZER]
    for key, value in meta.items():
        if key not in stamped_meta and key not in ("labels", "annotations", "finalizers"):
            stamped_meta[key] = value
    out["metadata"] = stamped_meta
    assert_disjoint(translator_labels, translator_annotations, stamped_meta)
    return out


def assert_disjoint(translator_labels: Mapping[str, str],
                    translator_annotations: Mapping[str, str],
                    stamped_meta: Mapping[str, Any]) -> None:
    """Translator keys first and unchanged, tier keys second, the two sets disjoint."""
    labels = list(stamped_meta["labels"])
    annotations = list(stamped_meta["annotations"])
    n_l, n_a = len(translator_labels), len(translator_annotations)
    if labels[:n_l] != list(translator_labels) or annotations[:n_a] != list(
            translator_annotations):
        raise StampError("the translator's keys are not first")
    if set(labels[n_l:]) & set(translator_labels) or set(annotations[n_a:]) & set(
            translator_annotations):
        raise StampError("the translator's and the tier's key sets intersect")
    if not set(labels[n_l:]) <= set(TIER_LABELS) or not set(annotations[n_a:]) <= set(
            TIER_ANNOTATIONS):
        raise StampError("a key after the translator's is not a tier key")


def apply_body(dry_run_result: Mapping[str, Any]) -> tuple[dict[str, Any], str]:
    """The apply: the dry-run object (server-owned metadata and status stripped) plus exactly
    the submitted-spec hash annotation, written last. Returns ``(body, hash)``."""
    body = copy.deepcopy(dict(dry_run_result))
    body.pop("status", None)
    meta = body.setdefault("metadata", {})
    for key in SERVER_METADATA:
        meta.pop(key, None)
    digest = spec_sha256(body.get("spec"))
    annotations = dict(meta.get("annotations") or {})
    annotations.pop(SPEC_HASH_ANNOTATION, None)
    annotations[SPEC_HASH_ANNOTATION] = digest
    meta["annotations"] = annotations
    return body, digest


__all__ = [
    "CORRELATION_LABEL",
    "PRINCIPAL_ANNOTATION",
    "SERVER_METADATA",
    "SPEC_HASH_ANNOTATION",
    "SUBMITTED_AT_ANNOTATION",
    "THREAD_ANNOTATION",
    "TIER_ANNOTATIONS",
    "TIER_LABEL",
    "TIER_LABELS",
    "StampError",
    "apply_body",
    "assert_disjoint",
    "canonical_json",
    "rfc3339",
    "spec_sha256",
    "stamp",
]
