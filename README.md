# MacIPMI

Native macOS-App (SwiftUI) zur Verwaltung von Servern über IPMI 2.0 – gebaut für ältere
Supermicro-Boards (X9) und funktional an Supermicros **IPMIView** angelehnt.
Das IPMI-Protokoll (RMCP+, RAKP-HMAC-SHA1, AES-CBC-128, Cipher Suite 3) ist in Swift
implementiert, ebenso die KVM-Konsole (ATEN iKVM) – `ipmitool`, Java oder Rosetta werden nicht benötigt.

## Funktionen

| Bereich | Inhalt |
|---|---|
| Systemliste | Mehrere BMCs, Passwörter im Schlüsselbund, Verbindungsstatus |
| Übersicht | Stromstatus, Ein/Aus/ACPI-Shutdown/Reset/Power Cycle, Identify-LED, Verhalten nach Stromausfall, Boot-Gerät (PXE/Disk/CD/BIOS, einmalig oder dauerhaft, UEFI), Supermicro-Lüftermodus, BMC-Infos, BMC-Neustart |
| Sensoren | Alle SDR-Sensoren (Temperatur, Spannung, Lüfter, diskrete Sensoren) mit Status und Grenzwerten, Auto-Refresh alle 5 s, Filter |
| Ereignisprotokoll | SEL lesen, kopieren, löschen; Ereignistexte auf Deutsch |
| FRU | Gehäuse-, Mainboard- und Produktdaten |
| Netzwerk | IP-Konfiguration, MAC, Gateway, VLAN des BMC |
| Benutzer | BMC-Benutzer anzeigen, umbenennen, Passwort setzen, aktivieren, Berechtigung ändern |
| Konsole | Native KVM-Konsole (Bild, Tastatur, Maus, Tastenkombinationen, Bildschirmfoto), Webinterface öffnen |

## Installation

Mit Homebrew (App nach `/Applications`, `ipmi-cli` in den PATH):

```bash
brew install --cask l151820/tap/macipmi
```

Aktualisieren mit `brew upgrade --cask macipmi`, entfernen mit `brew uninstall --cask macipmi`.

Alternativ liegen fertige Builds (Universal: Apple Silicon und Intel, macOS 14+) unter **Releases**. Die App ist
ad-hoc-signiert, aber nicht notarisiert – nach einem manuellen Download die Quarantäne entfernen
(Homebrew erledigt das selbst) oder unter **Systemeinstellungen → Datenschutz & Sicherheit → „Dennoch öffnen“**
bestätigen:

```bash
xattr -dr com.apple.quarantine /Applications/MacIPMI.app
```

### Neue Version veröffentlichen

```bash
git tag v0.3.0 && git push origin v0.3.0
```

Der Workflow baut die Universal-App, legt das GitHub-Release an und aktualisiert den Cask im Tap
[l151820/homebrew-tap](https://github.com/l151820/homebrew-tap) (über den Deploy-Key im Secret `TAP_DEPLOY_KEY`, einmalig einzurichten mit `scripts/setup-tap-key.sh`).

## Bauen

Funktioniert mit Xcode oder nur mit den Command Line Tools:

```bash
scripts/build-app.sh
open build/MacIPMI.app
```

Beim ersten Verbindungsaufbau fragt macOS, ob MacIPMI auf das lokale Netzwerk zugreifen darf – bitte erlauben.

> Ohne Xcode baut das Skript gegen das macOS-26-SDK, weil SwiftUI ab dem 27er-SDK für `@State` ein
> Compiler-Plugin braucht, das nur Xcode mitbringt.

## Kommandozeile

`ipmi-cli` nutzt dieselbe Bibliothek und eignet sich zum Testen:

```bash
build/ipmi-cli -H 192.168.1.100 caps                  # ohne Login
IPMI_PASSWORD=… build/ipmi-cli -H 192.168.1.100 -U ADMIN info
build/ipmi-cli -H 192.168.1.100 -U ADMIN sensors      # fragt nach dem Passwort
build/ipmi-cli -H 192.168.1.100 -U ADMIN -v power status   # -v zeigt die Pakete
```

Befehle: `caps`, `info`, `power status|on|off|soft|cycle|reset`, `chassis`, `identify [s]`,
`sensors`, `sel [clear]`, `fru`, `lan`, `users`, `fan [standard|full|optimal|heavyio]`,
`kvm [snapshot datei.png]` (Bildschirmfoto über die native Konsole), `kvm console` (siehe unten).

### Konsole im Terminal

```bash
build/ipmi-cli -H 192.168.1.100 -U ADMIN kvm console              # Layout des Servers: de
build/ipmi-cli -H 192.168.1.100 -U ADMIN kvm console --layout us
```

Das Terminal wird selbst zur KVM-Konsole. In iTerm2 (und WezTerm) erscheint das echte Bild über das
Inline-Image-Protokoll, in anderen Terminals eine farbige Blockgrafik (`--mode image|blocks` erzwingt
eine Darstellung). Eingaben gehen an den Server – auch Strg+C. **Strg+]** öffnet das Menü:
`q` beenden · `d` Strg+Alt+Entf · `1`–`6` Strg+Alt+F1–F6 · `]` Strg+] senden. Da ein Terminal Zeichen
statt Tasten liefert, muss `--layout` zum Tastaturlayout des Servers passen.

## Aufbau

- `Sources/IPMIKit` – Protokoll und Befehle (`IPMISession` ist ein Actor, eine UDP-Sitzung pro BMC)
- `Sources/MacIPMI` – SwiftUI-App
- `Sources/ipmi-cli` – Kommandozeilen-Werkzeug
- `Tests/IPMIKitTests` – Selbsttest (`swift run ipmikit-selftest`), u. a. Krypto-Testvektoren und Paket-Roundtrips

## KVM-Konsole

X9-Boards (Nuvoton WPCM450 „Hermon“) sprechen auf TCP 5900 RFB 3.8 mit ATEN-Erweiterungen:
MacIPMI holt über das Webinterface ein Einmal-Token (Login → `url_redirect.cgi?url_name=ikvm&url_type=jwsk`
→ Logout), meldet sich damit per Sicherheitstyp 16 an und dekodiert die Bilddaten (RGB555, Vollbild oder
16×16-Kacheln). Tastatur als USB-HID-Codes, Maus absolut. Protokollbeschreibung nach
[ipmicow](https://github.com/tbbuck/ipmicow) (MIT) und dem noVNC-Fork von kelleyk; eigene Implementierung.

## Noch nicht enthalten

- Serial over LAN (SOL)
- Firmware-Update und virtuelle Medien (bitte über das Webinterface)
