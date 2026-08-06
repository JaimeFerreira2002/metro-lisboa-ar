# Route planning — fastest, not shortest

meetro plans a route between two stations using the **live position of trains**, so it
can return the *fastest* trip rather than the one with the fewest stops. Those aren't
the same thing: if the next train on the direct line is six minutes out while a slightly
longer route has a train pulling in now, the longer route gets you there first.

This works because the server already learns everything a time-dependent planner needs
(see [ARCHITECTURE.md](ARCHITECTURE.md)):

- **adjacency**, direction by direction — `Registry._pred[destino][stop]`,
- **segment travel times**, as moving averages — `Registry._segment[(destino, a, b)]`,
- **live waits** — each tracked train's itinerary is seconds-to-arrival at every
  upcoming station, so "when does the next train toward X reach station S?" is a lookup.

## The model

[`server/app/router.py`](../server/app/router.py) runs Dijkstra over a small graph whose
edge weights are **all in seconds**, so shortest-path = fastest trip:

| Node | Meaning |
|---|---|
| `hub(s)` | standing at station `s`, not on a train |
| `ride(s, D)` | aboard a train of direction (destino) `D`, currently at `s` |

| Edge | From → To | Weight |
|---|---|---|
| **board** | `hub(s)` → `ride(s, D)` | live wait for the next train toward `D` at `s` |
| **ride** | `ride(s, D)` → `ride(b, D)` | learned segment time `s → b` |
| **alight** | `ride(s, D)` → `hub(s)` | transfer penalty |

Riding onward costs only the segment time — you don't re-pay a wait to stay on the train.
Changing lines routes through `hub`, so it pays the **transfer penalty** (walking between
platforms) plus the wait for the next train on the new line. The penalty sits on *alight*,
and the destination is read from its `ride` node (Dijkstra reaches it before the costlier
`hub`), so the last leg is never charged a phantom transfer.

When no train is currently observed heading a needed direction (off-peak, or a cold
server), boarding falls back to a nominal headway (`default_headway_seconds`) so the
planner still answers — flagged per leg as non-live in the response.

Tunables live in [`config.py`](../server/app/config.py): `default_headway_seconds`,
`transfer_penalty_seconds`, `default_segment_seconds`.

## The endpoint

```
GET /route?from=<stop_id>&to=<stop_id>
```

Returns a `RoutePlan`: `total_seconds` end to end, plus a `legs[]` list — each leg is one
line ride with its board/alight stops, the stops in between, `wait_seconds`,
`ride_seconds`, and a `live` flag. `404` for unknown stations or when the destination
isn't reachable from the current topology.

## Limits

- **Estimates, like everything here.** Positions and segment times are inferred, so ETAs
  are approximate — good to a few seconds at best.
- **Waits are snapshotted at request time.** The wait for a train you'd board *after* a
  transfer is computed as of now, not as of when you'd actually reach that platform. It's
  a good approximation over a short trip and keeps the model a plain shortest-path.
- **Cold start.** Adjacency is learned, so right after a server restart some routes are
  unavailable until the feed warms up. The planner says so (404) rather than guessing.

## Tests

[`server/tests/test_router.py`](../server/tests/test_router.py) builds a registry from
synthetic feed entries (so it exercises the real learning path) and checks, among other
things, that a longer ride wins when its train is closer. Run them with:

```bash
cd server
pip install -r requirements.txt -r requirements-dev.txt
python -m pytest
```
