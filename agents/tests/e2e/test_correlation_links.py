"""T138 — the correlation link, followed in both directions, with no timestamp (SC-039; FR-093,
FR-095, R-19; quickstart.md §27).

From the **fabric service view** of a tier-created service (Grafana ``evpn-service-path``, whose
``service`` variable is the device network-instance name) to the **agent conversation** that created
it (Grafana ``intent-tier``, its conversation-trace panel reading the analytics store), and back —
each hop taken the way a click takes it: the link template is read from the provisioned dashboard
through Grafana's API, rendered with the row it hangs off, checked to carry the correlation
identifier or the service and **no time range**, and the query the destination panel runs is run
through Grafana with the rendered variable.
"""

from __future__ import annotations

import re
from typing import Any

import pytest
from conftest import record, wait_for
from obsflow import (
    CORRELATION_LABEL,
    TIME_MARKERS,
    grafana,
    link_to,
    panel_links,
    panels,
    prom_query,
    query_params,
    render_link,
    service_info,
    wait_trace,
)
from tierflow import network

FABRIC_VIEW = "agentic-netops-evpn-service-path"
TIER_VIEW = "intent-tier"
ANALYTICS_UID = "agent-analytics"
PREFIX = {"vlan": "vlan-", "mac-vrf": "macvrf-", "ip-vrf": "ipvrf-"}


def untimed(url: str) -> None:
    for marker in TIME_MARKERS:
        assert marker not in url, f"link carries a time filter ({marker}): {url}"


def panel_with(dashboard: dict[str, Any], predicate: Any) -> dict[str, Any]:
    for p in panels(dashboard):
        if predicate(p):
            return p
    raise AssertionError(f"no matching panel in {dashboard.get('uid')}")


def is_trace_panel(p: dict[str, Any]) -> bool:
    return (p.get("datasource") or {}).get("uid") == ANALYTICS_UID or any(
        (t.get("datasource") or {}).get("uid") == ANALYTICS_UID for t in p.get("targets") or [])


def is_created_by_panel(p: dict[str, Any]) -> bool:
    return any("agentic_netops_agent_service_info" in (t.get("expr") or "")
               for t in p.get("targets") or [])


@pytest.fixture(scope="module")
def ctx(traced_service: Any) -> dict[str, Any]:
    cid = traced_service.correlation_id
    obj = network(traced_service.network)
    assert obj and obj["metadata"]["labels"][CORRELATION_LABEL] == cid
    wait_for("service_info in Prometheus", lambda: bool(service_info(traced_service.network)),
             timeout=180, every=5)
    wait_trace(cid, lambda s: any(x["span"] == "convergence" for x in s))
    info = service_info(traced_service.network)[0]
    # the device instance is named from the service id — the Network name without the tier's
    # migr- prefix (internal/model/names.go)
    service_id = traced_service.network.removeprefix("migr-")
    return {"svc": traced_service, "cid": cid, "info": info, "service_id": service_id,
            "instance": PREFIX[info["construct"]] + service_id}


def fabric_vars(expr: str, instance: str, service_id: str) -> str:
    """The fabric view's variables as they resolve once ``service`` is chosen."""
    for name, val in (("service_id", service_id), ("service", instance)):
        expr = expr.replace("${" + name + "}", val).replace("$" + name, val)
    return expr


def test_fabric_view_to_conversation_and_back(ctx: dict[str, Any]) -> None:
    cid, instance, service_id = ctx["cid"], ctx["instance"], ctx["service_id"]
    hops: dict[str, Any] = {"correlation_id": cid, "service": instance}
    with grafana() as gf:
        fabric = gf.dashboard(FABRIC_VIEW)
        tier = gf.dashboard(TIER_VIEW)

        # ---- hop 1: the fabric service view's "created by conversation" panel → intent-tier
        created = panel_with(fabric, is_created_by_panel)
        expr = next(t["expr"] for t in created["targets"] if "service_info" in t.get("expr", ""))
        rows = prom_query(fabric_vars(expr, instance, service_id))
        assert rows, f"the fabric view's panel finds no conversation for {instance}: {expr}"
        row = rows[0]["metric"]
        assert row.get("correlation_id") == cid, row
        link = link_to(panel_links(created), TIER_VIEW)
        url = render_link(link["url"], {**row, "service": instance, "service_id": service_id})
        untimed(url)
        assert query_params(url).get("var-correlation_id") == [cid], url
        hops["fabric_to_conversation"] = url

        # ---- the conversation itself: the trace panel's query with that variable, through Grafana
        tpanel = panel_with(tier, is_trace_panel)
        sql = next(t["rawSql"] for t in tpanel["targets"] if t.get("rawSql"))
        assert "$__timeFilter" not in sql and "$__timeFrom" not in sql, sql
        spans = gf.sql(ANALYTICS_UID, sql.replace("${correlation_id}", cid)
                       .replace("$correlation_id", cid))
        assert spans, f"the conversation trace panel returned nothing for {cid}"
        names = {str(v) for r in spans for v in r.values()}
        assert "convergence" in names and "stage.deployer" in names, sorted(names)[:40]
        hops["conversation_rows"] = len(spans)

        # ---- hop 2: from the conversation back to the fabric service view
        back = link_to(panel_links(tpanel), FABRIC_VIEW)
        target_row = next((r for r in spans if instance in {str(v) for v in r.values()}), None)
        assert target_row is not None, f"no trace row names the service instance {instance}"
        url2 = render_link(back["url"], {k: str(v) for k, v in target_row.items()}
                           | {"correlation_id": cid})
        untimed(url2)
        params = query_params(url2)
        assert params.get("var-service") == [instance], url2
        assert params.get("var-service_id") == [service_id], url2
        hops["conversation_to_fabric"] = url2

        # the fabric view the link opens shows that service: its own variable resolves, and the
        # "created by" panel there closes the loop on the same correlation identifier
        instances = prom_query(f'count by (network_instance_name) ({{network_instance_name="'
                               f'{instance}"}})')
        assert instances, f"no fabric series for {instance}"
        again = prom_query(fabric_vars(expr, instance, service_id))
        assert again[0]["metric"]["correlation_id"] == cid
    record("t138-correlation-links", hops)


def test_links_carry_no_time_range_anywhere() -> None:
    with grafana() as gf:
        for uid in (FABRIC_VIEW, TIER_VIEW):
            dash = gf.dashboard(uid)
            for p in panels(dash):
                for link in panel_links(p):
                    if re.search(rf"/d/({FABRIC_VIEW}|{TIER_VIEW})", link.get("url", "")):
                        untimed(link["url"])
                        assert not link.get("keepTime"), link
