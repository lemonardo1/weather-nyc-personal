import SwiftUI

struct ContentView: View {
    @State private var forecast: Forecast?
    @State private var error: String?
    @State private var showSettings = false
    @State private var isLoading = false

    /// Snapshot currently shown during playback (nil = live forecast).
    @State private var playbackFrame: Forecast?
    @State private var playbackLabel: String?
    /// All frames of the running playback; the chart fits its axes to these so they don't jump between frames.
    @State private var playbackFrames: [Forecast] = []
    @State private var playTask: Task<Void, Never>?
    private var isPlaying: Bool { playTask != nil }

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("temperatureUnit") private var temperatureUnit: TemperatureUnit = .celsius
    @AppStorage("windUnit") private var windUnit: WindUnit = .kmh
    @AppStorage("precipitationUnit") private var precipitationUnit: PrecipitationUnit = .mm
    @AppStorage("showTemperature") private var showTemperature = true
    @AppStorage("showRain") private var showRain = true
    @AppStorage("showWind") private var showWind = true

    private var visibleMetrics: Set<Metric> {
        var set = Set<Metric>()
        if showTemperature { set.insert(.temperature) }
        if showRain { set.insert(.rain) }
        if showWind { set.insert(.wind) }
        return set
    }

    var body: some View {
        content
            .safeAreaInset(edge: .top) { topBar }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .presentationDetents([.medium, .large])
            }
            .task { await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await load() } }
            }
    }

    private var content: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            if let forecast {
                let convert = { (f: Forecast) in
                    f.converted(temperature: temperatureUnit, wind: windUnit, precipitation: precipitationUnit)
                }
                VStack(spacing: 10) {
                    ForecastChart(forecast: convert(playbackFrame ?? forecast), visible: visibleMetrics,
                                  scaleAlso: playbackFrames.map(convert))
                    Legend(visible: visibleMetrics)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .overlay(alignment: .top) {
                    if let playbackLabel {
                        PlaybackBadge(text: playbackLabel)
                            .padding(.top, 6)
                            .transition(.opacity)
                    }
                }
            } else if let error {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(.secondary)
                    Button("다시 시도") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            glassButton("gearshape", label: "설정") { showSettings = true }
            titleButton
            glassButton(isPlaying ? "stop.fill" : "play.fill", label: isPlaying ? "정지" : "재생") {
                isPlaying ? stopPlayback() : startPlayback()
            }
            .disabled(forecast == nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func glassButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    /// Location + request metadata on the same row as the buttons. Tap to refresh.
    private var titleButton: some View {
        Button { Task { await load() } } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(Location.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    }
                }
                if let f = forecast {
                    Text(String(format: "%@ · generated %.2fms · downloaded %.0fms · %@",
                                coordinates(f), f.generationMs, f.downloadMs, f.timeZoneAbbreviation))
                        .font(.caption2)
                        .foregroundStyle(Palette.subtitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isLoading ? 0.6 : 1)
        .sensoryFeedback(.impact(weight: .light), trigger: isLoading) { _, new in new }
    }

    private func coordinates(_ f: Forecast) -> String {
        let lat = String(format: "%.2f°%@", abs(f.latitude), f.latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.2f°%@", abs(f.longitude), f.longitude >= 0 ? "E" : "W")
        return "\(lat) \(lon) \(Int(f.elevation))m"
    }

    private func load() async {
        guard !isLoading, !isPlaying else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await WeatherService.fetch()
            SnapshotStore.save(fresh)
            forecast = fresh
            error = nil
            Task.detached(priority: .utility) { await SnapshotStore.backfill() }
        } catch {
            if forecast == nil { self.error = error.localizedDescription }
        }
    }

    // MARK: - Playback (3h ago → 2h ago → 1h ago → now)

    private func startPlayback() {
        guard let current = forecast else { return }
        playTask = Task {
            defer { playTask = nil }
            var history = SnapshotStore.history(before: current)
            if history.count < 3 {
                withAnimation { playbackLabel = "과거 예보 불러오는 중…" }
                await SnapshotStore.backfill()
                history = SnapshotStore.history(before: current)
            }
            guard !history.isEmpty, !Task.isCancelled else {
                withAnimation { playbackLabel = "과거 예보를 불러오지 못했어요" }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { playbackLabel = nil }
                return
            }

            let frames = history.map { ($0.aligned(to: current), Self.label($0, relativeTo: current)) }
                + [(current, Self.label(current, relativeTo: current))]

            // Jump to the oldest frame without animating, then morph forward.
            playbackFrames = frames.map(\.0)
            playbackFrame = frames[0].0
            withAnimation { playbackLabel = frames[0].1 }
            for (frame, label) in frames.dropFirst() {
                try? await Task.sleep(for: .seconds(1.6))
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.9)) {
                    playbackFrame = frame
                    playbackLabel = label
                }
            }
            try? await Task.sleep(for: .seconds(1.5))
            if Task.isCancelled { return }
            withAnimation {
                playbackFrame = nil
                playbackLabel = nil
                playbackFrames = []
            }
        }
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
        withAnimation {
            playbackFrame = nil
            playbackLabel = nil
            playbackFrames = []
        }
    }

    private static func label(_ f: Forecast, relativeTo current: Forecast) -> String {
        let time = f.fetchedAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()
            .locale(Locale(identifier: "en_GB")))
        let hoursAgo = Int((current.fetchedAt.timeIntervalSince(f.fetchedAt) / 3600).rounded())
        let source = f.modelRun != nil ? "\(time) 모델 런" : "\(time) 수집"
        return hoursAgo == 0 ? "현재 · \(source)" : "\(hoursAgo)시간 전 · \(source)"
    }
}

private struct PlaybackBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .contentTransition(.numericText())
    }
}

private struct Legend: View {
    let visible: Set<Metric>

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Metric.allCases.filter(visible.contains)) { m in
                HStack(spacing: 5) {
                    m.legendSymbol
                        .frame(width: 8, height: 8)
                    Text(m.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .minimumScaleFactor(0.7)
    }
}

#Preview {
    ContentView().preferredColorScheme(.dark)
}
