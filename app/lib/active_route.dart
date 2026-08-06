/// A route the user has started and is actively travelling.
///
/// Wraps the immutable [RoutePlan] with mutable progress (which leg you're on)
/// and a start time, and persists across app restarts via SharedPreferences — so
/// a trip survives backgrounding or a relaunch mid-journey.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class ActiveRoute {
  final RoutePlan plan;
  final String fromName;
  final String toName;
  final int currentLeg;
  final DateTime startedAt;

  ActiveRoute({
    required this.plan,
    required this.fromName,
    required this.toName,
    this.currentLeg = 0,
    required this.startedAt,
  });

  int get legCount => plan.legs.length;
  bool get isComplete => currentLeg >= legCount;
  bool get isLastLeg => currentLeg == legCount - 1;
  RouteLeg? get leg => isComplete ? null : plan.legs[currentLeg];

  ActiveRoute copyWith({int? currentLeg}) => ActiveRoute(
        plan: plan,
        fromName: fromName,
        toName: toName,
        currentLeg: currentLeg ?? this.currentLeg,
        startedAt: startedAt,
      );

  Map<String, dynamic> toJson() => {
        'plan': plan.toJson(),
        'from_name': fromName,
        'to_name': toName,
        'current_leg': currentLeg,
        'started_at': startedAt.toIso8601String(),
      };

  factory ActiveRoute.fromJson(Map<String, dynamic> j) => ActiveRoute(
        plan: RoutePlan.fromJson(j['plan'] as Map<String, dynamic>),
        fromName: j['from_name'] as String? ?? '',
        toName: j['to_name'] as String? ?? '',
        currentLeg: (j['current_leg'] as num? ?? 0).toInt(),
        startedAt: DateTime.tryParse(j['started_at'] as String? ?? '') ?? DateTime.now(),
      );

  // ---- persistence ----

  static const _key = 'active_route';

  static Future<ActiveRoute?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_key);
    if (s == null) return null;
    try {
      return ActiveRoute.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null; // corrupt / old shape — treat as no active route
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(toJson()));
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
