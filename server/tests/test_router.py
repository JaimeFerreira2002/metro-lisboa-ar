"""Route planner tests.

These build a Registry the same way the poller does — by feeding it synthetic
tempoEspera entries — so they exercise the real adjacency/segment learning and the
live-wait lookup, not a mock. `now` is pinned to the capture time so ETAs are used
as-is (dt = 0).
"""

from __future__ import annotations

import pytest

from app.registry import Registry
from app.router import plan_route

NOW = 1000.0

_SLOTS = [("comboio", "tempoChegada1"), ("comboio2", "tempoChegada2"), ("comboio3", "tempoChegada3")]

NAMES = {"A": "Alpha", "B": "Bravo", "C": "Charlie", "Z": "Zeta"}


def _entry(stop: str, destino: str, trains: list[tuple[str, float]]) -> dict:
    """One platform entry: the upcoming trains (train_id, eta) at `stop`."""
    e = {"stop_id": stop, "destino": destino}
    for (tk, ek), (tid, eta) in zip(_SLOTS, trains):
        e[tk] = tid
        e[ek] = eta
    return e


def _name(sid: str) -> str:
    return NAMES.get(sid, sid)


def _dname(d: str) -> str:
    return {"90": "Zeta (direct)", "10": "Zeta (via Charlie)", "1": "Bravo", "2": "Zeta"}.get(d, d)


def test_longer_path_wins_when_its_train_is_closer():
    """A → Z has a direct 2-hop ride on one line whose next train is 300 s out, and
    a 3-stop ride on another line whose train is pulling in now. The planner must
    take the longer ride because it arrives sooner."""
    reg = Registry()
    # Direct line (Verde, destino 90): train P1 is 300 s from A, 420 s from Z.
    reg.ingest_line("Verde", [
        _entry("A", "90", [("P1", 300)]),
        _entry("Z", "90", [("P1", 420)]),
    ], captured_at=NOW)
    # Indirect line (Azul, destino 10): train Q1 is 10 s from A, then C, then Z.
    reg.ingest_line("Azul", [
        _entry("A", "10", [("Q1", 10)]),
        _entry("C", "10", [("Q1", 70)]),
        _entry("Z", "10", [("Q1", 130)]),
    ], captured_at=NOW)

    plan = plan_route(reg, _name, _dname, "A", "Z", now=NOW)

    assert plan is not None
    # 10 s wait + 60 + 60 ride = 130, beating the direct 300 + 120 = 420.
    assert plan.total_seconds == pytest.approx(130.0, abs=0.5)
    assert len(plan.legs) == 1
    leg = plan.legs[0]
    assert leg.line == "Azul"
    assert leg.num_stops == 2
    assert leg.stop_names == ["Alpha", "Charlie", "Zeta"]
    assert leg.wait_seconds == pytest.approx(10.0, abs=0.5)
    assert leg.ride_seconds == pytest.approx(120.0, abs=0.5)
    assert leg.live is True


def test_transfer_route_has_two_legs_and_pays_the_penalty():
    """No direct line A → Z: ride line Azul A→B, change to Verde B→Z."""
    reg = Registry()
    reg.ingest_line("Azul", [
        _entry("A", "1", [("X1", 5)]),
        _entry("B", "1", [("X1", 65)]),
    ], captured_at=NOW)
    reg.ingest_line("Verde", [
        _entry("B", "2", [("Y1", 20)]),
        _entry("Z", "2", [("Y1", 80)]),
    ], captured_at=NOW)

    plan = plan_route(reg, _name, _dname, "A", "Z", now=NOW)

    assert plan is not None
    assert len(plan.legs) == 2
    assert plan.legs[0].line == "Azul"
    assert plan.legs[0].board_stop == "A" and plan.legs[0].alight_stop == "B"
    assert plan.legs[1].line == "Verde"
    assert plan.legs[1].board_stop == "B" and plan.legs[1].alight_stop == "Z"
    # 5 wait + 60 ride + 90 transfer + 20 wait + 60 ride = 235.
    assert plan.total_seconds == pytest.approx(235.0, abs=0.5)


def test_same_station_is_a_zero_length_plan():
    reg = Registry()
    plan = plan_route(reg, _name, _dname, "A", "A", now=NOW)
    assert plan is not None
    assert plan.total_seconds == 0.0
    assert plan.legs == []


def test_unreachable_returns_none():
    reg = Registry()
    reg.ingest_line("Azul", [
        _entry("A", "1", [("X1", 5)]),
        _entry("B", "1", [("X1", 65)]),
    ], captured_at=NOW)
    # Z is never observed, so it isn't in the graph.
    assert plan_route(reg, _name, _dname, "A", "Z", now=NOW) is None
