import Foundation

public enum ChassisControl: UInt8, Sendable, CaseIterable {
    case powerDown = 0, powerUp = 1, powerCycle = 2, hardReset = 3, diagnosticInterrupt = 4, softShutdown = 5

    public var displayName: String {
        switch self {
        case .powerDown: return "Ausschalten (hart)"
        case .powerUp: return "Einschalten"
        case .powerCycle: return "Power Cycle"
        case .hardReset: return "Reset"
        case .diagnosticInterrupt: return "NMI auslösen"
        case .softShutdown: return "Herunterfahren (ACPI)"
        }
    }
}

public enum PowerRestorePolicy: UInt8, Sendable, CaseIterable, Identifiable {
    case alwaysOff = 0, previous = 1, alwaysOn = 2, unknown = 3
    public var id: UInt8 { rawValue }
    public var displayName: String {
        switch self {
        case .alwaysOff: return "Aus bleiben"
        case .previous: return "Letzter Zustand"
        case .alwaysOn: return "Einschalten"
        case .unknown: return "Unbekannt"
        }
    }
}

public enum BootDevice: UInt8, Sendable, CaseIterable, Identifiable {
    case noOverride = 0, pxe = 1, disk = 2, safeMode = 3, diagnostic = 4, cdrom = 5, biosSetup = 6, floppy = 15
    public var id: UInt8 { rawValue }
    public var displayName: String {
        switch self {
        case .noOverride: return "Keine Änderung"
        case .pxe: return "Netzwerk (PXE)"
        case .disk: return "Festplatte"
        case .safeMode: return "Festplatte (abgesicherter Modus)"
        case .diagnostic: return "Diagnose"
        case .cdrom: return "CD/DVD"
        case .biosSetup: return "BIOS-Setup"
        case .floppy: return "Wechselmedium"
        }
    }
}

public struct ChassisStatus: Sendable {
    public let powerOn: Bool
    public let powerOverload: Bool
    public let interlock: Bool
    public let mainPowerFault: Bool
    public let powerControlFault: Bool
    public let restorePolicy: PowerRestorePolicy
    public let lastPowerEvent: [String]
    public let intrusion: Bool
    public let frontPanelLockout: Bool
    public let driveFault: Bool
    public let coolingFault: Bool
    public let identifyState: String?

    init(data d: [UInt8]) throws {
        guard d.count >= 3 else { throw IPMIError.malformed("Chassis Status zu kurz") }
        powerOn = d[0] & 0x01 != 0
        powerOverload = d[0] & 0x02 != 0
        interlock = d[0] & 0x04 != 0
        mainPowerFault = d[0] & 0x08 != 0
        powerControlFault = d[0] & 0x10 != 0
        restorePolicy = PowerRestorePolicy(rawValue: (d[0] >> 5) & 0x03) ?? .unknown
        var ev: [String] = []
        if d[1] & 0x01 != 0 { ev.append("Netzausfall") }
        if d[1] & 0x02 != 0 { ev.append("Überlast") }
        if d[1] & 0x04 != 0 { ev.append("Interlock") }
        if d[1] & 0x08 != 0 { ev.append("Stromversorgungsfehler") }
        if d[1] & 0x10 != 0 { ev.append("Über IPMI eingeschaltet") }
        lastPowerEvent = ev
        intrusion = d[2] & 0x01 != 0
        frontPanelLockout = d[2] & 0x02 != 0
        driveFault = d[2] & 0x04 != 0
        coolingFault = d[2] & 0x08 != 0
        if d[2] & 0x40 != 0 {
            switch (d[2] >> 4) & 0x03 {
            case 0: identifyState = "Aus"
            case 1: identifyState = "Zeitgesteuert an"
            case 2: identifyState = "Dauerhaft an"
            default: identifyState = nil
            }
        } else {
            identifyState = nil
        }
    }
}

extension IPMISession {
    public func chassisStatus() async throws -> ChassisStatus {
        try ChassisStatus(data: await send(netFn: NetFn.chassis, cmd: 0x01))
    }

    public func chassisControl(_ action: ChassisControl) async throws {
        try await send(netFn: NetFn.chassis, cmd: 0x02, data: [action.rawValue])
    }

    /// Identify LED. `seconds == 0` turns it off.
    public func identify(seconds: UInt8 = 15, forceOn: Bool = false) async throws {
        try await send(netFn: NetFn.chassis, cmd: 0x04, data: [seconds, forceOn ? 1 : 0])
    }

    public func setPowerRestorePolicy(_ p: PowerRestorePolicy) async throws {
        try await send(netFn: NetFn.chassis, cmd: 0x06, data: [p.rawValue])
    }

    public func setBootDevice(_ device: BootDevice, persistent: Bool = false, efi: Bool = false) async throws {
        var flags: UInt8 = device == .noOverride ? 0x00 : 0x80
        if persistent { flags |= 0x40 }
        if efi { flags |= 0x20 }
        try await send(netFn: NetFn.chassis, cmd: 0x08, data: [0x05, flags, device.rawValue << 2, 0, 0])
    }
}
