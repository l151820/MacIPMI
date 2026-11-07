@testable import IPMIKit
import Foundation

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0
func expect(_ ok: @autoclosure () throws -> Bool, _ msg: String = "", line: Int = #line) {
    let r = (try? ok()) ?? false
    if r { passed += 1 } else { failures += 1; print("FEHLER Zeile \(line) \(msg)") }
}
func expectThrows(_ f: () throws -> Void, line: Int = #line) {
    do { try f(); failures += 1; print("FEHLER Zeile \(line): kein Fehler geworfen") } catch { passed += 1 }
}


private func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var it = s.filter { !$0.isWhitespace }.makeIterator()
    while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
    return out
}

func checksum() {
    expect(ipmiChecksum([0x20, 0x18]) == 0xC8)
    expect(ipmiChecksum([0x81, 0x04, 0x01]) == 0x7A)
}

func ipmiMessageMatchesWireCapture() {
    // Identical to the Get Channel Auth Capabilities request the X9 BMC answered.
    let m = IPMISession.ipmiMessage(netFn: NetFn.app, lun: 0, cmd: 0x38, seq: 0, data: [0x8E, 0x04])
    expect(m == hex("20 18 C8 81 00 38 8E 04 B5"))
}

func parsesChannelAuthCapsFromX9() throws {
    // Real reply payload from the Supermicro X9 BMC (192.168.2.61).
    let msg = hex("81 1C 63 20 00 38 00 01 96 06 03 45 53 00 00 70")
    let r = try IPMISession.parseIPMIResponse(msg)
    expect(r.completionCode == 0)
    let caps = try ChannelAuthCapabilities(data: r.data)
    expect(caps.supportsIPMI20)
    expect(caps.supportsIPMI15)
    expect(caps.nonNullUsernames)
    expect(!caps.anonymousLogin)
}

func hmacSHA1RFC2202() {
    let mac = IPMICrypto.hmacSHA1(key: [UInt8](repeating: 0x0B, count: 20), data: Array("Hi There".utf8))
    expect(mac == hex("b617318655057264e28bc0b6fb378c8ef146be00"))
}

func aesFIPS197() throws {
    let key = hex("000102030405060708090a0b0c0d0e0f")
    let c = try IPMICrypto.aesCBC(encrypt: true, key: key, iv: [UInt8](repeating: 0, count: 16),
                                  data: hex("00112233445566778899aabbccddeeff"))
    expect(c == hex("69c4e0d86a7b0430d8cdb78070b4c55a"))
}

func securePacketRoundTrip() throws {
    let keys = SessionKeys(k1: IPMICrypto.randomBytes(20), aes: IPMICrypto.randomBytes(16))
    for len in [7, 8, 15, 16, 17, 40] {
        let payload = IPMICrypto.randomBytes(len)
        let pkt = try IPMISession.buildSecure(payload: payload, sessionID: 0xA1B2C3D4, sequence: 7, keys: keys)
        // integrity range (auth type .. next header) must be DWORD aligned
        expect((pkt.count - 4 - 12) % 4 == 0)
        guard let p = try IPMISession.parseRMCPPlus(pkt, keys: keys) else { expect(false); continue }
        expect(p.payload == payload)
        expect(p.sessionID == 0xA1B2C3D4)
        expect(p.sequence == 7)
    }
}

func tamperedPacketIsRejected() throws {
    let keys = SessionKeys(k1: IPMICrypto.randomBytes(20), aes: IPMICrypto.randomBytes(16))
    var pkt = try IPMISession.buildSecure(payload: [1, 2, 3], sessionID: 1, sequence: 1, keys: keys)
    pkt[20] ^= 0xFF
    expectThrows { _ = try IPMISession.parseRMCPPlus(pkt, keys: keys) }
}

func sensorConversion() {
    let temp = SensorConversion(m: 1, b: 0, bExp: 0, rExp: 0, format: 0, linearization: 0)
    expect(temp.value(raw: 40) == 40)
    // Typical Supermicro fan: M=75 → 75 RPM per count
    let fan = SensorConversion(m: 75, b: 0, bExp: 0, rExp: 0, format: 0, linearization: 0)
    expect(fan.value(raw: 40) == 3000)
    // Voltage with R exp -3: M=16 → 0.016 V per count
    let volt = SensorConversion(m: 16, b: 0, bExp: 0, rExp: -3, format: 0, linearization: 0)
    expect(abs(volt.value(raw: 75)! - 1.2) < 0.0001)
    let signed = SensorConversion(m: 1, b: 0, bExp: 0, rExp: 0, format: 2, linearization: 0)
    expect(signed.value(raw: 0xF6) == -10)
    expect(SDRRecord.sign(0x3FF, bits: 10) == -1)
    expect(SDRRecord.sign(0x8, bits: 4) == -8)
}

func fruFieldDecoding() {
    var i = 0
    let latin = [0xC0 | 5] + Array("X9SCL".utf8)
    expect(FRUInfo.readField(latin, &i) == "X9SCL")
    i = 0
    expect(FRUInfo.readField([0x42, 0x12, 0x3A], &i) == "123")
    i = 0
    // 6-bit ASCII "IPMI": I=0x29 P=0x30 M=0x2D I=0x29
    let v: UInt32 = 0x29 | (0x30 << 6) | (0x2D << 12) | (0x29 << 18)
    expect(FRUInfo.readField([0x83, UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v >> 16)], &i) == "IPMI")
}

func selEntryDescription() {
    // Threshold event: upper critical going high on a temperature sensor
    let rec = hex("0100 02 00000060 2000 04 01 0A 01 59 46 50")
    let e = SELEntry(record: rec)
    expect(e.id == 1)
    expect(e.sensorNumber == 0x0A)
    expect(e.eventDescription.hasPrefix("Oberer kritischer Wert überschritten"))
    expect(!e.isDeassertion)
}

func jnlpParsing() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <jnlp spec="1.0+" codebase="http://192.168.2.61:80/">
    <resources><j2se version="1.6.0+"/><jar href="iKVM__V1.69.21.0x0.jar" download="eager" main="true"/></resources>
    <resources os="Mac OS X" arch="x86_64"><nativelib href="libmac_x86_64__V1.0.5.jar" download="eager"/></resources>
    <application-desc main-class="tw.com.aten.ikvm.KVMMain"><argument>192.168.2.61</argument><argument>x</argument></application-desc>
    </jnlp>
    """
    let j = try JNLPDescriptor.parse(Data(xml.utf8))
    expect(j.codebase?.absoluteString == "http://192.168.2.61:80/")
    expect(j.mainJar == "iKVM__V1.69.21.0x0.jar")
    expect(j.mainClass == "tw.com.aten.ikvm.KVMMain")
    expect(j.arguments == ["192.168.2.61", "x"])
    expect(j.nativeLibs == ["libmac_x86_64__V1.0.5.jar"])
}

func hermonDecoding() {
    // Full frame 2x1: red, blue (RGB555 little endian)
    var fb = [UInt32](repeating: 0, count: 2)
    let full: [UInt8] = [1, 0, 0x12, 0x34, 0x56, 0x78, 0, 0, 0, 4, 0x00, 0x7C, 0x1F, 0x00]
    HermonDecoder.decode(full, into: &fb, width: 2, height: 1, x: 0, y: 0, w: 2, h: 1)
    expect(fb == [0xFFFF0000, 0xFF0000FF], "Vollbild")
    // One tile at row 1, col 2 in a 64x32 framebuffer, all green
    var fb2 = [UInt32](repeating: 0, count: 64 * 32)
    var tile: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2]
    for _ in 0..<256 { tile += [0xE0, 0x03] }
    HermonDecoder.decode(tile, into: &fb2, width: 64, height: 32, x: 0, y: 0, w: 64, h: 32)
    expect(fb2[16 * 64 + 32] == 0xFF00FF00, "Kachel Anfang")
    expect(fb2[31 * 64 + 47] == 0xFF00FF00, "Kachel Ende")
    expect(fb2[15 * 64 + 32] == 0 && fb2[16 * 64 + 31] == 0 && fb2[16 * 64 + 48] == 0, "außerhalb der Kachel")
    expect(HermonDecoder.image(fb2, width: 64, height: 32) != nil)
    // Key map: no crash on literal, a few spot checks
    expect(HIDKeyMap.macToHID.count > 100)
    expect(HIDKeyMap.usage(forMacKeyCode: 0x00) == 0x04)   // A
    expect(HIDKeyMap.usage(forMacKeyCode: 0x24) == 0x28)   // Return
    expect(HIDKeyMap.f(1) == 0x3A && HIDKeyMap.f(12) == 0x45)
}

let tests: [(String, () throws -> Void)] = [
    ("hermonDecoding", hermonDecoding),
    ("jnlpParsing", jnlpParsing),
    ("checksum", checksum),
    ("ipmiMessageMatchesWireCapture", ipmiMessageMatchesWireCapture),
    ("parsesChannelAuthCapsFromX9", parsesChannelAuthCapsFromX9),
    ("hmacSHA1RFC2202", hmacSHA1RFC2202),
    ("aesFIPS197", aesFIPS197),
    ("securePacketRoundTrip", securePacketRoundTrip),
    ("tamperedPacketIsRejected", tamperedPacketIsRejected),
    ("sensorConversion", sensorConversion),
    ("fruFieldDecoding", fruFieldDecoding),
    ("selEntryDescription", selEntryDescription),
]
for (name, t) in tests {
    do { try t() } catch { failures += 1; print("FEHLER in \(name): \(error)") }
}
print("\(passed) Prüfungen bestanden, \(failures) fehlgeschlagen")
exit(failures == 0 ? 0 : 1)
