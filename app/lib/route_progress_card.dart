/// The pinned "you're on a route" card that floats above the nav bar while a
/// route is active. Shows the current leg — line, direction, where to get off —
/// plus the live next-train wait, and the controls to advance a leg or end.
import 'package:flutter/material.dart';

import 'active_route.dart';
import 'line_logo.dart';
import 'models.dart';
import 'panel.dart';
import 'strings.dart';

String _min(double seconds) {
  final m = (seconds / 60).round();
  return '${m < 1 && seconds > 0 ? 1 : m} min';
}

class RouteProgressCard extends StatelessWidget {
  final ActiveRoute route;

  /// Live seconds until the next train on this leg reaches the board station
  /// (from the arrivals feed). Null when unknown / not yet fetched.
  final double? liveWaitSeconds;

  final VoidCallback onNext;
  final VoidCallback onEnd;

  const RouteProgressCard({
    super.key,
    required this.route,
    required this.liveWaitSeconds,
    required this.onNext,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    final leg = route.leg;
    if (leg == null) return const SizedBox.shrink();
    final color = Color(lineColors[leg.line] ?? 0xFF888888);

    return Panel(
      glowColor: color,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      borderRadius: const BorderRadius.all(Radius.circular(24)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: progress + end.
          Row(
            children: [
              Text(
                route.legCount > 1
                    ? '${tr('Step', 'Etapa')} ${route.currentLeg + 1}/${route.legCount}'
                    : tr('On your way', 'A caminho'),
                style: const TextStyle(color: Colors.black54, fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Expanded(child: _progressDots(color)),
              GestureDetector(
                onTap: onEnd,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.05), shape: BoxShape.circle),
                  child: const Icon(Icons.close_rounded, color: Colors.black54, size: 16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Line + direction.
          Row(
            children: [
              LineLogo(leg.line, height: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('toward ${leg.destinoName}', 'sentido ${leg.destinoName}'),
                  style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (liveWaitSeconds != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00A19B).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.wifi_tethering_rounded, size: 12, color: Color(0xFF00A19B)),
                      const SizedBox(width: 4),
                      Text(tr('in ${_min(liveWaitSeconds!)}', 'em ${_min(liveWaitSeconds!)}'),
                          style: const TextStyle(color: Color(0xFF00A19B), fontSize: 11, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // The key instruction while riding: where to get off.
          Row(
            children: [
              const Icon(Icons.logout_rounded, size: 16, color: Colors.black45),
              const SizedBox(width: 6),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: const TextStyle(color: Colors.black87, fontSize: 16, fontWeight: FontWeight.w700),
                    children: [
                      TextSpan(text: '${tr('Get off at', 'Sair em')} '),
                      TextSpan(text: leg.alightStopName, style: TextStyle(color: color)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 22),
            child: Text(
              '${leg.numStops} ${leg.numStops == 1 ? tr('stop', 'estação') : tr('stops', 'estações')} · ${_min(leg.rideSeconds)}',
              style: const TextStyle(color: Colors.black45, fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(height: 12),
          // Advance control.
          GestureDetector(
            onTap: onNext,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(14)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(route.isLastLeg ? Icons.flag_rounded : Icons.arrow_forward_rounded,
                      color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    route.isLastLeg
                        ? tr('I have arrived', 'Cheguei')
                        : tr('Next leg', 'Próxima etapa'),
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressDots(Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < route.legCount; i++)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            width: i == route.currentLeg ? 14 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i <= route.currentLeg ? color : Colors.black.withOpacity(0.15),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}
