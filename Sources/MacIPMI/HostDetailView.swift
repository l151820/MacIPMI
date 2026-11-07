import IPMIKit
import SwiftUI

struct HostDetailView: View {
    @Environment(HostStore.self) private var store
    let connection: HostConnection
    let onEdit: () -> Void

    var body: some View {
        Group {
            if connection.isConnected {
                ConnectedView(conn: connection)
            } else {
                ConnectPanel(conn: connection, onEdit: onEdit)
            }
        }
        .navigationTitle(connection.host.name)
        .navigationSubtitle("\(connection.host.address) · \(connection.host.username)")
        .toolbar {
            if connection.isConnected {
                ToolbarItem {
                    Button { connection.disconnect() } label: {
                        Label("Trennen", systemImage: "xmark.circle")
                    }
                    .help("Sitzung beenden")
                }
            }
        }
        .alert("MacIPMI", isPresented: Binding(get: { connection.message != nil },
                                               set: { if !$0 { connection.message = nil } })) {
            Button("OK") {}
        } message: {
            Text(connection.message ?? "")
        }
    }
}

struct ConnectPanel: View {
    @Environment(HostStore.self) private var store
    let conn: HostConnection
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text(conn.host.name).font(.title2.bold())
            Text("\(conn.host.address):\(String(conn.host.port)) · \(conn.host.username)")
                .foregroundStyle(.secondary)
            if case .failed(let msg) = conn.state {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            if conn.state == .connecting {
                ProgressView("Verbinde …").padding(.top, 6)
            } else {
                HStack {
                    Button("Bearbeiten …", action: onEdit)
                    Button("Verbinden") {
                        Task { await conn.connect(password: store.password(for: conn.host) ?? "") }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum DetailTab: Hashable {
    case overview, sensors, events, fru, network, users, console
}

struct ConnectedView: View {
    let conn: HostConnection
    @State private var tab = DetailTab.overview

    var body: some View {
        TabView(selection: $tab) {
            OverviewTab(conn: conn)
                .tabItem { Label("Übersicht", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(DetailTab.overview)
            SensorsTab(conn: conn)
                .tabItem { Label("Sensoren", systemImage: "thermometer.medium") }
                .tag(DetailTab.sensors)
            EventLogTab(conn: conn)
                .tabItem { Label("Ereignisprotokoll", systemImage: "list.bullet.rectangle") }
                .tag(DetailTab.events)
            FRUTab(conn: conn)
                .tabItem { Label("FRU", systemImage: "shippingbox") }
                .tag(DetailTab.fru)
            NetworkTab(conn: conn)
                .tabItem { Label("Netzwerk", systemImage: "network") }
                .tag(DetailTab.network)
            UsersTab(conn: conn)
                .tabItem { Label("Benutzer", systemImage: "person.2") }
                .tag(DetailTab.users)
            ConsoleTab(conn: conn)
                .tabItem { Label("Konsole", systemImage: "display") }
                .tag(DetailTab.console)
        }
        .padding(.top, 6)
    }
}

/// Two-column key/value grid used by several tabs.
struct InfoGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SensorHealth {
    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .yellow
        case .critical: return .orange
        case .nonRecoverable: return .red
        case .unavailable: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .nonRecoverable: return "xmark.octagon.fill"
        case .unavailable: return "minus.circle"
        }
    }
}
