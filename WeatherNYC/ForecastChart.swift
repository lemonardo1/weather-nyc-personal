import SwiftUI
import Charts

enum Palette {
    static let background = Color(red: 0.02, green: 0.04, blue: 0.08)
    static let grid = Color.white.opacity(0.18)
    static let axisLabel = Color.white.opacity(0.75)
    static let subtitle = Color.white.opacity(0.6)
}

enum Metric: String, CaseIterable, Identifiable {
    case temperature = "temperature_2m"
    case wind = "wind_speed_10m"
    case rain = "rain"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .temperature: Color(red: 0.40, green: 0.72, blue: 0.98)
        case .wind: Color(red: 0.42, green: 0.86, blue: 0.45)
        case .rain: Color(red: 0.42, green: 0.36, blue: 0.85)
        }
    }

    @ViewBuilder var legendSymbol: some View {
        switch self {
        case .temperature: Circle().fill(color)
        case .wind: Rectangle().fill(color)
        case .rain: Rectangle().fill(color).scaleEffect(x: 0.45, y: 1)
        }
    }
}

/// Two y-axes sharing the same 5 gridlines: temperature on the leading edge, wind on the trailing edge.
/// Wind values are mapped into the temperature coordinate space for plotting.
struct DualScale {
    static let intervals = 5
    private static let steps: [Double] = [0.5, 1, 2, 2.5, 4, 5, 8, 10, 15, 20, 25, 40, 50, 100]

    let lo: Double
    let tempStep: Double
    let windStep: Double

    var hi: Double { lo + Double(Self.intervals) * tempStep }
    var ticks: [Double] { (0...Self.intervals).map { lo + Double($0) * tempStep } }
    /// y position of the weather icon row (just below the top gridline).
    var iconY: Double { hi - 0.3 * tempStep }

    init(tempMin: Double, tempMax: Double, windMax: Double) {
        // Leave ~0.6 step of headroom at the top for the icon row.
        var lo = 0.0, tempStep = Self.steps.last!
        for s in Self.steps {
            let l = (tempMin / s).rounded(.down) * s
            if l + Double(Self.intervals) * s >= tempMax + 0.6 * s {
                lo = l; tempStep = s; break
            }
        }
        self.lo = lo
        self.tempStep = tempStep
        self.windStep = Self.steps.first { Double(Self.intervals) * $0 >= windMax + 0.6 * $0 } ?? Self.steps.last!
    }

    func plotY(wind: Double) -> Double { lo + wind / windStep * tempStep }
    func wind(atY y: Double) -> Double { (y - lo) / tempStep * windStep }
}

/// 0-based scale with 4 gridlines for hourly rain; never flatter than `minimumTop` so drizzle doesn't look like a downpour.
struct RainScale {
    static let intervals = 4
    private static let steps: [Double] = [0.01, 0.02, 0.025, 0.05, 0.1, 0.2, 0.25, 0.5, 1, 2, 2.5, 5, 10, 20]

    let step: Double
    var hi: Double { Double(Self.intervals) * step }
    var ticks: [Double] { (0...Self.intervals).map { Double($0) * step } }

    init(max: Double, minimumTop: Double) {
        let target = Swift.max(max, minimumTop)
        step = Self.steps.first { Double(Self.intervals) * $0 >= target } ?? Self.steps.last!
    }
}

/// Main line chart (temperature + wind) above a rain bar chart; both scroll and select together.
struct ForecastChart: View {
    let forecast: Forecast
    var visible: Set<Metric> = Set(Metric.allCases)
    /// Extra forecasts whose values the y-axes must also fit (playback frames), so axes stay put while lines morph.
    var scaleAlso: [Forecast] = []

    @State private var selection: Date?
    @State private var scrollX: Date = Location.calendar.startOfDay(for: Date())

    private let calendar = Location.calendar
    private var hours: [HourPoint] { forecast.hours }
    private var showsLines: Bool { visible.contains(.temperature) || visible.contains(.wind) }
    private var showsRain: Bool { visible.contains(.rain) }

    /// Fixed y-axis label width so both charts' plot areas line up horizontally.
    private static let axisLabelWidth: CGFloat = 28

    private var scaleHours: [HourPoint] { hours + scaleAlso.flatMap(\.hours) }

    private var scale: DualScale {
        let temps = visible.contains(.temperature) ? scaleHours.compactMap(\.temperature) : []
        let winds = visible.contains(.wind) ? scaleHours.compactMap(\.windSpeed) : []
        return DualScale(tempMin: temps.min() ?? 0, tempMax: temps.max() ?? 30, windMax: winds.max() ?? 20)
    }

    private var rainScale: RainScale {
        RainScale(max: scaleHours.compactMap(\.rain).max() ?? 0,
                  minimumTop: forecast.precipitationUnit == "inch" ? 0.04 : 1)
    }

    private var xDomain: ClosedRange<Date> {
        guard let first = hours.first?.date, let last = hours.last?.date else { return Date()...Date() }
        return first...last.addingTimeInterval(3600)
    }

    private var selectedHour: HourPoint? {
        guard let selection else { return nil }
        return hours.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    var body: some View {
        GeometryReader { geo in
            // ~6pt per hour → about 2.5 days visible in portrait, full week on wide screens.
            let visibleHours = min(Double(hours.count), max(36, geo.size.width / 6))

            VStack(spacing: 14) {
                if showsLines {
                    lineChart(width: geo.size.width, visibleHours: visibleHours)
                }
                if showsRain {
                    rainChart(visibleHours: visibleHours)
                        .frame(height: showsLines ? geo.size.height * 0.26 : nil)
                }
            }
        }
    }

    // MARK: - Temperature + wind

    private func lineChart(width: CGFloat, visibleHours: Double) -> some View {
        let scale = scale
        // Keep weather icons ≥ ~24pt apart.
        let pointsPerHour = width / visibleHours
        let iconEvery = [2, 3, 4, 6, 8, 12].first { Double($0) * pointsPerHour >= 24 } ?? 12

        return Chart {
            ForEach(hours) { h in
                if visible.contains(.temperature), let t = h.temperature {
                    LineMark(x: .value("Time", h.date), y: .value("Temp", t),
                             series: .value("Metric", Metric.temperature.rawValue))
                        .foregroundStyle(by: .value("Metric", Metric.temperature.rawValue))
                }
                if visible.contains(.wind), let w = h.windSpeed {
                    LineMark(x: .value("Time", h.date), y: .value("Temp", scale.plotY(wind: w)),
                             series: .value("Metric", Metric.wind.rawValue))
                        .foregroundStyle(by: .value("Metric", Metric.wind.rawValue))
                }
            }
            .lineStyle(StrokeStyle(lineWidth: 1.4))
            .interpolationMethod(.monotone)

            ForEach(hours.filter { calendar.component(.hour, from: $0.date) % iconEvery == 0 }) { h in
                if let code = h.weatherCode {
                    PointMark(x: .value("Time", h.date), y: .value("Temp", scale.iconY))
                        .symbol {
                            Image(systemName: WeatherIcon.symbol(code: code, isDay: h.isDay))
                                .font(.system(size: 13, weight: .light))
                                .foregroundStyle(.white)
                        }
                }
            }

            nowRule

            if let h = selectedHour {
                selectionRule(h)
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        SelectionCard(hour: h, visible: visible, forecast: forecast)
                    }
            }
        }
        .chartForegroundStyleScale(domain: Metric.allCases.map(\.rawValue),
                                   range: Metric.allCases.map(\.color))
        .chartLegend(.hidden)
        .chartYScale(domain: scale.lo...scale.hi)
        .chartYAxis {
            AxisMarks(position: .leading, values: scale.ticks) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.grid)
                AxisValueLabel {
                    if let y = v.as(Double.self) { axisLabel(Self.number(y), alignment: .trailing) }
                }
                .foregroundStyle(Palette.axisLabel)
            }
            AxisMarks(position: .trailing, values: scale.ticks) { v in
                AxisValueLabel {
                    if let y = v.as(Double.self) {
                        axisLabel(visible.contains(.wind) ? Self.number(scale.wind(atY: y)) : "", alignment: .leading)
                    }
                }
                .foregroundStyle(Metric.wind.color.opacity(0.85))
            }
        }
        .chartXAxis { xAxis(labels: !showsRain) }
        .modifier(SharedX(scrollX: $scrollX, selection: $selection, domain: xDomain, visibleHours: visibleHours))
        .padding(.top, 56) // room for the selection card
        .overlay(alignment: .top) {
            HStack {
                if visible.contains(.temperature) {
                    Text(forecast.temperatureUnit).foregroundStyle(Palette.axisLabel)
                }
                Spacer()
                if visible.contains(.wind) {
                    Text(forecast.windUnit).foregroundStyle(Metric.wind.color.opacity(0.85))
                }
            }
            .font(.caption2.weight(.semibold))
            .padding(.top, 36)
        }
    }

    // MARK: - Rain

    private func rainChart(visibleHours: Double) -> some View {
        let scale = rainScale
        return Chart {
            ForEach(hours) { h in
                if let r = h.rain, r > 0 {
                    BarMark(x: .value("Time", h.date, unit: .hour), y: .value("Rain", r))
                        .foregroundStyle(Metric.rain.color)
                }
            }

            nowRule

            if let h = selectedHour {
                if showsLines {
                    selectionRule(h)
                } else {
                    // The card normally lives on the line chart; show it here when that chart is hidden.
                    selectionRule(h)
                        .annotation(position: .top, spacing: 0,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            SelectionCard(hour: h, visible: visible, forecast: forecast)
                        }
                }
            }
        }
        .chartYScale(domain: 0...scale.hi)
        .chartYAxis {
            AxisMarks(position: .leading, values: scale.ticks) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Palette.grid)
                AxisValueLabel {
                    if let y = v.as(Double.self) { axisLabel(Self.number(y), alignment: .trailing) }
                }
                .foregroundStyle(Metric.rain.color.opacity(0.95))
            }
            // Empty trailing labels keep the plot width identical to the line chart.
            AxisMarks(position: .trailing, values: scale.ticks) { _ in
                AxisValueLabel { axisLabel("", alignment: .leading) }
            }
        }
        .chartXAxis { xAxis(labels: true) }
        .modifier(SharedX(scrollX: $scrollX, selection: $selection, domain: xDomain, visibleHours: visibleHours))
        .padding(.top, showsLines ? 16 : 56)
        .overlay(alignment: .topLeading) {
            Text(forecast.precipitationUnit)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Metric.rain.color.opacity(0.95))
                .padding(.top, showsLines ? 0 : 36)
        }
    }

    // MARK: - Shared pieces

    private var nowRule: some ChartContent {
        RuleMark(x: .value("Now", Date()))
            .foregroundStyle(.white.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1))
    }

    private func selectionRule(_ h: HourPoint) -> some ChartContent {
        RuleMark(x: .value("Selected", h.date))
            .foregroundStyle(.white.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private func xAxis(labels: Bool) -> some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 12)) { v in
            AxisTick(length: 4).foregroundStyle(Palette.grid)
            if labels {
                AxisValueLabel(anchor: .top) {
                    if let d = v.as(Date.self) {
                        let isMidnight = calendar.component(.hour, from: d) == 0
                        Text(isMidnight ? Self.dayLabel(d) : "12:00")
                            .fontWeight(isMidnight ? .semibold : .regular)
                    }
                }
                .foregroundStyle(Palette.axisLabel)
            }
        }
    }

    private func axisLabel(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .frame(width: Self.axisLabelWidth, alignment: alignment)
    }

    private static func number(_ v: Double) -> String {
        let r = (v * 1000).rounded() / 1000
        return r.rounded() == r ? String(Int(r)) : String(format: "%g", r)
    }

    private static func dayLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = Location.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return f.string(from: d)
    }
}

/// Horizontal scrolling, visible window, selection and time zone shared by both charts.
private struct SharedX: ViewModifier {
    @Binding var scrollX: Date
    @Binding var selection: Date?
    let domain: ClosedRange<Date>
    let visibleHours: Double

    func body(content: Content) -> some View {
        content
            // Explicit domain: a rain chart with no bars would otherwise infer a different x range.
            .chartXScale(domain: domain)
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: visibleHours * 3600)
            .chartScrollPosition(x: $scrollX)
            .chartXSelection(value: $selection)
            .environment(\.timeZone, Location.timeZone)
            .environment(\.calendar, Location.calendar)
    }
}

private struct SelectionCard: View {
    let hour: HourPoint
    let visible: Set<Metric>
    let forecast: Forecast

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let code = hour.weatherCode {
                    Image(systemName: WeatherIcon.symbol(code: code, isDay: hour.isDay))
                }
                Text(hour.date, format: .dateTime.weekday(.abbreviated).hour().minute()
                    .locale(Locale(identifier: "en_GB")))
            }
            .font(.caption2.weight(.semibold))
            row(.temperature, hour.temperature, "%.1f %@", forecast.temperatureUnit)
            row(.wind, hour.windSpeed, "%.1f %@", forecast.windUnit)
            row(.rain, hour.rain, forecast.precipitationUnit == "inch" ? "%.3f %@" : "%.1f %@",
                forecast.precipitationUnit)
        }
        .padding(6)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.grid))
        .environment(\.timeZone, Location.timeZone)
    }

    @ViewBuilder private func row(_ m: Metric, _ v: Double?, _ format: String, _ unit: String) -> some View {
        if visible.contains(m), let v {
            HStack(spacing: 4) {
                m.legendSymbol.frame(width: 6, height: 6)
                Text(String(format: format, v, unit))
            }
            .font(.caption2.monospacedDigit())
        }
    }
}
