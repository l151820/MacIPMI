import IPMIKit
import SwiftUI

struct OverviewTab: View {
    let conn: HostConnection
    @State private var pending: ChassisControl?
    @State private var confirmBMCReset = false
    @State private var bootDevice: BootDevice = .pxe
    @State private var bootPersistent = false
    @State private var bootEFI = false
    @State private var bootInfo: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                powerBox
                HStack(alignment: .top, spacing: 16) {
                    chassisBox
                    VStack(spacing: 16) {
                        bootBox
                        fanBox
                    }
                }
                bmcBox
            }
            .padding()
        }
        .task { await conn.refreshOverview() }
        .confirmationDialog(pending.map { "\($0.displayName) ausführen?" } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { action in
            Button(action.displayName, role: .destructive) { Task { await conn.power(action) } }
        } message: { action in
            Text(warning(for: action))
        }
        .confirmationDialog("BMC neu starten?", isPresented: $confirmBMCReset) {
            Button("BMC neu starten", role: .destructive) { Task { await conn.bmcColdReset() } }
        } message: {
            Text("Der Server läuft weiter, aber das BMC ist für 1–2 Minuten nicht erreichbar.")
        }
    }

    private func warning(for a: ChassisControl) -> String {
        switch a {
        case .powerDown: return "Der Server wird sofort ohne Herunterfahren ausgeschaltet. Nicht gespeicherte Daten gehen verloren."
        case .powerCycle: return "Der Server wird hart aus- und wieder eingeschaltet."
        case .hardReset: return "Der Server wird sofort zurückgesetzt."
        case .softShutdown: return "Das Betriebssystem erhält ein ACPI-Signal zum Herunterfahren."
        case .diagnosticInterrupt: return "Ein NMI wird ausgelöst (kann das Betriebssystem anhalten)."
        case .powerUp: return ""
        }
    }

    // MARK: Boxes

    private var powerBox: some View {
        GroupBox {
            HStack(spacing: 18) {
                Image(systemName: "power.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(conn.chassis?.powerOn == true ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conn.chassis.map { $0.powerOn ? "Eingeschaltet" : "Ausgeschaltet" } ?? "Unbekannt")
                        .font(.title2.bold())
                    if let c = conn.chassis, c.powerOverload || c.mainPowerFault || c.powerControlFault {
                        Label("Stromversorgungsfehler gemeldet", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Stromversorgung").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if conn.isBusy("power") || conn.isBusy("overview") { ProgressView().controlSize(.small) }
                Button { Task { await conn.refreshOverview() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Status aktualisieren")
            }
            Divider().padding(.vertical, 6)
            HStack {
                Button { Task { await conn.power(.powerUp) } } label: { Label("Einschalten", systemImage: "power") }
                    .disabled(conn.chassis?.powerOn == true)
                Button { pending = .softShutdown } label: { Label("Herunterfahren", systemImage: "moon") }
                Button { pending = .powerDown } label: { Label("Ausschalten", systemImage: "poweroff") }
                Button { pending = .hardReset } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                Button { pending = .powerCycle } label: { Label("Power Cycle", systemImage: "arrow.triangle.2.circlepath") }
                Spacer()
            }
            .disabled(conn.isBusy("power"))
        } label: {
            Text("Stromversorgung")
        }
    }

    private var chassisBox: some View {
        GroupBox("Gehäuse") {
            VStack(alignment: .leading, spacing: 10) {
                if let c = conn.chassis {
                    InfoGrid(rows: [
                        ("Letztes Ereignis", c.lastPowerEvent.isEmpty ? "–" : c.lastPowerEvent.joined(separator: ", ")),
                        ("Gehäuse geöffnet", c.intrusion ? "Ja" : "Nein"),
                        ("Lüfterfehler", c.coolingFault ? "Ja" : "Nein"),
                        ("Laufwerksfehler", c.driveFault ? "Ja" : "Nein"),
                        ("Frontpanel gesperrt", c.frontPanelLockout ? "Ja" : "Nein"),
                        ("Identify-LED", c.identifyState ?? "–"),
                    ])
                    Picker("Nach Stromausfall", selection: Binding(
                        get: { c.restorePolicy },
                        set: { p in Task { await conn.setRestorePolicy(p) } })) {
                        ForEach(PowerRestorePolicy.allCases.filter { $0 != .unknown }) { Text($0.displayName).tag($0) }
                        if c.restorePolicy == .unknown { Text("Unbekannt").tag(PowerRestorePolicy.unknown) }
                    }
                } else {
                    Text("Keine Daten").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Identify-LED")
                    Spacer()
                    Button("15 s") { Task { await conn.identify(seconds: 15) } }
                    Button("60 s") { Task { await conn.identify(seconds: 60) } }
                    Button("Aus") { Task { await conn.identify(seconds: 0) } }
                }
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity)
    }

    private var bootBox: some View {
        GroupBox("Boot-Gerät") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Gerät", selection: $bootDevice) {
                    ForEach(BootDevice.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Dauerhaft (sonst nur nächster Start)", isOn: $bootPersistent)
                Toggle("UEFI-Boot", isOn: $bootEFI)
                HStack {
                    if let bootInfo { Text(bootInfo).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Übernehmen") {
                        Task {
                            if await conn.setBootDevice(bootDevice, persistent: bootPersistent, efi: bootEFI) {
                                bootInfo = "Gesetzt: \(bootDevice.displayName)"
                            }
                        }
                    }
                    .disabled(conn.isBusy("boot"))
                }
            }
            .padding(4)
        }
    }

    private var fanBox: some View {
        GroupBox("Lüftermodus (Supermicro)") {
            HStack {
                if let mode = conn.fanMode {
                    Picker("", selection: Binding(get: { mode },
                                                  set: { m in Task { await conn.setFanMode(m) } })) {
                        ForEach(SupermicroFanMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(conn.isBusy("fan"))
                } else {
                    Text("Nicht verfügbar").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(4)
        }
    }

    private var bmcBox: some View {
        GroupBox("BMC") {
            VStack(alignment: .leading, spacing: 10) {
                if let d = conn.deviceID {
                    InfoGrid(rows: [
                        ("Hersteller", "\(d.manufacturerName) (IANA \(d.manufacturerID))"),
                        ("Produkt-ID", String(format: "0x%04X", d.productID)),
                        ("Firmware", d.firmwareVersion),
                        ("IPMI-Version", d.ipmiVersion),
                        ("Geräte-ID / Revision", "\(d.deviceID) / \(d.deviceRevision)"),
                        ("GUID", conn.guid ?? "–"),
                        ("Funktionen", d.capabilities.joined(separator: ", ")),
                    ])
                } else {
                    Text("Keine Daten").foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("BMC neu starten …", role: .destructive) { confirmBMCReset = true }
                }
            }
            .padding(4)
        }
    }
}
