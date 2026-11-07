import AppKit
import IPMIKit
import SwiftUI

// MARK: - Ereignisprotokoll

struct EventLogTab: View {
    let conn: HostConnection
    @State private var confirmClear = false
    @State private var selection: Set<SELEntry.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let i = conn.selInfo {
                    Text("\(i.entries) Einträge · \(i.freeBytes) Bytes frei")
                    if i.overflow {
                        Label("Überlauf", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Spacer()
                if conn.isBusy("sel") { ProgressView().controlSize(.small) }
                Button("Kopieren") { copy() }
                    .disabled(conn.sel.isEmpty)
                Button("Löschen …", role: .destructive) { confirmClear = true }
                    .disabled(conn.sel.isEmpty)
                Button { Task { await conn.loadSEL() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Aktualisieren")
            }
            .padding(10)

            Table(conn.sel, selection: $selection) {
                TableColumn("ID") { e in Text(String(format: "%04X", e.id)).monospacedDigit() }
                    .width(44)
                TableColumn("Zeitpunkt") { e in
                    Text(e.timestamp?.formatted(date: .numeric, time: .standard) ?? "–").monospacedDigit()
                }
                .width(min: 120, ideal: 150)
                TableColumn("Sensor") { e in Text(sensorLabel(e)) }
                    .width(min: 120, ideal: 200)
                TableColumn("Ereignis") { e in Text(e.eventDescription).help(e.eventDescription) }
                    .width(min: 200, ideal: 320)
                TableColumn("Richtung") { e in
                    Text(e.directionText).foregroundStyle(e.isDeassertion ? .secondary : .primary)
                }
                .width(min: 70, ideal: 90)
            }
            .overlay {
                if conn.sel.isEmpty && !conn.isBusy("sel") {
                    ContentUnavailableView("Keine Ereignisse", systemImage: "checkmark.circle")
                }
            }
        }
        .task { await conn.loadSEL() }
        .confirmationDialog("Ereignisprotokoll löschen?", isPresented: $confirmClear) {
            Button("Alle Einträge löschen", role: .destructive) { Task { await conn.clearSEL() } }
        } message: {
            Text("Alle Einträge des System Event Log werden unwiderruflich gelöscht.")
        }
    }

    private func sensorLabel(_ e: SELEntry) -> String {
        guard e.isSystemEvent else { return "OEM" }
        let name = conn.sensorName(e.sensorNumber) ?? "#\(e.sensorNumber)"
        return "\(name) (\(e.sensorTypeName))"
    }

    private func copy() {
        let list = selection.isEmpty ? conn.sel : conn.sel.filter { selection.contains($0.id) }
        let text = list.map { e in
            [String(format: "%04X", e.id),
             e.timestamp?.formatted(date: .numeric, time: .standard) ?? "-",
             sensorLabel(e), e.eventDescription, e.directionText].joined(separator: "\t")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - FRU

struct FRUTab: View {
    let conn: HostConnection

    var body: some View {
        Group {
            if let fru = conn.fru, !fru.sections.isEmpty {
                Form {
                    ForEach(fru.sections) { s in
                        Section(s.title) {
                            ForEach(s.fields) { f in
                                LabeledContent(f.label) { Text(f.value).textSelection(.enabled) }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else if conn.isBusy("fru") {
                ProgressView("Lese FRU-Inventar …")
            } else {
                ContentUnavailableView("Keine FRU-Daten", systemImage: "shippingbox")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { if conn.fru == nil { await conn.loadFRU() } }
    }
}

// MARK: - Netzwerk

struct NetworkTab: View {
    let conn: HostConnection

    var body: some View {
        Form {
            Section("BMC-Netzwerk (Kanal \(conn.lan?.channel ?? 1))") {
                if let l = conn.lan {
                    LabeledContent("IP-Quelle", value: l.ipSource ?? "–")
                    LabeledContent("IP-Adresse", value: l.ipAddress ?? "–")
                    LabeledContent("Subnetzmaske", value: l.subnetMask ?? "–")
                    LabeledContent("Standard-Gateway", value: l.gateway ?? "–")
                    LabeledContent("Gateway-MAC", value: l.gatewayMAC ?? "–")
                    LabeledContent("MAC-Adresse", value: l.macAddress ?? "–")
                    LabeledContent("VLAN", value: l.vlan ?? "–")
                } else if conn.isBusy("lan") {
                    ProgressView()
                } else {
                    Text("Keine Daten").foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Aktualisieren") { Task { await conn.loadLAN() } }
                }
            }
        }
        .formStyle(.grouped)
        .task { if conn.lan == nil { await conn.loadLAN() } }
    }
}

// MARK: - Benutzer

struct UsersTab: View {
    let conn: HostConnection
    @State private var selection: IPMIUser.ID?
    @State private var editing: IPMIUser?
    @State private var showEmpty = false

    private var rows: [IPMIUser] {
        showEmpty ? conn.users : conn.users.filter { !$0.name.isEmpty || $0.enabled == true }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Leere Plätze anzeigen", isOn: $showEmpty)
                Spacer()
                if conn.isBusy("users") { ProgressView().controlSize(.small) }
                Button("Bearbeiten …") { editing = conn.users.first { $0.id == selection } }
                    .disabled(selection == nil)
                Button { Task { await conn.loadUsers() } } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(10)
            Table(rows, selection: $selection) {
                TableColumn("ID") { u in Text(String(u.id)).monospacedDigit() }.width(36)
                TableColumn("Name") { u in Text(u.name.isEmpty ? "(leer)" : u.name).foregroundStyle(u.name.isEmpty ? .secondary : .primary) }
                TableColumn("Status") { u in
                    Text(u.enabled.map { $0 ? "Aktiv" : "Deaktiviert" } ?? "–")
                }
                TableColumn("Berechtigung") { u in Text(u.privilegeName) }
                TableColumn("IPMI-Messaging") { u in Text(u.ipmiMessaging ? "Ja" : "Nein") }
            }
            .contextMenu(forSelectionType: IPMIUser.ID.self) { ids in
                Button("Bearbeiten …") { editing = conn.users.first { ids.contains($0.id) } }
            } primaryAction: { ids in
                editing = conn.users.first { ids.contains($0.id) }
            }
        }
        .task { if conn.users.isEmpty { await conn.loadUsers() } }
        .sheet(item: $editing) { u in UserEditSheet(conn: conn, user: u) }
    }
}

struct UserEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conn: HostConnection
    let user: IPMIUser
    @State private var name = ""
    @State private var password = ""
    @State private var password2 = ""
    @State private var enabled = true
    @State private var privilege: UInt8 = 0x04

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Benutzer \(user.id)") {
                    TextField("Name", text: $name).disabled(user.fixedName)
                    SecureField("Neues Passwort (leer = unverändert)", text: $password)
                    SecureField("Passwort wiederholen", text: $password2)
                    Toggle("Aktiviert", isOn: $enabled)
                    Picker("Berechtigung", selection: $privilege) {
                        ForEach([UInt8(0x02), 0x03, 0x04, 0x0F], id: \.self) { Text(IPMIUser.privilegeName($0)).tag($0) }
                    }
                }
                if user.fixedName {
                    Text("Der Name dieses Benutzers ist im BMC fest vorgegeben.").font(.caption).foregroundStyle(.secondary)
                }
                if !password.isEmpty && password.utf8.count > 20 {
                    Text("IPMI-Passwörter dürfen höchstens 20 Zeichen lang sein.").font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    Task {
                        await conn.saveUser(user, name: name, password: password, enabled: enabled, privilege: privilege)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password != password2 || password.utf8.count > 20 || conn.isBusy("users"))
            }
            .padding()
        }
        .frame(width: 420)
        .onAppear {
            name = user.name
            enabled = user.enabled ?? false
            privilege = user.privilege
        }
    }
}

// MARK: - Konsole

struct ConsoleTab: View {
    @Environment(\.openWindow) private var openWindow
    let conn: HostConnection

    var body: some View {
        Form {
            Section("Remote-Konsole") {
                Text("Native KVM-Konsole für Supermicro X9 (ATEN iKVM) – ohne Java und ohne Rosetta. Tastatureingaben gehen an den Server, sobald das Konsolenfenster aktiv ist; Cmd+Q und Cmd+W bleiben beim Mac.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button {
                        openWindow(id: "kvm", value: conn.host.id)
                    } label: {
                        Label("Konsole öffnen", systemImage: "display")
                    }
                    .keyboardShortcut("k")
                    Spacer()
                }
            }
            Section("Webinterface") {
                Text("Virtuelle Medien, Firmware-Update und weitere Einstellungen sind über das Webinterface des BMC erreichbar.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button { conn.openWebInterface() } label: {
                        Label("Webinterface im Browser öffnen", systemImage: "safari")
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }
}
