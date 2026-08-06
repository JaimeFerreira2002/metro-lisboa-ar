/// Phase 1 Flutter client: a 2D live map mirroring the web debug view.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart' hide Path; // latlong2's Path shadows dart:ui Path
import 'package:shared_preferences/shared_preferences.dart';

import 'legal.dart';
import 'line_logo.dart';
import 'line_stripe.dart';
import 'metro_api.dart';
import 'models.dart';
import 'nearby_panel.dart';
import 'active_route.dart';
import 'live_activity.dart';
import 'panel.dart';
import 'route_planner.dart';
import 'route_progress_card.dart';
import 'search_box.dart';
import 'splash.dart';
import 'station_details.dart';
import 'stations_panel.dart';
import 'schedule.dart';
import 'strings.dart';
import 'trains_panel.dart';

void main() async {
  // Resolve the language before the first frame (saved choice, else device locale).
  WidgetsFlutterBinding.ensureInitialized();
  await loadLang();
  runApp(const MetroApp());
}

class MetroApp extends StatelessWidget {
  const MetroApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'meetro',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          scaffoldBackgroundColor: Colors.white,
          textTheme: GoogleFonts.poppinsTextTheme(),
        ),
        home: const _Root(),
      );
}

/// Splash first, then the map.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool _ready = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      child: _ready
          ? const MapScreen()
          : SplashScreen(onDone: () => setState(() => _ready = true)),
    );
  }
}

enum MapStyle { cozy, minimal, light, dark }

extension MapStyleX on MapStyle {
  // All keyless: CARTO raster basemaps (© OpenStreetMap contributors © CARTO).
  String get url => switch (this) {
        MapStyle.cozy => 'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
        MapStyle.minimal =>
          'https://basemaps.cartocdn.com/rastertiles/voyager_nolabels/{z}/{x}/{y}.png',
        MapStyle.light => 'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
        MapStyle.dark => 'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
      };
  String get label => switch (this) {
        MapStyle.cozy => tr('Cozy', 'Acolhedor'),
        MapStyle.minimal => tr('Minimal', 'Mínimo'),
        MapStyle.light => tr('Light', 'Claro'),
        MapStyle.dark => tr('Dark', 'Escuro'),
      };
  IconData get icon => switch (this) {
        MapStyle.cozy => Icons.local_cafe_rounded,
        MapStyle.minimal => Icons.layers_clear_rounded,
        MapStyle.light => Icons.light_mode_rounded,
        MapStyle.dark => Icons.dark_mode_rounded,
      };
}

// Cozy palette
const _ink = Colors.black87;
const _inkSoft = Colors.black45;
const _ok = Color(0xFF34C759);
const _warn = Color(0xFFFF9F0A);

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _api = MetroApi();
  final _mapController = MapController();

  int _tab = 0; // 0 map, 1 nearby, 2 trains, 3 stations, 4 info (settings = gear)
  MapStyle _style = MapStyle.cozy;

  List<TrackLine> _track = [];
  List<Station> _stations = [];
  List<TrainPosition> _trains = [];
  List<LineStatus> _lines = [];
  LatLng? _userLocation;
  Station? _selectedStation;
  String? _followTrainId; // camera auto-follows this train
  bool _settingsOpen = false;
  bool _didAutoOpenNearby = false;
  Set<String> _favorites = {}; // favourited stop_ids, persisted locally
  DateTime? _lastUpdate; // when the last live snapshot arrived
  Timer? _linesTimer;

  // Active route the user has started (persisted). Null when not travelling.
  ActiveRoute? _activeRoute;
  double? _legWaitLive; // live wait for the current leg's next train, if known
  Timer? _routeTimer;

  @override
  void initState() {
    super.initState();
    _api.track().then((t) => setState(() => _track = t));
    _api.stations().then((s) => setState(() => _stations = s));
    _api.trainStream().listen(_onTrains);
    _api.connected.addListener(_onConnectionChanged);
    _refreshLines();
    _linesTimer = Timer.periodic(const Duration(seconds: 20), (_) => _refreshLines());
    _initLocation();
    _loadFavorites();
    _loadActiveRoute();
  }

  // ---- favourites ----

  static const _favKey = 'favorite_stops';

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_favKey) ?? const [];
    if (mounted) setState(() => _favorites = ids.toSet());
  }

  Future<void> _toggleFavorite(String stopId) async {
    HapticFeedback.selectionClick();
    final next = {..._favorites};
    next.contains(stopId) ? next.remove(stopId) : next.add(stopId);
    setState(() => _favorites = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_favKey, next.toList());
  }

  // ---- active route ----

  Future<void> _loadActiveRoute() async {
    final r = await ActiveRoute.load();
    if (!mounted || r == null || r.isComplete) return;
    setState(() => _activeRoute = r);
    _startRouteTimer();
    _refreshLegHint();
    LiveActivityService.start(r);
  }

  /// Called from the route planner's "Start route" button.
  void _startRoute(RoutePlan plan, Station from, Station to) {
    HapticFeedback.mediumImpact();
    final r = ActiveRoute(
      plan: plan,
      fromName: from.name,
      toName: to.name,
      startedAt: DateTime.now(),
    );
    setState(() {
      _activeRoute = r;
      _legWaitLive = null;
      _tab = 0;
      _selectedStation = null;
      _followTrainId = null;
      _settingsOpen = false;
    });
    r.save();
    LiveActivityService.start(r);
    _startRouteTimer();
    _refreshLegHint();
    _fitRouteBounds(r);
  }

  void _advanceRoute() {
    final r = _activeRoute;
    if (r == null) return;
    final next = r.copyWith(currentLeg: r.currentLeg + 1);
    if (next.isComplete) {
      _endRoute(arrived: true);
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _activeRoute = next;
      _legWaitLive = null;
    });
    next.save();
    LiveActivityService.update(next);
    _refreshLegHint();
    _fitLegBounds(next);
  }

  void _endRoute({bool arrived = false}) {
    HapticFeedback.selectionClick();
    _routeTimer?.cancel();
    _routeTimer = null;
    setState(() {
      _activeRoute = null;
      _legWaitLive = null;
    });
    ActiveRoute.clear();
    LiveActivityService.end();
    if (arrived && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr("You've arrived.", 'Chegou ao destino.')),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  void _startRouteTimer() {
    _routeTimer?.cancel();
    _routeTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshLegHint());
  }

  /// Live wait for the current leg's next train at its board station.
  Future<void> _refreshLegHint() async {
    final leg = _activeRoute?.leg;
    if (leg == null) return;
    final board = _stationByName[leg.boardStopName];
    if (board == null) return;
    final arrivals = await _api.arrivals(board.stopId);
    final etas = arrivals
        .where((a) => a.line == leg.line && a.destinoName == leg.destinoName)
        .map((a) => a.etaSeconds)
        .toList();
    if (!mounted || _activeRoute?.leg != leg) return;
    setState(() => _legWaitLive = etas.isEmpty ? null : etas.reduce(math.min));
  }

  Map<String, Station> get _stationByName => {for (final s in _stations) s.name: s};

  List<LatLng> _legPoints(RouteLeg leg) {
    final byName = _stationByName;
    return [
      for (final n in leg.stopNames)
        if (byName[n] != null) byName[n]!.pos,
    ];
  }

  void _fitRouteBounds(ActiveRoute r) => _fitPoints([for (final leg in r.plan.legs) ..._legPoints(leg)]);

  void _fitLegBounds(ActiveRoute r) {
    final leg = r.leg;
    if (leg != null) _fitPoints(_legPoints(leg));
  }

  void _fitPoints(List<LatLng> pts) {
    if (pts.length < 2) {
      if (pts.length == 1) _mapController.move(pts.first, 15);
      return;
    }
    _mapController.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(pts),
      padding: const EdgeInsets.fromLTRB(60, 120, 60, 260),
    ));
  }

  List<Polyline> _routePolylines(ActiveRoute r) {
    final out = <Polyline>[];
    for (var i = 0; i < r.plan.legs.length; i++) {
      final leg = r.plan.legs[i];
      final pts = _legPoints(leg);
      if (pts.length < 2) continue;
      final color = Color(lineColors[leg.line] ?? 0xFF888888);
      final done = i < r.currentLeg;
      out.add(Polyline(
        points: pts,
        color: done ? color.withOpacity(0.25) : color,
        strokeWidth: i == r.currentLeg ? 7 : 5,
        borderColor: Colors.white.withOpacity(0.85),
        borderStrokeWidth: 1.5,
      ));
    }
    return out;
  }

  List<Marker> _routeMarkers(ActiveRoute r) {
    final byName = _stationByName;
    final legs = r.plan.legs;
    if (legs.isEmpty) return const [];
    final markers = <Marker>[];
    final originName = legs.first.stopNames.isNotEmpty ? legs.first.stopNames.first : legs.first.boardStopName;
    final origin = byName[originName];
    if (origin != null) markers.add(_routePin(origin.pos, Icons.trip_origin_rounded, Colors.black87));
    for (var i = 1; i < legs.length; i++) {
      final s = byName[legs[i].boardStopName];
      if (s != null) markers.add(_routePin(s.pos, Icons.sync_alt_rounded, Color(lineColors[legs[i].line] ?? 0xFF888888)));
    }
    final destName = legs.last.stopNames.isNotEmpty ? legs.last.stopNames.last : legs.last.alightStopName;
    final dest = byName[destName];
    if (dest != null) markers.add(_routePin(dest.pos, Icons.flag_rounded, const Color(0xFFEA1D76)));
    return markers;
  }

  Marker _routePin(LatLng pos, IconData icon, Color color) => Marker(
        point: pos,
        width: 30,
        height: 30,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2.5),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4)],
          ),
          child: Icon(icon, color: color, size: 16),
        ),
      );

  void _onConnectionChanged() {
    if (mounted) setState(() {});
  }

  /// Tapping the map dismisses whatever is open — the same place the nav bar's
  /// map button lands you. Marker taps are consumed by the markers themselves,
  /// so selecting a station doesn't immediately dismiss its own panel.
  void _dismissPanel() {
    final nothingOpen =
        _tab == 0 && _selectedStation == null && _followTrainId == null && !_settingsOpen;
    if (nothingOpen) return; // don't buzz for a tap on a bare map
    HapticFeedback.selectionClick();
    setState(() {
      _tab = 0;
      _selectedStation = null;
      _followTrainId = null;
      _settingsOpen = false;
    });
  }

  bool get _online => _api.connected.value;

  Widget _offlineBanner() => Panel(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, color: _warn, size: 16),
            const SizedBox(width: 8),
            Text(
              _lastUpdate == null
                  ? tr("Can't reach the server · retrying…", 'Sem ligação ao servidor · a tentar…')
                  : tr('No connection · showing last known', 'Sem ligação · a mostrar o último conhecido'),
              style: const TextStyle(color: _ink, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );

  void _onTrains(List<TrainPosition> t) {
    setState(() {
      _trains = t;
      _lastUpdate = DateTime.now();
    });
    // keep the camera centered on the followed train as it moves
    final id = _followTrainId;
    if (id != null) {
      final match = t.where((x) => x.trainId == id);
      if (match.isNotEmpty) {
        _mapController.move(match.first.pos, _mapController.camera.zoom);
      }
    }
  }

  void _followTrain(TrainPosition t) {
    HapticFeedback.selectionClick();
    setState(() {
      _followTrainId = t.trainId;
      _selectedStation = null;
      _settingsOpen = false;
    });
    _mapController.move(t.pos, 15);
  }

  Future<void> _refreshLines() async {
    final l = await _api.lines();
    if (mounted) setState(() => _lines = l);
  }

  @override
  void dispose() {
    _linesTimer?.cancel();
    _routeTimer?.cancel();
    _api.connected.removeListener(_onConnectionChanged);
    super.dispose();
  }

  int _countFor(String line) => _trains.where((t) => t.line == line).length;

  // ---- map zoom ----

  static const _initialZoom = 12.0;
  static const _stationZoom = 13.0; // below this, station dots are hidden
  static const _defaultCenter = LatLng(38.728, -9.145); // central Lisbon
  double _zoom = _initialZoom;

  /// Frame the whole network — the "take me back" escape hatch after you've
  /// followed a train into a corner of the map.
  ///
  /// Fitted to the real track bounds rather than a fixed zoom: the network is
  /// wider than a phone shows at z12, and the right zoom differs per screen.
  void _resetView() {
    HapticFeedback.selectionClick();
    setState(() {
      _followTrainId = null;
      _selectedStation = null;
    });
    final points = [
      for (final t in _track) ...t.points,
      for (final s in _stations) s.pos,
    ];
    if (points.isEmpty) {
      _mapController.move(_defaultCenter, _initialZoom); // geometry not loaded yet
      return;
    }
    _mapController.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(points),
      // Leave room for the HUD above and the nav bar + panels below.
      padding: const EdgeInsets.fromLTRB(36, 96, 36, 128),
    ));
  }

  bool get _showStations => _zoom >= _stationZoom;

  void _onMapMoved(MapCamera camera, bool hasGesture) {
    final was = _showStations;
    _zoom = camera.zoom;
    // Only rebuild when we cross the threshold (this fires on every frame of a
    // pan/zoom), and defer it — onPositionChanged can fire during layout.
    if (_showStations != was) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  // ---- location ----

  Future<void> _initLocation() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission(); // triggers the OS pop-up
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
    if (!await Geolocator.isLocationServiceEnabled()) return;
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        _userLocation = LatLng(pos.latitude, pos.longitude);
        // once per launch, surface Nearby as the opening panel
        if (!_didAutoOpenNearby) {
          _didAutoOpenNearby = true;
          _tab = 1;
        }
      });
    } catch (_) {
      /* location unavailable — stay on the map */
    }
  }

  Widget _nearbyPrompt() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Icon(Icons.near_me_rounded, color: _ink, size: 22),
            SizedBox(width: 8),
            Text(tr('Nearby', 'Perto'), style: const TextStyle(color: _ink, fontSize: 20, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 12),
          Text(tr('Enable location to see the stations closest to you and their next trains.',
                  'Ative a localização para ver as estações mais próximas e os próximos comboios.'),
              style: TextStyle(color: _inkSoft, height: 1.4)),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _goToMyLocation,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(color: _ink, borderRadius: BorderRadius.circular(14)),
              child: Text(tr('Enable location', 'Ativar localização'),
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      );

  Future<void> _goToMyLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) return;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
    final pos = await Geolocator.getCurrentPosition();
    final ll = LatLng(pos.latitude, pos.longitude);
    if (!mounted) return;
    setState(() => _userLocation = ll);
    _mapController.move(ll, 15);
  }

  void _flyTo(LatLng target, Station? station) {
    _mapController.move(target, station != null ? 15 : 14);
    setState(() {
      _settingsOpen = false;
      if (station != null) {
        _selectedStation = station;
      }
    });
  }

  /// Station closest to the user (or the selected one), used to pre-fill the
  /// route planner's origin. Null when we have neither a location nor stations.
  Station? _originGuess() {
    if (_selectedStation != null) return _selectedStation;
    final here = _userLocation;
    if (here == null || _stations.isEmpty) return null;
    const dist = Distance();
    return _stations.reduce((a, b) => dist(here, a.pos) <= dist(here, b.pos) ? a : b);
  }

  void _openRoutePlanner() {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RoutePlannerScreen(
        api: _api,
        stations: _stations,
        initialFrom: _originGuess(),
        onStart: _startRoute,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _defaultCenter,
              initialZoom: _initialZoom,
              onPositionChanged: _onMapMoved,
              onTap: (_, __) => _dismissPanel(),
            ),
            children: [
              TileLayer(
                urlTemplate: _style.url,
                userAgentPackageName: 'com.jaimeferreira.meetro',
              ),
              PolylineLayer(
                polylines: _track
                    .map((t) => Polyline(
                          points: t.points,
                          color: Color(t.color).withOpacity(0.6),
                          strokeWidth: 4,
                        ))
                    .toList(),
              ),
              // Active route drawn over the base track, under the markers.
              if (_activeRoute != null) ...[
                PolylineLayer(polylines: _routePolylines(_activeRoute!)),
                MarkerLayer(markers: _routeMarkers(_activeRoute!)),
              ],
              // station dots would clutter the city-wide view — only show them
              // once you're zoomed in enough for them to be useful
              if (_showStations)
                MarkerLayer(markers: _stations.map(_stationMarker).toList()),
              MarkerLayer(markers: _trains.map(_trainMarker).toList()),
              if (_userLocation != null)
                MarkerLayer(markers: [_userMarker(_userLocation!)]),
            ],
          ),

          // Always-visible data credit + tile attribution (required by OSM/CARTO).
          // Sits above the nav bar so the centred nav pill can't cover it.
          Align(
            alignment: Alignment.bottomLeft,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 56),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          'assets/icons/logo_metro.png',
                          height: 18,
                          errorBuilder: (_, __, ___) => const Icon(
                              Icons.directions_subway_rounded,
                              size: 12,
                              color: Colors.black54),
                        ),
                        const SizedBox(width: 5),
                        Text('Metro de Lisboa',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Colors.black.withOpacity(0.6))),
                      ],
                    ),
                    Text('© OpenStreetMap · CARTO',
                        style: TextStyle(fontSize: 9, color: Colors.black.withOpacity(0.45))),
                  ],
                ),
              ),
            ),
          ),

          // Top: search + live count
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SearchBox(api: _api, stations: _stations, onPick: _flyTo),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() {
                            _settingsOpen = !_settingsOpen;
                            _selectedStation = null;
                            _followTrainId = null;
                          });
                        },
                        child: Panel(
                          padding: const EdgeInsets.all(12),
                          borderRadius: const BorderRadius.all(Radius.circular(30)),
                          child: Icon(Icons.settings_rounded,
                              color: _settingsOpen ? Color(lineColors['Azul']!) : _ink),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Only claim a count once we've actually had data — otherwise
                  // "0 trains live" would read as "the metro isn't running".
                  if (_lastUpdate != null)
                    Panel(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      borderRadius: const BorderRadius.all(Radius.circular(18)),
                      // An empty map at 03:00 means the metro is shut, not that
                      // we're broken — say so instead of counting to zero.
                      child: _online && _trains.isEmpty && metroIsClosed()
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.bedtime_rounded, color: _inkSoft, size: 20),
                                const SizedBox(width: 8),
                                Text(closedLine(),
                                    style: const TextStyle(
                                        color: _ink,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700)),
                              ],
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.directions_subway_rounded,
                                    color: _online ? _ink : _inkSoft, size: 20),
                                const SizedBox(width: 8),
                                Text('${_trains.length}',
                                    style: TextStyle(
                                        color: _online ? _ink : _inkSoft,
                                        fontSize: 24,
                                        fontWeight: FontWeight.w800,
                                        height: 1)),
                                const SizedBox(width: 6),
                                Text(_online ? tr('trains live', 'comboios ao vivo')
                                             : tr('trains · last known', 'comboios · último conhecido'),
                                    style: const TextStyle(
                                        color: _inkSoft, fontSize: 13, fontWeight: FontWeight.w500)),
                              ],
                            ),
                    ),
                  if (!_online) ...[
                    if (_lastUpdate != null) const SizedBox(height: 8),
                    _offlineBanner(),
                  ],
                ],
              ),
            ),
          ),

          // route-planner + reset-view + my-location buttons
          SafeArea(
            child: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 16, bottom: 80),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: _openRoutePlanner,
                      child: const Panel(
                        padding: EdgeInsets.all(14),
                        borderRadius: BorderRadius.all(Radius.circular(30)),
                        child: Icon(Icons.alt_route_rounded, color: _ink),
                      ),
                    ),
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: _resetView,
                      child: const Panel(
                        padding: EdgeInsets.all(14),
                        borderRadius: BorderRadius.all(Radius.circular(30)),
                        child: Icon(Icons.zoom_out_map_rounded, color: _ink),
                      ),
                    ),
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: _goToMyLocation,
                      child: const Panel(
                        padding: EdgeInsets.all(14),
                        borderRadius: BorderRadius.all(Radius.circular(30)),
                        child: Icon(Icons.my_location_rounded, color: _ink),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Animated panels (slide up + fade between states), with the pinned
          // active-route card floating just above them when a trip is running.
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_activeRoute != null && !_activeRoute!.isComplete) ...[
                      RouteProgressCard(
                        route: _activeRoute!,
                        liveWaitSeconds: _legWaitLive,
                        onNext: _advanceRoute,
                        onEnd: _endRoute,
                      ),
                      const SizedBox(height: 10),
                    ],
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 320),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: Tween(begin: const Offset(0, 0.18), end: Offset.zero).animate(anim),
                          child: child,
                        ),
                      ),
                      child: _panelContent(),
                    ),
                  ],
                ),
              ),
            ),
          ),

          _navBar(),
        ],
      ),
    );
  }

  // ---- panels ----

  Widget _panelContent() {
    final Widget? inner;
    final Key key;
    var glow = Colors.white; // panel halo — tinted for a followed train
    if (_settingsOpen) {
      inner = SingleChildScrollView(child: _settingsContent());
      key = const ValueKey('settings');
    } else if (_followTrainId != null) {
      inner = _followContent();
      key = const ValueKey('follow');
      final match = _trains.where((t) => t.trainId == _followTrainId);
      if (match.isNotEmpty) glow = Color(lineColors[match.first.line] ?? 0xFFFFFFFF);
    } else if (_selectedStation != null) {
      inner = StationDetailsPanel(
        api: _api,
        station: _selectedStation!,
        onClose: () => setState(() => _selectedStation = null),
        isFavorite: _favorites.contains(_selectedStation!.stopId),
        onToggleFavorite: () => _toggleFavorite(_selectedStation!.stopId),
      );
      key = const ValueKey('station');
      // Match the glow to the station's line, as we do for a followed train.
      // Interchanges serve two, so there's no single colour — leave those white.
      final lines = _selectedStation!.lines;
      if (lines.length == 1) glow = Color(lineColors[lines.first] ?? 0xFFFFFFFF);
    } else if (_tab == 1) {
      inner = _userLocation == null
          ? _nearbyPrompt()
          : NearbyPanel(
              api: _api,
              stations: _stations,
              location: _userLocation!,
              onTapStation: (s) => _flyTo(s.pos, s),
              favorites: _favorites,
              onToggleFavorite: _toggleFavorite,
            );
      key = const ValueKey('nearby');
    } else if (_tab == 2) {
      inner = TrainsList(trains: _trains, onSelect: _followTrain);
      key = const ValueKey('trains');
    } else if (_tab == 3) {
      inner = StationsList(
        api: _api,
        stations: _stations,
        favorites: _favorites,
        onToggleFavorite: _toggleFavorite,
      );
      key = const ValueKey('stations');
    } else if (_tab == 4) {
      inner = SingleChildScrollView(child: _infoContent());
      key = const ValueKey('info');
    } else {
      return const SizedBox.shrink(key: ValueKey('none'));
    }

    return ConstrainedBox(
      key: key,
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
      child: Panel(glowColor: glow, child: inner),
    );
  }

  Widget _followContent() {
    final matches = _trains.where((t) => t.trainId == _followTrainId).toList();
    final close = GestureDetector(
      onTap: () => setState(() => _followTrainId = null),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: Colors.black.withOpacity(0.05), shape: BoxShape.circle),
        child: const Icon(Icons.close_rounded, color: Colors.black54, size: 18),
      ),
    );
    if (matches.isEmpty) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        StripeHeader(
            icon: Icons.directions_subway_rounded,
            title: '${tr('Train', 'Comboio')} $_followTrainId',
            trailing: close),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(tr('This train is no longer live', 'Este comboio já não está ativo'),
              style: TextStyle(color: _inkSoft, fontWeight: FontWeight.w500)),
        ),
      ]);
    }
    final t = matches.first;
    final color = Color(lineColors[t.line] ?? 0xFF9E9E9E);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        StripeHeader(
          icon: Icons.directions_subway_rounded,
          title: '${tr('Train', 'Comboio')} ${t.trainId}',
          trailing: close,
          lines: [t.line], // this train's own line, not all four
        ),
        const SizedBox(height: 10),
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              LineLogo(t.line, height: 16),
              const SizedBox(width: 6),
              Text(t.line, style: const TextStyle(color: _ink, fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
          const Spacer(),
          const Icon(Icons.my_location_rounded, color: _inkSoft, size: 16),
          const SizedBox(width: 4),
          Text(tr('following', 'a seguir'), style: const TextStyle(color: _inkSoft, fontSize: 12, fontWeight: FontWeight.w500)),
        ]),
        const SizedBox(height: 14),
        Text('→ ${t.destinoName}',
            style: const TextStyle(color: _ink, fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Text('${tr('Next', 'Próxima')}: ${t.nextStopName}',
                style: const TextStyle(color: _inkSoft, fontWeight: FontWeight.w500)),
          ),
          Text(fmtEta(t.etaSeconds),
              style: const TextStyle(color: _ink, fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(width: 4),
          const Padding(
            padding: EdgeInsets.only(bottom: 3),
            child: Text('min', style: TextStyle(color: _inkSoft, fontSize: 12)),
          ),
        ]),
      ],
    );
  }

  Widget _infoContent() {
    final disrupted = _lines.where((l) => !l.isNormal).toList();
    final closed = metroIsClosed();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        StripeHeader(icon: Icons.info_rounded, title: tr('Service status', 'Estado do serviço')),
        const SizedBox(height: 12),
        // Closed is the answer to "why is it empty?", so it leads.
        if (closed)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [
              const Icon(Icons.bedtime_rounded, color: _inkSoft, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${closedTitle()} — ${opensAt().toLowerCase()}',
                    style: const TextStyle(
                        color: _ink, fontWeight: FontWeight.w700, fontSize: 13)),
              ),
            ]),
          ),
        if (!_online)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [
              const Icon(Icons.cloud_off_rounded, color: _warn, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    _lastUpdate == null
                        ? tr("Can't reach the server — retrying…", 'Sem ligação ao servidor — a tentar…')
                        : tr('No connection — the figures below are the last known.', 'Sem ligação — os valores abaixo são os últimos conhecidos.'),
                    style: const TextStyle(color: _warn, fontWeight: FontWeight.w600, fontSize: 12)),
              ),
            ]),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('${_trains.length}',
                style: TextStyle(
                    color: _online ? _ink : _inkSoft,
                    fontSize: 44,
                    fontWeight: FontWeight.w800,
                    height: 1)),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                  !_online
                      ? tr('trains (last known)', 'comboios (último conhecido)')
                      : closed
                          ? tr('trains — service ended', 'comboios — serviço encerrado')
                          : tr('trains circulating', 'comboios em circulação'),
                  style: const TextStyle(color: _inkSoft, fontWeight: FontWeight.w500)),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(children: [
          const Icon(Icons.schedule_rounded, color: _inkSoft, size: 18),
          const SizedBox(width: 8),
          Text(scheduleLabel(),
              style: const TextStyle(
                  color: _inkSoft, fontWeight: FontWeight.w500, fontSize: 13)),
          const SizedBox(width: 8),
          Text(serviceHours,
              style: const TextStyle(color: _ink, fontWeight: FontWeight.w700, fontSize: 13)),
          Text(' · ${everyDay()}',
              style: const TextStyle(
                  color: _inkSoft, fontWeight: FontWeight.w500, fontSize: 13)),
        ]),
        const SizedBox(height: 16),
        for (final line in lineOrder) _lineRow(line),
        const SizedBox(height: 16),
        Row(children: [
          const Icon(Icons.warning_rounded, color: _ink, size: 18),
          const SizedBox(width: 8),
          Text(disrupted.isEmpty ? 'Warnings' : 'Warnings (${disrupted.length})',
              style: const TextStyle(color: _ink, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 6),
        if (disrupted.isEmpty)
          Row(children: [
            Icon(Icons.check_circle, color: _ok, size: 18),
            SizedBox(width: 8),
            Text(tr('All lines running normally', 'Todas as linhas em serviço normal'),
                style: TextStyle(color: _inkSoft, fontWeight: FontWeight.w500)),
          ])
        else
          for (final l in disrupted)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('${l.line}: ${l.detail.isEmpty ? l.status : l.detail}',
                  style: const TextStyle(color: _warn, fontWeight: FontWeight.w600)),
            ),
      ],
    );
  }

  Widget _lineRow(String line) {
    final status = _lines.firstWhere(
      (l) => l.line == line,
      orElse: () => LineStatus(line: line, status: '—', detail: ''),
    );
    final ok = status.isNormal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(width: 26, child: Center(child: LineLogo(line, height: 22))),
          const SizedBox(width: 10),
          Expanded(
            child: Text(line, style: const TextStyle(color: _ink, fontWeight: FontWeight.w600)),
          ),
          Text('${_countFor(line)}',
              style: const TextStyle(color: _ink, fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(width: 4),
          Text(tr('trains', 'comboios'), style: const TextStyle(color: _inkSoft, fontSize: 12)),
          const SizedBox(width: 12),
          Icon(ok ? Icons.check_circle : Icons.warning_amber_rounded,
              color: ok ? _ok : _warn, size: 18),
        ],
      ),
    );
  }

  Widget _settingsContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        StripeHeader(
          icon: Icons.settings_rounded,
          title: tr('Settings', 'Definições'),
          trailing: GestureDetector(
            onTap: () => setState(() => _settingsOpen = false),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.05), shape: BoxShape.circle),
              child: const Icon(Icons.close_rounded, color: Colors.black54, size: 18),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Icon(Icons.layers_rounded, color: _inkSoft, size: 18),
          SizedBox(width: 6),
          Text(tr('Map style', 'Estilo do mapa'), style: const TextStyle(color: _inkSoft, fontWeight: FontWeight.w500)),
        ]),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final s in MapStyle.values) ...[
              _styleChip(s),
              if (s != MapStyle.values.last) const SizedBox(width: 10),
            ],
          ],
        ),
        const SizedBox(height: 20),
        Row(children: [
          const Icon(Icons.translate_rounded, color: _inkSoft, size: 18),
          const SizedBox(width: 6),
          Text(tr('Language', 'Idioma'),
              style: const TextStyle(color: _inkSoft, fontWeight: FontWeight.w500)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _langChip(AppLang.en, 'English'),
          const SizedBox(width: 10),
          _langChip(AppLang.pt, 'Português'),
        ]),
        const SizedBox(height: 20),
        _aboutSection(),
      ],
    );
  }

  Widget _aboutSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          Icon(Icons.info_outline_rounded, color: _inkSoft, size: 18),
          SizedBox(width: 6),
          Text(tr('About & credits', 'Sobre e créditos'), style: const TextStyle(color: _inkSoft, fontWeight: FontWeight.w500)),
        ]),
        const SizedBox(height: 10),
        Text(disclaimer, style: TextStyle(color: _inkSoft, fontSize: 12, height: 1.4)),
        const SizedBox(height: 14),
        for (final (label, source) in credits)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: _ink, fontSize: 12, fontWeight: FontWeight.w700)),
                Text(source, style: const TextStyle(color: _inkSoft, fontSize: 12)),
              ],
            ),
          ),
        const SizedBox(height: 6),
        _legalRow('Privacy Policy', privacyPolicy),
        _legalRow('Terms of Use', termsOfUse),
        const SizedBox(height: 8),
        Text('$appName · v$appVersion',
            style: const TextStyle(color: _inkSoft, fontSize: 11)),
      ],
    );
  }

  Widget _legalRow(String title, String body) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => LegalScreen(title: title, body: body)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(title, style: const TextStyle(color: _ink, fontWeight: FontWeight.w600)),
            ),
            const Icon(Icons.chevron_right_rounded, color: _inkSoft, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _langChip(AppLang lang, String label) {
    final selected = appLang == lang;
    return Expanded(
      child: GestureDetector(
        onTap: () async {
          HapticFeedback.selectionClick();
          await setLang(lang);
          if (mounted) setState(() {}); // re-render every tr() in the tree
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? _ink : Colors.black.withOpacity(0.05),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : _ink,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  Widget _styleChip(MapStyle s) {
    final selected = _style == s;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _style = s);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? _ink : Colors.black.withOpacity(0.05),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              Icon(s.icon, size: 20, color: selected ? Colors.white : _ink),
              const SizedBox(height: 4),
              Text(
                s.label,
                style: TextStyle(
                  color: selected ? Colors.white : _ink,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- nav bar ----

  Widget _navBar() {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 550),
          curve: Curves.easeOutBack,
          builder: (context, v, child) => Transform.translate(
            offset: Offset(0, (1 - v) * 80),
            child: Opacity(opacity: v.clamp(0.0, 1.0), child: child),
          ),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Panel(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              borderRadius: const BorderRadius.all(Radius.circular(30)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Map sits in the middle as the standout "home" button
                  _navItem(Icons.explore_rounded, tr('Nearby', 'Perto'), 1),
                  _navItem(Icons.directions_subway_rounded, tr('Trains', 'Comboios'), 2),
                  _mapNavButton(),
                  _navItem(Icons.pin_drop_rounded, tr('Stations', 'Estações'), 3),
                  _navItem(Icons.info_rounded, tr('Info', 'Info'), 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The centre "home" button — always dark-filled so it stands out from the
  /// other tabs, ringed in blue when the map is the active view.
  Widget _mapNavButton() {
    final selected =
        _tab == 0 && _selectedStation == null && _followTrainId == null && !_settingsOpen;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() {
          _tab = 0;
          _selectedStation = null;
          _followTrainId = null;
          _settingsOpen = false;
        });
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: _ink,
          shape: BoxShape.circle,
          border: selected ? Border.all(color: Color(lineColors['Azul']!), width: 2.5) : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: const Icon(Icons.map_rounded, color: Colors.white, size: 24),
      ),
    );
  }

  Widget _navItem(IconData icon, String label, int index) {
    final selected = _tab == index &&
        _selectedStation == null &&
        _followTrainId == null &&
        !_settingsOpen;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() {
          // tapping the tab you're already on deselects it, back to the map
          _tab = selected ? 0 : index;
          _selectedStation = null;
          _followTrainId = null;
          _settingsOpen = false;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? _ink : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: selected ? Colors.white : _inkSoft),
            if (selected) ...[
              const SizedBox(width: 8),
              Text(label,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ],
          ],
        ),
      ),
    );
  }

  // ---- markers ----

  Marker _stationMarker(Station s) {
    final color = Color(lineColors[s.lines.isNotEmpty ? s.lines.first : ''] ?? 0xFF9E9E9E);
    return Marker(
      point: s.pos,
      width: 22,
      height: 22,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() {
            _selectedStation = s;
            _followTrainId = null;
            _settingsOpen = false;
            _tab = 0;
          });
        },
        child: Center(
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 2)],
            ),
          ),
        ),
      ),
    );
  }

  Marker _userMarker(LatLng p) => Marker(
        point: p,
        width: 22,
        height: 22,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0A84FF),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 4)],
          ),
        ),
      );

  Marker _trainMarker(TrainPosition t) {
    final color = Color(lineColors[t.line] ?? 0xFFFFFFFF);
    final followed = t.trainId == _followTrainId;
    final box = followed ? 50.0 : 40.0;
    final dot = followed ? 34.0 : 26.0;
    return Marker(
      point: t.pos,
      width: box,
      height: box,
      child: GestureDetector(
        onTap: () => _followTrain(t),
        child: Tooltip(
          message: '${t.trainId} → ${t.destinoName}\n'
              'next: ${t.nextStopName} in ${(t.etaSeconds / 60).floor()}:'
              '${(t.etaSeconds % 60).round().toString().padLeft(2, '0')}',
          child: Stack(
            alignment: Alignment.center,
            children: [
              // direction arrow, orbiting the marker (bearing: 0 = north)
              Transform.rotate(
                angle: t.bearing * math.pi / 180,
                child: SizedBox(
                  width: box,
                  height: box,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: CustomPaint(
                      size: Size(followed ? 14 : 11, followed ? 11 : 8),
                      painter: _ArrowPainter(color),
                    ),
                  ),
                ),
              ),
              // the round train icon
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: followed ? 4 : 3),
                  boxShadow: followed
                      ? [BoxShadow(color: color.withOpacity(0.6), blurRadius: 14, spreadRadius: 2)]
                      : [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 4)],
                ),
                padding: EdgeInsets.all(followed ? 4 : 3),
                child: Image.asset(
                  'assets/icons/metro.png',
                  errorBuilder: (_, __, ___) =>
                      Container(decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small filled triangle (with a white outline for contrast) pointing up;
/// rotated by a train's bearing to show its direction of travel.
class _ArrowPainter extends CustomPainter {
  final Color color;
  const _ArrowPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter old) => old.color != color;
}
