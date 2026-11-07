import Foundation

public enum SupermicroFanMode: UInt8, Sendable, CaseIterable, Identifiable {
    case standard = 0, full = 1, optimal = 2, heavyIO = 4

    public var id: UInt8 { rawValue }
    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .full: return "Volle Drehzahl"
        case .optimal: return "Optimal"
        case .heavyIO: return "Heavy IO"
        }
    }
}

extension IPMISession {
    /// Supermicro OEM: current fan mode (netFn 0x30, cmd 0x45).
    public func supermicroFanMode() async throws -> SupermicroFanMode? {
        let d = try await send(netFn: NetFn.supermicro, cmd: 0x45, data: [0x00])
        return d.first.flatMap(SupermicroFanMode.init(rawValue:))
    }

    public func setSupermicroFanMode(_ mode: SupermicroFanMode) async throws {
        try await send(netFn: NetFn.supermicro, cmd: 0x45, data: [0x01, mode.rawValue])
    }
}

/// Access to the Supermicro (ATEN) BMC web interface (used to mint iKVM console tokens).
public enum SupermicroWeb {
    static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Short, tag-free excerpt of an HTML response for error messages.
    static func excerpt(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "(leere Antwort)" }
        return s.count > 160 ? String(s.prefix(160)) + "…" : s
    }
}
