/// Thin bridge to an iOS ActivityKit Live Activity that mirrors the active route
/// on the lock screen and Dynamic Island.
///
/// The native side — a Live Activity in the widget extension plus a MethodChannel
/// handler in the Runner — is *optional*. Every call is best-effort and silently
/// no-ops when the platform side isn't wired, the platform isn't iOS, or the OS is
/// below 16.1 / has Live Activities disabled. So this compiles and runs today with
/// no native changes; wiring the native half (see docs/LIVE_ACTIVITY.md) lights it
/// up without touching this file.
import 'package:flutter/services.dart';

import 'active_route.dart';

class LiveActivityService {
  static const _channel = MethodChannel('meetro/live_activity');

  static Future<void> start(ActiveRoute route) => _send('start', route);
  static Future<void> update(ActiveRoute route) => _send('update', route);

  static Future<void> end() async {
    try {
      await _channel.invokeMethod('end');
    } on PlatformException {
      // no activity running / unsupported — ignore
    } on MissingPluginException {
      // native side not wired — ignore
    }
  }

  static Future<void> _send(String method, ActiveRoute route) async {
    final leg = route.leg;
    // Absolute end time so the OS can count down on-device between updates.
    final etaMs = DateTime.now()
        .add(Duration(
            seconds: (((leg?.waitSeconds ?? 0) + (leg?.rideSeconds ?? 0)).round())))
        .millisecondsSinceEpoch;
    try {
      await _channel.invokeMethod(method, {
        'to': route.toName,
        'legIndex': route.currentLeg,
        'legCount': route.legCount,
        'line': leg?.line ?? '',
        'direction': leg?.destinoName ?? '',
        'board': leg?.boardStopName ?? '',
        'alight': leg?.alightStopName ?? '',
        'numStops': leg?.numStops ?? 0,
        'etaEpochMs': etaMs,
        'complete': route.isComplete,
      });
    } on PlatformException {
      // unsupported / disabled — ignore
    } on MissingPluginException {
      // native side not present — ignore
    }
  }
}
