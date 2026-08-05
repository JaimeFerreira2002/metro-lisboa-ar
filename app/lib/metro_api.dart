/// Client for the interpolation service. Shared by the 2D map now and the AR
/// view later — the app never talks to the Metro API directly.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'models.dart';

class MetroApi {
  /// Override at build time: --dart-define=API_BASE=http://<host>:8000
  /// Android emulator reaches the host via 10.0.2.2; iOS simulator via localhost.
  static const base = String.fromEnvironment('API_BASE', defaultValue: 'http://localhost:8000');

  /// Whether the live stream is currently delivering data. Drives the offline
  /// banner and lets panels tell "no trains" apart from "can't reach server".
  final ValueNotifier<bool> connected = ValueNotifier(false);

  /// Retries until the server answers, so app/server launch order doesn't matter.
  Future<List<Station>> stations() async {
    while (true) {
      try {
        final resp = await http.get(Uri.parse('$base/stations'));
        final list = jsonDecode(resp.body) as List;
        return list.map((e) => Station.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Baked track polylines (one per line+direction). Retries until reachable.
  Future<List<TrackLine>> track() async {
    while (true) {
      try {
        final resp = await http.get(Uri.parse('$base/track'));
        final gj = jsonDecode(resp.body) as Map<String, dynamic>;
        final feats = (gj['features'] as List?) ?? [];
        return feats.map((f) => TrackLine.fromFeature(f as Map<String, dynamic>)).toList();
      } catch (_) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Per-line operational status. Retries until reachable.
  Future<List<LineStatus>> lines() async {
    while (true) {
      try {
        final resp = await http.get(Uri.parse('$base/lines'));
        final list = jsonDecode(resp.body) as List;
        return list.map((e) => LineStatus.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Geocode a free-text query to places near Lisbon (OpenStreetMap Nominatim).
  Future<List<Place>> geocode(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeQueryComponent('$q, Lisboa')}&format=json&limit=5',
      );
      final resp = await http.get(uri, headers: {'User-Agent': 'metro-lisboa-ar/0.1'});
      if (resp.statusCode != 200) return [];
      final list = jsonDecode(resp.body) as List;
      return list
          .map((e) => Place(
                name: (e['display_name'] as String).split(',').take(2).join(','),
                pos: LatLng(double.parse(e['lat'] as String), double.parse(e['lon'] as String)),
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Upcoming trains at one station (on-demand; single attempt, [] on failure).
  Future<List<Arrival>> arrivals(String stopId) async {
    try {
      final resp = await http.get(Uri.parse('$base/station/$stopId/arrivals'));
      if (resp.statusCode != 200) return [];
      final list = jsonDecode(resp.body) as List;
      return list.map((e) => Arrival.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Fastest route between two stations, using live train waits (`GET /route`).
  /// Single attempt; returns null on failure or when no route is found (404 —
  /// e.g. the topology is still warming up after a server restart).
  Future<RoutePlan?> route(String fromStopId, String toStopId) async {
    try {
      final uri = Uri.parse('$base/route')
          .replace(queryParameters: {'from': fromStopId, 'to': toStopId});
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return null;
      return RoutePlan.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Live train snapshots via Server-Sent Events (`GET /stream`).
  /// Reconnects automatically if the server is down or the connection drops.
  Stream<List<TrainPosition>> trainStream() async* {
    while (true) {
      try {
        final req = http.Request('GET', Uri.parse('$base/stream'));
        final resp = await http.Client().send(req);
        final lines = resp.stream.transform(utf8.decoder).transform(const LineSplitter());
        await for (final line in lines) {
          if (line.startsWith('data:')) {
            final data = jsonDecode(line.substring(5).trim()) as List;
            connected.value = true;
            yield data.map((e) => TrainPosition.fromJson(e as Map<String, dynamic>)).toList();
          }
        }
      } catch (_) {
        // server unreachable or stream dropped — fall through and retry
      }
      connected.value = false; // stream ended or failed
      await Future.delayed(const Duration(seconds: 2));
    }
  }
}
