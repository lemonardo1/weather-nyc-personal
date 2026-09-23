import Foundation
import BackgroundTasks

/// Forecast snapshots saved on every fetch (foreground and hourly background refresh),
/// so the chart can replay how the forecast changed over the last few hours.
enum SnapshotStore {
    /// How long snapshots are kept.
    static let retention: TimeInterval = 48 * 3600
    /// A fetch this soon after the previous snapshot replaces it instead of adding a new one.
    static let mergeWindow: TimeInterval = 15 * 60

    private static let lock = NSLock()
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snapshots.json")
    }

    static func all() -> [Forecast] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    static func save(_ forecast: Forecast) {
        lock.lock(); defer { lock.unlock() }
        var snapshots = read()
        if let last = snapshots.last, forecast.fetchedAt.timeIntervalSince(last.fetchedAt) < mergeWindow {
            snapshots.removeLast()
        }
        snapshots.append(forecast)
        let cutoff = forecast.fetchedAt.addingTimeInterval(-retention)
        snapshots.removeAll { $0.fetchedAt < cutoff }
        if let data = try? JSONEncoder().encode(snapshots) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Snapshots closest to `hoursBack` hours before `current` (within ±`tolerance`), oldest first, no duplicates.
    static func history(before current: Forecast, hoursBack: [Int] = [3, 2, 1],
                        tolerance: TimeInterval = 40 * 60) -> [(hoursAgo: Int, forecast: Forecast)] {
        let snapshots = all().filter { $0.fetchedAt < current.fetchedAt.addingTimeInterval(-mergeWindow) }
        var used = Set<Date>()
        var result: [(Int, Forecast)] = []
        for h in hoursBack.sorted(by: >) {
            let target = current.fetchedAt.addingTimeInterval(-Double(h) * 3600)
            let best = snapshots
                .filter { !used.contains($0.fetchedAt) && abs($0.fetchedAt.timeIntervalSince(target)) <= tolerance }
                .min { abs($0.fetchedAt.timeIntervalSince(target)) < abs($1.fetchedAt.timeIntervalSince(target)) }
            if let best {
                used.insert(best.fetchedAt)
                result.append((h, best))
            }
        }
        return result
    }

    private static func read() -> [Forecast] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Forecast].self, from: data)) ?? []
    }
}

/// Hourly background fetch. iOS decides the actual timing (typically hourly-ish when the app is used regularly,
/// less often on low battery / Low Power Mode, never after the app is force-quit).
enum BackgroundRefresh {
    static let identifier = "com.daeseongkim.weathernyc.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        schedule()
        if let forecast = try? await WeatherService.fetch() {
            SnapshotStore.save(forecast)
        }
    }
}
