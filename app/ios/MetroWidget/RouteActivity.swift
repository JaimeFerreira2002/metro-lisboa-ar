//  RouteActivity.swift
//  Live Activity for an in-progress meetro route — lock screen + Dynamic Island.
//
//  ┌─ NOT YET IN A BUILD TARGET ────────────────────────────────────────────┐
//  │ This file is a ready-to-wire scaffold. It is intentionally not added to  │
//  │ any Xcode target yet, so it doesn't affect the current build. To turn    │
//  │ the Live Activity on, follow docs/LIVE_ACTIVITY.md — it needs a real     │
//  │ device and Xcode, which CI can't provide.                                │
//  └─────────────────────────────────────────────────────────────────────────┘
//
//  The Dart side (app/lib/live_activity.dart) already sends start/update/end
//  over the `meetro/live_activity` MethodChannel; today those calls no-op until
//  LiveActivityBridge is registered.

import ActivityKit
import SwiftUI
import WidgetKit

/// Shared contract between the app (which starts/updates the activity) and the
/// widget (which renders it). The keys mirror the payload in
/// app/lib/live_activity.dart.
struct RouteActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var line: String
        var direction: String
        var alight: String
        var numStops: Int
        var legIndex: Int
        var legCount: Int
        var etaEpochMs: Double
        var complete: Bool
    }

    var destination: String
}

/// Line palette — mirrors app/lib/models.dart (lineColors) and MetroWidget.swift.
private func routeLineColor(_ line: String) -> Color {
    switch line {
    case "Amarela": return Color(red: 0.96863, green: 0.65882, blue: 0.00000)
    case "Azul": return Color(red: 0.18431, green: 0.49020, blue: 0.88235)
    case "Verde": return Color(red: 0.00000, green: 0.63137, blue: 0.60784)
    case "Vermelha": return Color(red: 0.91765, green: 0.11373, blue: 0.46275)
    default: return .gray
    }
}

private func routeEtaDate(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

@available(iOS 16.1, *)
struct RouteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RouteActivityAttributes.self) { context in
            // Lock screen / notification banner.
            LockScreenView(state: context.state)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Circle().fill(routeLineColor(context.state.line)).frame(width: 12, height: 12)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(routeEtaDate(context.state.etaEpochMs), style: .timer)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 56)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("Get off at \(context.state.alight)")
                        .font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("\(context.state.numStops) stops · toward \(context.state.direction)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } compactLeading: {
                Circle().fill(routeLineColor(context.state.line)).frame(width: 10, height: 10)
            } compactTrailing: {
                Text(routeEtaDate(context.state.etaEpochMs), style: .timer)
                    .monospacedDigit().font(.caption2).frame(maxWidth: 44)
            } minimal: {
                Circle().fill(routeLineColor(context.state.line)).frame(width: 10, height: 10)
            }
        }
    }
}

@available(iOS 16.1, *)
private struct LockScreenView: View {
    let state: RouteActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(routeLineColor(state.line)).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("Get off at \(state.alight)")
                    .font(.headline).foregroundStyle(.white).lineLimit(1)
                Text("\(state.line) · toward \(state.direction)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(routeEtaDate(state.etaEpochMs), style: .timer)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit().foregroundStyle(.white)
                    .frame(maxWidth: 72, alignment: .trailing)
                Text("leg \(state.legIndex + 1)/\(state.legCount)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
