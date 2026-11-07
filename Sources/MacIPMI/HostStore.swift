import Foundation
import IPMIKit
import Observation
import Security

struct HostEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    var port: UInt16 = 623
    var username: String
    var privilege: UInt8 = IPMIPrivilege.administrator.rawValue
}

@MainActor @Observable
final class HostStore {
    var hosts: [HostEntry] = []
    var selection: HostEntry.ID?
    var showAddSheet = false

    @ObservationIgnored private var connections: [UUID: HostConnection] = [:]
    @ObservationIgnored private let defaultsKey = "hosts.v1"

    init() { load() }

    func connection(for host: HostEntry) -> HostConnection {
        if let c = connections[host.id], c.host == host { return c }
        connections[host.id]?.disconnect()
        let c = HostConnection(host: host)
        connections[host.id] = c
        return c
    }

    func add(_ h: HostEntry, password: String) {
        hosts.append(h)
        Keychain.set(password, account: h.id.uuidString)
        save()
        selection = h.id
    }

    func update(_ h: HostEntry, password: String?) {
        guard let idx = hosts.firstIndex(where: { $0.id == h.id }) else { return }
        hosts[idx] = h
        if let password { Keychain.set(password, account: h.id.uuidString) }
        connections[h.id]?.disconnect()
        connections[h.id] = nil
        save()
    }

    func delete(_ id: UUID) {
        connections[id]?.disconnect()
        connections[id] = nil
        Keychain.delete(account: id.uuidString)
        hosts.removeAll { $0.id == id }
        if selection == id { selection = nil }
        save()
    }

    func password(for h: HostEntry) -> String? {
        Keychain.get(account: h.id.uuidString)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([HostEntry].self, from: data) else { return }
        hosts = list
        selection = list.first?.id
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

enum Keychain {
    static let service = "tech.rabe.MacIPMI"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func set(_ value: String, account: String) {
        SecItemDelete(base(account) as CFDictionary)
        var q = base(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}
