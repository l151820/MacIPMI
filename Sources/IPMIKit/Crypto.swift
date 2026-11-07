import CommonCrypto
import Foundation

enum IPMICrypto {
    static func hmacSHA1(key: [UInt8], data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), key, key.count, data, data.count, &out)
        return out
    }

    /// AES-128-CBC without padding (IPMI handles its own padding).
    static func aesCBC(encrypt: Bool, key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(0),
            key, key.count,
            iv,
            data, data.count,
            &out, out.count,
            &moved
        )
        guard status == kCCSuccess else {
            throw IPMIError.malformed("AES-Fehler \(status)")
        }
        return Array(out.prefix(moved))
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) }
    }
}
