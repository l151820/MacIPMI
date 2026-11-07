import IPMIKit
import SwiftUI

struct ContentView: View {
    @Environment(HostStore.self) private var store
    @State private var editing: HostEntry?
    @State private var deleting: HostEntry?

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.selection) {
                Section("Systeme") {
                    ForEach(store.hosts) { h in
                        HostRow(connection: store.connection(for: h))
                            .tag(h.id)
                            .contextMenu {
                                Button("Bearbeiten …") { editing = h }
                                Divider()
                                Button("Löschen …", role: .destructive) { deleting = h }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Button { store.showAddSheet = true } label: { Label("System hinzufügen", systemImage: "plus") }
                }
            }
            .overlay {
                if store.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Systeme", systemImage: "server.rack")
                    } description: {
                        Text("Füge ein BMC über + hinzu.")
                    }
                }
            }
        } detail: {
            if let id = store.selection, let h = store.hosts.first(where: { $0.id == id }) {
                HostDetailView(connection: store.connection(for: h), onEdit: { editing = h })
                    .id(h)
            } else {
                ContentUnavailableView("Kein System ausgewählt", systemImage: "server.rack")
            }
        }
        .sheet(isPresented: $store.showAddSheet) { HostEditor(original: nil) }
        .sheet(item: $editing) { h in HostEditor(original: h) }
        .confirmationDialog("System löschen?", isPresented: Binding(get: { deleting != nil },
                                                                     set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { h in
            Button("„\(h.name)“ löschen", role: .destructive) { store.delete(h.id) }
        } message: { _ in
            Text("Der Eintrag und das gespeicherte Passwort werden entfernt.")
        }
    }
}

struct HostRow: View {
    let connection: HostConnection

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.host.name).lineLimit(1)
                Text(connection.host.address).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if connection.isConnected, let c = connection.chassis {
                Image(systemName: "power")
                    .foregroundStyle(c.powerOn ? .green : .secondary)
                    .help(c.powerOn ? "Eingeschaltet" : "Ausgeschaltet")
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch connection.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray.opacity(0.5)
        }
    }
}

struct HostEditor: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let original: HostEntry?

    @State private var name = ""
    @State private var address = ""
    @State private var port = "623"
    @State private var username = "ADMIN"
    @State private var password = ""
    @State private var privilege: IPMIPrivilege = .administrator

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("z. B. Fileserver"))
                    TextField("IP-Adresse / Hostname", text: $address, prompt: Text("192.168.1.10"))
                    TextField("Port", text: $port)
                }
                Section {
                    TextField("Benutzername", text: $username)
                    SecureField(original == nil ? "Passwort" : "Passwort (leer = unverändert)", text: $password)
                    Picker("Berechtigung", selection: $privilege) {
                        ForEach([IPMIPrivilege.user, .operator, .administrator]) { Text($0.displayName).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "Hinzufügen" : "Sichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || username.isEmpty)
            }
            .padding()
        }
        .frame(width: 440)
        .onAppear {
            guard let o = original else { return }
            name = o.name
            address = o.address
            port = String(o.port)
            username = o.username
            privilege = IPMIPrivilege(rawValue: o.privilege) ?? .administrator
        }
    }

    private func save() {
        let addr = address.trimmingCharacters(in: .whitespaces)
        var h = original ?? HostEntry(name: "", address: "", username: "")
        h.name = name.isEmpty ? addr : name
        h.address = addr
        h.port = UInt16(port) ?? 623
        h.username = username
        h.privilege = privilege.rawValue
        if original == nil {
            store.add(h, password: password)
        } else {
            store.update(h, password: password.isEmpty ? nil : password)
        }
        dismiss()
    }
}
