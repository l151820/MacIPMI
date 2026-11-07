import Foundation
import IPMIKit
import ImageIO

setvbuf(stdout, nil, _IOLBF, 0)

let usageText = """
Verwendung: ipmi-cli -H <host> [-U <benutzer>] [-p <port>] [-v] <befehl> [argumente]

Das Passwort wird aus der Umgebungsvariable IPMI_PASSWORD gelesen oder interaktiv abgefragt.

Befehle:
  caps                         Authentifizierungsfähigkeiten des BMC (ohne Login)
  info                         BMC-Informationen
  power status|on|off|soft|cycle|reset
  chassis                      Gehäusestatus
  identify [sekunden]          Identify-LED einschalten (0 = aus)
  sensors                      Alle Sensoren lesen
  sel [clear]                  Ereignisprotokoll anzeigen / löschen
  fru                          FRU-Inventar
  lan                          Netzwerkkonfiguration des BMC
  users                        Benutzerliste
  fan [standard|full|optimal|heavyio]   Supermicro-Lüftermodus lesen/setzen
  kvm console [--layout de|us] [--mode image|blocks]
                               KVM-Konsole direkt im Terminal (iTerm2: echtes Bild, sonst Blockgrafik).
                               Strg+] öffnet das Menü (q = beenden). --layout = Tastaturlayout des Servers
  kvm [snapshot [datei.png]]   Native Konsole: verbinden und ein Bildschirmfoto speichern
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

var host: String?
var user = "ADMIN"
var port: UInt16 = 623
var verbose = false
var rest: [String] = []
let argv = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < argv.count {
    let a = argv[i]
    switch a {
    case "-H", "-U", "-p":
        i += 1
        guard i < argv.count else { fail("Wert für \(a) fehlt") }
        if a == "-H" { host = argv[i] }
        if a == "-U" { user = argv[i] }
        if a == "-p" { port = UInt16(argv[i]) ?? 623 }
    case "-v": verbose = true
    case "-h", "--help": print(usageText); exit(0)
    default: rest.append(a)
    }
    i += 1
}
guard let host, let command = rest.first else {
    print(usageText)
    exit(2)
}
let args = Array(rest.dropFirst())

let needsLogin = command != "caps"
var password = ""
if needsLogin {
    if let p = ProcessInfo.processInfo.environment["IPMI_PASSWORD"] {
        password = p
    } else if let p = getpass("Passwort für \(user)@\(host): ") {
        password = String(cString: p)
    }
}

let session = IPMISession(credentials: IPMICredentials(host: host, port: port, username: user, password: password))
if verbose {
    await session.setLogger { FileHandle.standardError.write(Data(("  " + $0 + "\n").utf8)) }
}

func yesNo(_ b: Bool) -> String { b ? "ja" : "nein" }
let dateFormat: (Date?) -> String = { $0?.formatted(date: .numeric, time: .standard) ?? "–" }

do {
    switch command {
    case "caps":
        let c = try await session.channelAuthCapabilities()
        print("Kanal:              \(c.channel)")
        print("IPMI 1.5 / 2.0:     \(yesNo(c.supportsIPMI15)) / \(yesNo(c.supportsIPMI20))")
        print("Auth-Typen (1.5):   \(c.authTypes.joined(separator: ", "))")
        print("Anonymer Login:     \(yesNo(c.anonymousLogin))")
        print("Null-Benutzer:      \(yesNo(c.nullUsernames))")
        print("Benannte Benutzer:  \(yesNo(c.nonNullUsernames))")
        print("BMC-Key (Kg) aktiv: \(yesNo(c.kgSet))")

    case "info":
        let d = try await session.deviceID()
        print("Hersteller:   \(d.manufacturerName) (\(d.manufacturerID))")
        print("Produkt-ID:   0x\(String(format: "%04X", d.productID))")
        print("Geräte-ID:    \(d.deviceID) Rev. \(d.deviceRevision)")
        print("Firmware:     \(d.firmwareVersion)")
        print("IPMI-Version: \(d.ipmiVersion)")
        print("Funktionen:   \(d.capabilities.joined(separator: ", "))")
        if let g = try? await session.deviceGUID() { print("GUID:         \(g)") }

    case "power":
        let sub = args.first ?? "status"
        let map: [String: ChassisControl] = ["on": .powerUp, "off": .powerDown, "soft": .softShutdown,
                                             "cycle": .powerCycle, "reset": .hardReset]
        if let action = map[sub] {
            try await session.chassisControl(action)
            print("\(action.displayName): Befehl gesendet")
        } else {
            let s = try await session.chassisStatus()
            print("Stromversorgung: \(s.powerOn ? "an" : "aus")")
        }

    case "chassis":
        let s = try await session.chassisStatus()
        print("Stromversorgung:     \(s.powerOn ? "an" : "aus")")
        print("Netzwiederherstellg: \(s.restorePolicy.displayName)")
        print("Letztes Ereignis:    \(s.lastPowerEvent.isEmpty ? "–" : s.lastPowerEvent.joined(separator: ", "))")
        print("Überlast/Fehler:     \(yesNo(s.powerOverload)) / \(yesNo(s.mainPowerFault || s.powerControlFault))")
        print("Gehäuse geöffnet:    \(yesNo(s.intrusion))")
        print("Lüfterfehler:        \(yesNo(s.coolingFault))")
        print("Laufwerksfehler:     \(yesNo(s.driveFault))")
        print("Identify-LED:        \(s.identifyState ?? "–")")

    case "identify":
        let secs = UInt8(args.first ?? "15") ?? 15
        try await session.identify(seconds: secs)
        print("Identify-LED: \(secs == 0 ? "aus" : "\(secs) s")")

    case "sensors":
        let records = try await session.sdrRecords()
        let readings = try await session.readSensors(records)
        for r in readings {
            print("\(pad(r.record.name, 18)) \(pad(r.formattedValue, 28)) \(pad(r.health.label, 10)) \(r.thresholdText)")
        }

    case "sel":
        if args.first == "clear" {
            try await session.clearSEL()
            print("Ereignisprotokoll gelöscht")
        } else {
            let info = try await session.selInfo()
            print("SEL v\(info.version): \(info.entries) Einträge, \(info.freeBytes) Bytes frei\(info.overflow ? ", ÜBERLAUF" : "")")
            let names = Dictionary((try? await session.sdrRecords())?.map { ($0.sensorNumber, $0.name) } ?? [],
                                   uniquingKeysWith: { a, _ in a })
            for e in try await session.selEntries() {
                let sensor = names[e.sensorNumber] ?? "#\(e.sensorNumber)"
                print("\(pad(String(format: "%04X", e.id), 5)) \(pad(dateFormat(e.timestamp), 20)) \(pad(e.sensorTypeName + " " + sensor, 34)) \(e.eventDescription) [\(e.directionText)]")
            }
        }

    case "fru":
        let f = try await session.fru()
        if f.sections.isEmpty { print("Keine FRU-Daten (\(f.size) Bytes gelesen)") }
        for s in f.sections {
            print("[\(s.title)]")
            for fld in s.fields { print("  \(pad(fld.label, 20)) \(fld.value)") }
        }

    case "lan":
        let c = try await session.lanConfig()
        print("IP-Quelle:   \(c.ipSource ?? "–")")
        print("IP-Adresse:  \(c.ipAddress ?? "–")")
        print("Netzmaske:   \(c.subnetMask ?? "–")")
        print("Gateway:     \(c.gateway ?? "–") (\(c.gatewayMAC ?? "–"))")
        print("MAC:         \(c.macAddress ?? "–")")
        print("VLAN:        \(c.vlan ?? "–")")

    case "users":
        for u in try await session.users() where !u.name.isEmpty || u.enabled == true {
            let state = u.enabled.map { $0 ? "aktiv" : "deaktiviert" } ?? "?"
            print("\(pad(String(u.id), 3)) \(pad(u.name, 17)) \(pad(state, 12)) \(u.privilegeName)")
        }

    case "fan":
        if let name = args.first {
            let map: [String: SupermicroFanMode] = ["standard": .standard, "full": .full,
                                                    "optimal": .optimal, "heavyio": .heavyIO]
            guard let m = map[name.lowercased()] else { fail("Unbekannter Lüftermodus: \(name)") }
            try await session.setSupermicroFanMode(m)
            print("Lüftermodus gesetzt: \(m.displayName)")
        } else {
            let m = try await session.supermicroFanMode()
            print("Lüftermodus: \(m?.displayName ?? "unbekannt")")
        }

    case "kvm":
        let isConsole = args.first == "console"
        let logger: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(("  " + $0 + "\n").utf8)) }
        // MACIPMI_KVM_TOKEN skips the web login (for tests against a local stub server).
        let params = if let t = ProcessInfo.processInfo.environment["MACIPMI_KVM_TOKEN"] {
            KVMConsoleParams(host: host, token: t, videoPort: port == 623 ? 5900 : port)
        } else {
            try await SupermicroWeb.mintKVMConsole(host: host, username: user, password: password,
                                                   log: isConsole && !verbose ? nil : logger)
        }

        if isConsole {
            var layout = KeyboardLayout.de
            var mode = TerminalConsole.detectMode()
            var k = 1
            while k < args.count {
                switch args[k] {
                case "--layout":
                    k += 1
                    guard k < args.count, let l = KeyboardLayout(rawValue: args[k]) else { fail("--layout de|us") }
                    layout = l
                case "--mode":
                    k += 1
                    guard k < args.count, let m = TerminalConsole.Mode(rawValue: args[k]) else { fail("--mode image|blocks") }
                    mode = m
                default:
                    fail("Unbekannte Option: \(args[k])")
                }
                k += 1
            }
            let console = TerminalConsole(params: params, mode: mode, layout: layout, hostLabel: host)
            if let msg = console.run() { print(msg) }
            break
        }

        let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "kvm-snapshot.png")
        print("Token erhalten, verbinde mit \(params.host):\(params.videoPort) …")
        let (events, cont) = AsyncStream<ATENKVMSession.Event>.makeStream()
        let kvm = ATENKVMSession(params: params, log: logger) { cont.yield($0) }
        kvm.start()
        let timeout = Task { try await Task.sleep(for: .seconds(20)); cont.yield(.disconnected("Kein Bild innerhalb von 20 s")) }
        var frames = 0
        loop: for await ev in events {
            switch ev {
            case .connected(let w, let h, let name):
                print("Verbunden: ServerInit \(w)×\(h) „\(name)“")
            case .noSignal:
                print("Noch kein Bild – Server ausgeschaltet oder ohne Videosignal?")
            case .frame(let img):
                frames += 1
                guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else { break loop }
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
                print("Bild \(img.width)×\(img.height) gespeichert: \(out.path)")
                break loop
            case .disconnected(let reason):
                print("Getrennt: \(reason ?? "–")")
                break loop
            case .connecting:
                break
            }
        }
        timeout.cancel()
        kvm.stop()
        if frames == 0 { exit(1) }

    default:
        print(usageText)
        exit(2)
    }
    if needsLogin { await session.close() }
} catch {
    fail("Fehler: \(error.localizedDescription)")
}
