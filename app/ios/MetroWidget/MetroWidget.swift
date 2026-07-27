//  MetroWidget.swift
//  Home-screen widget: next trains at the station closest to you.
//
//  Notes:
//  - Talks to the backend directly (no App Group needed, so this works with a
//    free Apple ID; App Groups require a paid membership).
//  - Location comes from WidgetKit: set `NSWidgetWantsLocation = YES` in the
//    widget target's Info settings. It piggybacks on the main app's
//    When-In-Use permission, so grant location in the app first.
//  - iOS budgets widget refreshes (~every 10-15 min), so we can't stream. We
//    convert each ETA into an ABSOLUTE arrival Date at fetch time and let
//    SwiftUI count it down on-device — the countdown stays live between
//    refreshes instead of freezing on a stale "3:20".

import CoreLocation
import SwiftUI
import WidgetKit

// MARK: - Config

private let apiBase = "https://metro-lisboa-ar.fly.dev"
private let refreshMinutes = 10

// MARK: - API models (mirror the backend wire contract)

private struct APIStation: Decodable {
    let stop_id: String
    let name: String
    let lat: Double
    let lon: Double
    let lines: [String]
}

private struct APIArrival: Decodable {
    let line: String
    let destino_name: String
    let eta_seconds: Double
}

// Line colours — must match the app's palette in app/lib/models.dart
// (lineColors) so the widget and the map show the same shades.
func lineColor(_ line: String) -> Color {
    switch line {
    case "Amarela": return Color(red: 0.96863, green: 0.65882, blue: 0.00000) // #f7a800
    case "Azul": return Color(red: 0.18431, green: 0.49020, blue: 0.88235)    // #2f7de1
    case "Verde": return Color(red: 0.00000, green: 0.63137, blue: 0.60784)   // #00a19b
    case "Vermelha": return Color(red: 0.91765, green: 0.11373, blue: 0.46275) // #ea1d76
    default: return .gray
    }
}

// MARK: - Location

private final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()
    private let manager = CLLocationManager()
    private var handler: ((CLLocation?) -> Void)?

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func request(_ completion: @escaping (CLLocation?) -> Void) {
        handler = completion
        manager.delegate = self
        // If we already have a recent fix, use it — cheaper and instant.
        if let cached = manager.location {
            finish(cached)
            return
        }
        manager.requestLocation()
        // requestLocation() can silently never call back (e.g. unauthorized in
        // an extension). Don't let the timeline hang on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.finish(nil)
        }
    }

    private func finish(_ location: CLLocation?) {
        guard let handler else { return } // already finished (or timed out)
        self.handler = nil
        handler(location)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
}

// MARK: - Timeline

struct ArrivalItem: Identifiable {
    let id = UUID()
    let line: String
    let destination: String
    let arrivesAt: Date
}

struct MetroEntry: TimelineEntry {
    let date: Date
    let stationName: String?
    let distanceMeters: Double?
    let arrivals: [ArrivalItem]
    let message: String? // shown when there's nothing to render

    static var preview: MetroEntry {
        MetroEntry(
            date: Date(),
            stationName: "Alameda",
            distanceMeters: 180,
            arrivals: [
                ArrivalItem(line: "Verde", destination: "Telheiras", arrivesAt: Date().addingTimeInterval(95)),
                ArrivalItem(line: "Vermelha", destination: "Aeroporto", arrivesAt: Date().addingTimeInterval(240)),
                ArrivalItem(line: "Verde", destination: "Cais do Sodré", arrivesAt: Date().addingTimeInterval(410)),
            ],
            message: nil
        )
    }

    static func failure(_ message: String) -> MetroEntry {
        MetroEntry(date: Date(), stationName: nil, distanceMeters: nil, arrivals: [], message: message)
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> MetroEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (MetroEntry) -> Void) {
        if context.isPreview {
            completion(.preview)
            return
        }
        load(completion: completion)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MetroEntry>) -> Void) {
        load { entry in
            let next = Calendar.current.date(byAdding: .minute, value: refreshMinutes, to: Date())!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func load(completion: @escaping (MetroEntry) -> Void) {
        LocationProvider.shared.request { location in
            guard let location else {
                // Be specific — "no location" has very different causes.
                switch LocationProvider.shared.authorizationStatus {
                case .notDetermined:
                    completion(.failure("Open the app and allow location"))
                case .denied, .restricted:
                    completion(.failure("Location is off — enable it in Settings"))
                default:
                    completion(.failure("Waiting for a location fix…"))
                }
                return
            }
            Task {
                do {
                    let stations = try await fetch([APIStation].self, path: "/stations")
                    let nearest = stations.min {
                        distance($0, location) < distance($1, location)
                    }
                    guard let nearest else {
                        completion(.failure("No stations found"))
                        return
                    }
                    let arrivals = try await fetch(
                        [APIArrival].self,
                        path: "/station/\(nearest.stop_id)/arrivals"
                    )
                    let now = Date()
                    let items = arrivals.prefix(3).map {
                        ArrivalItem(
                            line: $0.line,
                            destination: $0.destino_name,
                            arrivesAt: now.addingTimeInterval($0.eta_seconds)
                        )
                    }
                    completion(MetroEntry(
                        date: now,
                        stationName: nearest.name,
                        distanceMeters: distance(nearest, location),
                        arrivals: Array(items),
                        message: items.isEmpty ? "No upcoming trains" : nil
                    ))
                } catch {
                    completion(.failure("Can't reach the server"))
                }
            }
        }
    }

    private func distance(_ station: APIStation, _ location: CLLocation) -> Double {
        CLLocation(latitude: station.lat, longitude: station.lon).distance(from: location)
    }

    private func fetch<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        guard let url = URL(string: apiBase + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Views

struct MetroWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: MetroEntry

    private var isSmall: Bool { family == .systemSmall }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.stationName == nil, let message = entry.message {
                // Nothing to describe yet — don't claim a "closest station".
                eyebrow("tram.fill", "NEXT TRAINS")
                Spacer(minLength: 6)
                Text(message)
                    .font(.system(size: isSmall ? 10 : 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                content
            }
            lineStripe
        }
        .padding(isSmall ? 11 : 14)
        .containerBackground(.background, for: .widget)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("location.fill", "CLOSEST STATION")
            stationLine
            if let message = entry.message {
                Spacer(minLength: 6)
                Text(message)
                    .font(.system(size: isSmall ? 10 : 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Divider().padding(.vertical, isSmall ? 5 : 7)
                HStack {
                    eyebrow("tram.fill", "NEXT TRAINS")
                    Spacer(minLength: 0)
                    Text("arrives in")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 3)
                ForEach(entry.arrivals.prefix(isSmall ? 2 : 3)) { arrival in
                    row(arrival)
                }
                Spacer(minLength: 4)
            }
        }
    }

    /// Small uppercase caption that says what the block below actually is.
    private func eyebrow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.6)
        }
        .foregroundStyle(.secondary)
    }

    private var stationLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(entry.stationName ?? "Nearby")
                .font(.system(size: isSmall ? 15 : 18, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 2)
            if let distance = entry.distanceMeters {
                Text(distance < 1000
                     ? "\(Int(distance)) m away"
                     : String(format: "%.1f km away", distance / 1000))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func row(_ arrival: ArrivalItem) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(lineColor(arrival.line))
                .frame(width: 7, height: 7)
            Text("→ \(arrival.destination)")
                .font(.system(size: isSmall ? 11 : 13))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 3)
            // Absolute date + .timer => counts down live between refreshes.
            Text(arrival.arrivesAt, style: .timer)
                .font(.system(size: isSmall ? 11 : 13, weight: .heavy))
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: isSmall ? 40 : 48, alignment: .trailing)
        }
        .padding(.vertical, 1.5)
    }

    /// The app's four-line motif.
    private var lineStripe: some View {
        HStack(spacing: 2) {
            ForEach(["Azul", "Amarela", "Verde", "Vermelha"], id: \.self) { line in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(lineColor(line))
                    .frame(height: 3)
            }
        }
    }
}

// MARK: - Widget

struct MetroWidget: Widget {
    let kind = "MetroWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            MetroWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Next trains nearby")
        .description("Live countdown to the next trains at the metro station closest to you.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// NOTE: no @main / WidgetBundle here — Xcode's generated MetroWidgetBundle.swift
// owns the entry point and already registers MetroWidget(). Declaring @main in
// both files is a "duplicate @main" compile error.
