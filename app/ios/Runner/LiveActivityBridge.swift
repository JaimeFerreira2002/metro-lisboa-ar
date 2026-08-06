//  LiveActivityBridge.swift
//  MethodChannel bridge that starts / updates / ends the route Live Activity.
//
//  ┌─ NOT YET IN A BUILD TARGET ────────────────────────────────────────────┐
//  │ Ready-to-wire scaffold, not added to the Runner target yet. See          │
//  │ docs/LIVE_ACTIVITY.md. Once added, register it where the Flutter engine   │
//  │ is available (AppDelegate or SceneDelegate):                              │
//  │                                                                           │
//  │   let controller = window?.rootViewController as! FlutterViewController   │
//  │   LiveActivityBridge.register(with: controller.binaryMessenger)           │
//  └─────────────────────────────────────────────────────────────────────────┘
//
//  Uses only local ActivityKit updates (pushType: nil) — no APNs, so it works
//  with a free Apple ID, matching this project's no-App-Group constraint.

import Flutter
import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

enum LiveActivityBridge {
    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "meetro/live_activity", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            if #available(iOS 16.1, *) {
                handle(call, result)
            } else {
                result(nil) // pre-16.1: Live Activities unsupported, silently ignore
            }
        }
    }

    @available(iOS 16.1, *)
    private static var current: Activity<RouteActivityAttributes>? {
        Activity<RouteActivityAttributes>.activities.first
    }

    @available(iOS 16.1, *)
    private static func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "start", "update":
            guard let a = call.arguments as? [String: Any] else { result(nil); return }
            let state = RouteActivityAttributes.ContentState(
                line: a["line"] as? String ?? "",
                direction: a["direction"] as? String ?? "",
                alight: a["alight"] as? String ?? "",
                numStops: a["numStops"] as? Int ?? 0,
                legIndex: a["legIndex"] as? Int ?? 0,
                legCount: a["legCount"] as? Int ?? 1,
                etaEpochMs: (a["etaEpochMs"] as? NSNumber)?.doubleValue ?? 0,
                complete: a["complete"] as? Bool ?? false
            )
            if let activity = current {
                Task { await activity.update(using: state) }
            } else {
                guard ActivityAuthorizationInfo().areActivitiesEnabled else { result(nil); return }
                let attributes = RouteActivityAttributes(destination: a["to"] as? String ?? "")
                do {
                    _ = try Activity.request(attributes: attributes, contentState: state, pushType: nil)
                } catch {
                    // user disabled Live Activities, or the OS declined — ignore
                }
            }
            result(nil)

        case "end":
            if let activity = current {
                Task { await activity.end(dismissalPolicy: .immediate) }
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
