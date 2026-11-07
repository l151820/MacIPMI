import AppKit
import IPMIKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

@MainActor @Observable
final class KVMConsoleModel {
    enum Status: Equatable {
        case idle, minting, connecting, connected, noSignal, closed
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "Bereit"
            case .minting: return "Hole Konsolen-Token vom BMC …"
            case .connecting: return "Verbinde mit der Konsole …"
            case .connected: return "Verbunden"
            case .noSignal: return "Kein Videosignal – Server ausgeschaltet?"
            case .closed: return "Verbindung getrennt"
            case .failed(let m): return m
            }
        }
    }

    let host: HostEntry
    var status: Status = .idle
    var image: CGImage?
    var serverName = ""

    @ObservationIgnored private(set) var session: ATENKVMSession?
    @ObservationIgnored private let password: () -> String

    init(host: HostEntry, password: @escaping () -> String) {
        self.host = host
        self.password = password
    }

    var resolutionText: String {
        guard let image else { return "" }
        return "\(image.width)×\(image.height)"
    }

    func start() async {
        stop()
        status = .minting
        do {
            let params = try await SupermicroWeb.mintKVMConsole(host: host.address, username: host.username,
                                                                password: password())
            status = .connecting
            let s = ATENKVMSession(params: params) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            session = s
            s.start()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        session?.stop()
        session = nil
    }

    private func handle(_ event: ATENKVMSession.Event) {
        switch event {
        case .connecting:
            status = .connecting
        case .connected(_, _, let name):
            serverName = name
            status = .connected
        case .frame(let img):
            image = img
            if status != .connected { status = .connected }
        case .noSignal:
            status = .noSignal
        case .disconnected(let reason):
            session = nil
            status = reason.map { .failed($0) } ?? .closed
        }
    }

    func send(_ usages: [UInt32]) { session?.sendKeyCombination(usages) }

    func saveScreenshot() {
        guard let image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(host.name) \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))).png"
            .replacingOccurrences(of: ":", with: "-")
        guard panel.runModal() == .OK, let url = panel.url,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

// MARK: - Window

struct KVMConsoleWindow: View {
    @Environment(HostStore.self) private var store
    let hostID: UUID?

    var body: some View {
        if let id = hostID, let host = store.hosts.first(where: { $0.id == id }) {
            KVMConsoleView(model: store.connection(for: host).kvmModel(store: store))
        } else {
            ContentUnavailableView("System nicht gefunden", systemImage: "display.trianglebadge.exclamationmark")
        }
    }
}

struct KVMConsoleView: View {
    let model: KVMConsoleModel
    @State private var hasFocus = false

    var body: some View {
        ZStack {
            Color.black
            KVMScreen(model: model, hasFocus: $hasFocus)
            if model.image == nil || model.status != .connected {
                statusOverlay
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle("Konsole – \(model.host.name)")
        .navigationSubtitle(model.status == .connected ? model.resolutionText : model.status.text)
        .toolbar { toolbar }
        .task {
            if model.session == nil, model.status != .connected { await model.start() }
        }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var statusOverlay: some View {
        VStack(spacing: 12) {
            switch model.status {
            case .minting, .connecting:
                ProgressView().controlSize(.large)
            case .noSignal:
                Image(systemName: "powersleep").font(.system(size: 40))
            case .failed, .closed:
                Image(systemName: "exclamationmark.triangle").font(.system(size: 40))
            default:
                EmptyView()
            }
            Text(model.status.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if case .failed = model.status {
                Button("Erneut verbinden") { Task { await model.start() } }
            } else if model.status == .closed {
                Button("Erneut verbinden") { Task { await model.start() } }
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Button("Strg+Alt+Entf") { model.send([HIDKeyMap.leftControl, HIDKeyMap.leftAlt, HIDKeyMap.delete]) }
                Button("Alt+Tab") { model.send([HIDKeyMap.leftAlt, HIDKeyMap.tab]) }
                Button("Alt+F4") { model.send([HIDKeyMap.leftAlt, HIDKeyMap.f(4)]) }
                Button("Windows-Taste") { model.send([HIDKeyMap.leftGUI]) }
                Button("Druck") { model.send([HIDKeyMap.printScreen]) }
                Divider()
                ForEach(1...6, id: \.self) { n in
                    Button("Strg+Alt+F\(n)") { model.send([HIDKeyMap.leftControl, HIDKeyMap.leftAlt, HIDKeyMap.f(n)]) }
                }
            } label: {
                Label("Tasten senden", systemImage: "keyboard")
            }
            .help("Tastenkombination an den Server senden")

            Button { model.saveScreenshot() } label: { Label("Bildschirmfoto", systemImage: "camera") }
                .disabled(model.image == nil)
                .help("Bildschirmfoto speichern")

            Button { Task { await model.start() } } label: { Label("Neu verbinden", systemImage: "arrow.clockwise") }
                .help("Konsole neu verbinden")
        }
    }
}

// MARK: - Screen (AppKit)

struct KVMScreen: NSViewRepresentable {
    let model: KVMConsoleModel
    @Binding var hasFocus: Bool

    func makeNSView(context: Context) -> KVMScreenView {
        let v = KVMScreenView()
        v.model = model
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ v: KVMScreenView, context: Context) {
        v.model = model
        v.setImage(model.image)
    }
}

final class KVMScreenView: NSView {
    weak var model: KVMConsoleModel?
    private var imageSize = CGSize.zero
    private var buttons: UInt8 = 0
    private var pressed: Set<UInt32> = []
    private var lastPointer: (Int, Int) = (-1, -1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setImage(_ img: CGImage?) {
        layer?.contents = img
        if let img { imageSize = CGSize(width: img.width, height: img.height) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.addObserver(self, selector: #selector(releaseAll),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func releaseAll() {
        guard let s = model?.session else { return }
        for u in pressed { s.sendKey(usage: u, down: false) }
        pressed.removeAll()
        if buttons != 0 {
            buttons = 0
            s.sendPointer(x: lastPointer.0, y: lastPointer.1, buttons: 0)
        }
    }

    // MARK: Keyboard

    private func key(_ code: UInt16, down: Bool) {
        guard let usage = HIDKeyMap.usage(forMacKeyCode: code), let s = model?.session else { return }
        if down { pressed.insert(usage) } else { pressed.remove(usage) }
        s.sendKey(usage: usage, down: down)
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }            // the remote OS does its own auto-repeat
        key(event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        key(event.keyCode, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let usage = HIDKeyMap.usage(forMacKeyCode: event.keyCode), let s = model?.session else { return }
        if usage == 0x39 {                       // Caps Lock toggles: tap it
            s.sendKeyCombination([usage])
            return
        }
        guard HIDKeyMap.isModifier(usage) else { return }
        // Each flagsChanged event is exactly one press or release of this physical key.
        let isDown = !pressed.contains(usage)
        if isDown { pressed.insert(usage) } else { pressed.remove(usage) }
        s.sendKey(usage: usage, down: isDown)
    }

    /// Cmd shortcuts: forward everything to the server except Cmd+Q / Cmd+W.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        let chars = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.contains(.command), chars == "q" || chars == "w" { return false }
        if let usage = HIDKeyMap.usage(forMacKeyCode: event.keyCode), let s = model?.session {
            s.sendKey(usage: usage, down: true)
            s.sendKey(usage: usage, down: false)   // keyUp is not delivered while Cmd is held
        }
        return true
    }

    // MARK: Mouse

    private func pointer(_ event: NSEvent) {
        guard imageSize.width > 0, let s = model?.session else { return }
        let p = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        let ox = (bounds.width - w) / 2, oy = (bounds.height - h) / 2
        let x = Int(((p.x - ox) / scale).rounded(.down))
        let y = Int(((p.y - oy) / scale).rounded(.down))
        let cx = min(max(x, 0), Int(imageSize.width) - 1), cy = min(max(y, 0), Int(imageSize.height) - 1)
        lastPointer = (cx, cy)
        s.sendPointer(x: cx, y: cy, buttons: buttons)
    }

    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); buttons |= 1; pointer(e) }
    override func mouseUp(with e: NSEvent) { buttons &= ~1; pointer(e) }
    override func rightMouseDown(with e: NSEvent) { buttons |= 4; pointer(e) }
    override func rightMouseUp(with e: NSEvent) { buttons &= ~4; pointer(e) }
    override func otherMouseDown(with e: NSEvent) { buttons |= 2; pointer(e) }
    override func otherMouseUp(with e: NSEvent) { buttons &= ~2; pointer(e) }
    override func mouseMoved(with e: NSEvent) { pointer(e) }
    override func mouseDragged(with e: NSEvent) { pointer(e) }
    override func rightMouseDragged(with e: NSEvent) { pointer(e) }
    override func otherMouseDragged(with e: NSEvent) { pointer(e) }
}
