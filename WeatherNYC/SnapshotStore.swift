import Foundation
import BackgroundTasks

/// Forecast snapshots saved on every fetch (foreground and hourly background refresh) plus past model runs
/// backfilled from Open-Meteo's archive, so the chart can replay how the forecast changed.
enum SnapshotStore {
    /// How long snapshots are kept.
    static let retention: TimeInterval = 48 * 3600
    /// A fetch this soon after the previous snapshot replaces it instead of adding a new one.
    static let mergeWindow: TimeInterval = 15 * 60

    private static let lock = NSLock()
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Versioned by model: snapshots from a different model aren't comparable.
        return dir.appendingPathComponent("snapshots-\(WeatherService.model).json")
    }

    static func all() -> [Forecast] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    static func save(_ forecast: Forecast) {
        lock.lock(); defer { lock.unlock() }
        var snapshots = read()
        if let last = snapshots.last, last.modelRun == nil,
           forecast.fetchedAt.timeIntervalSince(last.fetchedAt) < mergeWindow {
            snapshots.removeLast()
        }
        snapshots.append(forecast)
        write(snapshots)
    }

    /// Makes sure the last `count` archived model runs are stored. Runs already stored aren't refetched.
    static func backfill(count: Int = 3) async {
        let stored = Set(all().compactMap(\.modelRun))
        var available = 0
        // The archive keeps a run every 3 h (UTC) and publishes it a few hours late; look back up to 24 h.
        for run in candidateRuns(before: Date(), step: 3, limit: 8) {
            if available == count { break }
            if stored.contains(run) { available += 1; continue }
            guard let forecast = try? await WeatherService.fetchRun(run) else { continue }
            insert(forecast)
            available += 1
        }
    }

    /// The most recent `count` snapshots older than `current` (by at least 30 min), oldest first.
    static func history(before current: Forecast, count: Int = 3) -> [Forecast] {
        let cutoff = current.fetchedAt.addingTimeInterval(-30 * 60)
        let recent = all().filter { $0.fetchedAt <= cutoff && $0.fetchedAt > cutoff.addingTimeInterval(-24 * 3600) }
        return Array(recent.suffix(count))
    }

    private static func insert(_ forecast: Forecast) {
        lock.lock(); defer { lock.unlock() }
        var snapshots = read()
        snapshots.removeAll { $0.modelRun != nil && $0.modelRun == forecast.modelRun }
        snapshots.append(forecast)
        write(snapshots)
    }

    private static func candidateRuns(before date: Date, step: Int, limit: Int) -> [Date] {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let hour = utc.component(.hour, from: date)
        guard let latest = utc.date(bySettingHour: hour - hour % step, minute: 0, second: 0, of: date) else { return [] }
        return (0..<limit).map { latest.addingTimeInterval(-Double($0 * step) * 3600) }
    }

    /// Sorted by time, pruned to the retention window.
    private static func write(_ snapshots: [Forecast]) {
        let sorted = snapshots.sorted { $0.fetchedAt < $1.fetchedAt }
        let cutoff = Date().addingTimeInterval(-retention)
        let kept = sorted.filter { $0.fetchedAt >= cutoff }
        if let data = try? JSONEncoder().encode(kept) {
            try? data.write(to: fileURL, options: .atomic)
        }
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
        await SnapshotStore.backfill()
    }
}
