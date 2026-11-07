import Foundation

extension Array where Element == UInt8 {
    func u16(_ i: Int) -> UInt16 {
        UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }

    func u24(_ i: Int) -> UInt32 {
        UInt32(self[i]) | (UInt32(self[i + 1]) << 8) | (UInt32(self[i + 2]) << 16)
    }

    func u32(_ i: Int) -> UInt32 {
        UInt32(self[i]) | (UInt32(self[i + 1]) << 8) | (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24)
    }

    /// Bounds-safe sub-range.
    func bytes(_ from: Int, _ count: Int) -> [UInt8] {
        guard from >= 0, from < self.count, count > 0 else { return [] }
        return Array(self[from..<Swift.min(self.count, from + count)])
    }

    public var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

extension UInt16 {
    var le: [UInt8] { [UInt8(self & 0xFF), UInt8(self >> 8)] }
}

extension UInt32 {
    var le: [UInt8] {
        [UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF), UInt8((self >> 16) & 0xFF), UInt8(self >> 24)]
    }
}

/// IPMI two's-complement checksum.
func ipmiChecksum(_ bytes: [UInt8]) -> UInt8 {
    var sum: UInt8 = 0
    for b in bytes { sum &+= b }
    return 0 &- sum
}

/// Decodes a fixed-length, NUL-padded IPMI string.
func ipmiString(_ bytes: [UInt8]) -> String {
    let trimmed = bytes.prefix { $0 != 0 }
    return String(decoding: trimmed, as: UTF8.self).trimmingCharacters(in: .whitespaces)
}

/// Pads/truncates a string to a fixed number of bytes (NUL padded).
func fixedBytes(_ s: String, _ length: Int) -> [UInt8] {
    var b = Array(s.utf8.prefix(length))
    b += [UInt8](repeating: 0, count: length - b.count)
    return b
}
