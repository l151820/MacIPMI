import IPMIKit
import SwiftUI

enum SensorFilter: String, CaseIterable, Identifiable {
    case all = "Alle", temperature = "Temperatur", voltage = "Spannung", fan = "Lüfter", discrete = "Diskret"
    var id: Self { self }

    func matches(_ r: SensorReading) -> Bool {
        switch self {
        case .all: return true
        case .temperature: return r.record.sensorType == 0x01
        case .voltage: return r.record.sensorType == 0x02
        case .fan: return r.record.sensorType == 0x04
        case .discrete: return !r.record.isThreshold
        }
    }
}

struct SensorsTab: View {
    let conn: HostConnection
    @AppStorage("sensors.autoRefresh") private var autoRefresh = true
    @State private var filter = SensorFilter.all
    @State private var hideUnavailable = false
    @State private var selection: SensorReading.ID?

    private var rows: [SensorReading] {
        conn.sensors.filter { filter.matches($0) && (!hideUnavailable || $0.health != .unavailable) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    ForEach(SensorFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle("N/A ausblenden", isOn: $hideUnavailable)
                Spacer()
                if let t = conn.sensorsUpdated {
                    Text("Stand \(t.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if conn.isBusy("sensors") { ProgressView().controlSize(.small) }
                Toggle("Alle 5 s", isOn: $autoRefresh)
                Button { Task { await conn.refreshSensors() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Jetzt aktualisieren")
            }
            .padding(10)

            Table(rows, selection: $selection) {
                TableColumn("") { r in
                    Image(systemName: r.health.symbol).foregroundStyle(r.health.color)
                }
                .width(18)
                TableColumn("Sensor") { r in Text(r.record.name) }
                    .width(min: 120, ideal: 160)
                TableColumn("Wert") { r in
                    Text(r.formattedValue).monospacedDigit().help(r.formattedValue)
                }
                .width(min: 90, ideal: 160)
                TableColumn("Status") { r in Text(r.health.label).foregroundStyle(r.health == .ok ? .primary : r.health.color) }
                    .width(min: 60, ideal: 80)
                TableColumn("Typ") { r in Text(EventText.sensorTypeName(r.record.sensorType)).foregroundStyle(.secondary) }
                    .width(min: 80, ideal: 110)
                TableColumn("Grenzwerte  LNR / LC / LNC  ·  UNC / UC / UNR") { r in
                    Text(r.thresholdText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                .width(min: 180, ideal: 300)
            }
            .overlay {
                if conn.sensors.isEmpty && conn.isBusy("sensors") {
                    ProgressView("Lese Sensordaten (SDR) …")
                }
            }
        }
        .task(id: autoRefresh) {
            await conn.refreshSensors()
            while autoRefresh && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled || !conn.isConnected { break }
                await conn.refreshSensors()
            }
        }
    }
}
