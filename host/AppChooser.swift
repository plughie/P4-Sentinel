import SwiftUI

private struct AppEvent: Decodable {
    let type: String
    let source: String
    var app: String?
    var code: Int?
    var request: UInt32?
    var installed: InstalledApps?
}

private struct InstalledApps: Decodable {
    var sentinel: Bool?
    var controller: Bool?
}

@MainActor
private final class ChooserConnection: ObservableObject {
    enum Scene: String { case chooser, sentinel, network, rf, controller }

    @Published private(set) var scene = Scene.chooser
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Connecting over USB…"
    @Published private(set) var sentinelInstalled = false
    @Published private(set) var controllerInstalled = false
    private(set) var scanner: Scanner?
    private(set) var monitor: RFMonitor?

    private var process: Process?
    private var output: Pipe?
    private var input: Pipe?
    private var pending = Data()
    private var expected: Scene?
    private var expectingStatus = false
    private var sequence = UInt32.random(in: 1...1_000_000_000)
    private var deadline: DispatchWorkItem?
    private let decoder = JSONDecoder()
    var canGoBack: Bool { scene != .chooser || (busy && expected != .chooser) }

    func connect() {
        guard process == nil else { return }
        guard let config = SerialLaunchConfiguration.load() else {
            status = "Launch with open-scanner.sh --apps"
            return
        }

        let bridge = Process()
        let output = Pipe()
        let input = Pipe()
        bridge.executableURL = URL(fileURLWithPath: config.python)
        bridge.arguments = [config.bridge, "--port", config.port, "--json", "--commands", "--app-events"]
        bridge.standardInput = input
        bridge.standardOutput = output
        bridge.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                if chunk.isEmpty {
                    self?.disconnected("USB reader stopped")
                } else {
                    self?.receive(chunk)
                }
            }
        }
        do {
            try bridge.run()
            process = bridge
            self.output = output
            self.input = input
            requestRunningApp()
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            status = error.localizedDescription
        }
    }

    func close() {
        deadline?.cancel()
        if process?.isRunning == true { send("apps back") }
        try? input?.fileHandleForWriting.close()
        output?.fileHandleForReading.readabilityHandler = nil
    }

    func returnToChooser() {
        if process?.isRunning == true {
            open(.chooser)
        } else {
            output?.fileHandleForReading.readabilityHandler = nil
            try? input?.fileHandleForWriting.close()
            process = nil
            pending.removeAll()
            connect()
        }
    }

    func open(_ target: Scene) {
        guard process?.isRunning == true else { return }
        if target == .chooser {
            guard !busy || expected != .chooser else { return }
        } else if target == .sentinel || target == .controller {
            guard !busy, ready, scene == .chooser else { return }
        } else {
            guard !busy, ready, scene == .sentinel || scene == .network || scene == .rf else { return }
        }
        let previous = expected ?? scene
        expected = target
        expectingStatus = false
        sequence &+= 1
        busy = true
        switch (previous, target) {
        case (.network, .chooser):
            status = "Stopping network scan…"
        case (.rf, .chooser):
            status = "Releasing tuner…"
        case (_, .sentinel):
            status = "Opening RF Sentinel…"
        case (_, .network):
            status = "Opening Network Scanner…"
        case (_, .rf):
            status = "Opening RF Monitor…"
        case (_, .controller):
            status = "Opening Synesthesia Controller…"
        default:
            status = "Waiting for the dev kit…"
        }
        if target == .chooser {
            ready = false
            scanner = nil
            monitor = nil
            scene = .chooser
        }

        deadline?.cancel()
        let wait = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.busy = false
            self.ready = false
            self.expected = nil
            self.status = "The board did not confirm the switch."
        }
        deadline = wait
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: wait)
        let command: String
        if target == .chooser {
            command = "apps back"
        } else if (target == .sentinel || target == .controller) && scene == .chooser {
            command = "apps \(target.rawValue)"
        } else {
            command = "apps mode \(target.rawValue)"
        }
        send("\(command) \(sequence)")
    }

    private func requestRunningApp() {
        sequence &+= 1
        expected = nil
        expectingStatus = true
        busy = true
        ready = false
        status = "Checking the running app…"
        deadline?.cancel()
        let wait = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.busy = false
            self.expectingStatus = false
            self.status = "The board did not respond."
        }
        deadline = wait
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: wait)
        send("apps status \(sequence)")
    }

    private func disconnected(_ message: String) {
        deadline?.cancel()
        expected = nil
        expectingStatus = false
        ready = false
        busy = false
        if message != "USB reader stopped" || !status.hasPrefix("USB error") {
            status = message
        }
    }

    private func send(_ command: String) {
        do {
            try input?.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        } catch {
            disconnected("USB error: could not send the command")
        }
    }

    private func commandFromApp(_ command: String, scene owner: Scene) {
        if scene == owner, ready, !busy { send(command) }
    }

    private func receive(_ chunk: Data) {
        pending.append(chunk)
        while let end = pending.firstIndex(of: 10) {
            let line = pending[..<end]
            if let event = try? decoder.decode(AppEvent.self, from: line) {
                if event.source == "chooser" {
                    apply(event)
                } else if ready, !busy {
                    let record = Data(pending[...end])
                    if event.source == "network", scene == .network { scanner?.receive(record) }
                    if event.source == "rf", scene == .rf { monitor?.read(record) }
                }
            } else if let message = String(data: line, encoding: .utf8),
                      message.contains("SerialException:") || message.hasPrefix("Serial command failed:") {
                disconnected("USB error: \(message)")
            }
            pending.removeSubrange(...end)
        }
    }

    private func apply(_ event: AppEvent) {
        guard event.request == sequence, expected != nil || expectingStatus else { return }
        if event.type == "error" {
            deadline?.cancel()
            expected = nil
            expectingStatus = false
            busy = false
            status = "The board could not switch apps (\(event.code ?? 0))."
            return
        }
        guard event.type == "scene", let value = event.app, let next = Scene(rawValue: value),
              expectingStatus || next == expected else { return }
        deadline?.cancel()
        expected = nil
        expectingStatus = false
        switch next {
        case .chooser:
            scanner = nil
            monitor = nil
            if let installed = event.installed {
                sentinelInstalled = installed.sentinel ?? false
                controllerInstalled = installed.controller ?? false
            }
        case .sentinel:
            scanner = nil
            monitor = nil
        case .network:
            scanner = Scanner { [weak self] in self?.commandFromApp($0, scene: .network) }
        case .rf:
            monitor = RFMonitor { [weak self] in self?.commandFromApp($0, scene: .rf) }
        case .controller:
            break
        }
        ready = true
        busy = false
        status = "ESP32-P4 · USB"
        scene = next
    }
}

private struct ChooserView: View {
    @StateObject private var board = ChooserConnection()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if board.canGoBack {
                    Button { board.returnToChooser() } label: {
                        Label("Back to Apps", systemImage: "chevron.left")
                    }
                    .keyboardShortcut(.cancelAction)
                    if board.scene == .network || board.scene == .rf {
                        Button { board.open(.sentinel) } label: {
                            Label("Sentinel Tools", systemImage: "square.grid.2x2")
                        }
                    }
                } else {
                    Text("P4 Sentinel").font(.headline)
                }
                Spacer()
                if board.busy { ProgressView().controlSize(.small) }
                Text(board.status).foregroundStyle(.secondary).lineLimit(2)
                if board.scene == .chooser && !board.ready && !board.busy {
                    Button("Retry") { board.returnToChooser() }
                }
            }
            .padding(14)
            Divider()
            switch board.scene {
            case .chooser:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Apps").font(.largeTitle.bold())
                    appButton("RF Sentinel", detail: "Wi-Fi, Bluetooth LE, and receive-only RF",
                              icon: "dot.radiowaves.left.and.right", scene: .sentinel,
                              disabled: !board.sentinelInstalled)
                    if board.controllerInstalled {
                        appButton("Synesthesia Controller", detail: "Motion controller on device display",
                                  icon: "hand.draw", scene: .controller)
                    } else {
                        Label("Synesthesia Controller · slot reserved", systemImage: "hand.draw")
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .frame(maxWidth: 400)
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .network:
                if let scanner = board.scanner {
                    ScannerView(scanner: scanner).disabled(board.busy || !board.ready)
                }
            case .rf:
                if let monitor = board.monitor {
                    RFView(monitor: monitor).disabled(board.busy || !board.ready)
                }
            case .sentinel:
                VStack(alignment: .leading, spacing: 12) {
                    Text("RF Sentinel").font(.largeTitle.bold())
                    Text("Choose a receive-only tool. Changing tools restarts into the same Sentinel slot.")
                        .foregroundStyle(.secondary)
                    appButton("Network Scanner", detail: "Wi-Fi and Bluetooth LE",
                              icon: "wifi", scene: .network)
                    appButton("RF Monitor", detail: "RTL-SDR receive-only detectors",
                              icon: "waveform", scene: .rf)
                }
                .frame(maxWidth: 440)
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .controller:
                VStack(spacing: 10) {
                    Image(systemName: "hand.draw").font(.system(size: 42)).foregroundStyle(.secondary)
                    Text("Synesthesia Controller is running").font(.title2.bold())
                    Text("Use the device display to control the motion application.")
                        .foregroundStyle(.secondary)
                    Text("Back to Apps returns to the system chooser.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 450)
        .onAppear { board.connect() }
        .onDisappear { board.close() }
    }

    private func appButton(_ name: String, detail: String, icon: String,
                           scene: ChooserConnection.Scene, disabled: Bool = false) -> some View {
        Button { board.open(scene) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).frame(width: 32)
                VStack(alignment: .leading) {
                    Text(name).font(.headline)
                    Text(detail).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        .disabled(board.busy || !board.ready || disabled)
    }
}

private final class ChooserDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AppChooser: App {
    @NSApplicationDelegateAdaptor(ChooserDelegate.self) private var delegate

    var body: some Scene {
        Window("P4 Sentinel Apps", id: "chooser") { ChooserView() }
            .defaultSize(width: 850, height: 540)
    }
}
