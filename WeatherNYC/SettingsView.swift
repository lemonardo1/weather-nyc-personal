import SwiftUI

struct SettingsView: View {
    @AppStorage("temperatureUnit") private var temperatureUnit: TemperatureUnit = .celsius
    @AppStorage("windUnit") private var windUnit: WindUnit = .kmh
    @AppStorage("precipitationUnit") private var precipitationUnit: PrecipitationUnit = .mm
    @AppStorage("showTemperature") private var showTemperature = true
    @AppStorage("showRain") private var showRain = true
    @AppStorage("showWind") private var showWind = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("단위") {
                    Picker("기온", selection: $temperatureUnit) {
                        ForEach(TemperatureUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("풍속", selection: $windUnit) {
                        ForEach(WindUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("강수", selection: $precipitationUnit) {
                        ForEach(PrecipitationUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("표시할 그래프") {
                    toggle(.temperature, $showTemperature)
                    toggle(.wind, $showWind)
                    toggle(.rain, $showRain)
                }

                Section {
                    LabeledContent("위치", value: Location.name)
                    LabeledContent("데이터", value: "Open-Meteo · NBM")
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private func toggle(_ m: Metric, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                m.legendSymbol.frame(width: 8, height: 8)
                Text(m.rawValue).font(.callout.monospaced())
            }
        }
        .tint(m.color)
    }
}

#Preview {
    SettingsView().preferredColorScheme(.dark)
}
