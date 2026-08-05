"""Time-dependent route planning over the learned topology + live feed.

The shortest path (fewest stops) isn't always the fastest: a train six minutes
away loses to a slightly longer ride whose train is pulling in now. So we run
Dijkstra where every boarding pays the *live* wait for the next train in that
direction (from the feed), plus the learned segment time, plus a transfer penalty
when changing lines.

The graph — every edge weight is seconds, so Dijkstra is valid:

    hub(s)        standing at station s, not on a train
    ride(s, D)    aboard a train of direction (destino) D, currently at s

    board   hub(s)     -> ride(s, D)    wait(s, D)          D has a successor from s
    ride    ride(s, D) -> ride(b, D)    segment(D, s, b)    b follows s in D
    alight  ride(s, D) -> hub(s)        transfer_penalty

The transfer penalty sits on *alight*, so it's only paid when you get off to change
lines. Arrival at the destination is read from the ride node directly (Dijkstra pops
it before the more expensive hub node), so the final leg is never charged a phantom
transfer.
"""

from __future__ import annotations

import heapq
import time
from typing import Callable

from .config import settings
from .models import RouteLeg, RoutePlan


def plan_route(
    registry,
    station_name: Callable[[str], str],
    destino_name: Callable[[str], str],
    from_stop: str,
    to_stop: str,
    now: float | None = None,
) -> RoutePlan | None:
    """Fastest route from [from_stop] to [to_stop] given what the registry has
    learned and is currently seeing. Returns None when the destination is
    unreachable from the current graph (e.g. topology not yet warmed up)."""
    now = time.time() if now is None else now

    if from_stop == to_stop:
        return RoutePlan(
            from_stop=from_stop, to_stop=to_stop, total_seconds=0.0, legs=[], generated_at=now
        )

    # Flatten the learned directions into successor adjacency + segment lookups.
    succ: dict[str, dict[str, list[str]]] = {}   # destino -> {stop: [next, ...]}
    line_of: dict[str, str] = {}                  # destino -> line
    seg: dict[tuple[str, str, str], float] = {}   # (destino, a, b) -> seconds
    for d in registry.directions():
        D = d["destino"]
        line_of[D] = d["line"]
        adj = succ.setdefault(D, {})
        for stop, pred in d["pred"].items():
            adj.setdefault(pred, []).append(stop)
        for (a, b), secs in d["segment"].items():
            seg[(D, a, b)] = secs

    default_seg = settings.default_segment_seconds
    default_headway = settings.default_headway_seconds
    transfer_penalty = settings.transfer_penalty_seconds

    source = ("hub", from_stop)
    dist: dict[tuple, float] = {source: 0.0}
    parent: dict[tuple, tuple] = {}   # node -> (prev_node, kind, meta)
    counter = 0
    pq: list[tuple[float, int, tuple]] = [(0.0, counter, source)]

    target: tuple | None = None
    while pq:
        cost, _, node = heapq.heappop(pq)
        if cost > dist.get(node, float("inf")):
            continue
        # First time we pop any node at the destination, that's the cheapest
        # arrival — and it's a ride node (hub(to) costs an extra transfer), so no
        # phantom transfer is charged at the end.
        if node[1] == to_stop and node[0] == "ride":
            target = node
            break

        edges: list[tuple[tuple, float, str, object]] = []
        if node[0] == "hub":
            s = node[1]
            for D, adj in succ.items():
                if adj.get(s):  # D has somewhere to go from s
                    live_wait = registry.wait_seconds(s, D, now)
                    live = live_wait is not None
                    wait = live_wait if live else default_headway
                    edges.append((("ride", s, D), wait, "board", (D, wait, live)))
        else:  # ride node
            _, s, D = node
            for b in succ.get(D, {}).get(s, []):
                w = seg.get((D, s, b), default_seg)
                edges.append((("ride", b, D), w, "ride", (D, b, w)))
            edges.append((("hub", s), transfer_penalty, "alight", None))

        for nxt, w, kind, meta in edges:
            nd = cost + w
            if nd < dist.get(nxt, float("inf")):
                dist[nxt] = nd
                parent[nxt] = (node, kind, meta)
                counter += 1
                heapq.heappush(pq, (nd, counter, nxt))

    if target is None:
        return None

    # Walk parents back to the source, collecting edges in travel order.
    chain: list[tuple[str, tuple, tuple, object]] = []
    node = target
    while node in parent:
        prev, kind, meta = parent[node]
        chain.append((kind, prev, node, meta))
        node = prev
    chain.reverse()

    legs: list[RouteLeg] = []
    cur: dict | None = None
    for kind, prev, node, meta in chain:
        if kind == "board":
            D, wait, live = meta
            board = prev[1]
            cur = {
                "line": line_of.get(D, ""),
                "destino": D,
                "board": board,
                "stops": [board],
                "wait": float(wait),
                "ride": 0.0,
                "live": live,
            }
        elif kind == "ride":
            _, b, w = meta
            cur["stops"].append(b)
            cur["ride"] += float(w)
        elif kind == "alight":
            legs.append(_finalize(cur, station_name, destino_name))
            cur = None
    if cur is not None:
        legs.append(_finalize(cur, station_name, destino_name))

    # Drop any zero-length leg (board+alight at the same station — shouldn't be
    # optimal, but never emit one).
    legs = [lg for lg in legs if lg.num_stops > 0]

    return RoutePlan(
        from_stop=from_stop,
        to_stop=to_stop,
        total_seconds=round(dist[target], 1),
        legs=legs,
        generated_at=now,
    )


def _finalize(cur: dict, station_name, destino_name) -> RouteLeg:
    stops = cur["stops"]
    return RouteLeg(
        line=cur["line"],
        destino=cur["destino"],
        destino_name=destino_name(cur["destino"]),
        board_stop=stops[0],
        board_stop_name=station_name(stops[0]),
        alight_stop=stops[-1],
        alight_stop_name=station_name(stops[-1]),
        stop_names=[station_name(s) for s in stops],
        num_stops=len(stops) - 1,
        wait_seconds=round(cur["wait"], 1),
        ride_seconds=round(cur["ride"], 1),
        live=cur["live"],
    )
