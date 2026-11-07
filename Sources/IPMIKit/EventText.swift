import Foundation

/// Human readable names for sensor types and event offsets (IPMI 2.0 tables 42-2 / 42-3).
public enum EventText {
    public static func sensorTypeName(_ t: UInt8) -> String {
        switch t {
        case 0x01: return "Temperatur"
        case 0x02: return "Spannung"
        case 0x03: return "Strom"
        case 0x04: return "Lüfter"
        case 0x05: return "Gehäuse-Sicherheit"
        case 0x06: return "Plattform-Sicherheit"
        case 0x07: return "Prozessor"
        case 0x08: return "Netzteil"
        case 0x09: return "Stromversorgung"
        case 0x0A: return "Kühlung"
        case 0x0B: return "Sonstige Einheit"
        case 0x0C: return "Speicher"
        case 0x0D: return "Laufwerksschacht"
        case 0x0E: return "POST-Speichergröße"
        case 0x0F: return "Firmware-Fortschritt"
        case 0x10: return "Ereignisprotokollierung"
        case 0x11: return "Watchdog 1"
        case 0x12: return "Systemereignis"
        case 0x13: return "Kritischer Interrupt"
        case 0x14: return "Taster/Schalter"
        case 0x15: return "Modul/Platine"
        case 0x16: return "Mikrocontroller"
        case 0x17: return "Erweiterungskarte"
        case 0x18: return "Gehäuse"
        case 0x19: return "Chipsatz"
        case 0x1A: return "Sonstige FRU"
        case 0x1B: return "Kabel/Verbindung"
        case 0x1C: return "Terminator"
        case 0x1D: return "Systemstart"
        case 0x1E: return "Boot-Fehler"
        case 0x1F: return "Betriebssystem-Boot"
        case 0x20: return "Betriebssystem-Stopp"
        case 0x21: return "Steckplatz/Anschluss"
        case 0x22: return "ACPI-Zustand"
        case 0x23: return "Watchdog 2"
        case 0x24: return "Plattform-Alarm"
        case 0x25: return "Präsenz"
        case 0x26: return "Monitor-ASIC"
        case 0x27: return "LAN"
        case 0x28: return "Management-Subsystem"
        case 0x29: return "Batterie"
        case 0x2A: return "Sitzungsprotokoll"
        case 0x2B: return "Versionsänderung"
        case 0x2C: return "FRU-Status"
        case 0xC0...0xFF: return "OEM (0x\(String(format: "%02X", t)))"
        default: return "Typ 0x\(String(format: "%02X", t))"
        }
    }

    static let threshold: [String] = [
        "Unterer Warnwert unterschritten",
        "Unterer Warnwert (steigend)",
        "Unterer kritischer Wert unterschritten",
        "Unterer kritischer Wert (steigend)",
        "Unterer nicht behebbarer Wert unterschritten",
        "Unterer nicht behebbarer Wert (steigend)",
        "Oberer Warnwert (fallend)",
        "Oberer Warnwert überschritten",
        "Oberer kritischer Wert (fallend)",
        "Oberer kritischer Wert überschritten",
        "Oberer nicht behebbarer Wert (fallend)",
        "Oberer nicht behebbarer Wert überschritten",
    ]

    static let generic: [UInt8: [String]] = [
        0x02: ["Leerlauf", "Aktiv", "Beschäftigt"],
        0x03: ["Zustand aufgehoben", "Zustand aktiv"],
        0x04: ["Kein Vorausfall", "Vorausfall erkannt"],
        0x05: ["Grenzwert nicht überschritten", "Grenzwert überschritten"],
        0x06: ["Leistung erreicht", "Leistung unzureichend"],
        0x07: ["OK", "Unkritisch (von OK)", "Kritisch (von weniger schwer)", "Nicht behebbar (von weniger schwer)",
               "Unkritisch (von schwerer)", "Kritisch (von nicht behebbar)", "Nicht behebbar", "Überwachung", "Information"],
        0x08: ["Nicht vorhanden", "Vorhanden"],
        0x09: ["Deaktiviert", "Aktiviert"],
        0x0A: ["Läuft", "Im Test", "Ausgeschaltet", "Online", "Offline", "Außer Betrieb", "Eingeschränkt",
               "Energiesparmodus", "Installationsfehler"],
        0x0B: ["Vollständig redundant", "Redundanz verloren", "Redundanz eingeschränkt",
               "Nicht redundant (ausreichend, von redundant)", "Nicht redundant (ausreichend, von unzureichend)",
               "Nicht redundant (unzureichend)", "Redundanz eingeschränkt (von voll)", "Redundanz eingeschränkt (von nicht redundant)"],
        0x0C: ["S0/G0 Läuft", "S1 Schlafzustand", "S2 Schlafzustand", "S3 Suspend-to-RAM", "S4 Suspend-to-Disk",
               "S5/G2 Soft-Off", "S4/S5 Soft-Off", "G3 Mechanisch aus", "Schlafzustand", "G1 Schlafzustand",
               "S5 durch Override", "Legacy ON", "Legacy OFF", "", "Unbekannt"],
    ]

    static let sensorSpecific: [UInt8: [String]] = [
        0x05: ["Gehäuse geöffnet", "Laufwerksschacht geöffnet", "E/A-Bereich geöffnet", "Prozessorbereich geöffnet",
               "LAN-Verbindung getrennt", "Unerlaubtes Docking", "Lüfterbereich geöffnet"],
        0x07: ["IERR", "Thermischer Notaus", "FRB1/BIST-Fehler", "FRB2/Hang beim POST", "FRB3/Startfehler",
               "Konfigurationsfehler", "Nicht korrigierbarer CPU-Fehler", "Prozessor vorhanden", "Prozessor deaktiviert",
               "Terminator vorhanden", "Gedrosselt", "Machine Check (nicht korrigierbar)", "Machine Check (korrigierbar)"],
        0x08: ["Vorhanden", "Netzteilfehler", "Vorausfall", "Eingangsspannung verloren", "Eingang außerhalb des Bereichs",
               "Eingang außerhalb des Bereichs (vorhanden)", "Konfigurationsfehler", "Standby"],
        0x09: ["Ausgeschaltet", "Power Cycle", "240VA-Abschaltung", "Interlock-Abschaltung", "Netzspannung verloren",
               "Soft-Power-Fehler", "Stromversorgungsfehler", "Vorausfall"],
        0x0C: ["Korrigierbarer ECC-Fehler", "Nicht korrigierbarer ECC-Fehler", "Paritätsfehler", "Memory Scrub fehlgeschlagen",
               "Speichermodul deaktiviert", "ECC-Protokolllimit erreicht", "Vorhanden", "Konfigurationsfehler", "Spare",
               "Gedrosselt", "Kritische Übertemperatur"],
        0x0D: ["Laufwerk vorhanden", "Laufwerksfehler", "Vorausfall", "Hot Spare", "Konsistenzprüfung",
               "In kritischem Array", "In ausgefallenem Array", "Rebuild läuft", "Rebuild abgebrochen"],
        0x0F: ["Firmware-Fehler", "Firmware hängt", "Firmware-Fortschritt"],
        0x10: ["Protokollierung korrigierbarer Speicherfehler deaktiviert", "Protokollierung für Sensor deaktiviert",
               "Protokoll gelöscht", "Gesamte Protokollierung deaktiviert", "SEL voll", "SEL fast voll"],
        0x12: ["System neu konfiguriert", "OEM-Boot-Ereignis", "Unbestimmter Hardwarefehler",
               "Eintrag ins Zusatzprotokoll", "PEF-Aktion", "Zeitstempel synchronisiert"],
        0x13: ["NMI (Frontpanel)", "Bus-Timeout", "I/O-Channel-Check NMI", "Software-NMI", "PCI PERR", "PCI SERR",
               "EISA Fail-Safe Timeout", "Korrigierbarer Busfehler", "Nicht korrigierbarer Busfehler", "Fataler NMI",
               "Fataler Busfehler", "Bus eingeschränkt"],
        0x14: ["Power-Taste gedrückt", "Sleep-Taste gedrückt", "Reset-Taste gedrückt", "FRU-Verriegelung offen",
               "FRU-Serviceanforderung"],
        0x1D: ["Start durch Einschalten", "Start durch Hard-Reset", "Start durch Warm-Reset", "PXE-Boot angefordert",
               "Automatischer Diagnose-Boot", "Hard-Reset durch Betriebssystem", "Warm-Reset durch Betriebssystem",
               "Systemneustart"],
        0x1E: ["Kein bootfähiges Medium", "Diskette nicht bootfähig", "PXE-Server nicht gefunden",
               "Ungültiger Bootsektor", "Zeitüberschreitung bei Auswahl"],
        0x1F: ["Boot von A: abgeschlossen", "Boot von C: abgeschlossen", "PXE-Boot abgeschlossen",
               "Diagnose-Boot abgeschlossen", "CD-ROM-Boot abgeschlossen", "ROM-Boot abgeschlossen", "Boot abgeschlossen"],
        0x20: ["Kritischer Stopp beim Laden", "Kritischer Stopp zur Laufzeit", "Betriebssystem geordnet gestoppt",
               "Betriebssystem heruntergefahren", "Soft-Shutdown durch PEF", "Agent antwortet nicht"],
        0x21: ["Fehlerstatus", "Identifizierung", "Steckplatz belegt", "Bereit für Installation", "Bereit zum Entfernen",
               "Steckplatz ausgeschaltet", "Entfernen angefordert", "Verriegelt", "Steckplatz deaktiviert", "Ersatz-Steckplatz"],
        0x23: ["Timer abgelaufen", "Hard-Reset", "Ausschalten", "Power Cycle", "", "", "", "", "Timer-Interrupt"],
        0x25: ["Vorhanden", "Nicht vorhanden", "Deaktiviert"],
        0x29: ["Batterie schwach", "Batterie defekt", "Batterie vorhanden"],
        0x2A: ["Sitzung aktiviert", "Sitzung beendet", "Ungültiger Benutzername oder Passwort",
               "Benutzer wegen falscher Passwörter gesperrt"],
        0x2B: ["Hardwareänderung", "Firmware-/Softwareänderung", "Hardware-Inkompatibilität",
               "Firmware-/Software-Inkompatibilität", "Ungültige Hardwareversion", "Ungültige Firmwareversion",
               "Hardwareänderung erfolgreich", "Softwareänderung erfolgreich"],
        0x2C: ["Nicht installiert", "Inaktiv", "Aktivierung angefordert", "Aktivierung läuft", "Aktiv",
               "Deaktivierung angefordert", "Deaktivierung läuft", "Kommunikation verloren"],
    ]

    public static func describe(sensorType: UInt8, eventType: UInt8, offset: UInt8) -> String {
        let o = Int(offset & 0x0F)
        let list: [String]?
        switch eventType {
        case 0x01: list = threshold
        case 0x6F: list = sensorSpecific[sensorType]
        default: list = generic[eventType]
        }
        if let list, o < list.count, !list[o].isEmpty { return list[o] }
        return "Ereignis 0x\(String(format: "%02X", eventType))/Offset \(o)"
    }

    /// Rough severity for discrete states, used for colouring sensor rows.
    static func severity(sensorType: UInt8, eventType: UInt8, offset: UInt8) -> SensorHealth {
        switch eventType {
        case 0x6F:
            switch (sensorType, offset) {
            case (0x07, 0), (0x07, 1), (0x07, 6), (0x07, 11), (0x08, 1), (0x08, 3), (0x09, 4), (0x09, 6),
                 (0x0C, 1), (0x0D, 1), (0x0D, 6), (0x13, 9), (0x13, 10), (0x29, 1):
                return .critical
            case (0x05, _), (0x08, 2), (0x08, 4), (0x08, 5), (0x08, 6), (0x0C, 0), (0x0D, 2), (0x0D, 5),
                 (0x29, 0), (0x07, 10), (0x07, 12):
                return .warning
            default: return .ok
            }
        case 0x04 where offset == 1, 0x05 where offset == 1:
            return .warning
        case 0x07:
            switch offset {
            case 1, 4: return .warning
            case 2, 5: return .critical
            case 3, 6: return .nonRecoverable
            default: return .ok
            }
        case 0x0B:
            switch offset {
            case 1, 5: return .critical
            case 2, 3, 4, 6, 7: return .warning
            default: return .ok
            }
        default:
            return .ok
        }
    }
}
