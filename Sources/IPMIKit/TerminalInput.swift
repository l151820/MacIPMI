import Foundation

/// Keyboard layout of the *remote* system. A terminal delivers characters, not physical keys,
/// so characters are translated into the key positions that produce them on the server.
public enum KeyboardLayout: String, Sendable, CaseIterable {
    case de, us
}

/// Translates terminal input (UTF-8 text, control bytes, escape sequences, SGR mouse reports)
/// into HID key chords and mouse events for the KVM console.
public struct TerminalInputParser: Sendable {
    public enum Event: Equatable, Sendable {
        /// Chords pressed one after another; each chord is modifiers + key, pressed together.
        case keys([[UInt32]])
        /// SGR mouse report (1-based cell coordinates). button: 0 left, 1 middle, 2 right, 3 none.
        case mouse(column: Int, row: Int, button: Int, pressed: Bool, motion: Bool)
        case wheel(up: Bool, column: Int, row: Int)
        /// Ctrl+] – opens the local console menu.
        case escapeHatch
    }

    public var layout: KeyboardLayout

    public init(layout: KeyboardLayout) { self.layout = layout }

    // HID usages
    static let ctrl: UInt32 = 0xE0, shift: UInt32 = 0xE1, alt: UInt32 = 0xE2, altGr: UInt32 = 0xE6
    static let enter: UInt32 = 0x28, esc: UInt32 = 0x29, backspace: UInt32 = 0x2A, tab: UInt32 = 0x2B, space: UInt32 = 0x2C

    static func letter(_ c: Character, layout: KeyboardLayout) -> UInt32? {
        guard let a = c.asciiValue, (97...122).contains(a) else { return nil }
        var u = UInt32(a - 97) + 0x04
        if layout == .de {                       // QWERTZ: Y and Z swapped
            if c == "y" { u = 0x1D } else if c == "z" { u = 0x1C }
        }
        return u
    }

    static let digitUsage: [Character: UInt32] = ["1": 0x1E, "2": 0x1F, "3": 0x20, "4": 0x21, "5": 0x22,
                                                  "6": 0x23, "7": 0x24, "8": 0x25, "9": 0x26, "0": 0x27]

    static let usTable: [Character: [UInt32]] = [
        "!": [shift, 0x1E], "@": [shift, 0x1F], "#": [shift, 0x20], "$": [shift, 0x21], "%": [shift, 0x22],
        "^": [shift, 0x23], "&": [shift, 0x24], "*": [shift, 0x25], "(": [shift, 0x26], ")": [shift, 0x27],
        "-": [0x2D], "_": [shift, 0x2D], "=": [0x2E], "+": [shift, 0x2E], "[": [0x2F], "{": [shift, 0x2F],
        "]": [0x30], "}": [shift, 0x30], "\\": [0x31], "|": [shift, 0x31], ";": [0x33], ":": [shift, 0x33],
        "'": [0x34], "\"": [shift, 0x34], "`": [0x35], "~": [shift, 0x35], ",": [0x36], "<": [shift, 0x36],
        ".": [0x37], ">": [shift, 0x37], "/": [0x38], "?": [shift, 0x38],
    ]

    /// German (ISO) layout. Dead keys (^ ´ `) are followed by a space to produce the character itself.
    static let deTable: [Character: [[UInt32]]] = [
        "!": [[shift, 0x1E]], "\"": [[shift, 0x1F]], "§": [[shift, 0x20]], "$": [[shift, 0x21]],
        "%": [[shift, 0x22]], "&": [[shift, 0x23]], "/": [[shift, 0x24]], "(": [[shift, 0x25]],
        ")": [[shift, 0x26]], "=": [[shift, 0x27]],
        "ß": [[0x2D]], "?": [[shift, 0x2D]], "\\": [[altGr, 0x2D]],
        "´": [[0x2E], [space]], "`": [[shift, 0x2E], [space]],
        "ü": [[0x2F]], "Ü": [[shift, 0x2F]],
        "+": [[0x30]], "*": [[shift, 0x30]], "~": [[altGr, 0x30]],
        "#": [[0x32]], "'": [[shift, 0x32]],
        "ö": [[0x33]], "Ö": [[shift, 0x33]], "ä": [[0x34]], "Ä": [[shift, 0x34]],
        "^": [[0x35], [space]], "°": [[shift, 0x35]],
        ",": [[0x36]], ";": [[shift, 0x36]], ".": [[0x37]], ":": [[shift, 0x37]],
        "-": [[0x38]], "_": [[shift, 0x38]],
        "<": [[0x64]], ">": [[shift, 0x64]], "|": [[altGr, 0x64]],
        "@": [[altGr, 0x14]], "€": [[altGr, 0x08]], "{": [[altGr, 0x24]], "[": [[altGr, 0x25]],
        "]": [[altGr, 0x26]], "}": [[altGr, 0x27]], "µ": [[altGr, 0x10]], "²": [[altGr, 0x1F]], "³": [[altGr, 0x20]],
    ]

    /// Key chords that type `c` on the remote system.
    public func chords(for c: Character) -> [[UInt32]]? {
        if c == " " { return [[Self.space]] }
        if let u = Self.letter(c, layout: layout) { return [[u]] }
        if let lower = c.lowercased().first, lower != c, let u = Self.letter(lower, layout: layout) {
            return [[Self.shift, u]]
        }
        if let u = Self.digitUsage[c] { return [[u]] }
        switch layout {
        case .us: return Self.usTable[c].map { [$0] }
        case .de: return Self.deTable[c]
        }
    }

    static let csiTilde: [Int: UInt32] = [1: 0x4A, 2: 0x49, 3: 0x4C, 4: 0x4D, 5: 0x4B, 6: 0x4E, 7: 0x4A, 8: 0x4D,
                                          11: 0x3A, 12: 0x3B, 13: 0x3C, 14: 0x3D, 15: 0x3E, 17: 0x3F, 18: 0x40,
                                          19: 0x41, 20: 0x42, 21: 0x43, 23: 0x44, 24: 0x45]
    static let csiFinal: [UInt8: UInt32] = [UInt8(ascii: "A"): 0x52, UInt8(ascii: "B"): 0x51, UInt8(ascii: "C"): 0x4F,
                                            UInt8(ascii: "D"): 0x50, UInt8(ascii: "H"): 0x4A, UInt8(ascii: "F"): 0x4D,
                                            UInt8(ascii: "P"): 0x3A, UInt8(ascii: "Q"): 0x3B, UInt8(ascii: "R"): 0x3C,
                                            UInt8(ascii: "S"): 0x3D]

    static func modifiers(_ param: Int) -> [UInt32] {
        guard param > 1 else { return [] }
        let m = param - 1
        var out: [UInt32] = []
        if m & 4 != 0 { out.append(ctrl) }
        if m & 2 != 0 { out.append(alt) }
        if m & 1 != 0 { out.append(shift) }
        return out
    }

    /// Parses one chunk of terminal input. Escape sequences are expected to arrive in one chunk.
    public func parse(_ bytes: [UInt8]) -> [Event] {
        var events: [Event] = []
        var chords: [[UInt32]] = []
        func flush() { if !chords.isEmpty { events.append(.keys(chords)); chords = [] } }

        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1B {
                i += 1
                guard i < bytes.count else { chords.append([Self.esc]); break }
                let n = bytes[i]
                if n == UInt8(ascii: "[") || n == UInt8(ascii: "O") {
                    // CSI / SS3: parameters then a final byte in 0x40...0x7E
                    var j = i + 1
                    var params = ""
                    while j < bytes.count, !(0x40...0x7E).contains(bytes[j]) {
                        params.append(Character(UnicodeScalar(bytes[j])))
                        j += 1
                    }
                    guard j < bytes.count else { i = j; continue }
                    let final = bytes[j]
                    i = j + 1
                    if params.hasPrefix("<"), final == UInt8(ascii: "M") || final == UInt8(ascii: "m") {
                        let p = params.dropFirst().split(separator: ";").compactMap { Int($0) }
                        if p.count == 3 {
                            flush()
                            let code = p[0]
                            if code & 64 != 0 {
                                events.append(.wheel(up: code & 1 == 0, column: p[1], row: p[2]))
                            } else {
                                events.append(.mouse(column: p[1], row: p[2], button: code & 3,
                                                     pressed: final == UInt8(ascii: "M"), motion: code & 32 != 0))
                            }
                        }
                        continue
                    }
                    let nums = params.split(separator: ";").map { Int($0) ?? 1 }
                    let mods = Self.modifiers(nums.count > 1 ? nums[1] : 1)
                    if final == UInt8(ascii: "~"), let k = Self.csiTilde[nums.first ?? 0] {
                        chords.append(mods + [k])
                    } else if final == UInt8(ascii: "Z") {
                        chords.append([Self.shift, Self.tab])
                    } else if let k = Self.csiFinal[final] {
                        chords.append(mods + [k])
                    }
                    continue
                }
                // ESC + key = Alt + key
                if let (c, len) = Self.decodeScalar(bytes, at: i) {
                    for chord in keyChords(for: c, rawByte: bytes[i]) { chords.append([Self.alt] + chord) }
                    i += len
                } else {
                    i += 1
                }
                continue
            }
            if b == 0x1D { flush(); events.append(.escapeHatch); i += 1; continue }
            if let (c, len) = Self.decodeScalar(bytes, at: i) {
                chords += keyChords(for: c, rawByte: b)
                i += len
            } else {
                i += 1
            }
        }
        flush()
        return events
    }

    private func keyChords(for c: Character, rawByte b: UInt8) -> [[UInt32]] {
        switch b {
        case 0x0D, 0x0A: return [[Self.enter]]
        case 0x09: return [[Self.tab]]
        case 0x7F, 0x08: return [[Self.backspace]]
        case 0x00: return [[Self.ctrl, Self.space]]
        case 0x01...0x1A:
            let letter = Character(UnicodeScalar(b + 0x60))
            return Self.letter(letter, layout: layout).map { [[Self.ctrl, $0]] } ?? []
        case 0x1B: return [[Self.esc]]
        default:
            return chords(for: c) ?? []
        }
    }

    static func decodeScalar(_ bytes: [UInt8], at i: Int) -> (Character, Int)? {
        let b = bytes[i]
        let len = b < 0x80 ? 1 : b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
        guard i + len <= bytes.count else { return nil }
        let s = String(decoding: bytes[i..<(i + len)], as: UTF8.self)
        guard let c = s.first else { return nil }
        return (c, len)
    }
}
