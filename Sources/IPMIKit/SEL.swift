import Foundation

public struct SELInfo: Sendable {
    public let version: String
    public let entries: Int
    public let freeBytes: Int
    public let lastAddition: Date?
    public let lastErase: Date?
    public let overflow: Bool
}

public struct SELEntry: Sendable, Identifiable {
    public let id: UInt16
    public let recordType: UInt8
    public let timestamp: Date?
    public let generatorID: UInt16
    public let sensorType: UInt8
    public let sensorNumber: UInt8
    public let isDeassertion: Bool
    public let eventType: UInt8
    public let eventData: [UInt8]
    public let raw: [UInt8]

    init(record r: [UInt8]) {
        raw = r
        id = r.u16(0)
        recordType = r[2]
        if recordType < 0xE0 {
            timestamp = ipmiDate(r.u32(3))
        } else {
            timestamp = nil
        }
        generatorID = r.u16(7)
        sensorType = r[10]
        sensorNumber = r[11]
        isDeassertion = r[12] & 0x80 != 0
        eventType = r[12] & 0x7F
        eventData = Array(r[13..<16])
    }

    public var isSystemEvent: Bool { recordType == 0x02 }

    public var sensorTypeName: String {
        isSystemEvent ? EventText.sensorTypeName(sensorType) : "OEM"
    }

    public var eventDescription: String {
        guard isSystemEvent else {
            return "OEM-Eintrag Typ 0x\(String(format: "%02X", recordType)): \(Array(raw[3...]).hexString)"
        }
        var s = EventText.describe(sensorType: sensorType, eventType: eventType, offset: eventData[0] & 0x0F)
        if eventType == 0x01, eventData[0] >> 6 == 0x01 {
            s += " (Rohwert 0x\(String(format: "%02X", eventData[1])))"
        }
        return s
    }

    public var directionText: String { isDeassertion ? "Aufgehoben" : "Ausgelöst" }
}

func ipmiDate(_ t: UInt32) -> Date? {
    // Values up to 0x20000000 are relative to BMC init, 0xFFFFFFFF means unspecified.
    if t == 0xFFFF_FFFF || t <= 0x2000_0000 { return nil }
    return Date(timeIntervalSince1970: TimeInterval(t))
}

extension IPMISession {
    public func selInfo() async throws -> SELInfo {
        let d = try await send(netFn: NetFn.storage, cmd: 0x40)
        guard d.count >= 14 else { throw IPMIError.malformed("Get SEL Info") }
        return SELInfo(
            version: "\(d[0] & 0x0F).\(d[0] >> 4)",
            entries: Int(d.u16(1)),
            freeBytes: Int(d.u16(3)),
            lastAddition: ipmiDate(d.u32(5)),
            lastErase: ipmiDate(d.u32(9)),
            overflow: d[13] & 0x80 != 0)
    }

    func reserveSEL() async throws -> UInt16 {
        let r = try await request(netFn: NetFn.storage, cmd: 0x42)
        if r.completionCode == 0xC1 { return 0 }
        guard r.completionCode == 0, r.data.count >= 2 else { throw IPMIError.completionCode(r.completionCode) }
        return r.data.u16(0)
    }

    public func selEntries(limit: Int = 4096) async throws -> [SELEntry] {
        let reservation = try await reserveSEL()
        var id: UInt16 = 0
        var out: [SELEntry] = []
        while out.count < limit {
            let r = try await request(netFn: NetFn.storage, cmd: 0x43, data: reservation.le + id.le + [0x00, 0xFF])
            if r.completionCode == 0xCB { break }     // empty / no such entry
            guard r.completionCode == 0 else { throw IPMIError.completionCode(r.completionCode) }
            guard r.data.count >= 18 else { throw IPMIError.malformed("SEL-Eintrag zu kurz") }
            let next = r.data.u16(0)
            out.append(SELEntry(record: Array(r.data[2..<18])))
            if next == 0xFFFF || next == id { break }
            id = next
        }
        return out
    }

    public func clearSEL() async throws {
        let reservation = try await reserveSEL()
        try await send(netFn: NetFn.storage, cmd: 0x47, data: reservation.le + [0x43, 0x4C, 0x52, 0xAA])
    }

    public func selTime() async throws -> Date? {
        let d = try await send(netFn: NetFn.storage, cmd: 0x48)
        guard d.count >= 4 else { return nil }
        return ipmiDate(d.u32(0))
    }
}
