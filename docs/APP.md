# The Flutter app — module by module

~2,800 lines of Dart in [`app/lib/`](../app/lib). The app is a thin client: it never
talks to Metro, only to our server. See [ARCHITECTURE.md](ARCHITECTURE.md) for why.

| File | Lines | Job |
|---|---|---|
| `main.dart` | ~1,300 | **Everything visual.** Map, overlays, panels, nav, settings |
| `route_planner.dart` | ~420 | Fastest-route planner screen (calls `GET /route`) |
| `active_route.dart` | ~85 | A started route + its progress, persisted locally |
| `route_progress_card.dart` | ~185 | The pinned "you're on a route" card |
| `live_activity.dart` | ~65 | Bridge to the iOS Live Activity (no-ops until wired) |
| `nearby_panel.dart` | 230 | Closest stations to you, with live arrivals |
| `stations_panel.dart` | 207 | All 50 stations, line filter, expandable arrivals |
| `station_details.dart` | 175 | One station: lines, favourite toggle, next trains |
| `models.dart` | 141 | Wire types + **the line colour palette** |
| `search_box.dart` | 138 | Station and place search |
| `legal.dart` | 121 | Privacy/Terms text shown in-app |
| `metro_api.dart` | 116 | HTTP + SSE client |
| `line_stripe.dart` | 76 | The four-line motif; panel headers |
| `panel.dart` | 68 | The frosted panel with the glow |
| `trains_panel.dart` | 65 | Live train list |
| `splash.dart` | 62 | Logo fade |
| `line_logo.dart` | 55 | Official SVG pictograms |
| `strings.dart` | 39 | EN/PT translation |
| `schedule.dart` | 32 | Service hours, open/closed |

---

## How state works

There is **no state-management library** — no Provider, Riverpod, or BLoC. One big
`StatefulWidget`, `_MapScreenState`, holds everything and calls `setState`. Panels are
plain widgets handed data and callbacks.

That's a real decision, not an oversight. There's one screen, one data source, and one
consumer of that data. A store would add indirection without removing any. The cost is
that `main.dart` is long and every `setState` rebuilds the screen; if a second screen
ever shares this state (the AR view will), revisit it.

The fields that drive everything:

```dart
List<TrainPosition> _trains;   // latest SSE snapshot
List<Station> _stations;       // fetched once
List<TrackLine> _track;        // fetched once
int _tab;                      // 0 map · 1 nearby · 2 transit (trains/stations) · 3 info
bool _transitStations;         // transit sub-tab: false = trains, true = stations
Station? _selectedStation;     // station panel open
String? _followTrainId;        // camera glued to this train
bool _settingsOpen;            // gear panel
DateTime? _lastUpdate;         // when the last snapshot landed
```

`_panelContent()` reads them in priority order — settings, then followed train, then
selected station, then whichever tab is active — and returns one panel. Only one is
ever visible. Everything that opens a panel closes the others, which is why
`_followTrain`, `_dismissPanel` and the nav bar all clear the same four fields.

## `metro_api.dart` — talking to the server

**`base` is compiled in.** `String.fromEnvironment('API_BASE')` is resolved at *build*
time, defaulting to `http://localhost:8000`. On a phone, `localhost` is the phone —
so a build without the define produces an app that can never reach anything:

```bash
flutter build ios --release --dart-define=API_BASE=https://metro-lisboa-ar.fly.dev
```

There is no runtime setting for this. Forgetting it is the single easiest way to ship
a dead app.

**`trainStream()`** is the live feed: an infinite loop that opens `GET /stream`, splits
the response by line, and parses anything starting with `data:`. If the stream drops or
the server is unreachable it waits 2 seconds and reopens. It never gives up, so the app
survives a server restart, a tunnel, or a flight without any user action.

**`connected`** is a `ValueNotifier<bool>` flipped by that loop — true on each parsed
frame, false when the stream dies. It's what lets the UI distinguish **"no trains"**
from **"can't reach the server"**, which look identical otherwise and mean opposite
things. Combined with `schedule.dart`, the app can now separate three states that all
render as an empty map: closed, offline, and genuinely quiet.

**`stations()`, `track()`, `lines()`** retry forever on a 2-second loop, so app and
server launch order doesn't matter. **`arrivals()`** and **`geocode()`** try once and
return `[]` — they're user-initiated and a spinner that never ends is worse than an
empty list.

**`geocode()`** is the one call that leaves our infrastructure: free-text search goes to
OpenStreetMap's Nominatim with `, Lisboa` appended. Noted in
[PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md).

## `models.dart` — types and the palette

Mirrors [`server/app/models.py`](../server/app/models.py). Change a field there and it
must change here; nothing checks this for you.

It also owns the **single source of truth for line colours**:

```dart
const lineColors = <String, int>{
  'Amarela': 0xFFF7A800, 'Azul': 0xFF2F7DE1,
  'Verde':   0xFF00A19B, 'Vermelha': 0xFFEA1D76,
};
```

These are taken from the official pictograms, so map, markers, panels and the meetro
logo agree. Note `TrackLine.fromFeature` **deliberately ignores** the `colour` in the
track GeoJSON — that's OSM's own palette, a third set of near-miss values. Anything
that needs a line colour reads `lineColors`.

## `main.dart` — the screen

A `Stack`: `FlutterMap` at the bottom, then overlays (search, count chip, buttons,
Metro credit), then the panel, then the nav bar.

**Map layers**, bottom to top: tiles (CARTO raster, style-switchable) → track polylines
→ station dots → train markers → user location. Station dots are hidden below zoom 13
(`_stationZoom`); at city scale, 50 labels is noise. `_onMapMoved` only calls
`setState` when a move actually *crosses* that threshold — otherwise every pan would
rebuild the tree. It defers via `addPostFrameCallback`, because flutter_map fires
position callbacks mid-build and setState there throws.

**Trains** are re-rendered from each snapshot. There's no client-side animation — the
server's 1.5 s cadence and its dead-reckoned positions are what make motion look
continuous. If the map ever looks jumpy, the fix is server-side.

**Following a train** sets `_followTrainId`; `_onTrains` then re-centres the camera on
each snapshot as long as that train is still in the feed.

**Favourites** are stop IDs in `SharedPreferences` — local only, never sent anywhere.

## The panels

`panel.dart` — one frosted container everyone uses. Two learned details are load-bearing:
the glow and shadow sit **outside** the `ClipRRect` (inside, they were clipped away and
never rendered), and content is wrapped in `Material(type: MaterialType.transparency)`
so `ListTile` ink is visible.

`line_stripe.dart` — the four-colour motif and `StripeHeader`, the header every panel
uses. Its `lines` param scopes the stripe: pass a train's or station's lines and you
get only those colours; pass nothing and you get all four.

`line_logo.dart` — official SVG pictograms via `flutter_svg`, with `LineDot` as the
fallback where there's no room (below ~16 px the marks turn to mush).

The panel glow is tinted to match a followed train's line, or a single-line station's.
Interchanges keep white — two lines have no one colour.

## `strings.dart` — translation

Not `gen-l10n`. Just:

```dart
String tr(String en, String pt) => appLang == AppLang.pt ? pt : en;
```

Both languages live at the call site, which makes drift between them impossible — the
usual failure of key-based systems. It's the right call for two languages with no
plurals or date formats. It stops being right at a third language or the first
`Intl.plural`; every call goes through one function, so that migration stays mechanical.

`loadLang()` runs before `runApp` (which is why `main()` is `async`), reading the saved
choice or falling back to the device locale. Because `appLang` is a plain global read
at build time, **any widget holding translated text can't be `const`** — a `const`
widget wouldn't rebuild on language change.

## `schedule.dart` — open or closed

Metro runs 06:30–01:00, every day. This file owns that fact and answers "is it closed
right now?" against the **device clock** — no timezone conversion. Local time is Lisbon
time for anyone this app is for, and the alternative is shipping the tz database to fix
a case that doesn't arise.

It exists because an empty map at 03:00 looked identical to a broken app. Now the map
chip says "Metro closed · opens 06:30" instead of counting to zero — but only when
we're online *and* the list is empty, so a real outage still reads as an outage.

## `splash.dart`

Fade in, hold, fade out on the meetro logo, ~2 s, then `_Root` swaps in `MapScreen`.
Cosmetic — nothing loads behind it.

---

**Next:** [WIDGET.md](WIDGET.md) for the iOS widget · [SERVER.md](SERVER.md) for the
backend · [DEVELOPMENT.md](DEVELOPMENT.md) to run it.
