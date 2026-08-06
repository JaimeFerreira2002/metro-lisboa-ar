# Server — module by module

The backend is ~700 lines of Python across nine files. Read
[ARCHITECTURE.md](ARCHITECTURE.md) first for the idea; this is the map of where each
piece of it lives.

| File | Lines | Job |
|---|---|---|
| [`main.py`](../server/app/main.py) | 117 | FastAPI app, startup wiring, all HTTP routes |
| [`registry.py`](../server/app/registry.py) | 171 | **The brain.** Itineraries, learned topology, positions |
| [`track.py`](../server/app/track.py) | 134 | Arc-length interpolation along real OSM tunnel geometry |
| [`metro_client.py`](../server/app/metro_client.py) | 76 | Talks to Metro; owns the OAuth token |
| [`reference.py`](../server/app/reference.py) | 42 | Station catalog + destination names, loaded once |
| [`poller.py`](../server/app/poller.py) | 41 | The 12-second loop |
| [`geo.py`](../server/app/geo.py) | 37 | Haversine, bearing, straight-line fallback |
| [`models.py`](../server/app/models.py) | 35 | Pydantic wire contract |
| [`config.py`](../server/app/config.py) | 31 | Env-var settings |

Dependencies point one way: `main` → `poller` → `registry` → `reference` → `client` →
`config`. Nothing imports `main`.

---

## `config.py` — settings

Pydantic `BaseSettings` with the prefix `ML_`, so the field `poll_interval_seconds` is
set by the env var `ML_POLL_INTERVAL_SECONDS`. Values come from the environment, or
`server/.env` locally. No config file, no CLI flags.

The knobs worth knowing:

| Setting | Default | Meaning |
|---|---|---|
| `poll_interval_seconds` | 12 | How often we ask Metro. Lower = more load on them |
| `stream_interval_seconds` | 1.5 | How often SSE pushes. Costs nothing upstream — it's re-reading state |
| `default_segment_seconds` | 100 | Assumed segment crossing time before one is learned |
| `insecure_tls` | **`True`** | **Disables TLS verification.** See [SECURITY.md](SECURITY.md) |
| `lines` | the four | Amarela, Azul, Verde, Vermelha — capitalised, as the API wants |

`settings` is a module-level singleton, imported directly wherever needed.

## `metro_client.py` — the only thing that talks to Metro

An `httpx.AsyncClient` wrapper that hides two things.

**OAuth.** Metro uses `client_credentials`: POST your Basic credential to `/token`,
get a bearer token good for about an hour. `_token_value()` returns the cached token
and only refreshes when it's within 60 seconds of expiry — so the refresh is lazy and
invisible to callers. Three credential shapes are accepted (`ML_BASIC_AUTH`,
`ML_CONSUMER_KEY` + `ML_CONSUMER_SECRET`, or a static `ML_ACCESS_TOKEN`); the
pre-encoded blob is the easy one.

**The envelope.** Every Metro response is wrapped in `{"resposta": ..., "codigo": ...}`.
Each method unwraps it and type-checks the payload, returning `[]` or `{}` rather than
raising when the shape is wrong. Metro's API returns `codigo: "400"` with a *string*
in `resposta` on error, so this matters.

The four calls used: `waits_for_line`, `stations`, `destinos`, `line_status`.

## `reference.py` — static data

Loaded once at startup: 50 stations (id, name, lat/lon, lines) and 24 destination codes
→ names. Rarely changes; never refreshed while running.

Two Metro quirks are absorbed here. Lines arrive as the *string* `"[Verde, Vermelha]"`,
not a JSON array — `_parse_bracket_list` unpicks it. And rows that fail to parse are
skipped rather than fatal, because one bad station shouldn't take down the service.

Destination codes matter more than they look: `tempoEspera` gives you `destino: "54"`,
and only `infoDestinos` knows that's Telheiras. There are 24 of them for 8 termini —
the extras are **short-turn services** that stop before the end of the line.

## `poller.py` — the loop

Forty-one lines, and the only writer to the registry. Every 12 seconds, for each of
the four lines: fetch wait times → `ingest_line`; fetch line status → `set_line_status`.
Then `prune` drops trains unseen for 90 s.

Two details that matter more than their size suggests:

**Failures don't break the loop.** Each call is individually wrapped; an exception logs
a warning and the loop continues. One line's outage doesn't stop the other three, and a
transient Metro blip doesn't kill the poller — which, since it's the only poller, would
silently freeze the whole app.

**The interval is drift-corrected.** It waits `poll_interval - elapsed`, not
`poll_interval`, so a slow round of requests doesn't push the cadence later and later.
It also waits on `stop.wait()` with a timeout rather than `asyncio.sleep`, so shutdown
is immediate instead of up to 12 seconds late.

## `registry.py` — the brain

The one file to actually read. [ARCHITECTURE.md](ARCHITECTURE.md) explains the
reasoning; here's the shape.

**State**

```python
trains:   dict[train_id, TrainObservation]     # latest itinerary + captured_at
_pred:    dict[destino, dict[stop, pred_stop]] # learned adjacency, per direction
_segment: dict[(destino, from, to), float]     # learned segment seconds (EMA)
line_status: dict[line, LineStatus]
```

All in memory. Nothing is persisted — restart and it re-learns within a few polls.

**`ingest_line`** inverts platforms into trains. Each platform entry carries three
train slots (`comboio`/`tempoChegada1`, `comboio2`/`tempoChegada2`, `comboio3`/…),
defined once in `_SLOTS`. ETAs come through `_eta`, which treats `None`, `""` and
Metro's `"--"` as absent. If a train shows twice at one stop, the **smaller** ETA wins.
Each poll *replaces* a train's observation wholesale rather than merging.

**`_learn`** builds topology from consecutive itinerary pairs. The guard
`0 < seg < 600` rejects garbage: non-positive deltas (bad ordering) and gaps over ten
minutes (a stale entry, or a train that vanished and came back). The EMA is
`0.7 * old + 0.3 * new`.

**`snapshot`** is called on every SSE tick — every 1.5 s, per connected client. It
subtracts elapsed time from each ETA, takes the first station still ahead as the next
stop, and calls `_place`. Trains with nothing ahead, or an unknown next station, are
dropped.

**`_place`** does the geometry, and has two branches:

- *Predecessor known* → compute `progress`, ask `track.segment_point` for a real point
  on the tunnel polyline, fall back to `geo.interpolate`'s straight line if that line
  has no geometry. Speed is segment length ÷ segment time.
- *Predecessor unknown* → park at the next station with `progress = -1`, speed 0, and
  a bearing aimed at the station after. `-1` is the "not really placed" sentinel.

**`arrivals_at`** is the other consumer: rather than positioning trains, it scans every
train's itinerary for a given stop and returns the soonest arrivals. This powers the
station panels and the iOS widget. Note it re-derives arrivals from the same
observations — there is no separate arrivals feed.

## `track.py` — real tunnels

Turns `progress` (0..1 between two stations) into a real coordinate.

A `Polyline` precomputes **cumulative distance** along its points, so any point can be
addressed by arc-length in metres. `project()` finds the arc-length nearest a given
coordinate — used to ask "where along this tunnel is Alameda?" `point_at()` binary-
searches back the other way.

`segment_point` picks the **directional** polyline: for each candidate it projects both
stations and keeps the one where the next station is furthest *ahead* of the previous
one. That's how direction is resolved from the train's own motion rather than from its
`destino` — which matters, because short-turn destinos aren't line termini and can't be
matched against a polyline's endpoints.

Two performance notes. `project()` is O(points) and would run per train per SSE tick,
so station arc-lengths are cached in `_station_s` after first use. That cache is keyed
by `id(poly)` — safe only because `by_line` holds every polyline for the process's
lifetime; if polylines ever became disposable, a recycled `id()` would silently return
another line's arc-length. And `project` uses flat equirectangular maths with a
`cos(lat)` correction instead of haversine per candidate segment: at city scale the
error is negligible and it's much cheaper.

## `geo.py` — the fallback

Haversine distance, bearing, and linear interpolation between two coordinates. Only
reached when `track.py` has no geometry for a line. Its header comment is stale — it
describes straight-line interpolation as the primary path, which stopped being true
when `track.py` landed.

## `models.py` — the contract

Pydantic models shared with every client: `Station`, `LineStatus`, `TrainPosition`.
`TrainPosition` is the important one — it's what `/stream` and `/trains` emit, and
what [`app/lib/models.dart`](../app/lib/models.dart) parses on the other side.
**Changing a field here breaks the app**; the two files must move together.

## `main.py` — wiring and routes

The `lifespan` context manager is the startup/shutdown story: construct the client,
reference, and registry; `await ref.load(client)`; load track geometry; start the
poller task; stash everything on `app.state`. On shutdown, set the stop event, cancel
the task, close the HTTP client.

Ordering isn't incidental — reference data must be loaded before the first poll lands,
or observations would reference stations we can't resolve. **If `ref.load` raises, the
app doesn't start.** That's the failure you get with a missing or wrong `ML_BASIC_AUTH`:
Fly reports a failing health check, because the process never came up. See
[DEVELOPMENT.md](DEVELOPMENT.md).

Routes are thin — each one reads `app.state` and calls a method. The only interesting
one is `/stream`, an SSE endpoint whose generator loops forever, serialising
`registry.snapshot(...)` every `stream_interval_seconds`. Every connected client gets
its own generator and its own `snapshot()` call, so snapshot cost scales with viewers
(the *poll* cost doesn't).

`/route?from=<stop>&to=<stop>` is the newest route and the one with real logic behind
it: it plans the **fastest** trip using live train waits, not the fewest stops. The
planner lives in [`router.py`](../server/app/router.py) — a Dijkstra over
`(station, direction)` states whose edge weights come straight from what the registry
has learned: the live wait for the next train in a direction, the EMA segment times,
and a transfer penalty. See [ROUTING.md](ROUTING.md) for the model. It 404s for unknown
stations and when the destination isn't reachable from the current (possibly
still-warming) topology.

`/` serves the debug map from `server/web/` — a single Leaflet page, no build step,
the fastest way to see whether the server is sane. It's mounted only if the directory
exists, and **it's public in production**. See [SECURITY.md](SECURITY.md).
