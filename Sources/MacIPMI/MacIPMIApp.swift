import AppKit
import SwiftUI

@main
struct MacIPMIApp: App {
    @State private var store = HostStore()

    init() {
        // Needed when started via `swift run` (no app bundle).
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            // Outside the app bundle (`swift run`) there is no icon from Info.plist.
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../Resources/icon_1024.png").standardized
            if Bundle.main.bundleIdentifier == nil, let img = NSImage(contentsOf: url) {
                NSApplication.shared.applicationIconImage = img
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("MacIPMI") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neues System …") { store.showAddSheet = true }
                    .keyboardShortcut("n")
            }
        }

        WindowGroup("Remote-Konsole", id: "kvm", for: UUID.self) { $hostID in
            KVMConsoleWindow(hostID: hostID)
                .environment(store)
        }
        .defaultSize(width: 1040, height: 820)
    }
}
