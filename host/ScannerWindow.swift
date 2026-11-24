import SwiftUI

private struct ScanEvent: Decodable {
    let type: String
    var radio: String?
    var bssid: String?
    var ssid_hex: String?
    var channel: Int?
    var rssi: Int?
    var auth_mode: String?
    var pairwise_cipher: String?
    var group_cipher: String?
    var channel_width: String?
    var secondary_channel: String?
    var wps: Bool?
    var supported_standards: [String]?
    var raw_information_elements_available: Bool?
    var address: String?
    var address_type: Int?
    var name_hex: String?
    var adv_hex: String?
    var adv_truncated: Bool?
    var count: Int?
    var code: Int?
}

private struct Signal: Identifiable {
    let id: String
    let name: String
    let address: String
    let strength: Int
    var channel: Int? = nil
    var networkNameHidden = false
    var advertisementHex: String? = nil
    var advertisementTruncated = false
    var isSimulated = false
    var lastSeen: Date
    var strengthHistory = SignalStrengthHistory()
    var authMode: String? = nil
    var pairwiseCipher: String? = nil
    var groupCipher: String? = nil
    var channelWidth: String? = nil
    var secondaryChannel: String? = nil
    var wps: Bool? = nil
    var supportedStandards: [String]? = nil
    var rawInformationElementsAvailable: Bool? = nil
}

private struct TrackerPayloadObservation: Identifiable {
    let fingerprint: String
    var firstSeen: Date
    var lastSeen: Date
    var lastRSSI: Int
    var addresses: Set<String>
    var sampleHistory = SignalStrengthHistory()
    var sightingCount = 0

    var id: String { fingerprint }

    init(fingerprint: String, address: String, rssi: Int, at time: Date) {
        self.fingerprint = fingerprint
        firstSeen = time
        lastSeen = time
        lastRSSI = rssi
        addresses = [address]
        record(address: address, rssi: rssi, at: time)
    }

    mutating func record(address: String, rssi: Int, at time: Date) {
        lastSeen = time
        lastRSSI = rssi
        addresses.insert(address)
        sightingCount += 1
        sampleHistory.record(rssi, at: time)
    }
}

private struct DetectionAlert: Identifiable {
    let id: String
    let category: String
    let observedAs: String
    let evidence: String
    let confidence: String
    let strength: Int
    let severity: DetectionAlertSeverity
    let lastSeen: Date
}

private enum DetectionAlertSeverity {
    case red
    case yellow

    var priority: Int { self == .red ? 1 : 0 }
    var color: Color { self == .red ? .red : .yellow }
    var foreground: Color { self == .red ? .white : .black }
    var heading: String { self == .red ? "POSSIBLE MATCH" : "VERIFY SIGNATURE" }
}

final class Scanner: ObservableObject {
    @Published fileprivate var wifi: [String: Signal] = [:]
    @Published fileprivate var ble: [String: Signal] = [:]
    @Published fileprivate var trackerPayloads: [String: TrackerPayloadObservation] = [:]
    @Published fileprivate var freshnessNow = Date()
    @Published var wifiStatus = "Waiting for scan"
    @Published var bleStatus = "Waiting for scan"
    @Published var connection = "Connecting over USB…"
    @Published private(set) var ready = false
    @Published private(set) var activeRadio: String?
    @Published private(set) var autoScanEnabled = true

    private var reader: Process?
    private var output: Pipe?
    private var input: Pipe?
    private var pending = Data()
    private var deadline: DispatchWorkItem?
    private var freshnessTimer: Timer?
    private var nextAutoRadio = "wifi"
    private var nextScanWork: DispatchWorkItem?
    private var started = false
    private let decoder = JSONDecoder()
    private let sendThroughChooser: ((String) -> Void)?
    private var trackerProcessingEnabled = true
    fileprivate var sightingStore: DeviceAnnotationStore?

    init(sendThroughChooser: ((String) -> Void)? = nil) {
        self.sendThroughChooser = sendThroughChooser
    }

    func start() {
        startFreshnessTimer()
        if sendThroughChooser != nil {
            waitForBoard()
            return
        }
        guard reader == nil else { return }
        guard let config = SerialLaunchConfiguration.load() else {
            connection = "Launch with open-scanner.sh"
            return
        }
        let process = Process()
        let pipe = Pipe()
        let commands = Pipe()
        process.executableURL = URL(fileURLWithPath: config.python)
        process.arguments = [config.bridge, "--port", config.port, "--json", "--commands"]
        process.standardInput = commands
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
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
            try process.run()
            reader = process
            output = pipe
            input = commands
            waitForBoard()
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            connection = error.localizedDescription
        }
    }

    func stop() {
        deadline?.cancel()
        nextScanWork?.cancel()
        freshnessTimer?.invalidate()
        freshnessTimer = nil
        output?.fileHandleForReading.readabilityHandler = nil
        if let reader, reader.isRunning { reader.terminate() }
    }

    func setTrackerProcessingEnabled(_ enabled: Bool) {
        trackerProcessingEnabled = enabled
        if !enabled { trackerPayloads.removeAll() }
    }

    private func startFreshnessTimer() {
        guard freshnessTimer == nil else { return }
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            self.freshnessNow = now
            self.wifi = self.wifi.filter { SignalFreshness.isFresh(lastSeen: $0.value.lastSeen, at: now) }
            self.ble = self.ble.filter { SignalFreshness.isFresh(lastSeen: $0.value.lastSeen, at: now) }
            self.trackerPayloads = self.trackerPayloads.filter {
                now.timeIntervalSince($0.value.lastSeen) < TrackerDetector.keyRotationInterval
            }
        }
    }

    func toggleAutoScan() {
        autoScanEnabled.toggle()
        nextScanWork?.cancel()
        nextScanWork = nil
        if autoScanEnabled, ready, activeRadio == nil {
            refresh(nextAutoRadio)
        }
    }

    func refresh(_ radio: String) {
        guard ready, activeRadio == nil else { return }
        activeRadio = radio
        started = false
        setStatus(radio, "Starting scan…")
        scheduleTimeout(after: 30) { [weak self] in
            guard let self else { return }
            self.setStatus(radio, "Scan timed out")
            self.activeRadio = nil
            self.autoScanEnabled = false
            self.waitForBoard()
        }
        send("scan \(radio)")
    }

    private func waitForBoard() {
        ready = false
        connection = "Waiting for scanner over USB…"
        scheduleTimeout(after: 45) { [weak self] in
            self?.disconnected("Scanner did not respond over USB")
        }
        send("status")
    }

    private func scheduleTimeout(after seconds: Double, action: @escaping () -> Void) {
        deadline?.cancel()
        let work = DispatchWorkItem(block: action)
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func send(_ command: String) {
        if let sendThroughChooser {
            sendThroughChooser(command)
            return
        }
        guard let input else { return }
        do {
            try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        } catch {
            disconnected("Could not send USB command")
        }
    }

    private func disconnected(_ message: String) {
        if ready || activeRadio != nil || connection == "Waiting for scanner over USB…" {
            connection = message
        }
        if let radio = activeRadio { setStatus(radio, "Scan interrupted") }
        activeRadio = nil
        ready = false
        autoScanEnabled = false
        nextScanWork?.cancel()
        deadline?.cancel()
    }

    private func setStatus(_ radio: String, _ message: String) {
        if radio == "wifi" { wifiStatus = message }
        if radio == "ble" { bleStatus = message }
    }

    private func finish(_ radio: String, status: String) {
        setStatus(radio, status)
        guard activeRadio == radio, started else { return }
        activeRadio = nil
        deadline?.cancel()
        nextAutoRadio = radio == "wifi" ? "ble" : "wifi"
        if status == "Scan complete" { scheduleNextAutoScan() }
        else { autoScanEnabled = false }
    }

    private func scheduleNextAutoScan() {
        guard autoScanEnabled else { return }
        let radio = nextAutoRadio
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.autoScanEnabled, self.ready, self.activeRadio == nil else { return }
            self.refresh(radio)
        }
        nextScanWork?.cancel()
        nextScanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func receive(_ chunk: Data) {
        pending.append(chunk)
        while let end = pending.firstIndex(of: 10) {
            let line = pending[..<end]
            if let event = try? decoder.decode(ScanEvent.self, from: line) {
                apply(event)
            } else if let message = String(data: line, encoding: .utf8),
                      message.contains("SerialException:") || message.contains("OSError:")
                        || message.hasPrefix("Serial command failed:") {
                disconnected(message)
            }
            pending.removeSubrange(...end)
        }
    }

    private func apply(_ event: ScanEvent) {
        switch event.type {
        case "scanner_ready":
            deadline?.cancel()
            connection = "ESP32-P4 · USB"
            ready = true
            if autoScanEnabled, activeRadio == nil { refresh(nextAutoRadio) }
        case "scan_start":
            guard let radio = event.radio else { return }
            if activeRadio == radio { started = true }
            setStatus(radio, "Scanning…")
        case "wifi_ap":
            guard let address = event.bssid, let strength = event.rssi else { return }
            let now = Date()
            sightingStore?.updateSighting(radio: "Wi-Fi", address: address, at: now)
            var history = wifi[address]?.strengthHistory ?? SignalStrengthHistory()
            history.record(strength, at: now)
            wifi[address] = Signal(id: address, name: label(event.ssid_hex, fallback: "Hidden SSID"),
                                   address: address, strength: strength, channel: event.channel,
                                   networkNameHidden: event.ssid_hex?.isEmpty ?? true,
                                   lastSeen: now, strengthHistory: history,
                                   authMode: event.auth_mode, pairwiseCipher: event.pairwise_cipher,
                                   groupCipher: event.group_cipher, channelWidth: event.channel_width,
                                   secondaryChannel: event.secondary_channel, wps: event.wps,
                                   supportedStandards: event.supported_standards,
                                   rawInformationElementsAvailable: event.raw_information_elements_available)
        case "ble_advertisement":
            guard let address = event.address, let strength = event.rssi else { return }
            let id = "\(address)/\(event.address_type ?? 0)"
            let name = label(event.name_hex, fallback: ble[id]?.name ?? "Unnamed device")
            let now = Date()
            sightingStore?.updateSighting(radio: "Bluetooth LE", address: address, at: now)
            var history = ble[id]?.strengthHistory ?? SignalStrengthHistory()
            history.record(strength, at: now)
            ble[id] = Signal(id: id, name: name, address: address, strength: strength,
                             advertisementHex: event.adv_hex,
                             advertisementTruncated: event.adv_truncated ?? false,
                             lastSeen: now, strengthHistory: history)
            if trackerProcessingEnabled {
                let advertisement = ParsedBLEAdvertisement(hex: event.adv_hex,
                                                           wasTruncated: event.adv_truncated ?? false)
                if let fingerprint = TrackerDetector.payloadFingerprint(companyID: advertisement.companyID,
                                                                         manufacturerPayload: advertisement.manufacturerPayload) {
                    if var observation = trackerPayloads[fingerprint] {
                        observation.record(address: address, rssi: strength, at: now)
                        trackerPayloads[fingerprint] = observation
                    } else {
                        trackerPayloads[fingerprint] = TrackerPayloadObservation(
                            fingerprint: fingerprint, address: address, rssi: strength, at: now)
                    }
                }
            }
        case "scan_complete":
            if let radio = event.radio { finish(radio, status: "Scan complete") }
        case "scan_error":
            if let radio = event.radio { finish(radio, status: "Scan failed (\(event.code ?? 0))") }
        default: break
        }
    }

    private func label(_ hex: String?, fallback: String) -> String {
        guard let hex, !hex.isEmpty, hex.utf8.count.isMultiple(of: 2) else { return fallback }
        let characters = Array(hex)
        let bytes = stride(from: 0, to: characters.count - 1, by: 2).compactMap {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct ScannerView: View {
    @StateObject private var scanner: Scanner
    @StateObject private var watchlist: BLEWatchlistStore
    @StateObject private var annotations: DeviceAnnotationStore
    @State private var selection = "Wi-Fi"
    @State private var selectedSignalID: String?
    @State private var searchText = ""
    @State private var minimumSignal = -100.0
    @State private var showWatchlist = false
    @State private var showFavorites = false
    @State private var showWiFiChannelView = false
    @AppStorage("SynesthesiaMotionController.TrackerDetectionEnabled") private var trackerDetectionEnabled = true
    @State private var showTrackerSimulation = false

    init(scanner: Scanner = Scanner()) {
        _scanner = StateObject(wrappedValue: scanner)
        _watchlist = StateObject(wrappedValue: BLEWatchlistStore())
        _annotations = StateObject(wrappedValue: DeviceAnnotationStore())
    }

    var body: some View {
        let isWiFi = selection == "Wi-Fi"
        let simulatedTracker = showTrackerSimulation ? trackerDemoSignal : nil
        let allSignals = isWiFi ? Array(scanner.wifi.values) :
            Array(scanner.ble.values) + (simulatedTracker.map { [$0] } ?? [])
        let allEntries = allSignals.sorted {
            $0.strength == $1.strength ? $0.id < $1.id : $0.strength > $1.strength
        }
        let searchTerm = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = allEntries.filter(matchesFilters)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Network Scanner").font(.title2.bold())
                Spacer()
                Button("Favorites · \(annotations.annotations.count)") { showFavorites = true }
                Button("Watchlist · \(watchlist.rules.count)") { showWatchlist = true }
                if selection == "Bluetooth LE" {
                    Toggle("Trackers", isOn: $trackerDetectionEnabled)
                        .toggleStyle(.switch)
                        .help("Show or hide tracker-protocol labels and alerts. BLE scanning continues.")
                    Button(showTrackerSimulation ? "Clear Demo" : "Simulate Tracker") {
                        showTrackerSimulation.toggle()
                        if showTrackerSimulation { selectedSignalID = "SIMULATED-FIND-MY" }
                    }
                }
                Text(scanner.connection).foregroundStyle(.secondary).lineLimit(2)
            }
            if let alert = detectionAlert {
                DetectionAlertBanner(alert: alert, now: scanner.freshnessNow)
            }
            Picker("Radio", selection: $selection) {
                Text("Wi-Fi").tag("Wi-Fi")
                Text("Bluetooth LE").tag("Bluetooth LE")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if isWiFi {
                HStack(spacing: 8) {
                    Label("Wi-Fi Remote ID unavailable on this scan", systemImage: "info.circle")
                        .font(.callout.weight(.semibold))
                    Text("This path lists access points only; it does not expose Remote ID beacon frames or NAN service data. This does not mean no Wi-Fi Remote ID is present.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Text(isWiFi ? scanner.wifiStatus : scanner.bleStatus)
                Spacer()
                Text("Showing \(entries.count) of \(allEntries.count) \(isWiFi ? "networks" : "devices")")
                if isWiFi {
                    Button("Channels") { showWiFiChannelView = true }
                        .disabled(allEntries.isEmpty)
                }
                Button("Refresh") { scanner.refresh(isWiFi ? "wifi" : "ble") }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!scanner.ready || scanner.activeRadio != nil)
                Button(scanner.autoScanEnabled ? "Pause Auto" : "Resume Auto") {
                    scanner.toggleAutoScan()
                }
                .disabled(!scanner.ready)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(isWiFi ? "Filter by name or address" : "Filter by name, address, or signature",
                          text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(isWiFi ? "Filter by name or address" : "Filter by name, address, or detector signature")
                Button("Clear Filters") {
                    searchText = ""
                    minimumSignal = -100
                }
                .disabled(searchTerm.isEmpty && minimumSignal <= -100)
            }
            HStack(spacing: 12) {
                Text("Minimum signal")
                Slider(value: $minimumSignal, in: -100 ... -30, step: 5)
                    .accessibilityLabel("Minimum signal strength")
                Text("\(Int(minimumSignal)) dBm")
                    .monospacedDigit()
                    .frame(width: 65, alignment: .trailing)
            }
            .font(.callout)
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(isWiFi ? "Network" : "Device")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Address").frame(width: 150, alignment: .leading)
                        if isWiFi { Text("Channel").frame(width: 55, alignment: .leading) }
                        Text("Signal").frame(width: 80, alignment: .leading)
                        Text("Seen").frame(width: 75, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 34)

                    Divider()

                    LazyVStack(spacing: 1) {
                        ForEach(entries) { entry in
                            Button {
                                selectedSignalID = entry.id
                            } label: {
                                HStack(spacing: 8) {
                                    Text(entry.name)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if annotations.isFavorite(radio: isWiFi ? "Wi-Fi" : "Bluetooth LE",
                                                              address: entry.address) {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.yellow)
                                            .help("Favorited with a saved note")
                                    }
                                    if entry.isSimulated {
                                        Text("SIMULATED")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.orange)
                                    } else if isVehicleGroupMember(entry, isWiFi: isWiFi) {
                                        Text("POSSIBLE VEHICLE GROUP")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.yellow)
                                    } else if let glasses = glassMatch(for: entry) {
                                        Text(glasses.category.contains("Meta device") ? "META DEVICE CLUE" : "POSSIBLE GLASSES")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.yellow)
                                    } else if skimmerMatch(for: entry) != nil {
                                        Text("SERIAL MODULE CLUE")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.yellow)
                                    } else if trackerMatch(for: entry) != nil {
                                        Text("TRACKER SIGNAL")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.orange)
                                    }
                                    Text(entry.address)
                                        .lineLimit(1)
                                        .frame(width: 150, alignment: .leading)
                                    if isWiFi {
                                        Text(entry.channel.map(String.init) ?? "")
                                            .frame(width: 55, alignment: .leading)
                                    }
                                    Text("\(entry.strength) dBm")
                                        .monospacedDigit()
                                        .frame(width: 80, alignment: .leading)
                                    Text(SignalFreshness.ageLabel(lastSeen: entry.lastSeen, at: scanner.freshnessNow))
                                        .monospacedDigit()
                                        .frame(width: 75, alignment: .leading)
                                }
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                                .contentShape(Rectangle())
                                .background(selectedSignalID == entry.id ? Color.accentColor.opacity(0.55) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(entry.name), \(entry.address), \(entry.strength) dBm")
                            .accessibilityValue(selectedSignalID == entry.id ? "Selected" : "")
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                }
            }
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
            .frame(minHeight: 140, maxHeight: selectedDetailVisible ? 190 : .infinity)
            if isWiFi, let selectedWiFiSignal {
                ScrollView {
                    WiFiNetworkDetails(signal: selectedWiFiSignal, watchlist: watchlist,
                                       annotations: annotations,
                                       now: scanner.freshnessNow,
                                       vehicleGroupEvidence: vehicleGroupEvidence(for: "wifi:\(selectedWiFiSignal.id)"))
                }
                .frame(maxHeight: 220)
            } else if let selectedBLESignal {
                ScrollView {
                    BLEAdvertisementDetails(signal: selectedBLESignal, watchlist: watchlist,
                                             annotations: annotations,
                                             now: scanner.freshnessNow,
                                             trackerDetectionEnabled: trackerDetectionEnabled,
                                             trackerPayloads: scanner.trackerPayloads,
                                             vehicleGroupEvidence: vehicleGroupEvidence(for: "ble:\(selectedBLESignal.id)"))
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(16)
        .frame(minWidth: 580, minHeight: 420)
        .onChange(of: selection) { _, _ in selectedSignalID = nil }
        .onChange(of: searchText) { _, _ in clearFilteredSelection() }
        .onChange(of: minimumSignal) { _, _ in clearFilteredSelection() }
        .onAppear {
            scanner.setTrackerProcessingEnabled(trackerDetectionEnabled)
            scanner.sightingStore = annotations
            scanner.start()
        }
        .onChange(of: trackerDetectionEnabled) { _, enabled in
            scanner.setTrackerProcessingEnabled(enabled)
        }
        .onDisappear {
            scanner.sightingStore = nil
            scanner.stop()
        }
        .sheet(isPresented: $showWatchlist) {
            WatchlistManagerView(store: watchlist)
        }
        .sheet(isPresented: $showFavorites) {
            DeviceFavoritesView(store: annotations)
        }
        .sheet(isPresented: $showWiFiChannelView) {
            WiFiChannelActivityView(signals: Array(scanner.wifi.values))
                .padding(20)
                .frame(minWidth: 640, minHeight: 300)
        }
    }

    private func matchesFilters(_ signal: Signal) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesText = query.isEmpty
            || signal.name.localizedCaseInsensitiveContains(query)
            || signal.address.localizedCaseInsensitiveContains(query)
        let matchesTracker = trackerMatch(for: signal).map {
            query.isEmpty || query.localizedCaseInsensitiveContains("tracker")
                || $0.category.localizedCaseInsensitiveContains(query)
        } ?? false
        let matchesGlasses = glassMatch(for: signal).map {
            query.isEmpty || $0.category.localizedCaseInsensitiveContains(query)
                || $0.evidence.contains { $0.localizedCaseInsensitiveContains(query) }
        } ?? false
        let matchesModule = skimmerMatch(for: signal).map {
            query.isEmpty || query.localizedCaseInsensitiveContains("skimmer")
                || query.localizedCaseInsensitiveContains("serial")
                || $0.evidence.contains { $0.localizedCaseInsensitiveContains(query) }
        } ?? false
        let matchesVehicleGroup = vehicleGroupEvidence(for: "ble:\(signal.id)").map {
            query.isEmpty || query.localizedCaseInsensitiveContains("vehicle")
                || query.localizedCaseInsensitiveContains("fleet")
                || $0.localizedCaseInsensitiveContains(query)
        } ?? false
        return (matchesText || matchesTracker || matchesGlasses || matchesModule || matchesVehicleGroup)
            && Double(signal.strength) >= minimumSignal
    }

    private func clearFilteredSelection() {
        guard let selectedSignalID else { return }
        if showTrackerSimulation, selectedSignalID == trackerDemoSignal.id {
            if !matchesFilters(trackerDemoSignal) { self.selectedSignalID = nil }
            return
        }
        let signals = selection == "Wi-Fi" ? scanner.wifi : scanner.ble
        if let signal = signals[selectedSignalID], !matchesFilters(signal) {
            self.selectedSignalID = nil
        }
    }

    private var selectedBLESignal: Signal? {
        guard selection == "Bluetooth LE", let selectedSignalID else { return nil }
        if showTrackerSimulation, selectedSignalID == trackerDemoSignal.id { return trackerDemoSignal }
        return scanner.ble[selectedSignalID]
    }

    private var trackerDemoSignal: Signal {
        var history = SignalStrengthHistory()
        let values = [-74, -71, -76, -68, -64, -70, -61, -58, -62, -55, -60, -58]
        let now = scanner.freshnessNow
        for (index, rssi) in values.enumerated() {
            history.record(rssi, at: now.addingTimeInterval(TimeInterval(index - values.count + 1) * 5))
        }
        return Signal(id: "SIMULATED-FIND-MY", name: "Simulated Find My broadcast",
               address: "SIMULATED", strength: -58,
               advertisementHex: TrackerDetector.simulatedAdvertisement,
               isSimulated: true, lastSeen: now, strengthHistory: history)
    }

    private var selectedWiFiSignal: Signal? {
        guard selection == "Wi-Fi", let selectedSignalID else { return nil }
        return scanner.wifi[selectedSignalID]
    }

    private var selectedDetailVisible: Bool {
        selectedWiFiSignal != nil || selectedBLESignal != nil
    }

    private var vehicleCorrelationGroup: VehicleCorrelationGroup? {
        var candidates: [VehicleCorrelationCandidate] = []
        for signal in scanner.wifi.values {
            guard let match = PublicSafetyDetector.wifiMatch(bssid: signal.address) else { continue }
            candidates.append(VehicleCorrelationCandidate(id: "wifi:\(signal.id)", label: signal.name,
                                                           signature: match.category,
                                                           strengthHistory: signal.strengthHistory,
                                                           lastSeen: signal.lastSeen))
        }
        for signal in scanner.ble.values {
            let advertisement = ParsedBLEAdvertisement(hex: signal.advertisementHex,
                                                       wasTruncated: signal.advertisementTruncated)
            guard let match = PublicSafetyDetector.bluetoothMatch(name: signal.name,
                                                                  companyID: advertisement.companyID,
                                                                  serviceUUIDs: advertisement.serviceUUIDs) else { continue }
            candidates.append(VehicleCorrelationCandidate(id: "ble:\(signal.id)", label: signal.name,
                                                           signature: match.category,
                                                           strengthHistory: signal.strengthHistory,
                                                           lastSeen: signal.lastSeen))
        }
        return VehicleCorrelationDetector.group(from: candidates, at: scanner.freshnessNow)
    }

    private func vehicleGroupEvidence(for candidateID: String) -> String? {
        guard let group = vehicleCorrelationGroup,
              group.first.id == candidateID || group.second.id == candidateID else { return nil }
        return group.evidence
    }

    private func isVehicleGroupMember(_ signal: Signal, isWiFi: Bool) -> Bool {
        vehicleGroupEvidence(for: "\(isWiFi ? "wifi" : "ble"):\(signal.id)") != nil
    }

    private var detectionAlert: DetectionAlert? {
        var alerts: [DetectionAlert] = []
        for signal in scanner.wifi.values {
            var signatureCategories: [String] = []
            if let evidence = FlockDetector.wifiEvidence(ssid: signal.name) {
                signatureCategories.append("Possible Flock-related device")
                alerts.append(DetectionAlert(id: "flock-wifi-\(signal.id)", category: "Possible Flock-related device",
                                             observedAs: "Wi-Fi · \(signal.name)", evidence: evidence.joined(separator: "; "),
                                             confidence: DetectionConfidence.strongSignature,
                                             strength: signal.strength, severity: .red, lastSeen: signal.lastSeen))
            }
            if let evidence = BodyCameraDetector.wifiEvidence(ssid: signal.name) {
                signatureCategories.append("Possible body-worn camera")
                alerts.append(DetectionAlert(id: "bodycam-wifi-\(signal.id)", category: "Possible body-worn camera",
                                             observedAs: "Wi-Fi · \(signal.name)", evidence: evidence.joined(separator: "; "),
                                             confidence: DetectionConfidence.strongSignature,
                                             strength: signal.strength, severity: .red, lastSeen: signal.lastSeen))
            }
            if let match = PublicSafetyDetector.wifiMatch(bssid: signal.address) {
                signatureCategories.append(match.category)
                alerts.append(DetectionAlert(id: "public-safety-wifi-\(signal.id)", category: match.category,
                                             observedAs: "Wi-Fi · \(signal.name)",
                                             evidence: match.evidence.joined(separator: "; "),
                                             confidence: match.confidence,
                                             strength: signal.strength, severity: .yellow, lastSeen: signal.lastSeen))
            }
            alerts += watchedAlerts(kind: .wifiName, value: signal.name,
                                     observedAs: "Wi-Fi · \(signal.name)", signal: signal)
            alerts += watchedAlerts(kind: .wifiAddress, value: signal.address,
                                     observedAs: "Wi-Fi · \(signal.name)", signal: signal)
            alerts += watchedSignatureAlerts(signatureCategories, observedAs: "Wi-Fi · \(signal.name)", signal: signal)
        }
        for signal in scanner.ble.values {
            var signatureCategories: [String] = []
            let advertisement = ParsedBLEAdvertisement(hex: signal.advertisementHex,
                                                       wasTruncated: signal.advertisementTruncated)
            if trackerDetectionEnabled,
               let tracker = TrackerDetector.bluetoothMatch(companyID: advertisement.companyID,
                                                            manufacturerPayload: advertisement.manufacturerPayload) {
                let payloadObservation = TrackerDetector.payloadFingerprint(
                    companyID: advertisement.companyID,
                    manufacturerPayload: advertisement.manufacturerPayload
                ).flatMap { scanner.trackerPayloads[$0] }
                let payloadEvidence: String
                if let payloadObservation {
                    payloadEvidence = "Payload fingerprint \(payloadObservation.fingerprint.prefix(16)) · " +
                        "\(payloadObservation.sightingCount) sightings across \(payloadObservation.addresses.count) BLE address(es)"
                } else {
                    payloadEvidence = "First exact-payload observation in this session"
                }
                alerts.append(DetectionAlert(id: "tracker-\(signal.id)", category: tracker.category,
                                             observedAs: "Bluetooth LE · \(signal.name)",
                                             evidence: "\(tracker.evidence); \(payloadEvidence)",
                                             confidence: tracker.confidence,
                                             strength: signal.strength, severity: .yellow, lastSeen: signal.lastSeen))
            }
            if let drone = DroneIDDetector.decode(serviceData: advertisement.serviceData16) {
                alerts.append(DetectionAlert(id: "droneid-\(signal.id)-\(drone.messageType)",
                                             category: "Possible Remote ID drone",
                                             observedAs: "Bluetooth LE · \(signal.name)",
                                             evidence: "\(drone.messageType) · \(drone.fields.joined(separator: "; "))",
                                             confidence: "Valid Remote ID framing · broadcast identity is not independently verified",
                                             strength: signal.strength, severity: .yellow, lastSeen: signal.lastSeen))
            }
            if let glasses = SmartGlassesDetector.bluetoothMatch(
                name: signal.name, companyID: advertisement.companyID,
                manufacturerPayload: advertisement.manufacturerPayload,
                serviceUUIDs: advertisement.serviceUUIDs
            ) {
                signatureCategories.append(glasses.category)
                alerts.append(DetectionAlert(id: "glasses-\(signal.id)", category: glasses.category,
                                             observedAs: "Bluetooth LE · \(signal.name)",
                                             evidence: glasses.evidence.joined(separator: "; "),
                                             confidence: glasses.confidence,
                                             strength: signal.strength, severity: .yellow, lastSeen: signal.lastSeen))
            }
            if let module = SkimmerDetector.bluetoothMatch(name: signal.name,
                                                           serviceUUIDs: advertisement.serviceUUIDs) {
                signatureCategories.append(module.category)
                alerts.append(DetectionAlert(id: "serial-module-\(signal.id)", category: module.category,
                                             observedAs: "Bluetooth LE · \(signal.name)",
                                             evidence: module.evidence.joined(separator: "; "),
                                             confidence: module.confidence,
                                             strength: signal.strength, severity: .yellow, lastSeen: signal.lastSeen))
            }
            if let ravenEvidence = FlockDetector.ravenAudioSensorEvidence(
                serviceUUIDs: advertisement.serviceUUIDs
            ) {
                signatureCategories.append("Possible Flock Raven audio sensor")
                alerts.append(DetectionAlert(id: "flock-raven-\(signal.id)",
                                             category: "Possible Flock Raven audio sensor",
                                             observedAs: "Bluetooth LE · \(signal.name)",
                                             evidence: ravenEvidence.joined(separator: "; "),
                                             confidence: DetectionConfidence.strongSignature,
                                             strength: signal.strength, severity: .red, lastSeen: signal.lastSeen))
            }
            if let evidence = FlockDetector.bluetoothEvidence(
                name: signal.name, companyID: advertisement.companyID,
                manufacturerPayload: advertisement.manufacturerPayload,
                serviceUUIDs: advertisement.serviceUUIDs
            )?.filter({ !$0.contains("Raven short ID") }), !evidence.isEmpty {
                signatureCategories.append("Possible Flock-related device")
                alerts.append(DetectionAlert(id: "flock-ble-\(signal.id)", category: "Possible Flock-related device",
                                             observedAs: "Bluetooth LE · \(signal.name)",
                                             evidence: evidence.joined(separator: "; "),
                                             confidence: DetectionConfidence.strongSignature,
                                             strength: signal.strength, severity: .red, lastSeen: signal.lastSeen))
            }
            if let evidence = BodyCameraDetector.bluetoothEvidence(
                name: signal.name, advertisementHex: signal.advertisementHex
            ) {
                signatureCategories.append("Possible body-worn camera")
                alerts.append(DetectionAlert(id: "bodycam-ble-\(signal.id)", category: "Possible body-worn camera",
                                             observedAs: "Bluetooth LE · \(signal.name)",
                                             evidence: evidence.joined(separator: "; "),
                                             confidence: DetectionConfidence.strongSignature,
                                             strength: signal.strength, severity: .red, lastSeen: signal.lastSeen))
            }
            alerts += watchedAlerts(kind: .bluetoothName, value: signal.name,
                                    observedAs: "Bluetooth LE · \(signal.name)", signal: signal)
            alerts += watchedAlerts(kind: .bluetoothAddress, value: signal.address,
                                    observedAs: "Bluetooth LE · \(signal.name)", signal: signal)
            if let match = PublicSafetyDetector.bluetoothMatch(
                name: signal.name, companyID: advertisement.companyID,
                serviceUUIDs: advertisement.serviceUUIDs
            ) {
                signatureCategories.append(match.category)
                alerts.append(DetectionAlert(id: "public-safety-ble-\(signal.id)", category: match.category,
                                             observedAs: "Bluetooth LE · \(signal.name)",
                                             evidence: match.evidence.joined(separator: "; "),
                                             confidence: match.confidence,
                                             strength: signal.strength, severity: .yellow, lastSeen: signal.lastSeen))
            }
            alerts += watchedSignatureAlerts(signatureCategories, observedAs: "Bluetooth LE · \(signal.name)", signal: signal)
        }
        if let group = vehicleCorrelationGroup {
            alerts.append(DetectionAlert(id: "vehicle-group-\(group.first.id)-\(group.second.id)",
                                         category: "Possible co-moving public-safety-related signals",
                                         observedAs: "\(group.first.label) · \(group.second.label)",
                                         evidence: "\(group.evidence); RSSI correlation does not confirm a shared vehicle or agency",
                                         confidence: "Moderate · correlated signal trends; physical grouping unverified",
                                         strength: max(group.first.strengthHistory.samples.last?.rssi ?? -100,
                                                       group.second.strengthHistory.samples.last?.rssi ?? -100),
                                         severity: .yellow,
                                         lastSeen: max(group.first.lastSeen, group.second.lastSeen)))
        }
        if trackerDetectionEnabled, showTrackerSimulation {
            let tracker = TrackerDetector.bluetoothMatch(
                companyID: ParsedBLEAdvertisement(hex: trackerDemoSignal.advertisementHex,
                                                   wasTruncated: false).companyID,
                manufacturerPayload: ParsedBLEAdvertisement(hex: trackerDemoSignal.advertisementHex,
                                                             wasTruncated: false).manufacturerPayload
            )
            if let tracker {
                alerts.append(DetectionAlert(id: "tracker-simulated", category: "SIMULATED · \(tracker.category)",
                                             observedAs: "Demo fixture · no radio signal received",
                                             evidence: tracker.evidence, confidence: tracker.confidence,
                                             strength: trackerDemoSignal.strength, severity: .yellow,
                                             lastSeen: trackerDemoSignal.lastSeen))
            }
        }
        return alerts.max {
            $0.severity.priority == $1.severity.priority
                ? $0.strength < $1.strength
                : $0.severity.priority < $1.severity.priority
        }
    }

    private func trackerMatch(for signal: Signal) -> TrackerMatch? {
        guard trackerDetectionEnabled, !selectionIsWiFi else { return nil }
        let advertisement = ParsedBLEAdvertisement(hex: signal.advertisementHex,
                                                   wasTruncated: signal.advertisementTruncated)
        return TrackerDetector.bluetoothMatch(companyID: advertisement.companyID,
                                              manufacturerPayload: advertisement.manufacturerPayload)
    }

    private func glassMatch(for signal: Signal) -> SmartGlassesMatch? {
        guard !selectionIsWiFi else { return nil }
        let advertisement = ParsedBLEAdvertisement(hex: signal.advertisementHex,
                                                   wasTruncated: signal.advertisementTruncated)
        return SmartGlassesDetector.bluetoothMatch(name: signal.name, companyID: advertisement.companyID,
                                                   manufacturerPayload: advertisement.manufacturerPayload,
                                                   serviceUUIDs: advertisement.serviceUUIDs)
    }

    private func skimmerMatch(for signal: Signal) -> SkimmerModuleMatch? {
        guard !selectionIsWiFi else { return nil }
        let advertisement = ParsedBLEAdvertisement(hex: signal.advertisementHex,
                                                   wasTruncated: signal.advertisementTruncated)
        return SkimmerDetector.bluetoothMatch(name: signal.name, serviceUUIDs: advertisement.serviceUUIDs)
    }

    private var selectionIsWiFi: Bool { selection == "Wi-Fi" }

    private func watchedAlerts(kind: WatchRuleKind, value: String, observedAs: String,
                               signal: Signal) -> [DetectionAlert] {
        watchlist.matchingRules(kind, value: value).map { rule in
            let ruleLabel = rule.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return DetectionAlert(id: "watch-\(rule.id)-\(signal.id)",
                           category: "Watched \(kind.title) nearby", observedAs: observedAs,
                           evidence: "Exact \(kind.title.lowercased()) ‘\(value)’ matched rule ‘\(ruleLabel.isEmpty ? rule.value : ruleLabel)’",
                           confidence: DetectionConfidence.watchlist,
                           strength: signal.strength, severity: .yellow, lastSeen: signal.lastSeen)
        }
    }

    private func watchedSignatureAlerts(_ categories: [String], observedAs: String,
                                        signal: Signal) -> [DetectionAlert] {
        Array(Set(categories)).sorted().flatMap { category in
            watchedAlerts(kind: .signature, value: category, observedAs: observedAs, signal: signal)
        }
    }
}

private enum DetectionConfidence {
    static let strongSignature = "High-specificity signature match · device identity unconfirmed"
    static let watchlist = "Exact advertised-name match · device identity unverified"
}

private struct DetectionAlertBanner: View {
    let alert: DetectionAlert
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.severity.heading)
                    .font(.headline.bold())
                Text(alert.category.uppercased())
                    .font(.subheadline.bold())
                Text(alert.observedAs)
                    .font(.subheadline.weight(.semibold))
                Text(alert.evidence)
                    .font(.caption)
                    .lineLimit(2)
                Text("Confidence: \(alert.confidence)")
                    .font(.caption2)
                    .lineLimit(2)
                Text("Last seen \(SignalFreshness.ageLabel(lastSeen: alert.lastSeen, at: now))")
                    .font(.caption2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(alert.severity.foreground)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alert.severity.color, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Alert. \(alert.category). \(alert.observedAs). Evidence: \(alert.evidence). Confidence: \(alert.confidence). Last seen \(SignalFreshness.ageLabel(lastSeen: alert.lastSeen, at: now))")
    }
}

private struct WiFiChannelActivityView: View {
    @Environment(\.dismiss) private var dismiss
    let signals: [Signal]

    private var channels: [WiFiChannelSummary] {
        WiFiChannelActivity.summarize(signals.compactMap { signal in
            signal.channel.map { WiFiChannelObservation(channel: $0, rssi: signal.strength) }
        })
    }

    private var maximumCount: Int { max(channels.map(\.accessPointCount).max() ?? 0, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("2.4 GHz Wi-Fi · observed access points")
                    .font(.title3.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("This view counts recently retained access-point sightings. It does not measure channel energy, airtime, or utilization and is not calibrated.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .bottom, spacing: 6) {
                    ForEach(channels) { sample in
                    VStack(spacing: 5) {
                        Text("\(sample.accessPointCount)")
                            .font(.caption2.monospacedDigit())
                        RoundedRectangle(cornerRadius: 3)
                            .fill(sample.accessPointCount == 0 ? Color.secondary.opacity(0.15) : Color.blue.opacity(0.8))
                            .frame(height: sample.accessPointCount == 0
                                   ? 4
                                   : max(12, CGFloat(sample.accessPointCount) / CGFloat(maximumCount) * 88))
                        Text("\(sample.channel)")
                            .font(.caption.monospacedDigit())
                        Text(sample.strongestRSSI.map { "\($0)" } ?? "—")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Channel \(sample.channel): \(sample.accessPointCount) access points; strongest signal \(sample.strongestRSSI.map { "\($0) dBm" } ?? "none")")
                }
            }
            .frame(height: 130, alignment: .bottom)
            HStack(spacing: 4) {
                Text("Access points")
                Spacer()
                Text("Channel")
                Spacer()
                Text("Strongest AP RSSI · dBm")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if signals.isEmpty {
                ContentUnavailableView("No access points in the current scan",
                                       systemImage: "wifi.slash")
            }
        }
    }
}

private struct WiFiNetworkDetails: View {
    let signal: Signal
    @ObservedObject var watchlist: BLEWatchlistStore
    @ObservedObject var annotations: DeviceAnnotationStore
    let now: Date
    let vehicleGroupEvidence: String?

    private var flockEvidence: [String]? {
        FlockDetector.wifiEvidence(ssid: signal.name)
    }

    private var bodyCameraEvidence: [String]? {
        BodyCameraDetector.wifiEvidence(ssid: signal.name)
    }

    private var signatureCategories: [String] {
        var categories: [String] = []
        if flockEvidence != nil { categories.append("Possible Flock-related device") }
        if bodyCameraEvidence != nil { categories.append("Possible body-worn camera") }
        if let publicSafetyMatch { categories.append(publicSafetyMatch.category) }
        return categories
    }

    private var publicSafetyMatch: PublicSafetyMatch? {
        PublicSafetyDetector.wifiMatch(bssid: signal.address)
    }

    var body: some View {
        GroupBox("Network details") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(signal.name) · \(signal.address) · \(signal.strength) dBm")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                DeviceAnnotationEditor(store: annotations, radio: "Wi-Fi",
                                       name: signal.name, address: signal.address,
                                       lastSeen: signal.lastSeen)
                detailRow("SSID evidence", value: signal.networkNameHidden
                          ? "SSID omitted by AP; actual network name is unknown"
                          : "Broadcast SSID: \(signal.name)")
                detailRow("Last seen", value: SignalFreshness.ageLabel(lastSeen: signal.lastSeen, at: now))
                if let vehicleGroupEvidence {
                    detailRow("Possible vehicle group", value: vehicleGroupEvidence)
                    Text("Correlated signal changes only; this does not confirm that devices share a vehicle.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                SignalStrengthTrend(history: signal.strengthHistory)
                if let channel = signal.channel {
                    detailRow("Channel", value: String(channel))
                }
                detailRow("Security", value: signal.authMode ?? "Unavailable in scan record")
                detailRow("Pairwise cipher", value: signal.pairwiseCipher ?? "Unavailable in scan record")
                detailRow("Group cipher", value: signal.groupCipher ?? "Unavailable in scan record")
                detailRow("Channel width", value: signal.channelWidth ?? "Unavailable in scan record")
                detailRow("Secondary channel", value: signal.secondaryChannel ?? "Unavailable in scan record")
                detailRow("Supported Wi-Fi modes", value: signal.supportedStandards.map {
                    $0.isEmpty ? "None reported" : $0.joined(separator: ", ")
                } ?? "Unavailable in scan record")
                detailRow("WPS", value: signal.wps.map { $0 ? "Advertised" : "Not advertised" }
                          ?? "Unavailable in scan record")
                detailRow("BSSID/vendor evidence", value: WiFiBSSIDVendorEvidence.description(
                    bssid: signal.address,
                    vendorMatchEvidence: publicSafetyMatch?.evidence.joined(separator: "; ")))
                detailRow("Raw beacon information elements",
                          value: signal.rawInformationElementsAvailable == true
                            ? "Available; not decoded by this view"
                            : "Unavailable from this scan")
                HStack(spacing: 8) {
                    watchRuleButton(kind: .wifiName, value: signal.name, store: watchlist)
                    watchRuleButton(kind: .wifiAddress, value: signal.address, store: watchlist)
                }
                ForEach(signatureCategories, id: \.self) { category in
                    watchRuleButton(kind: .signature, value: category, store: watchlist)
                }
                Text("Passive access-point scan only. Client and probe frames are not collected.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let flockEvidence {
                    detailRow("Signature", value: "Possible Flock-related device")
                    detailRow("Confidence", value: DetectionConfidence.strongSignature)
                    detailRow("Evidence", value: flockEvidence.joined(separator: "; "))
                    confidenceNote
                }
                if let bodyCameraEvidence {
                    detailRow("Signature", value: "Possible body-worn camera")
                    detailRow("Confidence", value: DetectionConfidence.strongSignature)
                    detailRow("Evidence", value: bodyCameraEvidence.joined(separator: "; "))
                    confidenceNote
                }
                if let publicSafetyMatch {
                    detailRow("Signature", value: publicSafetyMatch.category)
                    detailRow("Confidence", value: publicSafetyMatch.confidence)
                    detailRow("Evidence", value: publicSafetyMatch.evidence.joined(separator: "; "))
                    confidenceNote
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).frame(width: 125, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .font(.caption)
    }

    private var confidenceNote: some View {
        Text("Confidence describes signature specificity, not a probability or confirmed identity.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

private struct SignalStrengthTrend: View {
    let history: SignalStrengthHistory

    private var firstRSSI: Int? { history.samples.first?.rssi }
    private var latestRSSI: Int? { history.samples.last?.rssi }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("RSSI trend · last minute")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let firstRSSI, let latestRSSI {
                    Text("\(firstRSSI) → \(latestRSSI) dBm · \(history.samples.count) samples")
                        .font(.caption.monospacedDigit())
                }
            }
            if history.samples.count > 1 {
                GeometryReader { geometry in
                    let values = history.samples.map(\.rssi)
                    let minimum = values.min() ?? 0
                    let maximum = values.max() ?? 0
                    let range = max(1, maximum - minimum)
                    Path { path in
                        for (index, sample) in history.samples.enumerated() {
                            let x = CGFloat(index) / CGFloat(history.samples.count - 1) * geometry.size.width
                            let y = range == 1 && minimum == maximum
                                ? geometry.size.height / 2
                                : CGFloat(maximum - sample.rssi) / CGFloat(range) * geometry.size.height
                            let point = CGPoint(x: x, y: y)
                            if index == 0 { path.move(to: point) }
                            else { path.addLine(to: point) }
                        }
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .frame(height: 30)
                .accessibilityHidden(true)
            } else {
                Text("Collecting readings…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Signal strength only · not distance")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let firstRSSI, let latestRSSI else {
            return "RSSI trend, collecting readings. Signal strength only, not distance."
        }
        return "RSSI trend for the last minute, from \(firstRSSI) to \(latestRSSI) dBm, " +
            "\(history.samples.count) samples. Signal strength only, not distance."
    }
}

private struct BLEAdvertisementDetails: View {
    let signal: Signal
    @ObservedObject var watchlist: BLEWatchlistStore
    @ObservedObject var annotations: DeviceAnnotationStore
    let now: Date
    let trackerDetectionEnabled: Bool
    let trackerPayloads: [String: TrackerPayloadObservation]
    let vehicleGroupEvidence: String?
    @State private var showCapturedAdvertisement = false

    private var parsed: ParsedBLEAdvertisement {
        ParsedBLEAdvertisement(hex: signal.advertisementHex,
                               wasTruncated: signal.advertisementTruncated)
    }

    private var trackerPayloadObservation: TrackerPayloadObservation? {
        guard let fingerprint = TrackerDetector.payloadFingerprint(companyID: parsed.companyID,
                                                                   manufacturerPayload: parsed.manufacturerPayload) else {
            return nil
        }
        return trackerPayloads[fingerprint]
    }

    private var flockEvidence: [String]? {
        guard let evidence = FlockDetector.bluetoothEvidence(name: signal.name, companyID: parsed.companyID,
                                                             manufacturerPayload: parsed.manufacturerPayload,
                                                             serviceUUIDs: parsed.serviceUUIDs) else { return nil }
        let nonRavenEvidence = evidence.filter { !$0.contains("Raven short ID") }
        return nonRavenEvidence.isEmpty ? nil : nonRavenEvidence
    }

    private var ravenAudioSensorEvidence: [String]? {
        FlockDetector.ravenAudioSensorEvidence(serviceUUIDs: parsed.serviceUUIDs)
    }

    private var bodyCameraEvidence: [String]? {
        BodyCameraDetector.bluetoothEvidence(name: signal.name, advertisementHex: signal.advertisementHex)
    }

    private var publicSafetyMatch: PublicSafetyMatch? {
        PublicSafetyDetector.bluetoothMatch(name: signal.name, companyID: parsed.companyID,
                                            serviceUUIDs: parsed.serviceUUIDs)
    }

    private var droneIDMatch: DroneIDMatch? {
        DroneIDDetector.decode(serviceData: parsed.serviceData16)
    }

    private var glassesMatch: SmartGlassesMatch? {
        SmartGlassesDetector.bluetoothMatch(name: signal.name, companyID: parsed.companyID,
                                            manufacturerPayload: parsed.manufacturerPayload,
                                            serviceUUIDs: parsed.serviceUUIDs)
    }

    private var skimmerMatch: SkimmerModuleMatch? {
        SkimmerDetector.bluetoothMatch(name: signal.name, serviceUUIDs: parsed.serviceUUIDs)
    }

    private var signatureCategories: [String] {
        var categories: [String] = []
        if flockEvidence != nil { categories.append("Possible Flock-related device") }
        if ravenAudioSensorEvidence != nil { categories.append("Possible Flock Raven audio sensor") }
        if bodyCameraEvidence != nil { categories.append("Possible body-worn camera") }
        if let publicSafetyMatch { categories.append(publicSafetyMatch.category) }
        if let glassesMatch { categories.append(glassesMatch.category) }
        if skimmerMatch != nil { categories.append("Possible Bluetooth serial module") }
        return categories
    }

    var body: some View {
        GroupBox("Advertisement details") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(signal.name) · \(signal.address) · \(signal.strength) dBm")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                DeviceAnnotationEditor(store: annotations, radio: "Bluetooth LE",
                                       name: signal.name, address: signal.address,
                                       lastSeen: signal.lastSeen)
                if signal.isSimulated {
                    Label("SIMULATION · local fixture only; no radio signal received",
                          systemImage: "play.rectangle")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    Text("Synthetic repeated sightings; no radio signal was received. This does not identify an AirTag or mean a tracker is following you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let tracker = TrackerDetector.bluetoothMatch(companyID: parsed.companyID,
                                                                manufacturerPayload: parsed.manufacturerPayload),
                   trackerDetectionEnabled {
                    detailRow("Tracker protocol", value: tracker.category)
                    detailRow("Confidence", value: tracker.confidence)
                    detailRow("Evidence", value: tracker.evidence)
                    if let trackerPayloadObservation {
                        detailRow("Payload fingerprint", value: String(trackerPayloadObservation.fingerprint.prefix(16)))
                        detailRow("Payload repeats", value: "\(trackerPayloadObservation.sightingCount) · \(trackerPayloadObservation.addresses.count) BLE address(es)")
                    }
                    TrackerSightingsHistory(history: trackerPayloadObservation?.sampleHistory ?? signal.strengthHistory,
                                            isSimulated: signal.isSimulated)
                    detailRow("Follow status", value: "Unknown · location and continuity evidence unavailable")
                    Text("Repeats share an exact, in-memory payload fingerprint and may span BLE address changes. The fingerprint rotates, is not a verified identity, and is not saved. RSSI is not distance.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let droneIDMatch {
                    detailRow("Remote ID", value: droneIDMatch.messageType)
                    detailRow("Protocol version", value: String(droneIDMatch.protocolVersion))
                    ForEach(Array(droneIDMatch.fields.enumerated()), id: \.offset) { _, field in
                        detailRow("Decoded field", value: field)
                    }
                    detailRow("Evidence", value: droneIDMatch.evidence)
                    detailRow("Alert", value: "Yellow · verify signature")
                    Text("This is a received broadcast, not verified ownership or affiliation. No law-enforcement or military identifier registry is configured, so those classifications are not inferred. Location fields are shown only when present and valid.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let vehicleGroupEvidence {
                    detailRow("Possible vehicle group", value: vehicleGroupEvidence)
                    Text("Correlated signal changes only; this does not confirm that devices share a vehicle.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                detailRow("Last seen", value: SignalFreshness.ageLabel(lastSeen: signal.lastSeen, at: now))
                SignalStrengthTrend(history: signal.strengthHistory)
                HStack(spacing: 8) {
                    watchRuleButton(kind: .bluetoothName, value: signal.name, store: watchlist)
                    watchRuleButton(kind: .bluetoothAddress, value: signal.address, store: watchlist)
                }
                ForEach(signatureCategories, id: \.self) { category in
                    watchRuleButton(kind: .signature, value: category, store: watchlist)
                }
                if watchlist.contains(.bluetoothName, value: signal.name) {
                    detailRow("Watchlist", value: "Exact advertised name · yellow alert when seen")
                    detailRow("Confidence", value: DetectionConfidence.watchlist)
                    confidenceNote
                }
                if let flockEvidence {
                    detailRow("Signature", value: "Possible Flock-related device")
                    detailRow("Confidence", value: DetectionConfidence.strongSignature)
                    detailRow("Evidence", value: flockEvidence.joined(separator: "; "))
                    confidenceNote
                }
                if let ravenAudioSensorEvidence {
                    detailRow("Signature", value: "Possible Flock Raven audio sensor")
                    detailRow("Confidence", value: DetectionConfidence.strongSignature)
                    detailRow("Evidence", value: ravenAudioSensorEvidence.joined(separator: "; "))
                    confidenceNote
                }
                if let bodyCameraEvidence {
                    detailRow("Signature", value: "Possible body-worn camera")
                    detailRow("Confidence", value: DetectionConfidence.strongSignature)
                    detailRow("Evidence", value: bodyCameraEvidence.joined(separator: "; "))
                    confidenceNote
                }
                if let publicSafetyMatch {
                    detailRow("Signature", value: publicSafetyMatch.category)
                    detailRow("Confidence", value: publicSafetyMatch.confidence)
                    detailRow("Evidence", value: publicSafetyMatch.evidence.joined(separator: "; "))
                    confidenceNote
                }
                if let glassesMatch {
                    detailRow("Signature", value: glassesMatch.category)
                    detailRow("Confidence", value: glassesMatch.confidence)
                    detailRow("Evidence", value: glassesMatch.evidence.joined(separator: "; "))
                    confidenceNote
                }
                if let skimmerMatch {
                    detailRow("Signature", value: skimmerMatch.category)
                    detailRow("Confidence", value: skimmerMatch.confidence)
                    detailRow("Evidence", value: skimmerMatch.evidence.joined(separator: "; "))
                    Text("A serial-module signature does not establish that the device is a card skimmer. Classic Bluetooth-only modules may not appear in this BLE scan.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                detailRow("Company ID", value: parsed.companyID.map { String(format: "0x%04X", $0) }
                          ?? "Not received in this advertisement")
                if let manufacturerPayload = parsed.manufacturerPayload {
                    detailRow("Company payload", value: manufacturerPayload.isEmpty
                              ? "Empty" : manufacturerPayload.map { String(format: "%02X", $0) }.joined())
                }
                let services = parsed.serviceUUIDs.isEmpty
                    ? "Not received in this advertisement"
                    : parsed.serviceUUIDs.joined(separator: ", ") + (parsed.hasPartialServiceList ? " · partial list" : "")
                detailRow("Service UUIDs", value: services)
                if parsed.malformed {
                    Text("Malformed advertisement field; only complete fields are shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup(isExpanded: $showCapturedAdvertisement) {
                    if let hex = signal.advertisementHex, !hex.isEmpty {
                        Text(hex.uppercased())
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                        if signal.advertisementTruncated {
                            Text("Capture truncated; details cover the captured bytes only.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Not received in this advertisement")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    HStack {
                        Text("Captured advertisement · \(parsed.byteCount) bytes")
                        Spacer()
                        if let hex = signal.advertisementHex, !hex.isEmpty {
                            Button("Copy hex") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(hex.uppercased(), forType: .string)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).frame(width: 125, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .font(.caption)
    }

    private var confidenceNote: some View {
        Text("Confidence describes signature specificity, not a probability or confirmed identity.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

private struct DeviceAnnotationEditor: View {
    @ObservedObject var store: DeviceAnnotationStore
    let radio: String
    let name: String
    let address: String
    let lastSeen: Date

    private var isFavorite: Bool { store.isFavorite(radio: radio, address: address) }

    private var note: Binding<String> {
        Binding(
            get: { store.annotation(radio: radio, address: address)?.note ?? "" },
            set: { store.updateNote(radio: radio, name: name, address: address, note: $0) }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                store.toggleFavorite(radio: radio, name: name, address: address, seenAt: lastSeen)
            } label: {
                Label(isFavorite ? "Favorited" : "Add to Favorites",
                      systemImage: isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.bordered)

            if isFavorite {
                TextField("Add a private note…", text: note)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Note for \(name)")
            } else {
                Text("Favorites and notes are saved on this Mac")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .onAppear {
            store.updateNameIfFavorite(radio: radio, name: name, address: address)
            store.updateSighting(radio: radio, address: address, at: lastSeen)
        }
        .onChange(of: name) { _, updatedName in
            store.updateNameIfFavorite(radio: radio, name: updatedName, address: address)
        }
        .onChange(of: lastSeen) { _, date in
            store.updateSighting(radio: radio, address: address, at: date)
        }
    }
}

private struct DeviceFavoritesView: View {
    @ObservedObject var store: DeviceAnnotationStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Favorites").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text("Only favorites are saved on this Mac. Each keeps its radio source and sighting time. Location is unavailable: this setup has no GPS or phone location source.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if store.annotations.isEmpty {
                ContentUnavailableView("No favorites yet",
                                       systemImage: "star",
                                       description: Text("Select a Wi-Fi network or BLE device, then choose Add to Favorites."))
            } else {
                List {
                    ForEach(store.annotations) { item in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Label(item.name, systemImage: "star.fill")
                                    .lineLimit(1)
                                Spacer()
                                Text(item.radio).foregroundStyle(.secondary)
                                Button(role: .destructive) {
                                    store.remove(item.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove favorite and note")
                            }
                            Text(item.address)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            HStack(spacing: 16) {
                                Label("Source: \(item.radio)", systemImage: "dot.radiowaves.left.and.right")
                                if let lastSeen = item.lastSeenAt {
                                    Label("Last seen: \(lastSeen.formatted(date: .numeric, time: .standard))",
                                          systemImage: "clock")
                                } else {
                                    Label("Sighting time unavailable", systemImage: "clock")
                                }
                                Spacer(minLength: 0)
                                Label(item.location.map {
                                    String(format: "%.5f, %.5f · %@", $0.latitude, $0.longitude, $0.source)
                                } ?? "Location unavailable", systemImage: "location.slash")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            TextField("Add a private note…", text: Binding(
                                get: { store.annotation(radio: item.radio, address: item.address)?.note ?? "" },
                                set: { store.updateNote(radio: item.radio, name: item.name,
                                                        address: item.address, note: $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 360)
    }
}

private func watchRuleButton(kind: WatchRuleKind, value: String,
                             store: BLEWatchlistStore) -> some View {
    let exists = store.contains(kind, value: value)
    return Button(exists ? "Remove \(kind.title)" : "Watch \(kind.title)") {
        store.toggle(kind, value: value)
    }
    .buttonStyle(.bordered)
    .accessibilityHint(exists ? "Removes this exact watch rule" : "Adds this exact value to the watchlist")
}

private struct WatchlistManagerView: View {
    @ObservedObject var store: BLEWatchlistStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: WatchRuleKind = .bluetoothName
    @State private var value = ""
    @State private var label = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rules are saved on this Mac. BLE names, addresses, and signatures match without case sensitivity; Wi-Fi names match exact case.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox("Add watch rule") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Match type", selection: $kind) {
                            ForEach(WatchRuleKind.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        TextField(kind.inputPrompt, text: $value)
                            .textFieldStyle(.roundedBorder)
                        TextField("Display label (optional)", text: $label)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Spacer()
                            Button("Add Rule") {
                                guard store.add(kind, value: value, label: label) else { return }
                                value = ""
                                label = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || store.contains(kind, value: value))
                        }
                    }
                    .padding(.top, 4)
                }

                HStack {
                    Text("Watch rules")
                        .font(.headline)
                    Spacer()
                    Text("\(store.rules.filter(\.enabled).count) active · \(store.rules.count) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if store.rules.isEmpty {
                    ContentUnavailableView("No watch rules yet", systemImage: "eye",
                                           description: Text("Add a rule here or watch a selected network/device."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(store.rules) { rule in
                                WatchRuleRow(rule: rule, store: store)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Watchlist")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }
}

private struct WatchRuleRow: View {
    let rule: WatchRule
    @ObservedObject var store: BLEWatchlistStore

    private var labelBinding: Binding<String> {
        Binding(get: { rule.label }, set: { store.rename(rule.id, label: $0) })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { rule.enabled }, set: { store.setEnabled(rule.id, enabled: $0) })
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Rule label", text: labelBinding)
                    .textFieldStyle(.roundedBorder)
                Text("\(rule.kind.title) · \(rule.value)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack {
                    Toggle("Enabled", isOn: enabledBinding)
                    Spacer()
                    Button("Remove", role: .destructive) { store.remove(rule.id) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .opacity(rule.enabled ? 1 : 0.65)
    }
}

private struct TrackerSightingsHistory: View {
    let history: SignalStrengthHistory
    let isSimulated: Bool

    var body: some View {
        GroupBox("Tracker sightings · last minute") {
            VStack(alignment: .leading, spacing: 4) {
                if history.samples.isEmpty {
                    Text("No RSSI samples recorded")
                        .font(.caption)
                } else {
                    ForEach(Array(history.samples.suffix(8).reversed().enumerated()), id: \.offset) { _, sample in
                        HStack {
                            Text(sample.time.formatted(date: .omitted, time: .standard))
                                .monospacedDigit()
                            Spacer()
                            Text("\(sample.rssi) dBm")
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                    Text(isSimulated
                         ? "Synthetic fixture · no radio observations received"
                         : "\(history.samples.count) time-bucketed RSSI samples")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ParsedBLEAdvertisement {
    var companyID: UInt16?
    var manufacturerPayload: [UInt8]?
    var serviceUUIDs: [String] = []
    var serviceData16: [String: [UInt8]] = [:]
    var hasPartialServiceList = false
    var malformed = false
    let byteCount: Int

    init(hex: String?, wasTruncated: Bool) {
        guard let hex, hex.count.isMultiple(of: 2) else {
            byteCount = 0
            malformed = hex != nil
            return
        }
        let characters = Array(hex)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        for offset in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[offset...offset + 1]), radix: 16) else {
                byteCount = 0
                malformed = true
                return
            }
            bytes.append(byte)
        }
        byteCount = bytes.count
        var offset = 0
        while offset < bytes.count {
            let fieldLength = Int(bytes[offset])
            if fieldLength == 0 { break }
            guard fieldLength >= 1, offset + fieldLength < bytes.count else {
                malformed = !wasTruncated
                break
            }
            let fieldType = bytes[offset + 1]
            let valueStart = offset + 2
            let fieldEnd = offset + 1 + fieldLength
            let value = Array(bytes[valueStart..<fieldEnd])
            switch fieldType {
            case 0x02, 0x03:
                hasPartialServiceList = hasPartialServiceList || fieldType == 0x02
                append16BitUUIDs(value)
            case 0x04, 0x05:
                hasPartialServiceList = hasPartialServiceList || fieldType == 0x04
                append32BitUUIDs(value)
            case 0x06, 0x07:
                hasPartialServiceList = hasPartialServiceList || fieldType == 0x06
                append128BitUUIDs(value)
            case 0x16:
                guard value.count >= 2 else { malformed = true; break }
                let uuid = UInt16(value[0]) | (UInt16(value[1]) << 8)
                let uuidText = String(format: "%04X", uuid)
                serviceUUIDs.append(uuidText)
                serviceData16[uuidText] = Array(value.dropFirst(2))
            case 0x20:
                guard value.count >= 4 else { malformed = true; break }
                append32BitUUIDs(Array(value.prefix(4)))
            case 0x21:
                guard value.count >= 16 else { malformed = true; break }
                append128BitUUIDs(Array(value.prefix(16)))
            case 0xFF where value.count >= 2 && companyID == nil:
                companyID = UInt16(value[0]) | (UInt16(value[1]) << 8)
                manufacturerPayload = Array(value.dropFirst(2))
            case 0xFF:
                malformed = true
            default:
                break
            }
            offset = fieldEnd
        }
    }

    private mutating func append16BitUUIDs(_ bytes: [UInt8]) {
        guard bytes.count.isMultiple(of: 2) else { malformed = true; return }
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            serviceUUIDs.append(String(format: "%04X", value))
        }
    }

    private mutating func append32BitUUIDs(_ bytes: [UInt8]) {
        guard bytes.count.isMultiple(of: 4) else { malformed = true; return }
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let value = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
            serviceUUIDs.append(String(format: "%08X", value))
        }
    }

    private mutating func append128BitUUIDs(_ bytes: [UInt8]) {
        guard bytes.count.isMultiple(of: 16) else { malformed = true; return }
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let value = bytes[offset..<offset + 16].reversed()
                .map { String(format: "%02X", $0) }.joined()
            serviceUUIDs.append("\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-"
                                + "\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-"
                                + "\(value.dropFirst(20))")
        }
    }
}

#if !APP_CHOOSER
private final class ScannerDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ScannerWindow: App {
    @NSApplicationDelegateAdaptor(ScannerDelegate.self) private var delegate

    var body: some Scene {
        Window("Synesthesia Network Scanner", id: "scanner") {
            ScannerView()
        }
        .defaultSize(width: 680, height: 470)
    }
}
#endif
