import CoreGraphics
import Darwin
import Foundation

/// Native client for the ATEN iKVM console of Supermicro X9 BMCs (Nuvoton WPCM450 "Hermon").
///
/// Protocol: RFB 3.8 on TCP 5900 with security type 16 (the web-minted token is sent as
/// user name and password, 24 bytes each), a ServerInit with a 12-byte ATEN trailer and
/// FramebufferUpdates carrying raw little-endian RGB555 pixels – either as a full frame or
/// as changed 16×16 tiles. Keyboard events carry USB HID usage codes.
public final class ATENKVMSession: @unchecked Sendable {
    public enum Event: Sendable {
        case connecting
        case connected(width: Int, height: Int, name: String)
        case frame(CGImage)
        case noSignal
        case disconnected(String?)
    }

    public let params: KVMConsoleParams
    private let handler: @Sendable (Event) -> Void
    private let log: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var running = false

    // Only touched on the network thread.
    private var fbWidth = 0
    private var fbHeight = 0
    private var pixels: [UInt32] = []
    private var lastPublish = Date.distantPast
    private var dirty = false
    private var gotFrame = false

    static let maxDimension = 4096
    static let messageNames: [UInt8: String] = [0x00: "FramebufferUpdate", 0x04: "Cursor", 0x16: "Keepalive",
                                                0x33: "VideoInfo", 0x37: "MouseInfo", 0x39: "Benutzerliste",
                                                0x3C: "ViewerLang"]

    public init(params: KVMConsoleParams, log: (@Sendable (String) -> Void)? = nil,
                handler: @escaping @Sendable (Event) -> Void) {
        self.params = params
        self.log = log
        self.handler = handler
    }

    deinit { closeSocket() }

    public var isRunning: Bool { lock.withLock { running } }

    public func start() {
        lock.withLock { running = true }
        let t = Thread { [self] in run() }
        t.name = "ATEN-KVM"
        t.qualityOfService = .userInteractive
        t.start()
    }

    public func stop() {
        lock.withLock { running = false }
        let s = lock.withLock { fd }
        if s >= 0 { shutdown(s, SHUT_RDWR) }
    }

    // MARK: - Input

    /// Key press/release with a USB HID usage code (see `HIDKeyMap`).
    public func sendKey(usage: UInt32, down: Bool) {
        var m = [UInt8](repeating: 0, count: 18)
        m[0] = 0x04
        m[2] = down ? 1 : 0
        m[5] = UInt8((usage >> 24) & 0xFF)
        m[6] = UInt8((usage >> 16) & 0xFF)
        m[7] = UInt8((usage >> 8) & 0xFF)
        m[8] = UInt8(usage & 0xFF)
        write(m)
    }

    /// Absolute pointer event in framebuffer pixels. Buttons: bit0 left, bit1 middle, bit2 right.
    public func sendPointer(x: Int, y: Int, buttons: UInt8) {
        let px = UInt16(clamping: max(0, x)), py = UInt16(clamping: max(0, y))
        var m = [UInt8](repeating: 0, count: 18)
        m[0] = 0x05
        m[2] = buttons
        m[3] = UInt8(px >> 8); m[4] = UInt8(px & 0xFF)
        m[5] = UInt8(py >> 8); m[6] = UInt8(py & 0xFF)
        write(m)
    }

    public func sendKeyCombination(_ usages: [UInt32]) {
        for u in usages { sendKey(usage: u, down: true) }
        for u in usages.reversed() { sendKey(usage: u, down: false) }
    }

    private func requestUpdate(incremental: Bool) {
        let w = UInt16(clamping: max(fbWidth, 1)), h = UInt16(clamping: max(fbHeight, 1))
        write([0x03, incremental ? 1 : 0, 0, 0, 0, 0, UInt8(w >> 8), UInt8(w & 0xFF), UInt8(h >> 8), UInt8(h & 0xFF)])
    }

    private func write(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 {
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                return
            }
            off += n
        }
    }

    // MARK: - Session

    private func run() {
        handler(.connecting)
        var reason: String?
        do {
            try connectSocket()
            try handshake()
            try messageLoop()
        } catch {
            reason = isRunning ? error.localizedDescription : nil
            log?("Sitzung beendet: \(error.localizedDescription)")
        }
        closeSocket()
        lock.withLock { running = false }
        handler(.disconnected(reason))
    }

    private func closeSocket() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    private func connectSocket() throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(params.host, String(params.videoPort), &hints, &res)
        guard rc == 0, let ai = res else {
            throw IPMIError.network("\(params.host) nicht auflösbar: \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(res) }
        let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard s >= 0 else { throw IPMIError.network("socket(): \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking connect with a 6 s timeout.
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        if Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen) != 0 && errno != EINPROGRESS {
            let m = String(cString: strerror(errno)); Darwin.close(s)
            throw IPMIError.network("Verbindung zu Port \(params.videoPort) fehlgeschlagen: \(m)")
        }
        var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 6000) == 1 else {
            Darwin.close(s)
            throw IPMIError.network("Zeitüberschreitung beim Verbinden mit Port \(params.videoPort)")
        }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
        guard err == 0 else {
            Darwin.close(s)
            throw IPMIError.network("Verbindung zu Port \(params.videoPort) fehlgeschlagen: \(String(cString: strerror(err)))")
        }
        _ = fcntl(s, F_SETFL, flags)
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        lock.withLock { fd = s }
        log?("TCP verbunden mit \(params.host):\(params.videoPort)")
    }

    /// Reads exactly `n` bytes. Returns nil only if `idleOK` and nothing arrived within one poll interval.
    private func read(_ n: Int, idleOK: Bool = false, timeout: TimeInterval = 15) throws -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        let deadline = Date().addingTimeInterval(timeout)
        let s = lock.withLock { fd }
        while got < n {
            let r = buf.withUnsafeMutableBytes { recv(s, $0.baseAddress! + got, n - got, 0) }
            if r > 0 { got += r; continue }
            if r == 0 {
                throw IPMIError.network(isRunning ? "Verbindung vom BMC geschlossen" : "Beendet")
            }
            if errno == EAGAIN || errno == EINTR {
                if !isRunning { throw IPMIError.network("Beendet") }
                if idleOK && got == 0 { return nil }
                if Date() > deadline { throw IPMIError.timeout }
                continue
            }
            throw IPMIError.network("recv(): \(String(cString: strerror(errno)))")
        }
        return buf
    }

    private func readBytes(_ n: Int) throws -> [UInt8] { try read(n)! }
    private func readU8() throws -> UInt8 { try readBytes(1)[0] }
    private func readU16() throws -> Int { let b = try readBytes(2); return Int(b[0]) << 8 | Int(b[1]) }
    private func readU32() throws -> UInt32 {
        let b = try readBytes(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    private func handshake() throws {
        let version = try readBytes(12)
        log?("Server: \(String(decoding: version, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        write(Array("RFB 003.008\n".utf8))

        let count = Int(try readU8())
        if count == 0 {
            let len = Int(try readU32())
            let reason = String(decoding: try readBytes(min(len, 1024)), as: UTF8.self)
            throw IPMIError.sessionSetup("BMC lehnt die Verbindung ab: \(reason)")
        }
        let types = try readBytes(count)
        log?("Sicherheitstypen: \(types)")
        guard types.contains(16) else { throw IPMIError.unsupported("Kein ATEN-Sicherheitstyp (16) angeboten: \(types)") }
        write([16])

        _ = try readBytes(24)                          // server info block, not a challenge
        var field = Array(params.token.utf8.prefix(24))
        field += [UInt8](repeating: 0, count: 24 - field.count)
        write(field + field)
        let result = try readBytes(4)
        guard result == [0, 0, 0, 0] else {
            throw IPMIError.sessionSetup("Konsolen-Token abgelehnt (\(result.hexString)) – Token abgelaufen?")
        }
        log?("Authentifiziert")

        write([0])                                     // ClientInit, not shared
        let si = try readBytes(24)
        fbWidth = Int(si[0]) << 8 | Int(si[1])
        fbHeight = Int(si[2]) << 8 | Int(si[3])
        let nameLen = Int(UInt32(si[20]) << 24 | UInt32(si[21]) << 16 | UInt32(si[22]) << 8 | UInt32(si[23]))
        let name = String(decoding: try readBytes(min(nameLen, 256)), as: UTF8.self)
        _ = try readBytes(12)                          // ATEN trailer
        log?("ServerInit: \(fbWidth)×\(fbHeight) „\(name)“")
        if fbWidth > 0, fbHeight > 0, fbWidth <= Self.maxDimension, fbHeight <= Self.maxDimension {
            pixels = [UInt32](repeating: 0xFF00_0000, count: fbWidth * fbHeight)
        }
        handler(.connected(width: fbWidth, height: fbHeight, name: name))
    }

    private func messageLoop() throws {
        requestUpdate(incremental: false)
        var lastRequest = Date()
        let started = Date()
        var reportedNoSignal = false

        while isRunning {
            guard let type = try read(1, idleOK: true)?.first else {
                if !gotFrame && !reportedNoSignal && Date().timeIntervalSince(started) > 5 {
                    reportedNoSignal = true
                    handler(.noSignal)
                }
                if Date().timeIntervalSince(lastRequest) > 0.25 {
                    requestUpdate(incremental: gotFrame)
                    lastRequest = Date()
                }
                flushFrame(force: true)
                continue
            }
            switch type {
            case 0x00:
                try readFramebufferUpdate()
                flushFrame(force: false)
                let wait = 0.033 - Date().timeIntervalSince(lastRequest)
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                requestUpdate(incremental: true)
                lastRequest = Date()
            case 0x04: _ = try readBytes(24)
            case 0x16: _ = try readBytes(1)
            case 0x33: _ = try readBytes(4)
            case 0x37: _ = try readBytes(2)
            case 0x39:
                let n = Int(try readU32())
                guard n < 64 else { throw IPMIError.malformed("Benutzerliste mit \(n) Einträgen") }
                _ = try readBytes(n * 260)
            case 0x3C: _ = try readBytes(8)
            default:
                throw IPMIError.malformed("Unbekannter Nachrichtentyp 0x\(String(format: "%02X", type))")
            }
            if type != 0x00 { log?("← \(Self.messageNames[type] ?? "?")") }
        }
    }

    private func readFramebufferUpdate() throws {
        _ = try readU8()
        let rects = try readU16()
        for _ in 0..<rects {
            let x = try readU16(), y = try readU16(), w = try readU16(), h = try readU16()
            let encoding = try readU32()
            _ = try readU32()                          // mode
            let len = Int(try readU32())
            guard len <= 16_000_000 else { throw IPMIError.malformed("Rechteck mit \(len) Bytes") }
            let data = try readBytes(len)
            guard w > 0, h > 0, w <= Self.maxDimension, h <= Self.maxDimension else { continue }
            if x == 0, y == 0, (w != fbWidth || h != fbHeight), data.first == 1 {
                fbWidth = w
                fbHeight = h
                pixels = [UInt32](repeating: 0xFF00_0000, count: w * h)
                log?("Auflösung \(w)×\(h)")
            }
            guard !pixels.isEmpty else { continue }
            if !gotFrame { log?("Erstes Bild: \(w)×\(h), Encoding \(encoding), \(len) Bytes") }
            HermonDecoder.decode(data, into: &pixels, width: fbWidth, height: fbHeight, x: x, y: y, w: w, h: h)
            gotFrame = true
            dirty = true
        }
    }

    private func flushFrame(force: Bool) {
        guard dirty, force || Date().timeIntervalSince(lastPublish) > 1.0 / 30 else { return }
        if let img = HermonDecoder.image(pixels, width: fbWidth, height: fbHeight) {
            handler(.frame(img))
        }
        dirty = false
        lastPublish = Date()
    }
}

/// Decoder for the Nuvoton WPCM450 ("Hermon") video payload.
public enum HermonDecoder {
    /// RGB555 (little endian on the wire) → 0xAARRGGBB.
    @inline(__always) static func argb(_ lo: UInt8, _ hi: UInt8) -> UInt32 {
        let p = UInt32(lo) | UInt32(hi) << 8
        let r5 = (p >> 10) & 0x1F, g5 = (p >> 5) & 0x1F, b5 = p & 0x1F
        let r = (r5 << 3) | (r5 >> 2), g = (g5 << 3) | (g5 >> 2), b = (b5 << 3) | (b5 >> 2)
        return 0xFF00_0000 | r << 16 | g << 8 | b
    }

    /// Payload: [mode(1) pixfmt(1) count(4, BE) len(4, BE)] then pixels.
    /// mode 1 = full frame (w*h RGB555), mode 0 = `count` tiles of [4 unknown, row, col, 16×16 RGB555].
    public static func decode(_ data: [UInt8], into fb: inout [UInt32], width: Int, height: Int,
                              x rx: Int, y ry: Int, w rw: Int, h rh: Int) {
        guard data.count >= 10, data[1] == 0 else { return }
        data.withUnsafeBufferPointer { d in
            fb.withUnsafeMutableBufferPointer { out in
                if d[0] == 1 {
                    guard d.count >= 10 + rw * rh * 2 else { return }
                    for row in 0..<rh {
                        let dy = ry + row
                        if dy >= height { break }
                        var i = 10 + row * rw * 2
                        let base = dy * width
                        for col in 0..<rw {
                            let dx = rx + col
                            if dx < width { out[base + dx] = argb(d[i], d[i + 1]) }
                            i += 2
                        }
                    }
                    return
                }
                let count = Int(d[2]) << 24 | Int(d[3]) << 16 | Int(d[4]) << 8 | Int(d[5])
                let stride = 6 + 512
                for t in 0..<count {
                    let off = 10 + t * stride
                    if off + stride > d.count { break }
                    let row = Int(d[off + 4]), col = Int(d[off + 5])
                    for ty in 0..<16 {
                        let dy = ry + row * 16 + ty
                        if dy >= height { break }
                        var i = off + 6 + ty * 32
                        let base = dy * width
                        for tx in 0..<16 {
                            let dx = rx + col * 16 + tx
                            if dx < width { out[base + dx] = argb(d[i], d[i + 1]) }
                            i += 2
                        }
                    }
                }
            }
        }
    }

    public static func image(_ pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
