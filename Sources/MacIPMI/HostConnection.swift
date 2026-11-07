import AppKit
import Foundation
import IPMIKit
import Observation

@MainActor @Observable
final class HostConnection {
    enum State: Equatable {
        case disconnected, connecting, connected
        case failed(String)
    }

    let host: HostEntry
    var state: State = .disconnected
    var message: String?
    var busy: Set<String> = []

    var deviceID: DeviceID?
    var guid: String?
    var chassis: ChassisStatus?
    var fanMode: SupermicroFanMode?
    var sdr: [SDRRecord] = []
    var sensors: [SensorReading] = []
    var sensorsUpdated: Date?
    var selInfo: SELInfo?
    var sel: [SELEntry] = []
    var fru: FRUInfo?
    var lan: LANConfig?
    var users: [IPMIUser] = []

    @ObservationIgnored private var session: IPMISession?
    @ObservationIgnored private var password = ""
    @ObservationIgnored private var kvm: KVMConsoleModel?

    /// The native KVM console model for this host (created on first use).
    func kvmModel(store: HostStore) -> KVMConsoleModel {
        if let kvm { return kvm }
        let h = host
        let m = KVMConsoleModel(host: h) { [weak self, weak store] in
            if let p = self?.password, !p.isEmpty { return p }
            return store?.password(for: h) ?? ""
        }
        kvm = m
        return m
    }

    init(host: HostEntry) { self.host = host }

    var isConnected: Bool { state == .connected }

    func connect(password: String) async {
        state = .connecting
        self.password = password
        let creds = IPMICredentials(host: host.address, port: host.port, username: host.username, password: password,
                                    privilege: IPMIPrivilege(rawValue: host.privilege) ?? .administrator)
        let s = IPMISession(credentials: creds)
        do {
            try await s.connect()
            session = s
            state = .connected
            await refreshOverview()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        let s = session
        session = nil
        state = .disconnected
        deviceID = nil; guid = nil; chassis = nil; fanMode = nil
        sdr = []; sensors = []; sel = []; selInfo = nil; fru = nil; lan = nil; users = []
        Task { await s?.close() }
    }

    /// Runs an operation; errors are shown as alert unless `quiet`.
    @discardableResult
    private func run<T>(_ key: String, quiet: Bool = false, _ op: (IPMISession) async throws -> T) async -> T? {
        guard let s = session else { return nil }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            return try await op(s)
        } catch {
            if !quiet { message = error.localizedDescription }
            return nil
        }
    }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    // MARK: Overview

    func refreshOverview() async {
        if deviceID == nil {
            deviceID = await run("overview") { try await $0.deviceID() }
            guid = await run("overview", quiet: true) { try await $0.deviceGUID() }
        }
        chassis = await run("overview") { try await $0.chassisStatus() }
        fanMode = await run("overview", quiet: true) { try await $0.supermicroFanMode() } ?? nil
    }

    func power(_ action: ChassisControl) async {
        await run("power") { try await $0.chassisControl(action) }
        try? await Task.sleep(for: .seconds(2))
        chassis = await run("power") { try await $0.chassisStatus() } ?? chassis
    }

    func identify(seconds: UInt8) async {
        await run("identify") { try await $0.identify(seconds: seconds) }
    }

    func setRestorePolicy(_ p: PowerRestorePolicy) async {
        await run("chassis") { try await $0.setPowerRestorePolicy(p) }
        chassis = await run("chassis") { try await $0.chassisStatus() } ?? chassis
    }

    func setBootDevice(_ d: BootDevice, persistent: Bool, efi: Bool) async -> Bool {
        await run("boot") { try await $0.setBootDevice(d, persistent: persistent, efi: efi) } != nil
    }

    func setFanMode(_ m: SupermicroFanMode) async {
        await run("fan") { try await $0.setSupermicroFanMode(m) }
        fanMode = await run("fan", quiet: true) { try await $0.supermicroFanMode() } ?? fanMode
    }

    func bmcColdReset() async {
        await run("bmc") { try await $0.bmcColdReset() }
        message = "Das BMC wird neu gestartet. Die Verbindung ist in ca. 1–2 Minuten wieder möglich."
        disconnect()
    }

    // MARK: Sensors

    func refreshSensors() async {
        if sdr.isEmpty {
            sdr = await run("sensors") { try await $0.sdrRecords() } ?? []
            if sdr.isEmpty { return }
        }
        let records = sdr
        if let r = await run("sensors", { try await $0.readSensors(records) }) {
            sensors = r
            sensorsUpdated = Date()
        }
    }

    func sensorName(_ number: UInt8) -> String? {
        sdr.first { $0.sensorNumber == number }?.name
    }

    // MARK: SEL

    func loadSEL() async {
        if sdr.isEmpty { sdr = await run("sel", quiet: true) { try await $0.sdrRecords() } ?? [] }
        selInfo = await run("sel") { try await $0.selInfo() }
        if let list = await run("sel", { try await $0.selEntries() }) {
            sel = list.reversed()
        }
    }

    func clearSEL() async {
        await run("sel") { try await $0.clearSEL() }
        await loadSEL()
    }

    // MARK: Inventory

    func loadFRU() async {
        fru = await run("fru") { try await $0.fru() }
    }

    func loadLAN() async {
        lan = await run("lan") { try await $0.lanConfig() }
    }

    func loadUsers() async {
        users = await run("users") { try await $0.users() } ?? users
    }

    func saveUser(_ original: IPMIUser, name: String, password newPassword: String,
                  enabled: Bool, privilege: UInt8) async {
        await run("users") { s in
            if name != original.name && !original.fixedName {
                try await s.setUserName(original.id, name: name)
            }
            if !newPassword.isEmpty {
                try await s.setUserPassword(original.id, password: newPassword)
            }
            if privilege != original.privilege {
                try await s.setUserAccess(original.id, privilege: privilege,
                                          ipmiMessaging: privilege != 0x0F, linkAuth: original.linkAuth)
            }
            if enabled != (original.enabled ?? false) {
                try await s.setUserEnabled(original.id, enabled: enabled)
            }
        }
        await loadUsers()
    }

    // MARK: Console

    func openWebInterface() {
        if let url = URL(string: "http://\(host.address)") { NSWorkspace.shared.open(url) }
    }
}
