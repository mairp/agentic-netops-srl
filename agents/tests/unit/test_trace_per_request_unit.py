"""One trace per request, and the per-stage metrics (T135; FR-090, FR-092, FR-093, NFR-009,
data-model.md §21, AD-57, AD-66).

The supervisor runs over the in-memory SLIM stand-in with every telemetry bundle in memory
(``otlp=False``): the mapper worker makes a real :class:`~common.llm.LLMClient` call (its model
transport stubbed), the allocator is a fake, and the deployer is the real stage over the fake API
server — so ``stage.*``, ``worker.call``, ``worker.handle``, ``model.call`` and ``convergence``
spans are all produced by the code under test, and all must carry the correlation id as trace id.
Then each stage is made to fail once, and the trace must say which stage failed and why — with
the payload that failed validation where there is one.
"""

from __future__ import annotations

import asyncio
import copy
import json
from pathlib import Path
from typing import Any

import pytest
from opentelemetry.trace import StatusCode

import common.transport as t
from common import metrics, tracing
from common.guards.redaction import find_credentials
from common.llm import LLMClient
from common.schemas.stream import parse_chunk
from provisioning.deployer.stamp import CORRELATION_LABEL
from provisioning.mapper.agent import Mapper
from supervisors.provisioning.graph.graph import Supervisor
from tests.unit import deployer_fakes as df
from tests.unit.conftest import CARD_IDS, GATEWAY_CREDENTIALS, Env, FakeClock, FakeWorkers
from tests.unit.test_mapper_refusals import REFUSE_CASES, Site, fixture, model_output
from tests.unit.test_mapper_refusals import stage as stage_message

pytestmark = pytest.mark.usefixtures("fresh_telemetry")

PROMPT = (
    "Extend vlan 120 as a mac-vrf across leaf01 ethernet-1/1 and leaf02 ethernet-1/1 "
    "for tenant blue"
)
MODEL = "openai/gpt-4o"
SECRET = "sk-live-9f8e7d6c5b4a39281706f5e4d3c2b1a0"  # noqa: S105 — a redaction probe
INTERPRETATION = {
    "service_id": df.SID,
    "service_type": "mac-vrf",
    "tenant": "blue",
    "endpoints": [
        {"site_or_node": "leaf01", "attachment": "ethernet-1/1", "vlan": 120},
        {"site_or_node": "leaf02", "attachment": "ethernet-1/1", "vlan": 120},
    ],
}


def llm_secret(root: Path) -> Path:
    secret = root / "llm-provider"
    secret.mkdir(exist_ok=True)
    (secret / "LLM_MODEL").write_text(MODEL)
    (secret / "API_KEY").write_text(SECRET)
    (secret / "BASE_URL").write_text("https://llm-gateway.example:4000/v1")
    return secret


def model_transport(content: str) -> Any:
    def transport(**_kwargs: Any) -> dict[str, Any]:
        return {
            "model": "gpt-4o-2024-08-06",
            "choices": [{"message": {"role": "assistant", "content": content}}],
            "usage": {"prompt_tokens": 42, "completion_tokens": 7},
            "response_cost": 0.00125,
        }

    return transport


class TracedWorkers(FakeWorkers):
    """The fake mapper calls the model through the real client, inside its worker span."""

    def __init__(self, gateway: t.InMemoryGateway, clock: FakeClock, llm: LLMClient) -> None:
        super().__init__(gateway, clock)
        self.llm = llm
        self.interpretation = copy.deepcopy(INTERPRETATION)
        self.assignment = copy.deepcopy(df.ASSIGNMENT)

    async def _mapper(self, request: t.StageMessage) -> Any:
        await asyncio.to_thread(self.llm.complete, [{"role": "user", "content": request.text}])
        return await super()._mapper(request)


class Rig:
    """A supervisor, two fake workers and the real deployer on one in-memory gateway."""

    def __init__(self, env: Env) -> None:
        self.settings = env.settings()
        self.gateway = t.InMemoryGateway(*GATEWAY_CREDENTIALS)
        self.clock = FakeClock()
        self.llm = LLMClient(
            llm_secret(env.root), transport=model_transport(json.dumps(INTERPRETATION))
        )
        self.workers = TracedWorkers(self.gateway, self.clock, self.llm)
        self.deployer = df.Rig()
        backend = self.gateway.connect(GATEWAY_CREDENTIALS, identity="devnet/provisioning/sup")

        async def no_sleep(_seconds: float) -> None:
            return None

        client = t.TransportClient(self.settings, backend, sleep=no_sleep)
        self.supervisor = Supervisor(self.settings, client, llm=None, clock=self.clock)

    async def start(self, *names: str) -> None:
        await self.workers.start(*[n for n in names if n != "deployer"])
        if "deployer" in names:
            card_id, skill = CARD_IDS["deployer"]
            await t.serve(
                {"id": card_id, "x-agentic-netops-worker": "deployer", "skills": [{"id": skill}]},
                self.deployer.deployer.handle,
                self.gateway.connect(GATEWAY_CREDENTIALS, identity=card_id),
            )

    async def turn(self, text: str, thread_id: str | None = None) -> list[dict[str, Any]]:
        out = [c async for c in self.supervisor.turn(text, principal="alice", thread_id=thread_id)]
        for chunk in out:
            parse_chunk(chunk)
        return out


@pytest.fixture
async def rig(env: Env) -> Any:
    r = Rig(env)
    yield r
    await r.supervisor.close()


def spans(tel: Any, name: str | None = None) -> list[Any]:
    return [s for s in tel.finished_spans() if name is None or s.name == name]


def one(tel: Any, name: str, **attrs: Any) -> Any:
    found = [s for s in spans(tel, name) if all(s.attributes.get(k) == v for k, v in attrs.items())]
    assert len(found) == 1, (name, attrs, [(s.name, dict(s.attributes)) for s in spans(tel)])
    return found[0]


def trace_id(span: Any) -> str:
    return tracing.format_trace_id(span.context.trace_id)


def failed(span: Any) -> bool:
    return span.status.status_code == StatusCode.ERROR


# --------------------------------------------------------------------------------------------------
# one trace per request
# --------------------------------------------------------------------------------------------------


async def test_one_trace_covers_every_stage_worker_model_call_and_convergence(
    rig: Rig, fresh_telemetry: Any
) -> None:
    await rig.start("mapper", "allocator", "deployer")
    rig.deployer.converge_at(10.0)
    first = await rig.turn(PROMPT)
    thread_id, cid = first[0]["thread_id"], first[0]["correlation_id"]
    await rig.turn("confirm", thread_id)
    last = await rig.turn("confirm", thread_id)
    assert last[-1]["type"] == "final" and last[-1]["status"] == "COMPLETED"

    tel = fresh_telemetry
    # Every span of every process of the request is in the one trace: trace id == correlation id
    # == the Network's correlation label.
    assert {trace_id(s) for s in spans(tel)} == {cid}
    network = rig.deployer.api.networks[df.NETWORK]
    assert network["metadata"]["labels"][CORRELATION_LABEL] == cid

    names = {s.name for s in spans(tel)}
    assert {
        "supervisor.request",
        "stage.supervisor",
        "stage.mapper",
        "stage.allocator",
        "stage.deployer",
        "worker.call",
        "worker.handle",
        "model.call",
        "convergence",
    } <= names
    for name in ("stage.mapper", "stage.allocator", "stage.deployer"):
        (span,) = spans(tel, name)
        assert span.attributes["agentic_netops.correlation_id"] == cid
        assert span.attributes["agentic_netops.stage"] == name.split(".", 1)[1]
        assert span.attributes["agentic_netops.outcome"] in ("succeeded", "converged")
        assert not failed(span)
    assert one(tel, "stage.deployer").attributes["agentic_netops.outcome"] == "converged"

    # worker.call is a child of its stage span; worker.handle a child of that call (traceparent)
    by_id = {s.context.span_id: s for s in spans(tel)}
    for worker in ("mapper", "allocator", "deployer"):
        call = one(tel, "worker.call", **{"agentic_netops.worker": worker})
        assert by_id[call.parent.span_id].name == f"stage.{worker}"
        assert call.attributes["agentic_netops.outcome"] == "succeeded"
        assert call.attributes["agentic_netops.attempts"] == 1
        handle = one(tel, "worker.handle", **{"agentic_netops.worker": worker})
        assert handle.parent.span_id == call.context.span_id
        assert handle.attributes["agentic_netops.outcome"] == "succeeded"

    # The model call is made in the mapper process, a child of that worker's span.
    model = one(tel, "model.call")
    assert by_id[model.parent.span_id].name == "worker.handle"
    assert model.attributes["gen_ai.request.model"] == MODEL
    assert model.attributes["gen_ai.system"] == "openai"
    assert "mac-vrf" in model.attributes["gen_ai.prompt"]
    assert json.loads(model.attributes["gen_ai.completion"]) == INTERPRETATION
    assert model.attributes["gen_ai.usage.input_tokens"] == 42
    assert model.attributes["gen_ai.usage.output_tokens"] == 7

    convergence = one(tel, "convergence")
    assert convergence.attributes["k8s.network.name"] == df.NETWORK
    assert convergence.attributes["k8s.network.namespace"] == df.NS
    assert convergence.attributes["agentic_netops.outcome"] == "converged"
    assert convergence.attributes["agentic_netops.ready"] == "True"
    assert convergence.attributes["agentic_netops.reason"] == "Converged"
    assert "agentic_netops.duration_seconds" in convergence.attributes
    assert not failed(convergence)
    assert all(
        "agentic_netops.failed_stage" not in s.attributes for s in spans(tel, "supervisor.request")
    )

    # ... and the metrics of the same request
    assert metrics.value(metrics.WORKER_CALLS, worker="mapper", outcome="succeeded") == 1
    assert metrics.value(metrics.WORKER_CALLS, worker="deployer", outcome="succeeded") == 1
    assert metrics.value(metrics.MODEL_CALLS, model=MODEL, outcome="succeeded") == 1
    assert metrics.value(metrics.MODEL_TOKENS, model=MODEL, kind="input") == 42
    assert metrics.value(metrics.MODEL_TOKENS, model=MODEL, kind="output") == 7
    assert metrics.value(metrics.MODEL_COST, model=MODEL) == pytest.approx(0.00125)
    assert metrics.value(metrics.CONFIRMATIONS, confirmation="first", decision="confirmed") == 1
    assert metrics.value(metrics.CONFIRMATIONS, confirmation="second", decision="confirmed") == 1
    for stage, outcome in (
        ("mapper", "succeeded"),
        ("allocator", "succeeded"),
        ("deployer", "converged"),
    ):
        count, total = metrics.histogram(metrics.STAGE_DURATION, stage=stage, outcome=outcome)
        assert count == 1 and total >= 0.0
    assert metrics.success_rate("deployer") == 1.0
    # the fabric-side join key: one service_info series for the submitted Network
    assert {
        "network": df.NETWORK,
        "namespace": df.NS,
        "correlation_id": cid,
        "construct": "mac-vrf",
    } in metrics.service_info()
    assert metrics.value(metrics.SERVICE_INFO, network=df.NETWORK, correlation_id=cid) == 1


async def test_the_traceparent_rides_the_request_metadata(fresh_telemetry: Any) -> None:
    with tracing.request_span("supervisor.request") as root:
        header = tracing.traceparent()
        message = t.build_request(
            t.KIND_STAGE,
            "map-network-request",
            {"text": "x"},
            correlation_id=root.correlation_id,
            traceparent=header,
        )
    assert header and header.split("-")[1] == root.correlation_id
    assert message.metadata[t.META]["traceparent"] == header
    # without one, the request metadata is exactly what it was before T135
    plain = t.build_request(t.KIND_STAGE, "map-network-request", None)
    assert "traceparent" not in plain.metadata[t.META]
    # a worker without a traceparent still opens its span in the correlation id's trace
    with tracing.worker_handle_span(
        "mapper", "map-network-request", traceparent_value=None, correlation_id=root.correlation_id
    ):
        pass
    handle = one(fresh_telemetry, "worker.handle")
    assert trace_id(handle) == root.correlation_id


# --------------------------------------------------------------------------------------------------
# NFR-009: the model call is recoverable, after redaction
# --------------------------------------------------------------------------------------------------


async def test_model_call_prompt_model_and_response_are_recoverable_and_redacted(
    tmp_path: Path, fresh_telemetry: Any
) -> None:
    client = LLMClient(
        llm_secret(tmp_path),
        transport=model_transport(f"The constructs are vlan and mac-vrf. password={SECRET}"),
    )
    messages = [
        {"role": "system", "content": "answer in construct vocabulary"},
        {
            "role": "user",
            "content": f"which constructs exist? api_key={SECRET} "
            "Authorization: Bearer abcdefghijklmnop0123",
        },
    ]
    with tracing.request_span("supervisor.request") as root:
        client.complete(messages)
    model = one(fresh_telemetry, "model.call")
    assert trace_id(model) == root.correlation_id
    attrs = dict(model.attributes)
    prompt = json.loads(attrs["gen_ai.prompt"])
    assert [m["role"] for m in prompt] == ["system", "user"]
    assert prompt[1]["content"].startswith("which constructs exist?")
    assert attrs["gen_ai.request.model"] == MODEL and attrs["gen_ai.system"] == "openai"
    assert attrs["gen_ai.response.model"] == "gpt-4o-2024-08-06"
    assert attrs["gen_ai.completion"].startswith("The constructs are vlan and mac-vrf.")
    assert attrs["gen_ai.usage.input_tokens"] == 42
    assert attrs["gen_ai.usage.cost"] == pytest.approx(0.00125)
    for value in attrs.values():
        text = str(value)
        assert SECRET not in text and "abcdefghijklmnop0123" not in text
        assert find_credentials(text) == []


async def test_a_model_endpoint_refusal_is_a_failed_model_call_span(
    tmp_path: Path, fresh_telemetry: Any
) -> None:
    secret = llm_secret(tmp_path)
    client = LLMClient(secret, transport=model_transport("x"))
    (secret / "BASE_URL").unlink()
    with pytest.raises(Exception, match="BASE_URL"):
        client.complete([{"role": "user", "content": "hi"}])
    model = one(fresh_telemetry, "model.call")
    assert failed(model) and "BASE_URL" in model.attributes["agentic_netops.failure.reason"]


# --------------------------------------------------------------------------------------------------
# one failure per stage: the trace names the stage, the reason and the payload
# --------------------------------------------------------------------------------------------------


def root_of(tel: Any, index: int = -1) -> Any:
    return spans(tel, "supervisor.request")[index]


async def test_a_guard_refusal_fails_the_supervisor_stage(rig: Rig, fresh_telemetry: Any) -> None:
    chunks = await rig.turn("SSH into leaf01 and run show interface")
    assert chunks[-1]["status"] == "FAILED"
    stage = one(fresh_telemetry, "stage.supervisor", **{"agentic_netops.node": "guard"})
    assert failed(stage) and stage.attributes["agentic_netops.outcome"] == "refused"
    assert "unsupported-or-unsafe" in stage.attributes["agentic_netops.failure.reason"]
    assert "SSH into leaf01" in stage.attributes["agentic_netops.failure.payload"]
    assert root_of(fresh_telemetry).attributes["agentic_netops.failed_stage"] == "supervisor"
    assert metrics.value(metrics.REFUSED_UNSAFE, **{"class": "unsupported-or-unsafe"}) == 1
    assert rig.workers.requests["mapper"] == []  # nothing reached a worker


async def test_a_refused_interpretation_fails_the_mapper_stage_with_its_payload(
    rig: Rig, fresh_telemetry: Any
) -> None:
    await rig.start("mapper", "allocator")
    rig.workers.interpretation = {
        **INTERPRETATION,
        "endpoints": [{"site_or_node": "leaf01", "attachment": "ethernet-1/1", "vlan": 1500}],
        "unsupported_properties": ["endpoints[0].vlan: 1500 is in the allocation band"],
    }
    chunks = await rig.turn(PROMPT)
    assert chunks[-1]["status"] == "FAILED"
    stage = one(fresh_telemetry, "stage.mapper")
    assert failed(stage) and stage.attributes["agentic_netops.outcome"] == "refused"
    assert "allocation band" in stage.attributes["agentic_netops.failure.reason"]
    payload = json.loads(stage.attributes["agentic_netops.failure.payload"])
    assert payload["endpoints"][0]["vlan"] == 1500
    assert root_of(fresh_telemetry).attributes["agentic_netops.failed_stage"] == "mapper"


async def test_a_schema_invalid_worker_answer_records_the_payload_that_failed(
    rig: Rig, fresh_telemetry: Any
) -> None:
    await rig.start("mapper", "allocator")
    rig.workers.interpretation = {**INTERPRETATION, "service_type": "l2vpn-bogus"}
    await rig.turn(PROMPT)
    for name in ("stage.mapper", "worker.call"):
        span = one(fresh_telemetry, name)
        assert failed(span), name
        assert "out-of-contract payload" in span.attributes["agentic_netops.failure.reason"]
        assert "l2vpn-bogus" in span.attributes["agentic_netops.failure.payload"]
        assert "service_type" in span.attributes["agentic_netops.failure.errors"]
    assert root_of(fresh_telemetry).attributes["agentic_netops.failed_stage"] == "mapper"
    assert metrics.value(metrics.WORKER_CALLS, worker="mapper", outcome="failed") == 1


async def test_the_mapper_worker_span_keeps_the_refused_interpretation(
    tmp_path: Path, fresh_telemetry: Any
) -> None:
    name, construct, vlan = next(
        c for c in REFUSE_CASES if c[0] == "refuse_vlan_named_in_allocation_band"
    )
    fx = fixture(name)
    from tests.unit.test_mapper_refusals import FakeLLM

    mapper = Mapper(
        Site(tmp_path).settings("mapper"), llm=FakeLLM(model_output(fx, construct, vlan))
    )
    with tracing.worker_handle_span(
        "mapper", "map-network-request", traceparent_value=None, correlation_id=df.CID
    ):
        await mapper.handle(
            stage_message(
                "map-network-request",
                {"text": fx["request_text"][construct].format(v=vlan), "operation": "create"},
            )
        )
    handle = one(fresh_telemetry, "worker.handle")
    assert failed(handle)
    assert f": {vlan} " in handle.attributes["agentic_netops.failure.reason"]
    payload = json.loads(handle.attributes["agentic_netops.failure.payload"])
    assert payload["endpoints"][0]["vlan"] == vlan


async def test_schema_invalid_model_output_is_kept_on_the_mapper_worker_span(
    tmp_path: Path, fresh_telemetry: Any
) -> None:
    from tests.unit.test_mapper_refusals import FakeLLM

    bad = {**INTERPRETATION, "service_type": "l2vpn-bogus"}
    mapper = Mapper(Site(tmp_path).settings("mapper"), llm=FakeLLM(bad))
    with tracing.worker_handle_span(
        "mapper", "map-network-request", traceparent_value=None, correlation_id=df.CID
    ):
        await mapper.handle(
            stage_message("map-network-request", {"text": PROMPT, "operation": "create"})
        )
    handle = one(fresh_telemetry, "worker.handle")
    assert failed(handle)
    assert "schema-invalid" in handle.attributes["agentic_netops.failure.reason"]
    assert "l2vpn-bogus" in handle.attributes["agentic_netops.failure.payload"]


async def test_an_unreachable_allocator_fails_its_call_and_stage(
    rig: Rig, fresh_telemetry: Any
) -> None:
    await rig.start("mapper")  # the allocator is scaled to zero
    first = await rig.turn(PROMPT)
    chunks = await rig.turn("confirm", first[0]["thread_id"])
    assert any(c["type"] == "error" and c.get("retryable") for c in chunks)
    call = one(fresh_telemetry, "worker.call", **{"agentic_netops.worker": "allocator"})
    assert failed(call) and call.attributes["agentic_netops.outcome"] == "unreachable"
    assert call.attributes["agentic_netops.attempts"] == 3
    stage = one(fresh_telemetry, "stage.allocator")
    assert failed(stage) and stage.attributes["agentic_netops.outcome"] == "unreachable"
    assert "worker unreachable: allocator" in stage.attributes["agentic_netops.failure.reason"]
    assert root_of(fresh_telemetry).attributes["agentic_netops.failed_stage"] == "allocator"
    assert "agentic_netops.failed_stage" not in root_of(fresh_telemetry, 0).attributes
    assert metrics.value(metrics.WORKER_CALLS, worker="allocator", outcome="unreachable") == 1
    assert (
        metrics.histogram(metrics.STAGE_DURATION, stage="allocator", outcome="unreachable")[0] == 1
    )


async def test_an_admission_refusal_fails_the_deployer_with_the_rejected_manifest(
    rig: Rig, fresh_telemetry: Any
) -> None:
    await rig.start("mapper", "allocator", "deployer")
    rig.deployer.api.services.append(
        {
            "metadata": {"name": "lab-macvrf", "namespace": df.SERVICES_NS},
            "spec": {
                "attachments": [{"node": "leaf01", "attachment": "ethernet-1/1", "vlan": 120}]
            },
        }
    )
    first = await rig.turn(PROMPT)
    thread_id = first[0]["thread_id"]
    await rig.turn("confirm", thread_id)
    chunks = await rig.turn("confirm", thread_id)
    assert chunks[-1]["status"] == "FAILED"
    tel = fresh_telemetry
    handle = one(
        tel,
        "worker.handle",
        **{"agentic_netops.worker": "deployer", "agentic_netops.operation": "create"},
    )
    assert failed(handle)
    assert "already owned by Network" in handle.attributes["agentic_netops.failure.reason"]
    manifest = json.loads(handle.attributes["agentic_netops.failure.payload"])
    assert manifest["kind"] == "Network" and manifest["metadata"]["name"] == df.NETWORK
    assert manifest["spec"]["attachments"][0]["vlan"] == 120
    stage = one(tel, "stage.deployer")
    assert failed(stage) and "already owned" in stage.attributes["agentic_netops.failure.reason"]
    assert root_of(tel).attributes["agentic_netops.failed_stage"] == "deployer"
    # the operation span names the construct: the dashboard's link back to the fabric view
    # builds the device instance name from it (T137)
    op = one(tel, "deployer.create")
    assert op.attributes["agentic_netops.construct"] in ("vlan", "mac-vrf", "ip-vrf")


# --------------------------------------------------------------------------------------------------
# the deployer: convergence span and the service_info gauge
# --------------------------------------------------------------------------------------------------


async def test_a_convergence_timeout_fails_the_convergence_span(fresh_telemetry: Any) -> None:
    deployer = df.Rig()
    report = await deployer.create()  # nothing ever converges
    assert report.status == "FAILED"
    convergence = one(fresh_telemetry, "convergence")
    assert failed(convergence) and convergence.attributes["agentic_netops.outcome"] == "timeout"
    assert "convergence timeout" in convergence.attributes["agentic_netops.failure.reason"]
    assert trace_id(convergence) == df.CID


async def test_service_info_follows_the_tier_submitted_networks(fresh_telemetry: Any) -> None:
    metrics.sync_service_info([])
    deployer = df.Rig()
    deployer.converge_at(10.0)
    assert (await deployer.create()).status == "COMPLETED"
    assert metrics.service_info() == [
        {
            "network": df.NETWORK,
            "namespace": df.NS,
            "correlation_id": df.CID,
            "construct": "mac-vrf",
        }
    ]
    assert metrics.value(metrics.SERVICE_INFO, network=df.NETWORK) == 1
    del deployer.api.networks[df.NETWORK]  # gone: the next read drops its series
    await deployer.status(tier_removed=True)
    assert metrics.service_info() == []
    assert metrics.value(metrics.SERVICE_INFO, network=df.NETWORK) == 0


def test_a_worker_operation_span_hangs_off_worker_handle() -> None:
    """The deployer's operation span is a child of the worker.handle it answers under (one
    connected trace); outside a worker.handle it is a request span in the correlation's trace."""
    from common import tracing

    telemetry = tracing.get_telemetry()
    cid = "ab" * 16
    with tracing.worker_handle_span("deployer", "deploy", traceparent_value=None,
                                    correlation_id=cid) as handle:
        with tracing.worker_operation_span("deployer.create", correlation_id=cid) as op:
            assert op.correlation_id == cid
            assert op.span.parent.span_id == handle.get_span_context().span_id
    with tracing.worker_operation_span("deployer.status", correlation_id=cid) as direct:
        assert direct.correlation_id == cid
    names = [s.name for s in telemetry.finished_spans()]
    assert "deployer.create" in names and "deployer.status" in names
