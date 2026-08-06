# Live Activity — active route on the lock screen

The active-route feature (see [ROUTING.md](ROUTING.md) and the app's
`route_progress_card.dart`) can also surface on the **lock screen and Dynamic
Island** as an ActivityKit **Live Activity** — line, direction, where to get off,
and a live countdown.

The Flutter side is done and always safe: `app/lib/live_activity.dart` sends
`start` / `update` / `end` over the `meetro/live_activity` MethodChannel as a route
progresses, and every call **no-ops** until the native half is wired. So the app
builds and runs today with nothing on the lock screen; the steps below light it up.

> **Why this isn't wired in the PR:** ActivityKit needs a real device and Xcode —
> neither is available in CI. The two Swift files below are committed as
> ready-to-wire scaffolds, deliberately **not** added to any target so they can't
> affect the current build. Wiring is a handful of Xcode clicks + a device test.

## What's already in the repo

| File | Role |
|---|---|
| `app/lib/live_activity.dart` | Dart bridge (wired into the route lifecycle) |
| `app/ios/MetroWidget/RouteActivity.swift` | `ActivityAttributes` + the Live Activity UI |
| `app/ios/Runner/LiveActivityBridge.swift` | MethodChannel handler that starts/updates/ends it |

Local updates only (`pushType: nil`) — no APNs, so this works with a **free Apple
ID**, consistent with the widget's no-App-Group approach ([WIDGET.md](WIDGET.md)).

## Wiring steps (Xcode, ~10 min, on a Mac)

1. **Add the Info.plist flag.** In `app/ios/Runner/Info.plist` add:
   ```xml
   <key>NSSupportsLiveActivities</key>
   <true/>
   ```
2. **Add `RouteActivity.swift` to the widget extension target** (`MetroWidgetExtension`):
   Xcode → select the file → File Inspector → Target Membership → check the widget
   extension.
3. **Register the Live Activity in the widget bundle.** In
   `MetroWidgetBundle.swift`, add it to the bundle body:
   ```swift
   var body: some Widget {
       MetroWidget()
       if #available(iOS 16.1, *) { RouteLiveActivity() }
   }
   ```
4. **Add `LiveActivityBridge.swift` to the Runner target** (Target Membership → Runner).
5. **Register the channel** where the Flutter engine is available. In
   `AppDelegate`/`SceneDelegate`, after the root controller exists:
   ```swift
   let controller = window?.rootViewController as! FlutterViewController
   LiveActivityBridge.register(with: controller.binaryMessenger)
   ```
   `RouteActivityAttributes` is shared: either add `RouteActivity.swift` to **both**
   the Runner and the widget targets, or factor the `struct` into a file that is.
6. **Run on a device** (iOS 16.1+; Dynamic Island needs an iPhone 14 Pro or newer).
   Plan a route → **Start route** → the Live Activity should appear; **Next leg** and
   **End** update and dismiss it.

## Notes

- `Activity.request(attributes:contentState:pushType:)` and `update(using:)` are the
  iOS 16.1 APIs. On the iOS 16.2+ SDK the compiler may suggest the newer
  `content:ActivityContent(state:staleDate:)` forms — swap them in if you want to
  silence the deprecation warnings; behaviour is the same.
- The countdown uses an absolute end time (`etaEpochMs`) so the OS keeps counting
  down between updates without the app running — the same trick the home-screen
  widget uses.
- Live Activities can't be fully exercised in the simulator's Dynamic Island for all
  devices; test the real thing on hardware before shipping.
