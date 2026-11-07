import Foundation

public enum IPMIError: Error, LocalizedError, Sendable {
    case timeout
    case network(String)
    case malformed(String)
    case completionCode(UInt8)
    case sessionSetup(String)
    case authenticationFailed
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Zeitüberschreitung – das BMC antwortet nicht (UDP-Port 623 erreichbar?)."
        case .network(let m):
            return "Netzwerkfehler: \(m)"
        case .malformed(let m):
            return "Ungültige Antwort vom BMC: \(m)"
        case .completionCode(let cc):
            return "BMC meldet Fehler 0x\(String(format: "%02X", cc)): \(IPMIError.describe(cc))"
        case .sessionSetup(let m):
            return "Sitzungsaufbau fehlgeschlagen: \(m)"
        case .authenticationFailed:
            return "Anmeldung fehlgeschlagen – Benutzername oder Passwort falsch."
        case .unsupported(let m):
            return "Nicht unterstützt: \(m)"
        }
    }

    public static func describe(_ cc: UInt8) -> String {
        switch cc {
        case 0xC0: return "Node beschäftigt"
        case 0xC1: return "Befehl nicht unterstützt"
        case 0xC2: return "Befehl für diese LUN ungültig"
        case 0xC3: return "Zeitüberschreitung bei der Verarbeitung"
        case 0xC4: return "Kein Speicherplatz"
        case 0xC5: return "Reservierung abgebrochen oder ungültig"
        case 0xC6: return "Anfragedaten abgeschnitten"
        case 0xC7: return "Ungültige Datenlänge"
        case 0xC8: return "Datenfeld zu lang"
        case 0xC9: return "Parameter außerhalb des Bereichs"
        case 0xCA: return "Angeforderte Byteanzahl nicht lieferbar"
        case 0xCB: return "Sensor, Datensatz oder Daten nicht vorhanden"
        case 0xCC: return "Ungültiges Datenfeld"
        case 0xCD: return "Befehl für diesen Sensor/Datensatz unzulässig"
        case 0xCE: return "Antwort konnte nicht erzeugt werden"
        case 0xCF: return "Doppelte Anfrage"
        case 0xD0: return "SDR-Repository wird aktualisiert"
        case 0xD1: return "Firmware-Update läuft"
        case 0xD2: return "BMC-Initialisierung läuft"
        case 0xD3: return "Ziel nicht verfügbar"
        case 0xD4: return "Unzureichende Berechtigung"
        case 0xD5: return "Im aktuellen Zustand nicht möglich"
        case 0xD6: return "Unterfunktion deaktiviert"
        case 0xFF: return "Unbekannter Fehler"
        default: return "Unbekannter Fehlercode"
        }
    }

    static func rakpStatus(_ s: UInt8) -> String {
        switch s {
        case 0x01: return "Keine Ressourcen für eine neue Sitzung"
        case 0x02: return "Ungültige Sitzungs-ID"
        case 0x03: return "Ungültiger Payload-Typ"
        case 0x04: return "Authentifizierungsalgorithmus nicht unterstützt"
        case 0x05: return "Integritätsalgorithmus nicht unterstützt"
        case 0x06: return "Keine passende Authentifizierung"
        case 0x07: return "Keine passende Integritätsprüfung"
        case 0x08: return "Inaktive Sitzungs-ID"
        case 0x09: return "Ungültige Rolle"
        case 0x0A: return "Angeforderte Berechtigungsstufe nicht erlaubt"
        case 0x0B: return "Keine Ressourcen für die angeforderte Rolle"
        case 0x0C: return "Ungültige Länge des Benutzernamens"
        case 0x0D: return "Benutzername unbekannt"
        case 0x0E: return "GUID nicht autorisiert"
        case 0x0F: return "Ungültiger Integritätswert (Passwort falsch?)"
        case 0x10: return "Verschlüsselungsalgorithmus nicht unterstützt"
        case 0x11: return "Keine passende Cipher Suite"
        case 0x12: return "Ungültiger Parameter"
        default: return "Status 0x\(String(format: "%02X", s))"
        }
    }
}
