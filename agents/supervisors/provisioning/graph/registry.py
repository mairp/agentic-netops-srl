"""The supervisor's durable record of what the tier itself did (T101; FR-026, FR-067, FR-105,
AD-58).

Two small tables in the same SQLite file as the thread checkpoints (``SUPERVISOR_CHECKPOINT_PATH``,
the ``supervisor-checkpoint`` PVC): they survive a restart exactly as the threads do, and they
span threads — a service created on one thread may be asked about or removed on another.

``tier_removals``
    The removals the tier issued. A ``Network`` that is gone is *deleted outside the intent tier*
    unless the tier removed it, and the supervisor is the process that knows which removals the
    tier issued — the deployer only executes them — so every deployer ``status`` request carries
    ``tier_removed`` from here. A row is written *before* the remove request is sent (a delete
    that lands and whose answer is lost is still the tier's) and dropped again only when the
    request provably never reached the deployer or the deployer refused it.

``tier_services``
    The services the tier submitted and their construct, so that a removal's confirmations name
    the construct (FR-026) even when it is asked on another thread than the creation.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

SCHEMA = (
    "CREATE TABLE IF NOT EXISTS tier_removals ("
    " network TEXT PRIMARY KEY, correlation_id TEXT NOT NULL, principal TEXT NOT NULL,"
    " at TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS tier_services ("
    " network TEXT PRIMARY KEY, construct TEXT NOT NULL, correlation_id TEXT NOT NULL,"
    " at TEXT NOT NULL)",
)


def _now() -> str:
    return datetime.now(UTC).isoformat()


class TierRegistry:
    """``tier_removals`` and ``tier_services`` on an open ``aiosqlite`` connection."""

    def __init__(self, conn: Any) -> None:
        self._conn = conn

    async def setup(self) -> None:
        for statement in SCHEMA:
            await self._conn.execute(statement)
        await self._conn.commit()

    # ------------------------------------------------------------------------------ removals

    async def record_removal(self, network: str, *, correlation_id: str,
                             principal: str) -> None:
        await self._conn.execute(
            "INSERT OR REPLACE INTO tier_removals (network, correlation_id, principal, at) "
            "VALUES (?, ?, ?, ?)", (network, correlation_id, principal, _now()))
        await self._conn.commit()

    async def forget_removal(self, network: str) -> None:
        await self._conn.execute("DELETE FROM tier_removals WHERE network = ?", (network,))
        await self._conn.commit()

    async def removed(self, network: str) -> bool:
        async with self._conn.execute(
                "SELECT 1 FROM tier_removals WHERE network = ?", (network,)) as cursor:
            return (await cursor.fetchone()) is not None

    # ------------------------------------------------------------------------------ services

    async def record_service(self, network: str, *, construct: str,
                             correlation_id: str) -> None:
        await self._conn.execute(
            "INSERT OR REPLACE INTO tier_services (network, construct, correlation_id, at) "
            "VALUES (?, ?, ?, ?)", (network, construct, correlation_id, _now()))
        await self._conn.commit()

    async def construct(self, network: str) -> str | None:
        async with self._conn.execute(
                "SELECT construct FROM tier_services WHERE network = ?", (network,)) as cursor:
            row = await cursor.fetchone()
        return str(row[0]) if row else None


__all__ = ["SCHEMA", "TierRegistry"]
