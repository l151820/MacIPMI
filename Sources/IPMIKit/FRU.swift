import Foundation

public struct FRUField: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let label: String
    public let value: String
}

public struct FRUSection: Sendable, Identifiable {
    public let id = UUID()
    public let title: String
    public let fields: [FRUField]
}

public struct FRUInfo: Sendable {
    public let sections: [FRUSection]
    public let size: Int

    static func parse(_ d: [UInt8]) -> FRUInfo {
        guard d.count >= 8, d[0] & 0x0F == 0x01 else { return FRUInfo(sections: [], size: d.count) }
        var sections: [FRUSection] = []

        let chassisOff = Int(d[2]) * 8
        if d[2] != 0, chassisOff + 3 < d.count {
            var i = chassisOff + 2
            var f = [FRUField(label: "Gehäusetyp", value: chassisType(d[i]))]
            i += 1
            f += readFields(d, &i, labels: ["Teilenummer", "Seriennummer"])
            sections.append(FRUSection(title: "Gehäuse", fields: f))
        }

        let boardOff = Int(d[3]) * 8
        if d[3] != 0, boardOff + 6 < d.count {
            var i = boardOff + 3
            var f: [FRUField] = []
            let minutes = d.u24(i)
            if minutes != 0 {
                let date = Date(timeIntervalSince1970: 820_454_400 + TimeInterval(minutes) * 60)
                f.append(FRUField(label: "Herstellungsdatum", value: date.formatted(date: .numeric, time: .shortened)))
            }
            i += 3
            f += readFields(d, &i, labels: ["Hersteller", "Produktname", "Seriennummer", "Teilenummer", "FRU-Datei-ID"])
            sections.append(FRUSection(title: "Mainboard", fields: f))
        }

        let productOff = Int(d[4]) * 8
        if d[4] != 0, productOff + 3 < d.count {
            var i = productOff + 3
            let f = readFields(d, &i, labels: ["Hersteller", "Produktname", "Modell/Teilenummer", "Version",
                                               "Seriennummer", "Asset-Tag", "FRU-Datei-ID"])
            sections.append(FRUSection(title: "Produkt", fields: f))
        }
        return FRUInfo(sections: sections, size: d.count)
    }

    static func readFields(_ d: [UInt8], _ i: inout Int, labels: [String]) -> [FRUField] {
        var out: [FRUField] = []
        var n = 0
        while i < d.count, d[i] != 0xC1, n < 32 {
            guard let v = readField(d, &i) else { break }
            let label = n < labels.count ? labels[n] : "Zusatzfeld \(n - labels.count + 1)"
            if !v.isEmpty { out.append(FRUField(label: label, value: v)) }
            n += 1
        }
        return out
    }

    static func readField(_ d: [UInt8], _ i: inout Int) -> String? {
        guard i < d.count else { return nil }
        let tl = d[i]
        let len = Int(tl & 0x3F)
        i += 1
        guard i + len <= d.count else { return nil }
        let raw = Array(d[i..<(i + len)])
        i += len
        switch tl >> 6 {
        case 0:
            return raw.hexString
        case 1:
            let map: [Character] = Array("0123456789 -.???")
            var s = ""
            for b in raw { s.append(map[Int(b >> 4)]); s.append(map[Int(b & 0x0F)]) }
            return s.trimmingCharacters(in: .whitespaces)
        case 2:
            var s = ""
            var acc: UInt32 = 0
            var bits = 0
            for b in raw {
                acc |= UInt32(b) << bits
                bits += 8
                while bits >= 6 {
                    s.append(Character(UnicodeScalar(UInt8(acc & 0x3F) + 0x20)))
                    acc >>= 6
                    bits -= 6
                }
            }
            return s.trimmingCharacters(in: .whitespaces)
        default:
            let s = String(bytes: raw.prefix { $0 != 0 }, encoding: .isoLatin1) ?? ""
            return s.trimmingCharacters(in: .whitespaces)
        }
    }

    static func chassisType(_ t: UInt8) -> String {
        let names = ["", "Sonstige", "Unbekannt", "Desktop", "Low-Profile-Desktop", "Pizza Box", "Mini Tower", "Tower",
                     "Portable", "Laptop", "Notebook", "Handheld", "Docking Station", "All in One", "Sub Notebook",
                     "Space-saving", "Lunch Box", "Main Server Chassis", "Expansion Chassis", "SubChassis",
                     "Bus Expansion Chassis", "Peripheral Chassis", "RAID Chassis", "Rack Mount Chassis",
                     "Sealed-case PC", "Multi-system Chassis", "Compact PCI", "Advanced TCA", "Blade", "Blade Enclosure"]
        return Int(t) < names.count && t != 0 ? names[Int(t)] : "Typ \(t)"
    }
}

extension IPMISession {
    public func fru(deviceID fruID: UInt8 = 0) async throws -> FRUInfo {
        let info = try await send(netFn: NetFn.storage, cmd: 0x10, data: [fruID])
        guard info.count >= 3 else { throw IPMIError.malformed("FRU Inventory Area Info") }
        let total = min(Int(info.u16(0)), 4096)
        var data: [UInt8] = []
        while data.count < total {
            let n = min(16, total - data.count)
            let off = data.count
            let r = try await send(netFn: NetFn.storage, cmd: 0x11,
                                   data: [fruID, UInt8(off & 0xFF), UInt8(off >> 8), UInt8(n)])
            guard let c = r.first, c > 0, r.count >= 1 + Int(c) else { break }
            data += r[1...Int(c)]
        }
        return FRUInfo.parse(data)
    }
}
