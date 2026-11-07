import Foundation

public enum SensorHealth: Int, Sendable, Comparable {
    case ok, warning, critical, nonRecoverable, unavailable

    public static func < (a: SensorHealth, b: SensorHealth) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .ok: return "Normal"
        case .warning: return "Warnung"
        case .critical: return "Kritisch"
        case .nonRecoverable: return "Nicht behebbar"
        case .unavailable: return "N/A"
        }
    }
}

public struct SensorConversion: Sendable {
    public let m: Int
    public let b: Int
    public let bExp: Int
    public let rExp: Int
    public let format: UInt8          // 0 unsigned, 1 one's complement, 2 two's complement, 3 none
    public let linearization: UInt8

    public func value(raw: UInt8) -> Double? {
        let x: Int
        switch format {
        case 0: x = Int(raw)
        case 1: x = raw & 0x80 != 0 ? -Int(~raw) : Int(raw)
        case 2: x = Int(Int8(bitPattern: raw))
        default: return nil
        }
        let y = (Double(m * x) + Double(b) * pow(10, Double(bExp))) * pow(10, Double(rExp))
        switch linearization & 0x7F {
        case 0: return y
        case 1: return log(y)
        case 2: return log10(y)
        case 3: return log2(y)
        case 4: return exp(y)
        case 5: return pow(10, y)
        case 6: return pow(2, y)
        case 7: return y == 0 ? nil : 1 / y
        case 8: return y * y
        case 9: return y * y * y
        case 10: return sqrt(y)
        case 11: return cbrt(y)
        default: return y
        }
    }
}

public struct SensorThresholds: Sendable {
    public var lnr: Double?
    public var lc: Double?
    public var lnc: Double?
    public var unc: Double?
    public var uc: Double?
    public var unr: Double?
}

public struct SDRRecord: Sendable, Identifiable {
    public let id: UInt16
    public let recordType: UInt8
    public let ownerID: UInt8
    public let lun: UInt8
    public let sensorNumber: UInt8
    public let entityID: UInt8
    public let entityInstance: UInt8
    public let sensorType: UInt8
    public let eventReadingType: UInt8
    public let name: String
    public let unit: String
    public let conversion: SensorConversion?
    public let thresholds: SensorThresholds

    public var isThreshold: Bool { recordType == 0x01 && eventReadingType == 0x01 && conversion != nil }

    init?(bytes b: [UInt8]) {
        guard b.count >= 5 else { return nil }
        id = b.u16(0)
        recordType = b[3]
        switch recordType {
        case 0x01:
            guard b.count >= 48 else { return nil }
            let units1 = b[20]
            let m = Self.sign(Int(b[24]) | (Int(b[25] & 0xC0) << 2), bits: 10)
            let bb = Self.sign(Int(b[26]) | (Int(b[27] & 0xC0) << 2), bits: 10)
            let conv = SensorConversion(
                m: m, b: bb,
                bExp: Self.sign(Int(b[29] & 0x0F), bits: 4),
                rExp: Self.sign(Int(b[29] >> 4), bits: 4),
                format: units1 >> 6,
                linearization: b[23])
            conversion = units1 >> 6 == 3 ? nil : conv
            unit = SensorUnits.describe(units1: units1, base: b[21], modifier: b[22])
            var t = SensorThresholds()
            if b[13] == 0x01, let c = conversion {
                let readable = b[18]
                if readable & 0x20 != 0 { t.unr = c.value(raw: b[36]) }
                if readable & 0x10 != 0 { t.uc = c.value(raw: b[37]) }
                if readable & 0x08 != 0 { t.unc = c.value(raw: b[38]) }
                if readable & 0x04 != 0 { t.lnr = c.value(raw: b[39]) }
                if readable & 0x02 != 0 { t.lc = c.value(raw: b[40]) }
                if readable & 0x01 != 0 { t.lnc = c.value(raw: b[41]) }
            }
            thresholds = t
            name = Self.idString(b, at: 47)
        case 0x02:
            guard b.count >= 32 else { return nil }
            conversion = nil
            unit = ""
            thresholds = SensorThresholds()
            name = Self.idString(b, at: 31)
        default:
            return nil
        }
        ownerID = b[5]
        lun = b[6] & 0x03
        sensorNumber = b[7]
        entityID = b[8]
        entityInstance = b[9]
        sensorType = b[12]
        eventReadingType = b[13]
    }

    static func sign(_ v: Int, bits: Int) -> Int {
        let top = 1 << (bits - 1)
        return v & top != 0 ? v - (1 << bits) : v
    }

    static func idString(_ b: [UInt8], at i: Int) -> String {
        guard i < b.count else { return "" }
        let len = Int(b[i] & 0x1F)
        return ipmiString(b.bytes(i + 1, len))
    }
}

public struct SensorReading: Sendable, Identifiable {
    public let record: SDRRecord
    public let value: Double?
    public let health: SensorHealth
    public let states: [String]
    public let rawState: UInt16

    public var id: UInt16 { record.id }

    static func unavailable(_ r: SDRRecord) -> SensorReading {
        SensorReading(record: r, value: nil, health: .unavailable, states: [], rawState: 0)
    }

    public var formattedValue: String {
        if health == .unavailable { return "N/A" }
        if record.isThreshold {
            guard let v = value else { return "N/A" }
            return Self.format(v, unit: record.unit)
        }
        return states.isEmpty ? String(format: "0x%04X", rawState) : states.joined(separator: ", ")
    }

    public static func format(_ v: Double, unit: String) -> String {
        let s: String
        if unit == "RPM" || unit.hasPrefix("°") || (v.rounded() == v && abs(v) >= 10) {
            s = String(format: "%.0f", v)
        } else if abs(v) >= 100 {
            s = String(format: "%.1f", v)
        } else {
            s = String(format: "%.3f", v)
        }
        return unit.isEmpty ? s : "\(s) \(unit)"
    }

    public var thresholdText: String {
        guard record.isThreshold else { return "" }
        let t = record.thresholds
        func f(_ v: Double?) -> String { v.map { Self.format($0, unit: "") } ?? "–" }
        return "\(f(t.lnr)) / \(f(t.lc)) / \(f(t.lnc))  ·  \(f(t.unc)) / \(f(t.uc)) / \(f(t.unr))"
    }
}

public enum SensorUnits {
    static let base: [String] = [
        "", "°C", "°F", "K", "V", "A", "W", "J", "C", "VA", "nit", "lm", "lx", "cd", "kPa", "PSI", "N", "CFM",
        "RPM", "Hz", "µs", "ms", "s", "min", "h", "d", "Woche", "mil", "in", "ft", "in³", "ft³", "mm", "cm", "m",
        "cm³", "m³", "l", "fl oz", "rad", "sr", "U", "Zyklen", "g", "oz", "lb", "ft-lb", "oz-in", "Gauss",
        "Gilbert", "H", "mH", "F", "µF", "Ω", "S", "mol", "Bq", "ppm", "", "dB", "dBA", "dBC", "Gy", "Sv",
        "K (Farbtemp.)", "bit", "kbit", "Mbit", "Gbit", "Byte", "KB", "MB", "GB", "Wort", "DWort", "QWort",
        "Zeile", "Treffer", "Fehltreffer", "Wiederholungen", "Resets", "Überläufe", "Unterläufe", "Kollisionen",
        "Pakete", "Nachrichten", "Zeichen", "Fehler", "korr. Fehler", "unkorr. Fehler", "fatale Fehler", "g",
    ]

    static func name(_ code: UInt8) -> String {
        Int(code) < base.count ? base[Int(code)] : ""
    }

    static func describe(units1: UInt8, base b: UInt8, modifier: UInt8) -> String {
        if units1 & 0x01 != 0 { return "%" }
        var s = name(b)
        switch (units1 >> 1) & 0x03 {
        case 1: s += "/" + name(modifier)
        case 2: s += "·" + name(modifier)
        default: break
        }
        return s
    }
}

extension IPMISession {
    func reserveSDR() async throws -> UInt16 {
        let r = try await request(netFn: NetFn.storage, cmd: 0x22)
        if r.completionCode == 0xC1 { return 0 }
        guard r.completionCode == 0, r.data.count >= 2 else { throw IPMIError.completionCode(r.completionCode) }
        return r.data.u16(0)
    }

    private func getSDR(_ reservation: inout UInt16, id: UInt16, offset: UInt8, count: UInt8) async throws -> (UInt16, [UInt8]) {
        for _ in 0..<3 {
            let r = try await request(netFn: NetFn.storage, cmd: 0x23, data: reservation.le + id.le + [offset, count])
            if r.completionCode == 0xC5 {
                reservation = try await reserveSDR()
                continue
            }
            guard r.completionCode == 0 else { throw IPMIError.completionCode(r.completionCode) }
            guard r.data.count >= 2 else { throw IPMIError.malformed("Get SDR") }
            return (r.data.u16(0), Array(r.data[2...]))
        }
        throw IPMIError.completionCode(0xC5)
    }

    /// Reads all sensor records (full + compact) from the BMC's SDR repository.
    public func sdrRecords() async throws -> [SDRRecord] {
        var reservation = try await reserveSDR()
        var id: UInt16 = 0
        var out: [SDRRecord] = []
        var guardCount = 0
        while id != 0xFFFF && guardCount < 1024 {
            guardCount += 1
            let (next, header) = try await getSDR(&reservation, id: id, offset: 0, count: 5)
            guard header.count >= 5 else { throw IPMIError.malformed("SDR-Kopf") }
            let length = Int(header[4])
            var body: [UInt8] = []
            while body.count < length {
                let n = min(16, length - body.count)
                let (_, chunk) = try await getSDR(&reservation, id: id, offset: UInt8(5 + body.count), count: UInt8(n))
                guard !chunk.isEmpty else { throw IPMIError.malformed("Leerer SDR-Block") }
                body += chunk
            }
            if let rec = SDRRecord(bytes: Array(header.prefix(5)) + body) { out.append(rec) }
            if next == id { break }
            id = next
        }
        return out
    }

    public func readSensor(_ rec: SDRRecord) async throws -> SensorReading {
        guard rec.ownerID == 0x20 else { return .unavailable(rec) }
        let r = try await request(netFn: NetFn.sensorEvent, cmd: 0x2D, data: [rec.sensorNumber], lun: rec.lun)
        guard r.completionCode == 0, r.data.count >= 2 else { return .unavailable(rec) }
        let d = r.data
        if d[1] & 0x20 != 0 || d[1] & 0x40 == 0 { return .unavailable(rec) }
        let st1: UInt8 = d.count > 2 ? d[2] : 0
        let st2: UInt8 = d.count > 3 ? d[3] : 0

        if rec.isThreshold {
            var h = SensorHealth.ok
            if st1 & 0x24 != 0 { h = .nonRecoverable }
            else if st1 & 0x12 != 0 { h = .critical }
            else if st1 & 0x09 != 0 { h = .warning }
            return SensorReading(record: rec, value: rec.conversion?.value(raw: d[0]), health: h,
                                 states: [], rawState: UInt16(st1 & 0x3F))
        }

        let bits = UInt16(st1) | (UInt16(st2 & 0x7F) << 8)
        var states: [String] = []
        var h = SensorHealth.ok
        for i in 0..<15 where bits & (1 << i) != 0 {
            states.append(EventText.describe(sensorType: rec.sensorType, eventType: rec.eventReadingType, offset: UInt8(i)))
            h = max(h, EventText.severity(sensorType: rec.sensorType, eventType: rec.eventReadingType, offset: UInt8(i)))
        }
        return SensorReading(record: rec, value: nil, health: h, states: states, rawState: bits)
    }

    /// Reads all given sensors. Per-sensor errors become N/A; a lost BMC aborts with `.timeout`.
    public func readSensors(_ records: [SDRRecord]) async throws -> [SensorReading] {
        var out: [SensorReading] = []
        for r in records {
            do {
                out.append(try await readSensor(r))
            } catch IPMIError.timeout {
                throw IPMIError.timeout
            } catch {
                out.append(.unavailable(r))
            }
        }
        return out
    }
}
