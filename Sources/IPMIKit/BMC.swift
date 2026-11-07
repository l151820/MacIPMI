import Foundation

public struct DeviceID: Sendable {
    public let deviceID: UInt8
    public let deviceRevision: UInt8
    public let providesSDR: Bool
    public let firmwareVersion: String
    public let ipmiVersion: String
    public let manufacturerID: UInt32
    public let productID: UInt16
    public let auxFirmware: [UInt8]
    public let capabilities: [String]

    init(data d: [UInt8]) throws {
        guard d.count >= 11 else { throw IPMIError.malformed("Get Device ID zu kurz") }
        deviceID = d[0]
        deviceRevision = d[1] & 0x0F
        providesSDR = d[1] & 0x80 != 0
        firmwareVersion = "\(d[2] & 0x7F).\(String(format: "%02X", d[3]))"
        ipmiVersion = "\(d[4] & 0x0F).\(d[4] >> 4)"
        let names = ["Sensoren", "SDR-Repository", "SEL", "FRU-Inventar", "IPMB-Event-Receiver",
                     "IPMB-Event-Generator", "Bridge", "Chassis"]
        capabilities = names.enumerated().filter { d[5] & (1 << $0.offset) != 0 }.map(\.element)
        manufacturerID = d.u24(6) & 0x0F_FFFF
        productID = d.u16(9)
        auxFirmware = d.bytes(11, 4)
    }

    public var manufacturerName: String {
        switch manufacturerID {
        case 10876: return "Supermicro"
        case 343: return "Intel"
        case 674: return "Dell"
        case 11: return "HPE"
        case 2: return "IBM"
        case 19046: return "Lenovo"
        case 20974: return "AMI"
        case 21317: return "ATEN"
        default: return "IANA \(manufacturerID)"
        }
    }
}

public struct LANConfig: Sendable {
    public let channel: UInt8
    public var ipSource: String? = nil
    public var ipAddress: String? = nil
    public var subnetMask: String? = nil
    public var gateway: String? = nil
    public var gatewayMAC: String? = nil
    public var macAddress: String? = nil
    public var vlan: String? = nil
}

public struct IPMIUser: Sendable, Identifiable {
    public let id: UInt8
    public let name: String
    public let enabled: Bool?
    public let privilege: UInt8
    public let ipmiMessaging: Bool
    public let linkAuth: Bool
    public let fixedName: Bool

    public static func privilegeName(_ p: UInt8) -> String {
        switch p {
        case 0x01: return "Callback"
        case 0x02: return "Benutzer"
        case 0x03: return "Operator"
        case 0x04: return "Administrator"
        case 0x05: return "OEM"
        case 0x0F: return "Kein Zugriff"
        default: return "0x\(String(format: "%02X", p))"
        }
    }

    public var privilegeName: String { Self.privilegeName(privilege) }
}

extension IPMISession {
    public func deviceID() async throws -> DeviceID {
        try DeviceID(data: await send(netFn: NetFn.app, cmd: 0x01))
    }

    public func deviceGUID() async throws -> String {
        let d = try await send(netFn: NetFn.app, cmd: 0x37)
        guard d.count >= 16 else { throw IPMIError.malformed("GUID") }
        let g = Array(d.prefix(16).reversed())
        let h = g.map { String(format: "%02x", $0) }
        return "\(h[0..<4].joined())-\(h[4..<6].joined())-\(h[6..<8].joined())-\(h[8..<10].joined())-\(h[10..<16].joined())"
    }

    // MARK: LAN

    public func lanParameter(channel: UInt8, parameter: UInt8) async throws -> [UInt8] {
        let d = try await send(netFn: NetFn.transport, cmd: 0x02, data: [channel & 0x0F, parameter, 0, 0])
        return Array(d.dropFirst())
    }

    public func lanConfig(channel: UInt8 = 1) async throws -> LANConfig {
        func ip(_ b: [UInt8]?) -> String? {
            guard let b, b.count >= 4 else { return nil }
            return b.prefix(4).map { String($0) }.joined(separator: ".")
        }
        func mac(_ b: [UInt8]?) -> String? {
            guard let b, b.count >= 6 else { return nil }
            return b.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
        }
        var c = LANConfig(channel: channel)
        c.ipAddress = ip(try await lanParameter(channel: channel, parameter: 3))
        if let s = try? await lanParameter(channel: channel, parameter: 4), let b = s.first {
            switch b & 0x0F {
            case 1: c.ipSource = "Statisch"
            case 2: c.ipSource = "DHCP"
            case 3: c.ipSource = "BIOS"
            case 4: c.ipSource = "Sonstige"
            default: c.ipSource = "Nicht angegeben"
            }
        }
        c.macAddress = mac(try? await lanParameter(channel: channel, parameter: 5))
        c.subnetMask = ip(try? await lanParameter(channel: channel, parameter: 6))
        c.gateway = ip(try? await lanParameter(channel: channel, parameter: 12))
        c.gatewayMAC = mac(try? await lanParameter(channel: channel, parameter: 13))
        if let v = try? await lanParameter(channel: channel, parameter: 20), v.count >= 2 {
            let raw = v.u16(0)
            c.vlan = raw & 0x8000 != 0 ? "\(raw & 0x0FFF)" : "Deaktiviert"
        }
        return c
    }

    // MARK: Users

    public func users(channel: UInt8 = 1) async throws -> [IPMIUser] {
        let first = try await send(netFn: NetFn.app, cmd: 0x44, data: [channel & 0x0F, 1])
        guard first.count >= 4 else { throw IPMIError.malformed("Get User Access") }
        let maxUsers = Int(first[0] & 0x3F)
        let fixedCount = Int(first[2] & 0x3F)
        var out: [IPMIUser] = []
        for uid in 1...max(1, maxUsers) {
            let a = uid == 1 ? first : try await send(netFn: NetFn.app, cmd: 0x44, data: [channel & 0x0F, UInt8(uid)])
            guard a.count >= 4 else { continue }
            let nameBytes = (try? await send(netFn: NetFn.app, cmd: 0x46, data: [UInt8(uid)])) ?? []
            let enabledBits = (a[1] >> 6) & 0x03
            out.append(IPMIUser(
                id: UInt8(uid),
                name: ipmiString(nameBytes),
                enabled: enabledBits == 1 ? true : (enabledBits == 2 ? false : nil),
                privilege: a[3] & 0x0F,
                ipmiMessaging: a[3] & 0x10 != 0,
                linkAuth: a[3] & 0x20 != 0,
                fixedName: uid <= fixedCount
            ))
        }
        return out
    }

    public func setUserName(_ id: UInt8, name: String) async throws {
        try await send(netFn: NetFn.app, cmd: 0x45, data: [id & 0x3F] + fixedBytes(name, 16))
    }

    public func setUserPassword(_ id: UInt8, password: String) async throws {
        let long = password.utf8.count > 16
        try await send(netFn: NetFn.app, cmd: 0x47,
                       data: [(id & 0x3F) | (long ? 0x80 : 0), 0x02] + fixedBytes(password, long ? 20 : 16))
    }

    public func setUserEnabled(_ id: UInt8, enabled: Bool) async throws {
        try await send(netFn: NetFn.app, cmd: 0x47, data: [id & 0x3F, enabled ? 0x01 : 0x00])
    }

    public func setUserAccess(_ id: UInt8, channel: UInt8 = 1, privilege: UInt8,
                              ipmiMessaging: Bool = true, linkAuth: Bool = false) async throws {
        var b: UInt8 = 0x80 | (channel & 0x0F)
        if ipmiMessaging { b |= 0x10 }
        if linkAuth { b |= 0x20 }
        try await send(netFn: NetFn.app, cmd: 0x43, data: [b, id & 0x3F, privilege & 0x0F])
    }
}
