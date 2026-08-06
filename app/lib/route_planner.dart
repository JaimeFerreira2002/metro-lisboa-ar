/// Route planner: pick an origin and destination station and get the *fastest*
/// route based on live train positions (GET /route). The fastest route isn't
/// always the fewest stops — a train that's minutes away can lose to a slightly
/// longer ride whose train is arriving now.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'line_logo.dart';
import 'line_stripe.dart';
import 'metro_api.dart';
import 'models.dart';
import 'panel.dart';
import 'strings.dart';

/// Round seconds to a friendly "N min" (never "0 min" for a real wait/ride).
String _mins(double seconds) {
  final m = (seconds / 60).round();
  return '${m < 1 && seconds > 0 ? 1 : m} min';
}

class RoutePlannerScreen extends StatefulWidget {
  final MetroApi api;
  final List<Station> stations;
  final Station? initialFrom;

  const RoutePlannerScreen({
    super.key,
    required this.api,
    required this.stations,
    this.initialFrom,
  });

  @override
  State<RoutePlannerScreen> createState() => _RoutePlannerScreenState();
}

class _RoutePlannerScreenState extends State<RoutePlannerScreen> {
  Station? _from;
  Station? _to;
  bool _loading = false;
  bool _searched = false;
  RoutePlan? _plan;

  @override
  void initState() {
    super.initState();
    _from = widget.initialFrom;
  }

  Future<void> _pick(bool origin) async {
    final picked = await showModalBottomSheet<Station>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _StationPicker(stations: widget.stations),
    );
    if (picked == null) return;
    setState(() {
      if (origin) {
        _from = picked;
      } else {
        _to = picked;
      }
      _searched = false;
      _plan = null;
    });
  }

  void _swap() {
    HapticFeedback.selectionClick();
    setState(() {
      final t = _from;
      _from = _to;
      _to = t;
      _searched = false;
      _plan = null;
    });
  }

  Future<void> _find() async {
    final from = _from, to = _to;
    if (from == null || to == null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _searched = true;
      _plan = null;
    });
    final plan = await widget.api.route(from.stopId, to.stopId);
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final canSearch = _from != null && _to != null && _from!.stopId != _to!.stopId;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F6),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.black87),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(tr('Plan a route', 'Planear rota'),
            style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _pickers(),
          const SizedBox(height: 16),
          _findButton(canSearch),
          const SizedBox(height: 20),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.only(top: 40),
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            )
          else if (_plan != null && _plan!.legs.isNotEmpty)
            _results(_plan!)
          else if (_searched)
            _empty(),
        ],
      ),
    );
  }

  Widget _pickers() => Panel(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        child: Row(
          children: [
            Expanded(
              child: Column(
                children: [
                  _pickRow(tr('From', 'De'), _from, Icons.trip_origin_rounded, () => _pick(true)),
                  const Divider(height: 1),
                  _pickRow(tr('To', 'Para'), _to, Icons.place_rounded, () => _pick(false)),
                ],
              ),
            ),
            IconButton(
              tooltip: tr('Swap', 'Trocar'),
              icon: const Icon(Icons.swap_vert_rounded, color: Colors.black54),
              onPressed: (_from != null || _to != null) ? _swap : null,
            ),
          ],
        ),
      );

  Widget _pickRow(String label, Station? station, IconData icon, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 18, color: Colors.black38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(color: Colors.black45, fontSize: 11, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      station?.name ?? tr('Choose station', 'Escolher estação'),
                      style: TextStyle(
                        color: station == null ? Colors.black38 : Colors.black87,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _findButton(bool enabled) => GestureDetector(
        onTap: enabled ? _find : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.alt_route_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text(tr('Find fastest route', 'Ver rota mais rápida'),
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      );

  Widget _empty() => Panel(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Icon(Icons.wrong_location_rounded, color: Colors.black26, size: 36),
            const SizedBox(height: 12),
            Text(
              tr('No route found. Live train data may still be warming up — try again in a moment.',
                  'Sem rota encontrada. Os dados dos comboios podem estar a carregar — tente novamente daqui a pouco.'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      );

  Widget _results(RoutePlan plan) {
    final transfers = plan.transfers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Total time headline.
        Panel(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StripeHeader(
                icon: Icons.route_rounded,
                title: '≈ ${_mins(plan.totalSeconds)}',
                lines: plan.legs.map((l) => l.line).toSet().toList(),
              ),
              const SizedBox(height: 10),
              Text(
                transfers == 0
                    ? tr('Direct · no transfers', 'Directo · sem trocas')
                    : (transfers == 1
                        ? tr('1 transfer', '1 troca')
                        : tr('$transfers transfers', '$transfers trocas')),
                style: const TextStyle(color: Colors.black54, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < plan.legs.length; i++) ...[
          if (i > 0) _transferDivider(),
          _legCard(plan.legs[i]),
        ],
      ],
    );
  }

  Widget _transferDivider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Row(
          children: [
            const Icon(Icons.transfer_within_a_station_rounded, size: 18, color: Colors.black38),
            const SizedBox(width: 8),
            Text(tr('Change here', 'Mudar aqui'),
                style: const TextStyle(color: Colors.black45, fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ),
      );

  Widget _legCard(RouteLeg leg) {
    final color = Color(lineColors[leg.line] ?? 0xFF888888);
    return Panel(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line colour spine + pictogram.
          Column(
            children: [
              LineLogo(leg.line, height: 22),
              const SizedBox(height: 6),
              Container(width: 4, height: 34, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Wait line — the live edge over a plain map.
                Row(
                  children: [
                    Icon(leg.live ? Icons.wifi_tethering_rounded : Icons.schedule_rounded,
                        size: 15, color: leg.live ? const Color(0xFF00A19B) : Colors.black38),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        leg.live
                            ? tr('Next train in ${_mins(leg.waitSeconds)}', 'Próximo comboio em ${_mins(leg.waitSeconds)}')
                            : tr('Train about every ${_mins(leg.waitSeconds)}', 'Comboio a cada ${_mins(leg.waitSeconds)}'),
                        style: const TextStyle(color: Colors.black54, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(leg.boardStopName,
                    style: const TextStyle(color: Colors.black87, fontSize: 16, fontWeight: FontWeight.w700)),
                Text(tr('toward ${leg.destinoName}', 'sentido ${leg.destinoName}'),
                    style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                  '${leg.numStops} ${leg.numStops == 1 ? tr('stop', 'estação') : tr('stops', 'estações')} · ${_mins(leg.rideSeconds)}',
                  style: const TextStyle(color: Colors.black45, fontSize: 12, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.place_rounded, size: 15, color: Colors.black38),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(leg.alightStopName,
                          style: const TextStyle(color: Colors.black87, fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A searchable list of stations, shown as a bottom sheet. Pops the chosen one.
class _StationPicker extends StatefulWidget {
  final List<Station> stations;
  const _StationPicker({required this.stations});

  @override
  State<_StationPicker> createState() => _StationPickerState();
}

class _StationPickerState extends State<_StationPicker> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = [...widget.stations]..sort((a, b) => a.name.compareTo(b.name));
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty ? all : all.where((s) => s.name.toLowerCase().contains(q)).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.all(14),
              child: TextField(
                controller: _controller,
                autofocus: true,
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w500),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded, color: Colors.black45),
                  hintText: tr('Search stations', 'Procurar estações'),
                  filled: true,
                  fillColor: const Color(0xFFF2F2F2),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final s = filtered[i];
                  return ListTile(
                    leading: const Icon(Icons.directions_subway_rounded, color: Colors.black45, size: 20),
                    title: Text(s.name, style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w600)),
                    subtitle: Row(
                      children: [
                        for (final line in s.lines)
                          Padding(
                            padding: const EdgeInsets.only(right: 4, top: 4),
                            child: Container(
                              width: 9,
                              height: 9,
                              decoration: BoxDecoration(color: Color(lineColors[line] ?? 0xFF888888), shape: BoxShape.circle),
                            ),
                          ),
                      ],
                    ),
                    onTap: () => Navigator.of(context).pop(s),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
