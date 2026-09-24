"""T127 — the scripted browser session over the operator chat surface (SC-019; quickstart.md §9).

The whole exchange is driven through the browser only — Playwright at the exact version
``agents/pyproject.toml`` pins, with the browser build that version fixes (``make verify-pins
VERIFY_PINS_FLAGS=--host-tooling`` runs first, from ``tests/e2e/chat_surface_e2e.sh``, and the
versions used are written into the run's evidence). Nothing here posts to the supervisor: every
request, confirmation and decline is typed or clicked in the page served on the Kind loopback
mapping (``http://127.0.0.1:13000``). The cluster is only *read*, through ``kubectl``, as the
independent witness of what the page reports:

* login — a wrong password stays on the form with nothing of the pipeline rendered; the accepted
  credential is held in memory only (the page's ``localStorage``, ``sessionStorage`` and cookies
  are empty after the whole session);
* one L2 construct (``mac-vrf``) and one L3 construct (``ip-vrf``) provisioned — both
  confirmations clicked, convergence rendered live without a reload, the ``Network`` read back
  ``Ready=True`` under the correlation id the page's chip shows — then removed through the page;
* a decline at the second confirmation cancels cleanly — no ``Network``, zero claims under the
  request's correlation label, and the thread stays amendable;
* a forced stage failure — a ``vlan`` on the (node, port, VLAN) ``lab-vlan`` already holds in
  ``agentic-netops-services``, which the deployer's pre-flight cannot see and admission refuses —
  shows the deployer stage in operator terms with a readable reason and the correlation id, never
  a stack trace.
"""

from __future__ import annotations

import json
import os
import re
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from conftest import INTENT_NS, kjson
from tierflow import claims_of, network, operator_login, wait_gone

UI_URL = os.environ.get("UI_URL", "http://127.0.0.1:13000")
STEP_MS = int(os.environ.get("CHAT_STEP_TIMEOUT_MS", "600000"))  # a real model is in the loop
TRACEBACK = re.compile(
    r"Traceback \(most recent call last\)|File \"[^\"]+\", line \d+|"
    r"\bat [\w.$<>]+ \([^)]*:\d+:\d+\)"
)

L2_PROMPT = (
    "Create a mac-vrf for tenant umbrella that extends VLAN 180 across leaf01 "
    "ethernet-1/1 and leaf02 ethernet-1/1"
)
L3_PROMPT = (
    "Create an ip-vrf for tenant umbrella on leaf01 ethernet-1/1 and leaf02 "
    "ethernet-1/1 using VLAN 280, with prefixes 10.61.0.0/24 and 2001:db8:61::/64"
)
DECLINE_PROMPT = (
    "Create a mac-vrf for tenant hooli across leaf01 ethernet-1/1 and leaf02 "
    "ethernet-1/1 and allocate its VLAN"
)
# lab-vlan (examples/constructs/vlan.yaml, agentic-netops-services) holds leaf01 ethernet-1/1
# VLAN 110: the tier's pre-flight cannot see that namespace, admission refuses the dry-run
FAILING_PROMPT = "Create a vlan for tenant hooli on leaf01 ethernet-1/1 with VLAN 110"


def evidence_path(name: str) -> Path | None:
    base = os.environ.get("EVIDENCE_DIR")
    if not base:
        return None
    path = Path(base) / "t127" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def record(name: str, payload: Any) -> None:
    path = evidence_path(f"{name}.json")
    if path:
        path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


@pytest.fixture(scope="module")
def browser() -> Iterator[Any]:
    from playwright.sync_api import sync_playwright

    with sync_playwright() as pw:
        chromium = pw.chromium.launch(headless=True)
        record("browser", {"browser": "chromium", "version": chromium.version, "ui_url": UI_URL})
        yield chromium
        chromium.close()


@pytest.fixture(scope="module")
def session(browser: Any) -> Iterator[Any]:
    """One logged-in page for the whole module; the login gate is asserted on the way in."""
    context = browser.new_context()
    page = context.new_page()
    page.set_default_timeout(STEP_MS)
    user, password = operator_login()
    page.goto(UI_URL)
    page.get_by_test_id("login-form").wait_for()

    # a wrong credential stays on the form, and nothing of the pipeline is rendered
    page.get_by_test_id("login-username").fill(user)
    page.get_by_test_id("login-password").fill(password + "-wrong")
    page.get_by_test_id("login-submit").click()
    page.get_by_test_id("login-error").wait_for()
    assert page.get_by_test_id("prompt-input").count() == 0
    assert page.get_by_test_id("login-form").is_visible()

    page.get_by_test_id("login-password").fill(password)
    page.get_by_test_id("login-submit").click()
    page.get_by_test_id("prompt-input").wait_for()
    assert page.get_by_test_id("login-form").count() == 0
    yield page

    storage = page.evaluate(
        "() => ({local: Object.keys(localStorage).length, "
        "session: Object.keys(sessionStorage).length, "
        "cookie: document.cookie})"
    )
    cookies = context.cookies()
    record("storage-after-session", {"storage": storage, "cookies": cookies})
    shot = evidence_path("final-page.png")
    if shot:
        page.screenshot(path=str(shot), full_page=True)
    context.close()
    assert storage == {"local": 0, "session": 0, "cookie": ""}, storage
    assert cookies == [], cookies


# --------------------------------------------------------------------------------------------------
# page helpers — every one of them acts through the page
# --------------------------------------------------------------------------------------------------


def new_thread(page: Any) -> None:
    button = page.get_by_test_id("new-thread")
    if button.count():
        button.click()


def send(page: Any, text: str) -> None:
    page.get_by_test_id("prompt-input").fill(text)
    page.get_by_test_id("prompt-send").click()


def wait_idle(page: Any) -> None:
    """The turn has ended: the send button is enabled again."""
    page.wait_for_function(
        "() => { const b = document.querySelector('[data-testid=\"prompt-send\"]');"
        " return b && !b.disabled && !document.querySelector('[data-streaming=\"true\"]'); }",
        timeout=STEP_MS,
    )


def count(page: Any, test_id: str) -> int:
    return page.get_by_test_id(test_id).count()


def await_confirmation(page: Any, stage: str, before: int) -> Any:
    """The next confirmation of ``stage`` (retrying a fresh request when the model asked a
    clarifying question instead — its phrasing is not what is under test)."""
    locator = page.locator(f'[data-testid="confirmation"][data-stage="{stage}"]')
    locator.nth(before).wait_for(timeout=STEP_MS)
    return locator.nth(before)


def request_to_first_confirmation(page: Any, prompt: str, attempts: int = 3) -> Any:
    for _ in range(attempts):
        new_thread(page)
        before = page.locator('[data-testid="confirmation"][data-stage="mapper"]').count()
        send(page, prompt)
        wait_idle(page)
        if page.locator('[data-testid="confirmation"][data-stage="mapper"]').count() > before:
            return page.locator('[data-testid="confirmation"][data-stage="mapper"]').nth(before)
    body = page.inner_text("body")[-3000:]
    raise AssertionError(f"no first confirmation for {prompt!r}:\n{body}")


def click_in(card: Any, test_id: str) -> None:
    card.get_by_test_id(test_id).click()


def last(page: Any, test_id: str) -> Any:
    loc = page.get_by_test_id(test_id)
    return loc.nth(loc.count() - 1)


def correlation_id(page: Any) -> str:
    chip = last(page, "correlation-chip")
    value = chip.get_attribute("data-correlation-id") or chip.inner_text()
    found = re.search(r"[0-9a-f]{32}", value)
    assert found, value
    return found.group(0)


def resources_on_page(page: Any) -> list[str]:
    text = page.inner_text("body")
    return sorted(set(re.findall(r"migr-[0-9a-z-]+", text)))


def provision_through_page(page: Any, prompt: str, construct: str) -> dict[str, Any]:
    first = request_to_first_confirmation(page, prompt)
    assert construct in first.inner_text().lower() or construct in page.inner_text("body").lower()
    # the interpretation is a distinct, labelled step with its payload readable
    stage = last(page, "stage-card")
    assert stage.get_attribute("data-stage") == "mapper", stage.get_attribute("data-stage")
    cid = correlation_id(page)

    n_alloc = page.locator('[data-testid="confirmation"][data-stage="allocator"]').count()
    click_in(first, "confirm-button")
    second = await_confirmation(page, "allocator", n_alloc)
    wait_idle(page)
    assignment_text = last(page, "stage-card").inner_text()

    started = time.monotonic()
    url_before = page.url
    click_in(second, "confirm-button")
    final = page.locator('[data-testid="final"]').last
    page.wait_for_function(
        "() => [...document.querySelectorAll('[data-testid=\"final\"]')].some("
        "e => e.dataset.status === 'COMPLETED' || e.dataset.status === 'FAILED' ||"
        " e.dataset.status === 'STATUS_UNKNOWN')",
        timeout=STEP_MS,
    )
    wait_idle(page)
    elapsed = time.monotonic() - started
    assert page.url == url_before  # convergence arrived on the page with no reload
    status = final.get_attribute("data-status")
    assert status == "COMPLETED", page.inner_text("body")[-3000:]
    progress = [p.get_attribute("data-ready") for p in page.get_by_test_id("progress").all()]
    assert "True" in progress, progress
    final_text = final.inner_text()
    assert "COMPLETED" not in final_text  # the redacted message, not the status token

    # the independent witness: the Network the tier created under this correlation id
    nets = kjson(
        "-n",
        INTENT_NS,
        "get",
        "networks.fabric.agentic-netops.io",
        "-l",
        f"agentic-netops.io/correlation-id={cid}",
    )["items"]
    assert len(nets) == 1, [n["metadata"]["name"] for n in nets]
    live = nets[0]
    ready = {c["type"]: c for c in live["status"]["conditions"]}["Ready"]
    assert ready["status"] == "True", ready
    name = live["metadata"]["name"]
    assert name in page.inner_text("body")
    return {
        "construct": construct,
        "network": name,
        "correlation_id": cid,
        "approval_to_converged_seconds": round(elapsed, 2),
        "progress_ready": progress,
        "final_text": final_text,
        "assignment_card": assignment_text[:2000],
        "live_ready": ready,
        "live_spec": live["spec"],
        "resource_version": live["metadata"]["resourceVersion"],
    }


def remove_through_page(page: Any, name: str) -> dict[str, Any]:
    new_thread(page)
    before = page.locator('[data-testid="confirmation"]').count()
    send(page, f"Remove the service {name}")
    wait_idle(page)
    clicks = 0
    while page.locator('[data-testid="confirmation"]').count() > before and clicks < 2:
        card = page.locator('[data-testid="confirmation"]').nth(before + clicks)
        click_in(card, "confirm-button")
        clicks += 1
        wait_idle(page)
    final = last(page, "final")
    status = final.get_attribute("data-status")
    progress = [
        (p.get_attribute("data-ready"), p.get_attribute("data-reason"))
        for p in page.get_by_test_id("progress").all()
    ]
    if status == "PROVISIONING":  # in progress, never converged and never an error card
        assert final.locator("xpath=ancestor::*[@data-testid='error-card']").count() == 0
        assert "progress" in final.inner_text().lower(), final.inner_text()
        wait_gone(name, timeout=300)
    else:
        assert status == "COMPLETED", page.inner_text("body")[-3000:]
    assert network(name) is None
    return {
        "network": name,
        "confirmations_clicked": clicks,
        "final_status": status,
        "final_text": final.inner_text(),
        "progress": progress[-4:],
    }


# --------------------------------------------------------------------------------------------------
# the session
# --------------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("construct", "prompt"),
    [("mac-vrf", L2_PROMPT), ("ip-vrf", L3_PROMPT)],
    ids=["l2-mac-vrf", "l3-ip-vrf"],
)
def test_provision_through_the_page(session: Any, construct: str, prompt: str) -> None:
    created = provision_through_page(session, prompt, construct)
    shot = evidence_path(f"{construct}-converged.png")
    if shot:
        session.screenshot(path=str(shot), full_page=True)
    held = sorted(c["metadata"]["name"] for c in claims_of(created["correlation_id"]))
    removed = remove_through_page(session, created["network"])
    after = sorted(c["metadata"]["name"] for c in claims_of(created["correlation_id"]))
    assert after == [], after
    record(
        f"provision-{construct}",
        {**created, "claims_while_live": held, "removal": removed, "claims_after_removal": after},
    )


def test_decline_cancels_cleanly(session: Any) -> None:
    page = session
    first = request_to_first_confirmation(page, DECLINE_PROMPT)
    cid = correlation_id(page)
    n_alloc = page.locator('[data-testid="confirmation"][data-stage="allocator"]').count()
    click_in(first, "confirm-button")
    second = await_confirmation(page, "allocator", n_alloc)
    wait_idle(page)
    held = sorted(c["metadata"]["name"] for c in claims_of(cid))
    assert held, "the assignment claimed nothing, so the decline would release nothing"
    click_in(second, "decline-button")
    wait_idle(page)
    final = last(page, "final")
    text = final.inner_text()
    assert "declin" in text.lower(), text
    assert final.get_attribute("data-status") != "COMPLETED"
    assert claims_of(cid) == []
    nets = kjson(
        "-n",
        INTENT_NS,
        "get",
        "networks.fabric.agentic-netops.io",
        "-l",
        f"agentic-netops.io/correlation-id={cid}",
    )["items"]
    assert nets == []
    # the thread stays amendable: the input is enabled on the same thread and is answered
    thread = last(page, "thread-id").inner_text()
    assert page.get_by_test_id("prompt-input").is_enabled()
    n_final = count(page, "final")
    send(page, "What constructs can I ask for?")
    wait_idle(page)
    assert count(page, "final") > n_final
    assert last(page, "thread-id").inner_text() == thread
    shot = evidence_path("decline.png")
    if shot:
        page.screenshot(path=str(shot), full_page=True)
    record(
        "decline",
        {
            "correlation_id": cid,
            "thread": thread,
            "claims_held_before_decline": held,
            "claims_after_decline": [],
            "networks": [],
            "final_text": text,
        },
    )


def test_forced_stage_failure_is_readable(session: Any) -> None:
    page = session
    holder = kjson(
        "-n", "agentic-netops-services", "get", "networks.fabric.agentic-netops.io", "lab-vlan"
    )
    assert any(
        a.get("vlan") == 110 and a.get("node") == "leaf01" for a in holder["spec"]["attachments"]
    ), holder["spec"]
    first = request_to_first_confirmation(page, FAILING_PROMPT)
    cid = correlation_id(page)
    n_alloc = page.locator('[data-testid="confirmation"][data-stage="allocator"]').count()
    click_in(first, "confirm-button")
    second = await_confirmation(page, "allocator", n_alloc)
    wait_idle(page)
    n_err = count(page, "error-card")
    click_in(second, "confirm-button")
    wait_idle(page)
    assert count(page, "error-card") > n_err, page.inner_text("body")[-3000:]
    card = last(page, "error-card")
    text = card.inner_text()
    assert card.get_attribute("data-stage") == "deployer", card.get_attribute("data-stage")
    assert "deploy" in text.lower(), text  # the stage in operator terms
    assert cid in (
        card.get_by_test_id("correlation-chip").get_attribute("data-correlation-id")
        or card.inner_text()
    )
    assert "lab-vlan" in text or "110" in text, text  # the reason names what refused it
    assert not TRACEBACK.search(page.inner_text("body")), "a stack trace reached the page"
    assert (
        kjson(
            "-n",
            INTENT_NS,
            "get",
            "networks.fabric.agentic-netops.io",
            "-l",
            f"agentic-netops.io/correlation-id={cid}",
        )["items"]
        == []
    )
    assert claims_of(cid) == []
    shot = evidence_path("forced-failure.png")
    if shot:
        page.screenshot(path=str(shot), full_page=True)
    record(
        "forced-failure",
        {
            "correlation_id": cid,
            "error_card": text,
            "stage": card.get_attribute("data-stage"),
            "holder": "agentic-netops-services/lab-vlan",
        },
    )
