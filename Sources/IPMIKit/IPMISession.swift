import Foundation

public enum IPMIPrivilege: UInt8, Sendable, CaseIterable, Codable, Identifiable {
    case callback = 1, user = 2, `operator` = 3, administrator = 4, oem = 5

    public var id: UInt8 { rawValue }

    public var displayName: String {
        switch self {
        case .callback: return "Callback"
        case .user: return "Benutzer"
        case .operator: return "Operator"
        case .administrator: return "Administrator"
        case .oem: return "OEM"
        }
    }
}

public struct IPMICredentials: Sendable {
    public var host: String
    public var port: UInt16
    public var username: String
    public var password: String
    public var privilege: IPMIPrivilege

    public init(host: String, port: UInt16 = 623, username: String, password: String,
                privilege: IPMIPrivilege = .administrator) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.privilege = privilege
    }
}

public struct IPMIResponse: Sendable {
    public let completionCode: UInt8
    public let data: [UInt8]
}

public enum NetFn {
    public static let chassis: UInt8 = 0x00
    public static let sensorEvent: UInt8 = 0x04
    public static let app: UInt8 = 0x06
    public static let storage: UInt8 = 0x0A
    public static let transport: UInt8 = 0x0C
    public static let supermicro: UInt8 = 0x30
}

public struct ChannelAuthCapabilities: Sendable {
    public let channel: UInt8
    public let authTypes: [String]
    public let supportsIPMI15: Bool
    public let supportsIPMI20: Bool
    public let anonymousLogin: Bool
    public let nullUsernames: Bool
    public let nonNullUsernames: Bool
    public let kgSet: Bool

    init(data d: [UInt8]) throws {
        guard d.count >= 4 else { throw IPMIError.malformed("Channel Auth Capabilities zu kurz") }
        channel = d[0]
        let at = d[1]
        var types: [String] = []
        if at & 0x01 != 0 { types.append("none") }
        if at & 0x02 != 0 { types.append("MD2") }
        if at & 0x04 != 0 { types.append("MD5") }
        if at & 0x10 != 0 { types.append("password") }
        if at & 0x20 != 0 { types.append("OEM") }
        authTypes = types
        let extended = at & 0x80 != 0
        supportsIPMI20 = extended && d[3] & 0x02 != 0
        supportsIPMI15 = !extended || d[3] & 0x01 != 0
        kgSet = d[2] & 0x20 != 0
        nonNullUsernames = d[2] & 0x04 != 0
        nullUsernames = d[2] & 0x02 != 0
        anonymousLogin = d[2] & 0x01 != 0
    }
}

struct SessionKeys: Sendable {
    let k1: [UInt8]
    let aes: [UInt8]
}

struct RMCPPlusPacket {
    let payloadType: UInt8
    let sessionID: UInt32
    let sequence: UInt32
    let payload: [UInt8]
}

/// An IPMI 2.0 (RMCP+) LAN session using cipher suite 3
/// (RAKP-HMAC-SHA1 / HMAC-SHA1-96 / AES-CBC-128), as supported by Supermicro X9 BMCs.
public actor IPMISession {
    public nonisolated let credentials: IPMICredentials
    public private(set) var timeout: TimeInterval = 1.0
    public private(set) var retries = 2

    private var transport: UDPTransport?
    private var consoleSID: UInt32 = 0
    private var bmcSID: UInt32 = 0
    private var outSeq: UInt32 = 0
    private var rqSeq: UInt8 = 0
    private var keys: SessionKeys?
    private var connectTask: Task<Void, Error>?
    private var logger: (@Sendable (String) -> Void)?

    static let rmcpHeader: [UInt8] = [0x06, 0x00, 0xFF, 0x07]

    public init(credentials: IPMICredentials) {
        self.credentials = credentials
    }

    public var isActive: Bool { keys != nil }

    public func setLogger(_ l: (@Sendable (String) -> Void)?) { logger = l }

    public func setTimeout(_ t: TimeInterval, retries r: Int) {
        timeout = t
        retries = r
    }

    private func log(_ s: @autoclosure () -> String) {
        logger?(s())
    }

    // MARK: - Connection

    public func connect() async throws {
        if keys != nil { return }
        if let t = connectTask { return try await t.value }
        let t = Task { try await self.establish() }
        connectTask = t
        defer { connectTask = nil }
        try await t.value
    }

    public func close() async {
        if keys != nil {
            _ = try? await rawRequest(netFn: NetFn.app, cmd: 0x3C, data: bmcSID.le, lun: 0)
        }
        keys = nil
        transport = nil
    }

    private func ensureTransport() throws -> UDPTransport {
        if let t = transport { return t }
        let t = try UDPTransport(host: credentials.host, port: credentials.port)
        transport = t
        return t
    }

    private func establish() async throws {
        keys = nil
        outSeq = 0
        rqSeq = 0
        transport = nil
        do {
            let caps = try await channelAuthCapabilities()
            guard caps.supportsIPMI20 else {
                throw IPMIError.unsupported("Das BMC meldet keine IPMI-2.0-Unterstützung (RMCP+).")
            }
            try await openSessionAndAuthenticate()
            let r = try await rawRequest(netFn: NetFn.app, cmd: 0x3B, data: [credentials.privilege.rawValue], lun: 0)
            guard r.completionCode == 0 else {
                throw IPMIError.sessionSetup("Berechtigungsstufe \(credentials.privilege.displayName) abgelehnt (\(IPMIError.describe(r.completionCode)))")
            }
            log("Sitzung aktiv, BMC-Session-ID 0x\(String(format: "%08X", bmcSID))")
        } catch {
            keys = nil
            transport = nil
            throw error
        }
    }

    // MARK: - Pre-session (IPMI 1.5 framing, no auth)

    /// Get Channel Authentication Capabilities. Works without credentials.
    public func channelAuthCapabilities() async throws -> ChannelAuthCapabilities {
        let t = try ensureTransport()
        let priv = credentials.privilege.rawValue
        let to = timeout, rt = retries

        func ask(_ channelByte: UInt8) async throws -> IPMIResponse {
            let msg = Self.ipmiMessage(netFn: NetFn.app, lun: 0, cmd: 0x38, seq: 0, data: [channelByte, priv])
            let pkt = Self.rmcpHeader + [0x00, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(msg.count)] + msg
            log(">> \(pkt.hexString)")
            let reply = try await t.exchange(pkt, timeout: to, retries: rt) { raw in
                raw.count >= 14 && raw[0] == 0x06 && raw[3] == 0x07 && raw[4] == 0x00
            }
            log("<< \(reply.hexString)")
            let len = Int(reply[13])
            guard reply.count >= 14 + len else { throw IPMIError.malformed("IPMI-1.5-Paket zu kurz") }
            return try Self.parseIPMIResponse(Array(reply[14..<(14 + len)]))
        }

        var r = try await ask(0x8E)            // request IPMI 2.0 extended data, current channel
        if r.completionCode != 0 { r = try await ask(0x0E) }
        guard r.completionCode == 0 else { throw IPMIError.completionCode(r.completionCode) }
        return try ChannelAuthCapabilities(data: r.data)
    }

    // MARK: - RMCP+ session establishment

    private func presession(type: UInt8, payload: [UInt8], expect: UInt8, tag: UInt8) async throws -> [UInt8] {
        let t = try ensureTransport()
        let pkt = Self.rmcpHeader + [0x06, type] + UInt32(0).le + UInt32(0).le + UInt16(payload.count).le + payload
        log(">> \(pkt.hexString)")
        let reply = try await t.exchange(pkt, timeout: timeout, retries: retries) { raw in
            guard let p = try? Self.parseRMCPPlus(raw, keys: nil) else { return false }
            return p.payloadType == expect && p.payload.first == tag
        }
        log("<< \(reply.hexString)")
        guard let p = try Self.parseRMCPPlus(reply, keys: nil) else {
            throw IPMIError.malformed("RMCP+-Antwort")
        }
        return p.payload
    }

    private func openSessionAndAuthenticate() async throws {
        consoleSID = UInt32.random(in: 0x0000_1000...0xFFFF_FFF0)
        let priv = credentials.privilege
        let username = Array(credentials.username.utf8.prefix(16))
        var kuid = Array(credentials.password.utf8.prefix(20))
        kuid += [UInt8](repeating: 0, count: 20 - kuid.count)

        // Open Session Request – cipher suite 3
        let tag1 = UInt8.random(in: 0...255)
        var open: [UInt8] = [tag1, priv == .administrator ? 0 : priv.rawValue, 0, 0] + consoleSID.le
        open += [0x00, 0, 0, 0x08, 0x01, 0, 0, 0]   // auth: RAKP-HMAC-SHA1
        open += [0x01, 0, 0, 0x08, 0x01, 0, 0, 0]   // integrity: HMAC-SHA1-96
        open += [0x02, 0, 0, 0x08, 0x01, 0, 0, 0]   // confidentiality: AES-CBC-128
        let osr = try await presession(type: 0x10, payload: open, expect: 0x11, tag: tag1)
        guard osr.count >= 2 else { throw IPMIError.malformed("Open Session Response") }
        guard osr[1] == 0 else { throw IPMIError.sessionSetup(IPMIError.rakpStatus(osr[1])) }
        guard osr.count >= 36, osr.u32(4) == consoleSID else {
            throw IPMIError.malformed("Open Session Response unvollständig")
        }
        bmcSID = osr.u32(8)
        guard osr[16] == 0x01, osr[24] == 0x01, osr[32] == 0x01 else {
            throw IPMIError.sessionSetup("BMC akzeptiert Cipher Suite 3 nicht")
        }

        // RAKP 1 / 2
        let tag2 = UInt8.random(in: 0...255)
        let rm = IPMICrypto.randomBytes(16)
        let role: UInt8 = priv.rawValue | 0x10       // name-only lookup
        let rakp1: [UInt8] = [tag2, 0, 0, 0] + bmcSID.le + rm + [role, 0, 0, UInt8(username.count)] + username
        let r2 = try await presession(type: 0x12, payload: rakp1, expect: 0x13, tag: tag2)
        guard r2.count >= 2 else { throw IPMIError.malformed("RAKP 2") }
        guard r2[1] == 0 else {
            if r2[1] == 0x0D || r2[1] == 0x0F { throw IPMIError.authenticationFailed }
            throw IPMIError.sessionSetup(IPMIError.rakpStatus(r2[1]))
        }
        guard r2.count >= 60, r2.u32(4) == consoleSID else { throw IPMIError.malformed("RAKP 2 unvollständig") }
        let rc = Array(r2[8..<24])
        let guid = Array(r2[24..<40])
        let authCode = Array(r2[40..<60])
        let userInfo: [UInt8] = [role, UInt8(username.count)] + username

        let expected = IPMICrypto.hmacSHA1(key: kuid, data: consoleSID.le + bmcSID.le + rm + rc + guid + userInfo)
        guard expected == authCode else { throw IPMIError.authenticationFailed }

        let sik = IPMICrypto.hmacSHA1(key: kuid, data: rm + rc + userInfo)
        let k1 = IPMICrypto.hmacSHA1(key: sik, data: [UInt8](repeating: 0x01, count: 20))
        let k2 = IPMICrypto.hmacSHA1(key: sik, data: [UInt8](repeating: 0x02, count: 20))

        // RAKP 3 / 4
        let tag3 = UInt8.random(in: 0...255)
        let auth3 = IPMICrypto.hmacSHA1(key: kuid, data: rc + consoleSID.le + userInfo)
        let rakp3: [UInt8] = [tag3, 0, 0, 0] + bmcSID.le + auth3
        let r4 = try await presession(type: 0x14, payload: rakp3, expect: 0x15, tag: tag3)
        guard r4.count >= 2 else { throw IPMIError.malformed("RAKP 4") }
        guard r4[1] == 0 else {
            if r4[1] == 0x0F { throw IPMIError.authenticationFailed }
            throw IPMIError.sessionSetup(IPMIError.rakpStatus(r4[1]))
        }
        guard r4.count >= 20, r4.u32(4) == consoleSID else { throw IPMIError.malformed("RAKP 4 unvollständig") }
        let icv = Array(IPMICrypto.hmacSHA1(key: sik, data: rm + bmcSID.le + guid).prefix(12))
        guard Array(r4[8..<20]) == icv else {
            throw IPMIError.sessionSetup("Integritätsprüfung von RAKP 4 fehlgeschlagen")
        }

        keys = SessionKeys(k1: k1, aes: Array(k2.prefix(16)))
    }

    // MARK: - Requests

    /// Sends an IPMI request; reconnects once if the session timed out.
    public func request(netFn: UInt8, cmd: UInt8, data: [UInt8] = [], lun: UInt8 = 0) async throws -> IPMIResponse {
        try await connect()
        do {
            return try await rawRequest(netFn: netFn, cmd: cmd, data: data, lun: lun)
        } catch IPMIError.timeout {
            log("Zeitüberschreitung – baue Sitzung neu auf")
            keys = nil
            transport = nil
            try await connect()
            return try await rawRequest(netFn: netFn, cmd: cmd, data: data, lun: lun)
        }
    }

    /// Like `request`, but throws on a non-zero completion code and returns only the data.
    @discardableResult
    public func send(netFn: UInt8, cmd: UInt8, data: [UInt8] = [], lun: UInt8 = 0) async throws -> [UInt8] {
        let r = try await request(netFn: netFn, cmd: cmd, data: data, lun: lun)
        guard r.completionCode == 0 else { throw IPMIError.completionCode(r.completionCode) }
        return r.data
    }

    func rawRequest(netFn: UInt8, cmd: UInt8, data: [UInt8], lun: UInt8) async throws -> IPMIResponse {
        guard let t = transport, let k = keys else { throw IPMIError.network("Keine aktive Sitzung") }
        rqSeq = (rqSeq + 1) & 0x3F
        let seq = rqSeq
        outSeq &+= 1
        if outSeq == 0 { outSeq = 1 }
        let msg = Self.ipmiMessage(netFn: netFn, lun: lun, cmd: cmd, seq: seq, data: data)
        log(">> netFn 0x\(String(format: "%02X", netFn)) cmd 0x\(String(format: "%02X", cmd)) [\(data.hexString)]")
        let pkt = try Self.buildSecure(payload: msg, sessionID: bmcSID, sequence: outSeq, keys: k)
        let csid = consoleSID
        let reply = try await t.exchange(pkt, timeout: timeout, retries: retries) { raw in
            guard let p = try? Self.parseRMCPPlus(raw, keys: k),
                  p.payloadType == 0x00, p.sessionID == csid, p.payload.count >= 8 else { return false }
            return (p.payload[4] >> 2) == seq && p.payload[5] == cmd
        }
        guard let p = try Self.parseRMCPPlus(reply, keys: k) else { throw IPMIError.malformed("RMCP+-Antwort") }
        let r = try Self.parseIPMIResponse(p.payload)
        log("<< cc 0x\(String(format: "%02X", r.completionCode)) [\(r.data.hexString)]")
        return r
    }

    /// BMC cold reset. The BMC usually does not answer, the session is dropped afterwards.
    public func bmcColdReset() async throws {
        try await connect()
        do {
            let r = try await rawRequest(netFn: NetFn.app, cmd: 0x02, data: [], lun: 0)
            if r.completionCode != 0 { throw IPMIError.completionCode(r.completionCode) }
        } catch IPMIError.timeout {
            // expected
        }
        keys = nil
        transport = nil
    }

    // MARK: - Packet helpers

    static func ipmiMessage(netFn: UInt8, lun: UInt8, cmd: UInt8, seq: UInt8, data: [UInt8]) -> [UInt8] {
        let head: [UInt8] = [0x20, (netFn << 2) | (lun & 0x03)]
        let body: [UInt8] = [0x81, (seq & 0x3F) << 2, cmd] + data
        return head + [ipmiChecksum(head)] + body + [ipmiChecksum(body)]
    }

    static func parseIPMIResponse(_ m: [UInt8]) throws -> IPMIResponse {
        guard m.count >= 8 else { throw IPMIError.malformed("IPMI-Antwort zu kurz (\(m.count) Bytes)") }
        return IPMIResponse(completionCode: m[6], data: Array(m[7..<(m.count - 1)]))
    }

    static func buildSecure(payloadType: UInt8 = 0, payload: [UInt8], sessionID: UInt32, sequence: UInt32,
                            keys: SessionKeys, iv fixedIV: [UInt8]? = nil) throws -> [UInt8] {
        let iv = fixedIV ?? IPMICrypto.randomBytes(16)
        var plain = payload
        let padLen = (16 - (plain.count + 1) % 16) % 16
        for i in 0..<padLen { plain.append(UInt8(i + 1)) }
        plain.append(UInt8(padLen))
        let encrypted = try IPMICrypto.aesCBC(encrypt: true, key: keys.aes, iv: iv, data: plain)
        let body = iv + encrypted
        var s: [UInt8] = [0x06, payloadType | 0xC0] + sessionID.le + sequence.le + UInt16(body.count).le + body
        let pad = (4 - (s.count + 2) % 4) % 4
        s += [UInt8](repeating: 0xFF, count: pad)
        s += [UInt8(pad), 0x07]
        s += IPMICrypto.hmacSHA1(key: keys.k1, data: s).prefix(12)
        return rmcpHeader + s
    }

    static func parseRMCPPlus(_ p: [UInt8], keys: SessionKeys?) throws -> RMCPPlusPacket? {
        guard p.count >= 16, p[0] == 0x06, p[3] == 0x07, p[4] == 0x06 else { return nil }
        let typeByte = p[5]
        let encrypted = typeByte & 0x80 != 0
        let authenticated = typeByte & 0x40 != 0
        let type = typeByte & 0x3F
        guard type != 0x02 else { return nil }   // OEM explicit payloads are not used
        let sid = p.u32(6)
        let seq = p.u32(10)
        let len = Int(p.u16(14))
        guard p.count >= 16 + len else { throw IPMIError.malformed("Payload-Länge stimmt nicht") }
        var payload = Array(p[16..<(16 + len)])

        if authenticated {
            guard let k = keys else { throw IPMIError.malformed("Authentifiziertes Paket ohne Sitzung") }
            guard p.count >= 16 + len + 2 + 12 else { throw IPMIError.malformed("Auth-Code fehlt") }
            let authStart = p.count - 12
            let mac = Array(IPMICrypto.hmacSHA1(key: k.k1, data: Array(p[4..<authStart])).prefix(12))
            guard mac == Array(p[authStart...]) else { throw IPMIError.malformed("Integritätsprüfung fehlgeschlagen") }
        }
        if encrypted {
            guard let k = keys else { throw IPMIError.malformed("Verschlüsseltes Paket ohne Sitzung") }
            guard payload.count >= 32, payload.count % 16 == 0 else { throw IPMIError.malformed("Verschlüsselte Länge") }
            let dec = try IPMICrypto.aesCBC(encrypt: false, key: k.aes, iv: Array(payload[0..<16]),
                                            data: Array(payload[16...]))
            guard let last = dec.last, Int(last) + 1 <= dec.count else { throw IPMIError.malformed("Padding") }
            payload = Array(dec[0..<(dec.count - 1 - Int(last))])
        }
        return RMCPPlusPacket(payloadType: type, sessionID: sid, sequence: seq, payload: payload)
    }
}
