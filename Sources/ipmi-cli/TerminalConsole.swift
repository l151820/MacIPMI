import CoreGraphics
import Darwin
import Foundation
import IPMIKit
import ImageIO

nonisolated(unsafe) private var windowResized = true
nonisolated(unsafe) private var savedTermios = termios()
nonisolated(unsafe) private var terminalIsRaw = false

/// Restores the terminal (also used from the exit/signal paths).
private func restoreTerminal() {
    guard terminalIsRaw else { return }
    terminalIsRaw = false
    let reset = "\u{1B}[?1006l\u{1B}[?1003l\u{1B}[?1002l\u{1B}[?1000l\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l"
    _ = reset.withCString { Darwin.write(STDOUT_FILENO, $0, strlen($0)) }
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios)
}

/// Turns the terminal into the server's KVM console.
/// iTerm2 (and compatible terminals) get a real image via the inline image protocol;
/// other terminals get a coloured half-block rendering.
final class TerminalConsole: @unchecked Sendable {
    enum Mode: String { case image, blocks }

    private let params: KVMConsoleParams
    private let mode: Mode
    private let parser: TerminalInputParser
    private let hostLabel: String

    private let lock = NSLock()
    private var latest: CGImage?
    private var dirty = false
    private var status = "Verbinde …"
    private var quit = false
    private var exitMessage: String?
    private var menuOpen = false
    private var session: ATENKVMSession?
    private var buttons: UInt8 = 0

    // geometry of the last drawn frame (for mouse mapping)
    private var cols = 80, rows = 24, cellW = 8.0, cellH = 16.0
    private var drawnRect = CGRect.zero        // image area in terminal pixels
    private var imageSize = CGSize.zero

    init(params: KVMConsoleParams, mode: Mode, layout: KeyboardLayout, hostLabel: String) {
        self.params = params
        self.mode = mode
        self.parser = TerminalInputParser(layout: layout)
        self.hostLabel = hostLabel
    }

    static func detectMode() -> Mode {
        let env = ProcessInfo.processInfo.environment
        let iterm = env["TERM_PROGRAM"] == "iTerm.app" || env["LC_TERMINAL"] == "iTerm2"
            || env["TERM_PROGRAM"] == "WezTerm"
        return iterm ? .image : .blocks
    }

    /// Runs the console until the user quits. Returns a message to print afterwards.
    func run() -> String? {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            return "Die Terminal-Konsole braucht ein interaktives Terminal."
        }
        enterRawMode()
        defer { restoreTerminal() }

        signal(SIGWINCH) { _ in windowResized = true }
        signal(SIGTERM) { _ in restoreTerminal(); exit(1) }
        signal(SIGHUP) { _ in restoreTerminal(); exit(1) }

        let s = ATENKVMSession(params: params) { [weak self] event in self?.handle(event) }
        lock.withLock { session = s }
        s.start()

        let input = Thread { [weak self] in self?.inputLoop() }
        input.start()

        var lastDraw = Date.distantPast
        while !lock.withLock({ quit }) {
            let resized = windowResized
            let (needsFrame, img) = lock.withLock { (dirty, latest) }
            if resized || (needsFrame && Date().timeIntervalSince(lastDraw) >= 0.1) {
                windowResized = false
                lock.withLock { dirty = false }
                updateGeometry()
                if resized { out("\u{1B}[2J") }
                if let img { draw(img) }
                drawStatus()
                lastDraw = Date()
            }
            usleep(20_000)
        }
        s.stop()
        return lock.withLock { exitMessage }
    }

    // MARK: - Session events

    private func handle(_ e: ATENKVMSession.Event) {
        lock.lock()
        defer { lock.unlock() }
        switch e {
        case .connecting: status = "Verbinde …"
        case .connected(let w, let h, _): status = "Verbunden (\(w)×\(h))"
        case .frame(let img):
            latest = img
            dirty = true
            if !status.hasPrefix("Live") || imageSize != CGSize(width: img.width, height: img.height) {
                status = "Live \(img.width)×\(img.height)"
            }
        case .noSignal:
            status = "Kein Videosignal – Server aus?"
            dirty = true
        case .disconnected(let reason):
            exitMessage = reason.map { "Konsole getrennt: \($0)" } ?? "Konsole beendet."
            quit = true
        }
    }

    // MARK: - Terminal

    private func enterRawMode() {
        tcgetattr(STDIN_FILENO, &savedTermios)
        var raw = savedTermios
        raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
        raw.c_cflag |= tcflag_t(CS8)
        withUnsafeMutablePointer(to: &raw.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        terminalIsRaw = true
        atexit { restoreTerminal() }
        // alternate screen, hide cursor, mouse: buttons + motion while pressed + any motion, SGR encoding
        out("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h")
    }

    private func out(_ s: String) {
        var data = Array(s.utf8)
        writeAll(&data)
    }

    private func writeAll(_ data: inout [UInt8]) {
        var off = 0
        while off < data.count {
            let n = data[off...].withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if n <= 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
            off += n
        }
    }

    private func updateGeometry() {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 1 {
            cols = Int(ws.ws_col)
            rows = Int(ws.ws_row)
            cellW = ws.ws_xpixel > 0 ? Double(ws.ws_xpixel) / Double(cols) : 8
            cellH = ws.ws_ypixel > 0 ? Double(ws.ws_ypixel) / Double(rows) : 16
        }
    }

    private func draw(_ img: CGImage) {
        let boxCols = cols, boxRows = rows - 1
        let iw = Double(img.width), ih = Double(img.height)
        lock.withLock { imageSize = CGSize(width: iw, height: ih) }

        switch mode {
        case .image:
            // Fit into the box keeping the aspect ratio; compute the size in cells ourselves so
            // mouse coordinates can be mapped exactly.
            let boxW = Double(boxCols) * cellW, boxH = Double(boxRows) * cellH
            let scale = min(boxW / iw, boxH / ih)
            let wCells = max(1, Int((iw * scale / cellW).rounded(.down)))
            let hCells = max(1, Int((ih * scale / cellH).rounded(.down)))
            lock.withLock {
                drawnRect = CGRect(x: 0, y: 0, width: Double(wCells) * cellW, height: Double(hCells) * cellH)
            }
            guard let jpeg = Self.jpeg(img) else { return }
            var seq = Array("\u{1B}[H\u{1B}]1337;File=inline=1;size=\(jpeg.count);width=\(wCells);height=\(hCells);preserveAspectRatio=0:".utf8)
            seq += Array(jpeg.base64EncodedString().utf8)
            seq.append(0x07)
            writeAll(&seq)

        case .blocks:
            // Two image rows per terminal row using the upper half block.
            // One cell = 1 sample wide and 2 samples high; keep the image's aspect on screen.
            var w = boxCols
            var h = Int(2 * Double(w) * cellW * ih / (iw * cellH))
            if h > boxRows * 2 {
                h = boxRows * 2
                w = max(1, Int(Double(h) * iw * cellH / (2 * cellW * ih)))
            }
            h = max(2, h & ~1)
            lock.withLock {
                drawnRect = CGRect(x: 0, y: 0, width: Double(w) * cellW, height: Double(h / 2) * cellH)
            }
            guard let px = Self.scaledPixels(img, width: w, height: h) else { return }
            var s = "\u{1B}[H"
            s.reserveCapacity(w * h * 20)
            for y in stride(from: 0, to: h, by: 2) {
                for x in 0..<w {
                    let t = px[y * w + x], b = y + 1 < h ? px[(y + 1) * w + x] : t
                    s += "\u{1B}[38;2;\(t.0);\(t.1);\(t.2);48;2;\(b.0);\(b.1);\(b.2)m▀"
                }
                s += "\u{1B}[0m\u{1B}[K\r\n"
            }
            out(s)
        }
    }

    private func drawStatus() {
        let st = lock.withLock { menuOpen ? "Menü: q Beenden · d Strg+Alt+Entf · 1–6 Strg+Alt+F1–F6 · ] Strg+] senden · Esc zurück"
                                          : "\(hostLabel) · \(status) · Strg+] Menü" }
        let text = String(st.prefix(max(0, cols - 1)))
        out("\u{1B}[\(rows);1H\u{1B}[0m\u{1B}[7m\u{1B}[2K \(text)\u{1B}[0m")
    }

    static func jpeg(_ img: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func scaledPixels(_ img: CGImage, width: Int, height: Int) -> [(UInt8, UInt8, UInt8)]? {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        return (0..<(width * height)).map { (buf[$0 * 4], buf[$0 * 4 + 1], buf[$0 * 4 + 2]) }
    }

    // MARK: - Input

    private func inputLoop() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while !lock.withLock({ quit }) {
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n <= 0 { if errno == EINTR { continue }; break }
            let chunk = Array(buf[0..<n])
            if lock.withLock({ menuOpen }) {
                menuKey(chunk)
                continue
            }
            for e in parser.parse(chunk) { dispatch(e) }
        }
    }

    private func dispatch(_ e: TerminalInputParser.Event) {
        guard let s = lock.withLock({ session }) else { return }
        switch e {
        case .keys(let chords):
            for c in chords { s.sendKeyCombination(c) }
        case .escapeHatch:
            lock.withLock { menuOpen = true }
            drawStatus()
        case .mouse(let col, let row, let button, let pressed, let motion):
            if !motion {
                let bit: UInt8 = button == 0 ? 1 : button == 1 ? 2 : button == 2 ? 4 : 0
                if pressed { buttons |= bit } else if button == 3 { buttons = 0 } else { buttons &= ~bit }
            }
            if let (x, y) = mapMouse(col: col, row: row) { s.sendPointer(x: x, y: y, buttons: buttons) }
        case .wheel:
            break   // the ATEN pointer message has no wheel field
        }
    }

    private func mapMouse(col: Int, row: Int) -> (Int, Int)? {
        lock.withLock {
            guard imageSize.width > 0, drawnRect.width > 0 else { return nil }
            let px = (Double(col) - 0.5) * cellW, py = (Double(row) - 0.5) * cellH
            guard drawnRect.contains(CGPoint(x: px, y: py)) else { return nil }
            let x = Int(px / drawnRect.width * imageSize.width)
            let y = Int(py / drawnRect.height * imageSize.height)
            return (min(x, Int(imageSize.width) - 1), min(y, Int(imageSize.height) - 1))
        }
    }

    private func menuKey(_ chunk: [UInt8]) {
        guard let b = chunk.first, let s = lock.withLock({ session }) else { return }
        lock.withLock { menuOpen = false }
        switch b {
        case UInt8(ascii: "q"), UInt8(ascii: "."):
            lock.withLock { exitMessage = "Konsole beendet."; quit = true }
        case UInt8(ascii: "d"):
            s.sendKeyCombination([HIDKeyMap.leftControl, HIDKeyMap.leftAlt, HIDKeyMap.delete])
        case UInt8(ascii: "1")...UInt8(ascii: "6"):
            s.sendKeyCombination([HIDKeyMap.leftControl, HIDKeyMap.leftAlt, HIDKeyMap.f(Int(b - UInt8(ascii: "0")))])
        case UInt8(ascii: "]"), 0x1D:
            s.sendKeyCombination([HIDKeyMap.leftControl, 0x30])
        default:
            break
        }
        drawStatus()
    }
}
