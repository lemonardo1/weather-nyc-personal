import Foundation

// Upper East Side, Manhattan (E 77th St & 2nd Ave)
enum Location {
    static let name = "Upper East Side"
    static let latitude = 40.7736
    static let longitude = -73.9566
    static let timeZone = TimeZone(identifier: "America/New_York")!

    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }
}

struct HourPoint: Identifiable, Codable {
    let date: Date
    let temperature: Double?
    let windSpeed: Double?
    let rain: Double?
    let weatherCode: Int?
    let isDay: Bool

    var id: Date { date }
}

/// One Open-Meteo response. Always stored in °C, km/h and mm; convert for display with `converted(...)`.
struct Forecast: Codable {
    let fetchedAt: Date
    let latitude: Double
    let longitude: Double
    let elevation: Double
    let generationMs: Double
    let downloadMs: Double
    let timeZoneAbbreviation: String
    let temperatureUnit: String
    let windUnit: String
    let precipitationUnit: String
    let hours: [HourPoint]
}

extension Forecast {
    func converted(temperature t: TemperatureUnit, wind w: WindUnit, precipitation p: PrecipitationUnit) -> Forecast {
        Forecast(
            fetchedAt: fetchedAt, latitude: latitude, longitude: longitude, elevation: elevation,
            generationMs: generationMs, downloadMs: downloadMs, timeZoneAbbreviation: timeZoneAbbreviation,
            temperatureUnit: t.label, windUnit: w.label, precipitationUnit: p.label,
            hours: hours.map {
                HourPoint(date: $0.date,
                          temperature: $0.temperature.map(t.fromCelsius),
                          windSpeed: $0.windSpeed.map(w.fromKmh),
                          rain: $0.rain.map(p.fromMm),
                          weatherCode: $0.weatherCode,
                          isDay: $0.isDay)
            }
        )
    }

    /// This forecast's values laid onto `reference`'s hours, so charts can morph point-for-point between snapshots.
    /// Hours this snapshot doesn't cover keep the reference values.
    func aligned(to reference: Forecast) -> Forecast {
        let byDate = Dictionary(hours.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        return Forecast(
            fetchedAt: fetchedAt, latitude: latitude, longitude: longitude, elevation: elevation,
            generationMs: generationMs, downloadMs: downloadMs, timeZoneAbbreviation: timeZoneAbbreviation,
            temperatureUnit: temperatureUnit, windUnit: windUnit, precipitationUnit: precipitationUnit,
            hours: reference.hours.map { byDate[$0.date] ?? $0 }
        )
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius, fahrenheit
    var id: String { rawValue }
    var label: String { self == .celsius ? "°C" : "°F" }
    func fromCelsius(_ c: Double) -> Double { self == .celsius ? c : c * 9 / 5 + 32 }
}

enum PrecipitationUnit: String, CaseIterable, Identifiable {
    case mm, inch
    var id: String { rawValue }
    var label: String { rawValue }
    func fromMm(_ mm: Double) -> Double { self == .mm ? mm : mm / 25.4 }
}

enum WindUnit: String, CaseIterable, Identifiable {
    case kmh, mph, ms, kn
    var id: String { rawValue }
    var label: String {
        switch self {
        case .kmh: "km/h"
        case .mph: "mph"
        case .ms: "m/s"
        case .kn: "kn"
        }
    }
    func fromKmh(_ v: Double) -> Double {
        switch self {
        case .kmh: v
        case .mph: v / 1.609344
        case .ms: v / 3.6
        case .kn: v / 1.852
        }
    }
}

// MARK: - Open-Meteo

private struct OpenMeteoResponse: Decodable {
    struct Hourly: Decodable {
        let time: [String]
        let temperature_2m: [Double?]
        let wind_speed_10m: [Double?]
        let rain: [Double?]
        let weather_code: [Int?]
        let is_day: [Int?]
    }

    let latitude: Double
    let longitude: Double
    let elevation: Double
    let generationtime_ms: Double
    let timezone_abbreviation: String
    let hourly: Hourly
}

enum WeatherService {
    static let url: URL = {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(Location.latitude)),
            .init(name: "longitude", value: String(Location.longitude)),
            .init(name: "hourly", value: "temperature_2m,wind_speed_10m,rain,weather_code,is_day"),
            .init(name: "timezone", value: Location.timeZone.identifier),
            .init(name: "past_days", value: "1"),
            .init(name: "forecast_days", value: "7"),
        ]
        return c.url!
    }()

    static func fetch() async throws -> Forecast {
        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await URLSession.shared.data(from: url)
        let elapsed = clock.now - start
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        let r = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = Location.timeZone
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm"

        let h = r.hourly
        let hours: [HourPoint] = h.time.indices.compactMap { i in
            guard let date = parser.date(from: h.time[i]) else { return nil }
            return HourPoint(
                date: date,
                temperature: h.temperature_2m[i],
                windSpeed: h.wind_speed_10m[i],
                rain: h.rain[i],
                weatherCode: h.weather_code[i],
                isDay: (h.is_day[i] ?? 1) == 1
            )
        }

        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        return Forecast(
            fetchedAt: Date(),
            latitude: r.latitude,
            longitude: r.longitude,
            elevation: r.elevation,
            generationMs: r.generationtime_ms,
            downloadMs: ms,
            timeZoneAbbreviation: r.timezone_abbreviation,
            temperatureUnit: TemperatureUnit.celsius.label,
            windUnit: WindUnit.kmh.label,
            precipitationUnit: PrecipitationUnit.mm.label,
            hours: hours
        )
    }
}

// MARK: - WMO weather code → SF Symbol

enum WeatherIcon {
    static func symbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max" : "moon.stars"
        case 1, 2: return isDay ? "cloud.sun" : "cloud.moon"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51, 53, 55: return "cloud.drizzle"
        case 56, 57, 66, 67: return "cloud.sleet"
        case 61, 63: return "cloud.rain"
        case 65: return "cloud.heavyrain"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow"
        case 80, 81: return isDay ? "cloud.sun.rain" : "cloud.moon.rain"
        case 82: return "cloud.heavyrain"
        case 95, 96, 99: return "cloud.bolt.rain"
        default: return "questionmark"
        }
    }
}
