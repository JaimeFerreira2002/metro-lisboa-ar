"""Train registry + position estimator.

Turns raw tempoEspera entries into positioned trains:
- groups the three upcoming-train slots per platform back into per-train itineraries
  (each train's ordered list of stations with seconds-to-arrival);
- learns station adjacency and segment travel times from the feed itself
  (the station *behind* a train is the predecessor of its next station);
- interpolates position along the segment the train is currently on, and advances
  it between polls so it glides and never jumps backward.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

from . import geo
from .config import settings
from .models import LineStatus, TrainPosition
from .reference import Reference

STALE_AFTER = 90.0          # drop trains whose last poll is older than this
_SLOTS = [("comboio", "tempoChegada1"), ("comboio2", "tempoChegada2"), ("comboio3", "tempoChegada3")]


def _eta(value) -> float | None:
    if value in (None, "", "--"):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


@dataclass
class TrainObservation:
    line: str
    destino: str
    itinerary: list[tuple[str, float]]  # (stop_id, eta_at_capture), sorted by eta
    captured_at: float


@dataclass
class Registry:
    trains: dict[str, TrainObservation] = field(default_factory=dict)
    line_status: dict[str, LineStatus] = field(default_factory=dict)
    # direction (destino) -> {stop: predecessor_stop}
    _pred: dict[str, dict[str, str]] = field(default_factory=dict)
    # (destino, from, to) -> EMA segment seconds
    _segment: dict[tuple[str, str, str], float] = field(default_factory=dict)
    # destino -> line it belongs to (learned from the feed, for route planning)
    _destino_line: dict[str, str] = field(default_factory=dict)

    def ingest_line(self, line: str, entries: list[dict], captured_at: float) -> None:
        # Invert platforms -> per-train (stop, eta) sightings.
        sightings: dict[str, dict] = {}
        for entry in entries:
            stop = entry.get("stop_id")
            destino = str(entry.get("destino", ""))
            if not stop:
                continue
            for train_key, eta_key in _SLOTS:
                train = entry.get(train_key)
                eta = _eta(entry.get(eta_key))
                if not train or eta is None:
                    continue
                rec = sightings.setdefault(train, {"destino": destino, "stops": {}})
                # keep the smallest eta if a train shows at the same stop twice
                rec["stops"][stop] = min(eta, rec["stops"].get(stop, eta))

        for train, rec in sightings.items():
            itinerary = sorted(rec["stops"].items(), key=lambda kv: kv[1])
            self.trains[train] = TrainObservation(line, rec["destino"], itinerary, captured_at)
            self._destino_line[rec["destino"]] = line
            self._learn(rec["destino"], itinerary)

    def _learn(self, destino: str, itinerary: list[tuple[str, float]]) -> None:
        pred = self._pred.setdefault(destino, {})
        for (a, eta_a), (b, eta_b) in zip(itinerary, itinerary[1:]):
            seg = eta_b - eta_a
            if 0 < seg < 600 and a != b:
                pred[b] = a
                key = (destino, a, b)
                prev = self._segment.get(key)
                self._segment[key] = seg if prev is None else 0.7 * prev + 0.3 * seg

    def set_line_status(self, status: LineStatus) -> None:
        self.line_status[status.line] = status

    def prune(self, now: float) -> None:
        dead = [t for t, o in self.trains.items() if now - o.captured_at > STALE_AFTER]
        for t in dead:
            del self.trains[t]

    def arrivals_at(self, ref: Reference, stop_id: str, now: float | None = None, limit: int = 6) -> list[dict]:
        """Upcoming trains at a station, soonest first — for the station schedule view."""
        now = time.time() if now is None else now
        out: list[dict] = []
        for train_id, obs in self.trains.items():
            dt = now - obs.captured_at
            if dt > STALE_AFTER:
                continue
            etas = [eta - dt for stop, eta in obs.itinerary if stop == stop_id and eta - dt > 0]
            if not etas:
                continue
            out.append({
                "train_id": train_id,
                "line": obs.line,
                "destino": obs.destino,
                "destino_name": ref.destino_name(obs.destino),
                "eta_seconds": round(min(etas), 1),
            })
        out.sort(key=lambda a: a["eta_seconds"])
        return out[:limit]

    # ---- route-planning views over the learned topology + live feed ----

    def directions(self) -> list[dict]:
        """One entry per learned direction (destino), for the route planner:
        its line, the predecessor map, and the known segment times. This is the
        whole graph the planner walks — adjacency and edge weights, direction by
        direction."""
        out = []
        for destino, pred in self._pred.items():
            segs = {
                (a, b): sec for (d, a, b), sec in self._segment.items() if d == destino
            }
            out.append({
                "destino": destino,
                "line": self._destino_line.get(destino, ""),
                "pred": dict(pred),          # {stop: predecessor}
                "segment": segs,             # {(from, to): seconds}
            })
        return out

    def wait_seconds(self, stop_id: str, destino: str, now: float | None = None) -> float | None:
        """Seconds until the next live train heading in direction [destino] reaches
        [stop_id] and still has stops beyond it (i.e. you can board here and ride
        onward). None when no such train is currently observed — the planner then
        falls back to a nominal headway."""
        now = time.time() if now is None else now
        best: float | None = None
        for obs in self.trains.values():
            if obs.destino != destino:
                continue
            dt = now - obs.captured_at
            if dt > STALE_AFTER:
                continue
            etas = {s: e for s, e in obs.itinerary}
            here = etas.get(stop_id)
            if here is None:
                continue
            adjusted = here - dt
            if adjusted <= 0:
                continue
            # The train must continue past this stop for boarding to be useful.
            if not any(e > here for s, e in obs.itinerary):
                continue
            best = adjusted if best is None else min(best, adjusted)
        return best

    def snapshot(self, ref: Reference, track=None, now: float | None = None) -> list[TrainPosition]:
        now = time.time() if now is None else now
        out: list[TrainPosition] = []
        for train_id, obs in self.trains.items():
            dt = now - obs.captured_at
            if dt > STALE_AFTER:
                continue
            # advance ETAs to "now", find the next not-yet-passed station
            adjusted = [(stop, eta - dt) for stop, eta in obs.itinerary]
            ahead = [(s, e) for s, e in adjusted if e > 0]
            if not ahead:
                continue
            next_stop, eta_next = ahead[0]
            nxt = ref.stations.get(next_stop)
            if nxt is None:
                continue
            pos = self._place(train_id, obs, next_stop, eta_next, ahead, ref, nxt, track)
            if pos is not None:
                out.append(pos)
        return out

    def _place(self, train_id, obs, next_stop, eta_next, ahead, ref, nxt, track) -> TrainPosition | None:
        prev_id = self._pred.get(obs.destino, {}).get(next_stop)
        prev = ref.stations.get(prev_id) if prev_id else None

        if prev is not None:
            seg_t = self._segment.get((obs.destino, prev_id, next_stop), settings.default_segment_seconds)
            progress = max(0.0, min(1.0, 1.0 - eta_next / seg_t)) if seg_t > 0 else 0.0
            geom = track.segment_point(
                obs.line, prev_id, (prev.lat, prev.lon), next_stop, (nxt.lat, nxt.lon), progress
            ) if track else None
            if geom is not None:
                lat, lon, bearing, dist = geom
            else:
                lat, lon = geo.interpolate(prev.lat, prev.lon, nxt.lat, nxt.lon, progress)
                bearing = geo.bearing_deg(prev.lat, prev.lon, nxt.lat, nxt.lon)
                dist = geo.haversine_m(prev.lat, prev.lon, nxt.lat, nxt.lon)
            speed = dist / seg_t if seg_t > 0 else 0.0
        else:
            # unknown predecessor (train near terminus / sparse topology): sit at next
            lat, lon, progress, speed = nxt.lat, nxt.lon, -1.0, 0.0
            after = ref.stations.get(ahead[1][0]) if len(ahead) > 1 else None
            bearing = geo.bearing_deg(nxt.lat, nxt.lon, after.lat, after.lon) if after else 0.0

        return TrainPosition(
            train_id=train_id,
            line=obs.line,
            destino=obs.destino,
            destino_name=ref.destino_name(obs.destino),
            next_stop=next_stop,
            next_stop_name=nxt.name,
            eta_seconds=round(eta_next, 1),
            lat=round(lat, 6),
            lon=round(lon, 6),
            bearing=round(bearing, 1),
            speed_mps=round(speed, 2),
            depth_m=20.0,  # v0 constant; per-station depths later
            progress=round(progress, 3),
        )
