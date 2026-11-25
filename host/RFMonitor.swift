import Combine
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import Darwin

private struct RFEvent: Decodable {
    let type: String
    var center: Int?
    var rate: Int?
    var drops: Int?
    var bins: [Int]?
    var code: Int?
    var samples: UInt64?
    var dropped_samples: UInt64?
    var elapsed_ms: UInt64?
    var i: [Int]?
    var q: [Int]?
    var valid_frames: UInt64?
    var icao: String?
    var df: Int?
    var type_code: Int?
    var callsign: String?
    var altitude_ft: Int?
    var altitude_kind: String?
    var candidate_id: UInt32?
    var candidate_count: UInt32?
    var strength_dbfs: Double?
    var active: Bool?
    var nac: Int?
    var duid: Int?
    var valid_nids: UInt32?
    var control_nids: UInt32?
    var control_nac: Int?
    var repeated_nids: UInt32?
    var opcode: Int?
    var channel: Int?
    var talkgroup: Int?
    var last_block: Bool?
    var pcm: String?
    var codec: String?
    var demod_samples: UInt64?
    var firmware_blocks: UInt64?
    var audio_lines: UInt64?
    var audio_bytes: UInt64?
    var audio_errors: UInt64?
    var audio_error_detail: String?
    var id: String?
    var flags: Int?
    var pressure_hpa: Int?
    var temperature_c: Int?
    var valid_packets: UInt32?
    var frequency: Int?
    var rise_db: Double?
    var resolution_hz: Int?
    var mounted: Bool?
    var logging: Bool?
    var capacity_bytes: UInt64?
    var free_bytes: UInt64?
    var faa_master_present: Bool?
    var path: String?
    var error: String?
    var ok: Bool?
    var rows: UInt32?
    var registration: String?
    var year: String?
    var aircraft_type: String?
    var last_action_date: String?
    var source: String?
    var matches: UInt32?
}

@MainActor
private final class LiveAudioOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000,
                                       channels: 1, interleaved: false)!
    private var configured = false
    private static let imaSteps: [Int32] = [
        7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767
    ]
    private static let imaIndexAdjust = [-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8]

    func start() throws {
        if !configured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            configured = true
        }
        if !engine.isRunning { try engine.start() }
        if !player.isPlaying { player.play() }
    }

    func enqueue(_ bytes: Data) {
        guard configured, player.isPlaying, !bytes.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bytes.count)),
              let channel = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(bytes.count)
        bytes.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Int8.self).baseAddress else { return }
            for index in 0..<bytes.count { channel[index] = Int16(source[index]) * 256 }
        }
        player.scheduleBuffer(buffer)
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    static func decodeIMAADPCM(_ bytes: Data, sampleCount: Int) -> Data? {
        guard sampleCount == 1600, bytes.count >= 3 + sampleCount / 2 else { return nil }
        var predictor = Int32(Int16(bitPattern: UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)))
        var index = Int(bytes[2])
        guard index < imaSteps.count else { return nil }
        var decoded = Data(capacity: sampleCount)
        decoded.append(UInt8(bitPattern: Int8(clamping: predictor / 256)))
        if sampleCount == 1 { return decoded }
        for sampleIndex in 1..<sampleCount {
            let nibbleIndex = sampleIndex - 1
            let packed = bytes[3 + nibbleIndex / 2]
            let code = Int((nibbleIndex & 1) == 0 ? packed & 0x0f : packed >> 4)
            let step = imaSteps[index]
            var delta = step >> 3
            if code & 1 != 0 { delta += step >> 2 }
            if code & 2 != 0 { delta += step >> 1 }
            if code & 4 != 0 { delta += step }
            predictor += code & 8 != 0 ? -delta : delta
            predictor = max(-32768, min(32767, predictor))
            index = max(0, min(imaSteps.count - 1, index + imaIndexAdjust[code]))
            let sample = max(-128, min(127, predictor / 256))
            decoded.append(UInt8(bitPattern: Int8(sample)))
        }
        return decoded
    }
}

struct ADSBObservation: Identifiable {
    let address: String
    var callsign: String?
    var altitudeFeet: Int?
    var altitudeKind: String?
    var messages: Int
    var lastSeen: Date
    var id: String { address }
}

struct ADSBRegistryEntry: Codable, Identifiable {
    var address: String
    var callsign: String
    var category: String
    var source: String
    var sourceDate: String
    var registration: String? = nil
    var yearManufactured: String? = nil
    var id: String { "\(address)|\(callsign)|\(source)" }
}

private func splitCSVRecord(_ line: String) -> [String] {
    var fields: [String] = []
    var field = ""
    var quoted = false
    var index = line.startIndex
    while index < line.endIndex {
        let char = line[index]
        let next = line.index(after: index)
        if char == "\"" {
            if quoted && next < line.endIndex && line[next] == "\"" {
                field.append("\"")
                index = next
            } else {
                quoted.toggle()
            }
        } else if char == "," && !quoted {
            fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
            field = ""
        } else {
            field.append(char)
        }
        index = line.index(after: index)
    }
    fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
    return fields
}

private func scanFAAMaster(_ url: URL, addresses: Set<String>) throws -> [ADSBRegistryEntry] {
    let file = fopen(url.path, "r")
    guard let file else { throw CocoaError(.fileReadUnknown) }
    defer { fclose(file) }
    var linePointer: UnsafeMutablePointer<CChar>?
    var lineCapacity = 0
    defer { if let linePointer { free(linePointer) } }

    guard getline(&linePointer, &lineCapacity, file) >= 0, let headerPointer = linePointer else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let header = splitCSVRecord(String(cString: headerPointer).replacingOccurrences(of: "\u{FEFF}", with: ""))
    let columns = Dictionary(uniqueKeysWithValues: header.enumerated().map {
        ($0.element.uppercased(), $0.offset)
    })
    guard let registrationIndex = columns["N-NUMBER"],
          let modeSIndex = columns["MODE S CODE HEX"],
          let yearIndex = columns["YEAR MFR"],
          let typeIndex = columns["TYPE AIRCRAFT"],
          let actionDateIndex = columns["LAST ACTION DATE"] else {
        throw RFMonitor.RegistryImportError.invalid
    }

    var wanted = addresses
    var matches: [String: ADSBRegistryEntry] = [:]
    while getline(&linePointer, &lineCapacity, file) >= 0, let recordPointer = linePointer {
        let fields = splitCSVRecord(String(cString: recordPointer))
        guard fields.count > [registrationIndex, modeSIndex, yearIndex, typeIndex, actionDateIndex].max()! else { continue }
        let address = fields[modeSIndex].uppercased().filter(\.isHexDigit)
        guard address.count == 6, wanted.contains(address) else { continue }
        let rawRegistration = fields[registrationIndex].uppercased()
            .filter { $0.isLetter || $0.isNumber }
        guard !rawRegistration.isEmpty else { continue }
        let registration = rawRegistration.hasPrefix("N") ? rawRegistration : "N" + rawRegistration
        let year = fields[yearIndex]
        let type = fields[typeIndex]
        let category = type.isEmpty ? "FAA registered aircraft" : "FAA type \(type)"
        matches[address] = ADSBRegistryEntry(address: address, callsign: "", category: category,
                                             source: "FAA Registry MASTER.txt",
                                             sourceDate: fields[actionDateIndex],
                                             registration: registration,
                                             yearManufactured: year.isEmpty ? nil : year)
        wanted.remove(address)
    }
    if ferror(file) != 0 { throw CocoaError(.fileReadUnknown) }
    return Array(matches.values)
}

struct P25NIDObservation: Identifiable {
    let nac: Int
    let duid: Int
    var frames: Int
    var centerHz: Int
    var id: String { "\(nac)-\(duid)" }
}

struct P25ControlCandidate: Identifiable {
    let nac: Int
    var repeatedNIDs: Int
    var centerHz: Int
    var lastSeen: Date
    var id: String { "\(nac)-\(centerHz)" }
}

struct P25GrantObservation: Identifiable {
    let frequencyHz: Int?
    let controlHz: Int
    let nac: Int
    let opcode: Int
    let channel: Int
    let talkgroup: Int?
    var lastSeen: Date
    var id: String { "\(nac)-\(controlHz)-\(channel)-\(talkgroup ?? 0)" }
}

struct TPMSObservation: Identifiable {
    let id: String
    let flags: Int
    let pressureHpa: Int
    let temperatureC: Int
    let centerHz: Int
    var lastSeen: Date
}

struct FrequencyObservation: Identifiable {
    let frequencyHz: Int
    let centerHz: Int
    let riseDB: Double
    let resolutionHz: Int
    let receivedAt: Date
    let id = UUID()
}

struct IQSampleBlock {
    let centerFrequencyHz: Int
    let sampleRate: Int
    let sequence: UInt32
    let receivedAt: Date
    let cu8: Data
}

@MainActor
final class RFMonitor: ObservableObject {
    enum Mode: String, CaseIterable {
        case sweep = "FM Sweep"
        case tune = "Tune"
        case activity = "Channel Watch"
        case iq = "IQ Capture"
        case adsb = "ADS-B"
        case tetra = "TETRA"
        case p25 = "P25"
        case audio = "Analog Audio"
        case tpms = "TPMS"
        case find = "Frequency Finder"
    }
    static let fmLow = 88_000_000
    static let fmHigh = 108_000_000
    static let step = 25_000

    @Published private(set) var ready = false
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published private(set) var status = "Connecting over USB…"
    @Published private(set) var trace: [Double?] = []
    @Published private(set) var signals: [SweepSignal] = []
    @Published private(set) var channels: [ChannelObservation] = []
    @Published private(set) var progress: Double?
    @Published private(set) var shownCenter = 98_000_000
    @Published private(set) var sampleRate = 960_000
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var affectedFrames = 0
    @Published private(set) var iqSamples: UInt64 = 0
    @Published private(set) var iqDroppedSamples: UInt64 = 0
    @Published private(set) var iqElapsedMilliseconds: UInt64 = 0
    @Published private(set) var iqInPhase: [Double] = []
    @Published private(set) var iqQuadrature: [Double] = []
    @Published private(set) var adsbObservations: [ADSBObservation] = []
    @Published private(set) var adsbValidFrames: UInt64 = 0
    @Published private(set) var adsbRegistry: [ADSBRegistryEntry] = []
    @Published private(set) var registryImportMessage: String?
    @Published private(set) var registryImporting = false
    @Published private(set) var tetraCandidateCount: UInt32 = 0
    @Published private(set) var tetraStrengths: [Double] = []
    @Published private(set) var tetraCurrentStrength: Double?
    @Published private(set) var tetraCandidateHistory: [(id: UInt32, strength: Double)] = []
    @Published private(set) var p25Observations: [P25NIDObservation] = []
    @Published private(set) var p25ControlCandidates: [P25ControlCandidate] = []
    @Published private(set) var p25ValidNIDs: UInt32 = 0
    @Published private(set) var p25Grants: [P25GrantObservation] = []
    @Published private(set) var audioBlocksReceived = 0
    @Published private(set) var audioSamplesReceived: UInt64 = 0
    @Published private(set) var audioDroppedSamples: UInt64 = 0
    @Published private(set) var audioElapsedMilliseconds: UInt64 = 0
    @Published private(set) var audioDemodSamples: UInt64 = 0
    @Published private(set) var audioFirmwareBlocks: UInt64 = 0
    @Published private(set) var audioEventsReceived = 0
    @Published private(set) var audioPayloadErrors = 0
    @Published private(set) var audioLateEventsDiscarded = 0
    @Published private(set) var audioBridgeLines: UInt64 = 0
    @Published private(set) var audioBridgeBytes: UInt64 = 0
    @Published private(set) var audioBridgeErrors: UInt64 = 0
    @Published private(set) var audioBridgeErrorDetail = ""
    @Published private(set) var tpmsObservations: [TPMSObservation] = []
    @Published private(set) var tpmsValidPackets: UInt32 = 0
    @Published private(set) var findObservation: FrequencyObservation?
    @Published private(set) var sdStatusAvailable = false
    @Published private(set) var sdMounted = false
    @Published private(set) var sdLogging = false
    @Published private(set) var sdCapacityBytes: UInt64 = 0
    @Published private(set) var sdFreeBytes: UInt64 = 0
    @Published private(set) var sdFAAMasterPresent = false
    @Published private(set) var sdPath = "/sdcard/RF_SENTINEL"
    @Published private(set) var sdExportMessage: String?
    @Published private(set) var sdError: String?
    let iqBlocks = PassthroughSubject<IQSampleBlock, Never>()

    private var process: Process?
    private var output: Pipe?
    private var commands: Pipe?
    private var pending = Data()
    private var timeout: DispatchWorkItem?
    private let decoder = JSONDecoder()
    private var mode = Mode.sweep
    private var center = 98_000_000
    private var p25ScanFrequencies: [Int]?
    private var p25ScanIndex = 0
    private var p25DwellTask: DispatchWorkItem?
    private var tiles: [(pass: Int, center: Int)] = []
    private var tileIndex = 0
    private var passes: [[Double?]] = []
    private var distances: [[Int]] = []
    private var threshold = 6.0
    private var detector: ChannelDetector?
    private var runID = 0
    private let sendThroughChooser: ((String) -> Void)?
    private let audioOutput = LiveAudioOutput()

    init(sendThroughChooser: ((String) -> Void)? = nil) {
        self.sendThroughChooser = sendThroughChooser
        if let data = UserDefaults.standard.data(forKey: "adsb.localRegistry.v1"),
           let entries = try? JSONDecoder().decode([ADSBRegistryEntry].self, from: data) {
            adsbRegistry = entries
        }
    }

    func registryMatch(for observation: ADSBObservation) -> ADSBRegistryEntry? {
        if let match = adsbRegistry.first(where: { !$0.address.isEmpty && $0.address == observation.address }) {
            return match
        }
        guard let callsign = observation.callsign?.uppercased() else { return nil }
        return adsbRegistry.first(where: { !$0.callsign.isEmpty && $0.callsign == callsign })
    }

    func importADSBRegistry(from url: URL) throws -> Bool {
        let granted = url.startAccessingSecurityScopedResource()
        let headerData: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            headerData = try handle.read(upToCount: 8192) ?? Data()
            try? handle.close()
        } catch {
            if granted { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        guard let headerLine = String(data: headerData, encoding: .utf8)?.components(separatedBy: .newlines).first else {
            if granted { url.stopAccessingSecurityScopedResource() }
            throw RegistryImportError.invalid
        }
        if headerLine.contains("N-NUMBER"), headerLine.contains("MODE S CODE HEX") {
            let addresses = Set(adsbObservations.map(\.address))
            guard !addresses.isEmpty else {
                if granted { url.stopAccessingSecurityScopedResource() }
                registryImportMessage = "Capture at least one aircraft before matching the FAA catalog."
                return false
            }
            registryImporting = true
            registryImportMessage = "Scanning FAA catalog for \(addresses.count) observed address(es)…"
            let sourceURL = url
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Result { try scanFAAMaster(sourceURL, addresses: addresses) }
                if granted { sourceURL.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.registryImporting = false
                    switch result {
                    case .success(let entries):
                        let found = Set(entries.map(\.address))
                        self.adsbRegistry.removeAll { found.contains($0.address) }
                        self.adsbRegistry.append(contentsOf: entries)
                        if let data = try? JSONEncoder().encode(self.adsbRegistry) {
                            UserDefaults.standard.set(data, forKey: "adsb.localRegistry.v1")
                        }
                        self.registryImportMessage = entries.isEmpty
                            ? "No observed aircraft matched a Mode S code in the FAA catalog."
                            : "Matched \(entries.count) observed aircraft to FAA registrations."
                    case .failure(let error):
                        self.registryImportMessage = error.localizedDescription
                    }
                }
            }
            return true
        }
        if granted { url.stopAccessingSecurityScopedResource() }
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = parseCSV(text)
        guard let header = rows.first else { throw RegistryImportError.invalid }
        let columns = Dictionary(uniqueKeysWithValues: header.enumerated().map {
            ($0.element.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0.offset)
        })
        guard let addressIndex = columns["icao24"], let categoryIndex = columns["category"],
              let sourceIndex = columns["source"], let dateIndex = columns["source_date"] else {
            throw RegistryImportError.invalid
        }
        let callsignIndex = columns["callsign"]
        let imported = rows.dropFirst().compactMap { row -> ADSBRegistryEntry? in
            func value(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let address = value(addressIndex).uppercased().filter(\.isHexDigit)
            let callsign = value(callsignIndex).uppercased()
            let category = value(categoryIndex), source = value(sourceIndex), date = value(dateIndex)
            guard (address.count == 6 || !callsign.isEmpty), !category.isEmpty, !source.isEmpty,
                  !date.isEmpty, address.allSatisfy(\.isHexDigit) else { return nil }
            return ADSBRegistryEntry(address: address, callsign: callsign, category: category,
                                     source: source, sourceDate: date)
        }
        guard !imported.isEmpty, let data = try? JSONEncoder().encode(imported) else {
            throw RegistryImportError.invalid
        }
        adsbRegistry = imported
        UserDefaults.standard.set(data, forKey: "adsb.localRegistry.v1")
        registryImportMessage = "Imported \(adsbRegistry.count) local registry rows."
        return false
    }

    private func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                if quoted && index + 1 < chars.count && chars[index + 1] == "\"" {
                    field.append("\""); index += 1
                } else { quoted.toggle() }
            } else if char == "," && !quoted {
                row.append(field); field = ""
            } else if (char == "\n" || char == "\r") && !quoted {
                if char == "\r", index + 1 < chars.count, chars[index + 1] == "\n" { index += 1 }
                row.append(field); field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            } else { field.append(char) }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    enum RegistryImportError: LocalizedError {
        case invalid
        var errorDescription: String? {
            "CSV needs icao24, category, source, and source_date columns, with at least one valid row."
        }
    }

    func connect() {
        if sendThroughChooser != nil {
            send("status")
            return
        }
        guard process == nil else { return }
        guard let config = SerialLaunchConfiguration.load() else {
            status = "Launch with open-scanner.sh --rf"
            return
        }
        let reader = Process()
        let output = Pipe()
        let commands = Pipe()
        reader.executableURL = URL(fileURLWithPath: config.python)
        reader.arguments = [config.bridge, "--port", config.port, "--json", "--commands", "--prefix", "@RF "]
        reader.standardInput = commands
        reader.standardOutput = output
        reader.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                if chunk.isEmpty { self?.disconnect() } else { self?.read(chunk) }
            }
        }
        do {
            try reader.run()
            self.process = reader
            self.output = output
            self.commands = commands
            send("status")
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            status = error.localizedDescription
        }
    }

    func close() {
        timeout?.cancel()
        audioOutput.stop()
        running = false
        if sendThroughChooser != nil { return }
        if ready { try? commands?.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8)) }
        try? commands?.fileHandleForWriting.close()
        output?.fileHandleForReading.readabilityHandler = nil
    }

    func start(_ mode: Mode, frequency: Int, bank: ChannelBank, threshold: Double,
               p25ScanFrequencies: [Int]? = nil) {
        guard ready, !running, !stopping else { return }
        runID += 1
        self.mode = mode
        self.threshold = threshold
        sampleRate = mode == .iq || mode == .tetra || mode == .p25 || mode == .audio || mode == .tpms ? 250_000 : mode == .adsb ? 2_048_000 : 960_000
        center = mode == .activity ? bank.tunerCenter : mode == .adsb ? 1_090_000_000 : frequency
        self.p25ScanFrequencies = mode == .p25 ? p25ScanFrequencies.flatMap { $0.isEmpty ? nil : $0 } : nil
        p25ScanIndex = 0
        shownCenter = center
        signals = []
        detector = mode == .activity ? ChannelDetector(bank: bank, threshold: threshold) : nil
        channels = detector?.observations ?? []
        affectedFrames = 0
        lastUpdated = nil
        if mode == .adsb {
            adsbObservations = []
            adsbValidFrames = 0
            iqSamples = 0
            iqDroppedSamples = 0
            iqElapsedMilliseconds = 0
        }
        if mode == .tetra {
            tetraCandidateCount = 0
            tetraStrengths = []
            tetraCurrentStrength = nil
            tetraCandidateHistory = []
            iqSamples = 0
            iqDroppedSamples = 0
            iqElapsedMilliseconds = 0
        }
        if mode == .p25 {
            p25Observations = []
            p25ControlCandidates = []
            p25ValidNIDs = 0
            p25Grants = []
            iqSamples = 0
            iqDroppedSamples = 0
            iqElapsedMilliseconds = 0
        }
        if mode == .audio {
            audioBlocksReceived = 0
            audioSamplesReceived = 0
            audioDroppedSamples = 0
            audioElapsedMilliseconds = 0
            audioDemodSamples = 0
            audioFirmwareBlocks = 0
            audioEventsReceived = 0
            audioPayloadErrors = 0
            audioLateEventsDiscarded = 0
            audioBridgeLines = 0
            audioBridgeBytes = 0
            audioBridgeErrors = 0
            audioBridgeErrorDetail = ""
            audioOutput.stop()
        }
        if mode == .tpms { tpmsObservations = []; tpmsValidPackets = 0 }
        if mode == .find { findObservation = nil }
        if mode == .sweep {
            // The shifted grids cover each other's masked center bins.
            tiles = (0...1).flatMap { pass in
                stride(from: Self.fmLow + 50_000 + 150_000 * pass,
                       through: Self.fmHigh, by: 300_000).map { (pass, $0) }
            }
            tileIndex = 0
            let count = (Self.fmHigh - Self.fmLow) / Self.step + 1
            trace = Array(repeating: nil, count: count)
            passes = [trace, trace]
            distances = Array(repeating: Array(repeating: Int.max, count: count), count: 2)
            progress = 0
        } else {
            trace = []
            progress = nil
        }
        if mode == .iq {
            iqSamples = 0
            iqDroppedSamples = 0
            iqElapsedMilliseconds = 0
            iqInPhase = []
            iqQuadrature = []
        }
        running = true
        captureNext()
    }

    func clearTrace() {
        trace = []
        signals = []
        channels = []
        progress = nil
        lastUpdated = nil
    }

    func prepare(_ mode: Mode) {
        guard !running, !stopping else { return }
        sampleRate = mode == .iq || mode == .tetra || mode == .p25 || mode == .audio || mode == .tpms ? 250_000 : mode == .adsb ? 2_048_000 : 960_000
        clearTrace()
        iqInPhase = []
        iqQuadrature = []
        if mode == .adsb {
            adsbObservations = []
            adsbValidFrames = 0
        }
        if mode == .tetra {
            tetraCandidateCount = 0
            tetraStrengths = []
            tetraCurrentStrength = nil
            tetraCandidateHistory = []
        }
        if mode == .p25 {
            p25Observations = []
            p25ControlCandidates = []
            p25ValidNIDs = 0
        }
        if mode == .audio {
            audioBlocksReceived = 0
            audioSamplesReceived = 0
            audioDroppedSamples = 0
            audioElapsedMilliseconds = 0
            audioDemodSamples = 0
            audioFirmwareBlocks = 0
            audioEventsReceived = 0
            audioPayloadErrors = 0
            audioLateEventsDiscarded = 0
            audioBridgeLines = 0
            audioBridgeBytes = 0
            audioBridgeErrors = 0
            audioBridgeErrorDetail = ""
            audioOutput.stop()
        }
        if mode == .tpms { tpmsObservations = []; tpmsValidPackets = 0 }
        if mode == .find { findObservation = nil }
    }

    func stop() {
        guard running else { return }
        running = false
        stopping = true
        p25DwellTask?.cancel()
        p25DwellTask = nil
        p25ScanFrequencies = nil
        status = "Releasing tuner…"
        send("stop")
    }

    private func captureNext() {
        guard running else { return }
        if mode == .iq {
            status = "Starting continuous IQ capture…"
            send("iq \(center)")
            return
        }
        if mode == .adsb {
            status = "Waiting for 1090 MHz samples…"
            send("adsb")
            return
        }
        if mode == .tetra {
            status = "Listening for burst candidates at \(Self.mhz(center)) MHz…"
            send("tetra \(center)")
            return
        }
        if mode == .p25 {
            if let frequencies = p25ScanFrequencies, !frequencies.isEmpty {
                center = frequencies[p25ScanIndex]
                status = "Scanning local P25 control frequencies · \(p25ScanIndex + 1) of \(frequencies.count) · \(Self.mhz(center)) MHz"
            } else {
                status = "Listening for valid P25 network IDs at \(Self.mhz(center)) MHz…"
            }
            send("p25 \(center)")
            return
        }
        if mode == .audio {
            status = "Starting live analog FM audio…"
            send("audio \(center)")
            return
        }
        if mode == .tpms {
            status = "Listening for supported Schrader TPMS packets…"
            send("tpms \(center)")
            return
        }
        if mode == .find {
            status = "Learning nearby background around \(Self.mhz(center)) MHz…"
            send("find \(center)")
            return
        }
        let requested = mode == .sweep ? tiles[tileIndex].center : center
        if mode == .sweep {
            status = "Sweeping \(Self.mhz(requested)) MHz · pass \(tiles[tileIndex].pass + 1) of 2"
        } else if mode == .activity {
            status = "Watching \(channels.count) channels"
        } else {
            status = "Tuned to \(Self.mhz(center)) MHz"
        }
        send("capture \(requested)")
    }

    private func send(_ command: String) {
        if let sendThroughChooser {
            sendThroughChooser(command)
        } else {
            do {
                try commands?.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
            } catch {
                disconnect("Could not send USB command")
                return
            }
        }
        timeout?.cancel()
        let wait = DispatchWorkItem { [weak self] in
            self?.disconnect("The P4 did not respond")
        }
        timeout = wait
        let responseTimeout: TimeInterval =
            (command.hasPrefix("faa match ") || command == "sd export adsb") ? 90 : 12
        DispatchQueue.main.asyncAfter(deadline: .now() + responseTimeout, execute: wait)
    }

    func setSDLogging(_ enabled: Bool) {
        guard ready else { return }
        send(enabled ? "sd logging on" : "sd logging off")
    }

    func matchObservedAircraftToFAAMasterOnSD() {
        guard ready, !running, sdMounted else { return }
        let addresses = Array(Set(adsbObservations.map(\.address))).sorted()
        guard !addresses.isEmpty else {
            registryImportMessage = "Capture at least one aircraft before matching the FAA catalog."
            return
        }
        guard addresses.count <= 64 else {
            registryImportMessage = "Match up to 64 observed aircraft per FAA catalog scan."
            return
        }
        registryImporting = true
        registryImportMessage = "Scanning the FAA catalog on the SD card…"
        send("faa match " + addresses.joined(separator: ","))
    }

    func exportADSBFramesToSD() {
        guard ready, !running, sdMounted else { return }
        sdExportMessage = "Exporting logged ADS-B frames to the SD card…"
        send("sd export adsb")
    }

    private func disconnect(_ reason: String? = nil) {
        if let reason { status = reason } else if ready || status == "Connecting over USB…" {
            status = "USB disconnected"
        }
        ready = false
        running = false
        stopping = false
        timeout?.cancel()
    }

    func read(_ chunk: Data) {
        pending.append(chunk)
        while let end = pending.firstIndex(of: 10) {
            let line = pending[..<end]
            if let event = try? decoder.decode(RFEvent.self, from: line) {
                receive(event)
            } else if let text = String(data: line, encoding: .utf8),
                      text.contains("SerialException:") || text.hasPrefix("Serial command failed:") {
                disconnect(text)
            }
            pending.removeSubrange(...end)
        }
    }

    private func receive(_ event: RFEvent) {
        switch event.type {
        case "ready":
            timeout?.cancel()
            ready = true
            status = "ESP32-P4 connected over USB"
        case "sd_status":
            sdStatusAvailable = true
            sdMounted = event.mounted ?? false
            sdLogging = event.logging ?? false
            sdCapacityBytes = event.capacity_bytes ?? 0
            sdFreeBytes = event.free_bytes ?? 0
            sdFAAMasterPresent = event.faa_master_present ?? false
            sdPath = event.path ?? "/sdcard/RF_SENTINEL"
            sdError = event.error
        case "sd_export":
            timeout?.cancel()
            if event.ok == true, let rows = event.rows, let path = event.path {
                sdExportMessage = "Saved \(rows) ADS-B frame rows to \(path)."
            } else {
                sdExportMessage = event.error ?? "ADS-B export failed."
            }
        case "faa_match":
            guard let address = event.icao, let registration = event.registration else { return }
            let entry = ADSBRegistryEntry(address: address, callsign: "",
                                          category: "FAA type \(event.aircraft_type ?? "unknown")",
                                          source: event.source ?? "FAA Registry MASTER.txt",
                                          sourceDate: event.last_action_date ?? "",
                                          registration: registration,
                                          yearManufactured: event.year)
            adsbRegistry.removeAll { $0.address == address }
            adsbRegistry.append(entry)
            if let data = try? JSONEncoder().encode(adsbRegistry) {
                UserDefaults.standard.set(data, forKey: "adsb.localRegistry.v1")
            }
        case "faa_match_complete":
            timeout?.cancel()
            registryImporting = false
            if event.ok == true {
                registryImportMessage = event.matches == 0
                    ? "No observed aircraft matched a Mode S code in the FAA catalog."
                    : "Matched \(event.matches ?? 0) observed aircraft to the FAA catalog on the SD card."
            } else {
                registryImportMessage = event.error ?? "FAA catalog lookup failed."
            }
        case "stopped":
            if running, mode == .p25, let frequencies = p25ScanFrequencies, !frequencies.isEmpty {
                p25DwellTask?.cancel()
                p25DwellTask = nil
                p25ScanIndex = (p25ScanIndex + 1) % frequencies.count
                center = frequencies[p25ScanIndex]
                status = "Scanning local P25 control frequencies · \(p25ScanIndex + 1) of \(frequencies.count) · \(Self.mhz(center)) MHz"
                let scanRun = runID
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.running, self.mode == .p25,
                          self.runID == scanRun, self.p25ScanFrequencies != nil else { return }
                    self.captureNext()
                }
                return
            }
            timeout?.cancel()
            stopping = false
            running = false
            audioOutput.stop()
            if progress == 1 {
                let missing = trace.count(where: { $0 == nil })
                if missing > 0 {
                    status = "Sweep finished · \(missing) frequency bins missing"
                } else {
                    status = signals.isEmpty
                        ? "Sweep complete · No repeatable signals above \(Int(threshold)) dB"
                        : "Sweep complete · \(signals.count) repeatable signals"
                }
            } else if !status.hasPrefix("Capture failed") {
                status = mode == .iq ? "IQ capture stopped · tuner idle"
                    : mode == .adsb ? "Stopped · \(adsbObservations.count) aircraft in this session"
                    : mode == .tetra ? "Stopped · \(tetraCandidateCount) burst candidates"
                    : mode == .p25 ? "Stopped · \(p25ValidNIDs) valid P25 network IDs"
                    : mode == .find ? (findObservation == nil ? "Finder stopped · no new signal candidate" : "Finder stopped · estimate retained")
                                    : "Tuner released"
            }
        case "iq_started":
            timeout?.cancel()
            if let rate = event.rate { sampleRate = rate }
            status = "Capturing continuous IQ · receive only"
        case "adsb_started":
            timeout?.cancel()
            if let rate = event.rate { sampleRate = rate }
            shownCenter = 1_090_000_000
            status = "Receiving · No valid messages yet"
        case "tetra_started":
            timeout?.cancel()
            if let rate = event.rate { sampleRate = rate }
            if let center = event.center { shownCenter = center }
            status = "Listening · No burst candidates yet"
        case "p25_started":
            timeout?.cancel()
            if let rate = event.rate { sampleRate = rate }
            if let center = event.center { shownCenter = center }
            status = "Listening · No valid P25 network IDs yet"
            if p25ScanFrequencies != nil {
                let scanRun = runID
                let dwell = DispatchWorkItem { [weak self] in
                    guard let self, self.running, self.mode == .p25,
                          self.runID == scanRun, self.p25ScanFrequencies != nil else { return }
                    self.send("stop")
                }
                p25DwellTask?.cancel()
                p25DwellTask = dwell
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: dwell)
            }
        case "audio_started":
            timeout?.cancel()
            if let rate = event.rate { sampleRate = rate }
            if let center = event.center { shownCenter = center }
            do {
                try audioOutput.start()
                status = "Live analog FM audio · receive only · not recording"
            } catch {
                status = "Could not start Mac audio output: \(error.localizedDescription)"
                stop()
            }
        case "audio_metrics":
            if let rate = event.rate { sampleRate = rate }
            if let samples = event.samples { audioSamplesReceived = samples }
            if let drops = event.dropped_samples { audioDroppedSamples = drops }
            if let elapsed = event.elapsed_ms { audioElapsedMilliseconds = elapsed }
            if let samples = event.demod_samples { audioDemodSamples = samples }
            if let blocks = event.firmware_blocks { audioFirmwareBlocks = blocks }
            lastUpdated = Date()
        case "audio_bridge_metrics":
            if let lines = event.audio_lines { audioBridgeLines = lines }
            if let bytes = event.audio_bytes { audioBridgeBytes = bytes }
            if let errors = event.audio_errors { audioBridgeErrors = errors }
            if let detail = event.audio_error_detail { audioBridgeErrorDetail = detail }
            lastUpdated = Date()
        case "tpms_started":
            timeout?.cancel()
            if let rate = event.rate { sampleRate = rate }
            if let center = event.center { shownCenter = center }
            status = "Listening · No CRC-valid Schrader packets yet"
        case "find_started":
            timeout?.cancel()
            if let rate = event.rate { sampleRate = rate }
            if let center = event.center { shownCenter = center }
            iqSamples = 0
            iqDroppedSamples = 0
            iqElapsedMilliseconds = 0
            status = "Learning background before the search…"
        case "find_armed":
            timeout?.cancel()
            status = "Ready · Send one brief test transmission inside the displayed search band"
        case "find_learning":
            status = "Relearning background after lost samples…"
        case "find_metrics":
            if let rate = event.rate { sampleRate = rate }
            if let samples = event.samples { iqSamples = samples }
            if let drops = event.dropped_samples { iqDroppedSamples = drops }
            if let elapsed = event.elapsed_ms { iqElapsedMilliseconds = elapsed }
            lastUpdated = Date()
        case "find_result":
            guard running, let frequency = event.frequency, let rise = event.rise_db else { return }
            let center = event.center ?? shownCenter
            let resolution = event.resolution_hz ?? sampleRate / 512
            findObservation = FrequencyObservation(frequencyHz: frequency, centerHz: center,
                                                   riseDB: rise, resolutionHz: resolution,
                                                   receivedAt: Date())
            status = "New signal candidate · \(Self.mhz(frequency)) MHz · +\(String(format: "%.1f", rise)) dB over learned background"
            lastUpdated = Date()
        case "tpms_metrics":
            if let rate = event.rate { sampleRate = rate }
            if let samples = event.samples { iqSamples = samples }
            if let drops = event.dropped_samples { iqDroppedSamples = drops }
            if let elapsed = event.elapsed_ms { iqElapsedMilliseconds = elapsed }
            if let count = event.valid_packets { tpmsValidPackets = count }
            status = running ? (tpmsValidPackets == 0 ? "Listening · No CRC-valid Schrader packets yet" : "Receiving · \(tpmsValidPackets) CRC-valid packets") : status
            lastUpdated = Date()
        case "tpms_packet":
            guard running, let id = event.id, let flags = event.flags,
                  let pressure = event.pressure_hpa, let temperature = event.temperature_c else { return }
            let center = event.center ?? shownCenter
            let observation = TPMSObservation(id: id, flags: flags, pressureHpa: pressure,
                                              temperatureC: temperature, centerHz: center, lastSeen: Date())
            tpmsObservations.removeAll { $0.id == id && $0.centerHz == center }
            tpmsObservations.insert(observation, at: 0)
            if tpmsObservations.count > 32 { tpmsObservations.removeLast(tpmsObservations.count - 32) }
            tpmsValidPackets = event.valid_packets ?? tpmsValidPackets + 1
            status = "CRC-valid Schrader TPMS packet · \(id)"
            lastUpdated = Date()
        case "audio_pcm":
            audioEventsReceived += 1
            guard running else {
                audioLateEventsDiscarded += 1
                return
            }
            guard let encoded = event.pcm, let payload = Data(base64Encoded: encoded) else {
                audioPayloadErrors += 1
                return
            }
            let data: Data
            if event.codec == "ima_adpcm4" {
                guard let count = event.samples, count <= UInt64(Int.max),
                      let decoded = LiveAudioOutput.decodeIMAADPCM(payload, sampleCount: Int(count)) else {
                    audioPayloadErrors += 1
                    return
                }
                data = decoded
            } else if event.codec == nil {
                data = payload
            } else {
                audioPayloadErrors += 1
                return
            }
            audioOutput.enqueue(data)
            audioBlocksReceived += 1
        case "tetra_metrics":
            if let rate = event.rate { sampleRate = rate }
            if let samples = event.samples { iqSamples = samples }
            if let drops = event.dropped_samples { iqDroppedSamples = drops }
            if let elapsed = event.elapsed_ms { iqElapsedMilliseconds = elapsed }
            if let count = event.candidate_count { tetraCandidateCount = count }
            if running && tetraCandidateCount == 0 { status = "Listening · No burst candidates yet" }
            else if running { status = "Listening · \(tetraCandidateCount) burst candidates" }
            lastUpdated = Date()
        case "p25_metrics":
            if let rate = event.rate { sampleRate = rate }
            if let samples = event.samples { iqSamples = samples }
            if let drops = event.dropped_samples { iqDroppedSamples = drops }
            if let elapsed = event.elapsed_ms { iqElapsedMilliseconds = elapsed }
            if let count = event.valid_nids { p25ValidNIDs = count }
            if running && p25ControlCandidates.isEmpty { status = "Listening · No repeated P25 control-format headers yet" }
            else if running { status = "Listening · \(p25ControlCandidates.count) control-channel candidate(s) · not message-validated" }
            lastUpdated = Date()
        case "p25_nid":
            guard let nac = event.nac, let duid = event.duid else { return }
            let center = event.center ?? shownCenter
            if let index = p25Observations.firstIndex(where: { $0.nac == nac && $0.duid == duid }) {
                p25Observations[index].frames += 1
                p25Observations[index].centerHz = center
            } else {
                p25Observations.insert(P25NIDObservation(nac: nac, duid: duid, frames: 1, centerHz: center), at: 0)
            }
            p25ValidNIDs = event.valid_nids ?? p25ValidNIDs + 1
            status = "Valid P25 NID · NAC \(String(format: "%03X", nac)) · DUID \(duid)"
            lastUpdated = Date()
        case "p25_control_candidate":
            guard let nac = event.nac else { return }
            let center = event.center ?? shownCenter
            let repeats = Int(event.repeated_nids ?? 3)
            if let index = p25ControlCandidates.firstIndex(where: { $0.nac == nac && $0.centerHz == center }) {
                p25ControlCandidates[index].repeatedNIDs = max(p25ControlCandidates[index].repeatedNIDs, repeats)
                p25ControlCandidates[index].lastSeen = Date()
            } else {
                p25ControlCandidates.insert(P25ControlCandidate(nac: nac, repeatedNIDs: repeats,
                                                                 centerHz: center, lastSeen: Date()), at: 0)
            }
            if p25ControlCandidates.count > 16 { p25ControlCandidates.removeLast() }
            status = "P25 control-channel candidate · NAC \(String(format: "%03X", nac)) · TSBK not validated"
            lastUpdated = Date()
        case "p25_grant":
            guard running, let nac = event.nac, let opcode = event.opcode, let channel = event.channel else { return }
            let control = event.center ?? shownCenter
            let decodedFrequency = event.frequency.flatMap { $0 > 0 ? $0 : nil }
            let grant = P25GrantObservation(frequencyHz: decodedFrequency, controlHz: control, nac: nac,
                                            opcode: opcode, channel: channel,
                                            talkgroup: event.talkgroup == 0 ? nil : event.talkgroup,
                                            lastSeen: Date())
            if let index = p25Grants.firstIndex(where: { $0.id == grant.id }) {
                p25Grants[index] = grant
            } else {
                p25Grants.insert(grant, at: 0)
            }
            p25Grants.sort { $0.lastSeen > $1.lastSeen }
            if p25Grants.count > 40 { p25Grants.removeLast(p25Grants.count - 40) }
            status = "CRC-valid P25 channel assignment · \(decodedFrequency.map { Self.mhz($0) + " MHz" } ?? "channel \(channel)") · NAC \(String(format: "%03X", nac))"
            lastUpdated = Date()
        case "tetra_candidate", "tetra_strength":
            guard let candidate = event.candidate_id, let strength = event.strength_dbfs else { return }
            if let center = event.center { shownCenter = center }
            tetraCurrentStrength = strength
            tetraStrengths.append(strength)
            if tetraStrengths.count > 120 { tetraStrengths.removeFirst(tetraStrengths.count - 120) }
            if event.type == "tetra_candidate" {
                tetraCandidateCount = max(tetraCandidateCount, candidate)
                tetraCandidateHistory.insert((candidate, strength), at: 0)
                if tetraCandidateHistory.count > 20 { tetraCandidateHistory.removeLast() }
                status = "Burst candidate · relative level \(String(format: "%.1f", strength)) dBFS"
            }
            lastUpdated = Date()
        case "adsb_metrics":
            if let rate = event.rate { sampleRate = rate }
            if let samples = event.samples { iqSamples = samples }
            if let drops = event.dropped_samples { iqDroppedSamples = drops }
            if let elapsed = event.elapsed_ms { iqElapsedMilliseconds = elapsed }
            if let count = event.valid_frames { adsbValidFrames = count }
            if running && adsbValidFrames == 0 { status = "Receiving · No valid messages yet" }
            else if running { status = "Receiving ADS-B · Local RTL-SDR" }
            lastUpdated = Date()
        case "iq_metrics":
            if let rate = event.rate { sampleRate = rate }
            if let samples = event.samples { iqSamples = samples }
            if let drops = event.dropped_samples { iqDroppedSamples = drops }
            if let elapsed = event.elapsed_ms { iqElapsedMilliseconds = elapsed }
            lastUpdated = Date()
        case "iq_waveform":
            guard let inPhase = event.i, let quadrature = event.q,
                  inPhase.count > 1, quadrature.count == inPhase.count else { return }
            iqInPhase = inPhase.map { Double($0) / 128.0 }
            iqQuadrature = quadrature.map { Double($0) / 128.0 }
            if let center = event.center { shownCenter = center }
            if let rate = event.rate { sampleRate = rate }
        case "error":
            timeout?.cancel()
            p25DwellTask?.cancel()
            p25DwellTask = nil
            p25ScanFrequencies = nil
            let wasReleasing = stopping
            running = false
            stopping = false
            audioOutput.stop()
            // ESP-IDF ESP_ERR_NOT_FOUND means the P4 could not find the receiver.
            if !wasReleasing, mode == .p25, event.code == 0x105 {
                status = "RTL-SDR not found by the P4. Reconnect it to the P4’s USB host port, then tap Listen."
                return
            }
            // The receiver driver stays in its FAULT state until recovery.
            if event.code == 0x12A09 {
                status = "RTL-SDR driver fault. Reopen RF Monitor from Sentinel Tools, then retry."
                return
            }
            status = wasReleasing ? "Could not release tuner (\(event.code ?? 0))"
                                   : mode == .adsb ? "ADS-B capture failed (\(event.code ?? 0))"
                                   : mode == .tetra ? "TETRA capture failed (\(event.code ?? 0))"
                                   : mode == .p25 ? "P25 capture failed (\(event.code ?? 0))"
                                                   : "Capture failed (\(event.code ?? 0))"
        case "adsb_frame":
            guard running, let address = event.icao else { return }
            var observation = adsbObservations.first(where: { $0.address == address })
                ?? ADSBObservation(address: address, callsign: nil, altitudeFeet: nil,
                                   altitudeKind: nil, messages: 0, lastSeen: Date())
            if let callsign = event.callsign, !callsign.isEmpty { observation.callsign = callsign }
            if let altitude = event.altitude_ft {
                observation.altitudeFeet = altitude
                observation.altitudeKind = event.altitude_kind
            }
            observation.messages += 1
            observation.lastSeen = Date()
            adsbObservations.removeAll { $0.address == address }
            adsbObservations.append(observation)
            adsbObservations.sort { $0.lastSeen > $1.lastSeen }
            if adsbObservations.count > 40 { adsbObservations.removeLast(adsbObservations.count - 40) }
            adsbValidFrames = max(adsbValidFrames, UInt64(adsbObservations.reduce(0) { $0 + $1.messages }))
            status = "Receiving ADS-B · Local RTL-SDR"
        case "frame":
            // A frame already being captured can arrive after Stop was requested.
            guard running, let hz = event.center, let rate = event.rate,
                  (800_000...1_000_000).contains(rate), let bins = event.bins, bins.count == 512 else { return }
            timeout?.cancel()
            lastUpdated = Date()
            sampleRate = rate
            if (event.drops ?? 0) > 0 { affectedFrames += 1 }
            if mode != .sweep {
                shownCenter = hz
                trace = bins.enumerated().map { i, value in
                    abs((i - bins.count / 2) * rate / bins.count) < 15_000 ? nil : Double(value) / 10
                }
                if mode == .activity {
                    detector?.observe(bins: bins, center: hz, rate: rate,
                                      dropped: (event.drops ?? 0) > 0,
                                      time: ProcessInfo.processInfo.systemUptime)
                    channels = detector?.observations ?? []
                }
                let captureRun = runID
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.runID == captureRun else { return }
                    self.captureNext()
                }
            } else {
                if (event.drops ?? 0) == 0 { incorporate(bins: bins, center: hz, rate: rate) }
                tileIndex += 1
                progress = Double(tileIndex) / Double(tiles.count)
                if tileIndex == tiles.count {
                    signals = SweepDetector.signals(in: passes, low: Self.fmLow, step: Self.step,
                                                    threshold: threshold)
                    stop()
                } else {
                    captureNext()
                }
            }
        default: break
        }
    }

    private func incorporate(bins: [Int], center hz: Int, rate: Int) {
        let pass = tiles[tileIndex].pass
        let sampleStep = Double(rate) / Double(bins.count)
        let minimum = max(0, (hz - 350_000 - Self.fmLow) / Self.step)
        let maximum = min(trace.count - 1, (hz + 350_000 - Self.fmLow) / Self.step)
        for i in minimum...maximum {
            let offset = Self.fmLow + i * Self.step - hz
            guard (30_000...337_500).contains(abs(offset)) else { continue }
            let rank = abs(abs(offset) - 175_000)
            guard rank < distances[pass][i] else { continue }
            let middle = Double(bins.count / 2) + Double(offset) / sampleStep
            let half = Double(Self.step) / (2 * sampleStep)
            let low = Int(ceil(middle - half)), high = Int(floor(middle + half))
            let sum = bins[low...high].reduce(0.0) { $0 + pow(10, Double($1) / 100) }
            passes[pass][i] = 10 * log10(sum / Double(high - low + 1))
            distances[pass][i] = rank
            let levels = passes.compactMap { $0[i] }
            // Use the weaker reading where both grids cover a bin.
            trace[i] = levels.min()
        }
    }

    static func mhz(_ frequency: Int) -> String { String(format: "%.3f", Double(frequency) / 1e6) }
}

private struct SpectrumChart: View {
    let samples: [Double?]
    let low: Int
    let high: Int
    let marker: Int?
    var markedSpan: ClosedRange<Int>?

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                VStack {
                    Text("−25")
                    Spacer()
                    Text("−60")
                    Spacer()
                    Text("−95")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Canvas { context, size in
                    var grid = Path()
                    for i in 0...4 {
                        let x = size.width * Double(i) / 4
                        grid.move(to: CGPoint(x: x, y: 0))
                        grid.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for i in 0...2 {
                        let y = size.height * Double(i) / 2
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(.secondary.opacity(0.30)), lineWidth: 1)
                    if let markedSpan {
                        let start = size.width * Double(max(low, markedSpan.lowerBound) - low) / Double(high - low)
                        let end = size.width * Double(min(high, markedSpan.upperBound) - low) / Double(high - low)
                        if end > start {
                            let area = CGRect(x: start, y: 0, width: end - start, height: size.height)
                            context.fill(Path(area), with: .color(.orange.opacity(0.18)))
                        }
                    }

                    var signal = Path()
                    var inSegment = false
                    for (i, level) in samples.enumerated() {
                        guard let level else { inSegment = false; continue }
                        let x = size.width * Double(i) / Double(max(samples.count - 1, 1))
                        let y = size.height * min(1, max(0, (-25 - level) / 70))
                        let point = CGPoint(x: x, y: y)
                        if inSegment { signal.addLine(to: point) } else { signal.move(to: point) }
                        inSegment = true
                    }
                    context.stroke(signal, with: .color(.cyan), lineWidth: 1.5)

                    if let marker, (low...high).contains(marker) {
                        let x = size.width * Double(marker - low) / Double(high - low)
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: 0))
                        line.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(line, with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .background(.black.opacity(0.87), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("Spectrum, relative dBFS")
            }
            HStack {
                Text(RFMonitor.mhz(low))
                Spacer()
                Text("MHz")
                Spacer()
                Text(RFMonitor.mhz(high))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.leading, 25)
        }
        .frame(minHeight: 250)
    }
}

private enum TetraBand: String, CaseIterable {
    case low = "390.000 MHz · 380–400 band"
    case mid = "420.000 MHz · 410–430 band"
    case high = "460.000 MHz · 450–470 band"

    var centerHz: Int {
        switch self {
        case .low: 390_000_000
        case .mid: 420_000_000
        case .high: 460_000_000
        }
    }
}

private enum P25Band: String, CaseIterable {
    case route = "San Mateo → South Lake Tahoe"
    case sanMateo = "San Mateo County"
    case contraCosta = "Contra Costa County"
    case alameda = "Alameda County"
    case sacramento = "Sacramento County"
    case elDorado = "El Dorado County"
    case tahoe = "Tahoe Basin"
    case manual = "Manual · 770 MHz"

    var scanFrequencies: [Int] {
        switch self {
        case .route:
            // Published CC candidates for the Bay Area → Sacramento → US-50 corridor.
            // Keep this set compact enough to cycle during a road trip.
            [772_031_250, 772_106_250, 772_256_250, 772_406_250, 772_706_250, 772_781_250, 773_406_250, 773_481_250,
             773_968_750, 774_631_250, 774_706_250,
             770_206_250, 770_943_750, 773_543_750, 773_818_750, 770_443_750, 773_068_750, 773_568_750, 774_056_250,
             773_906_250, 774_181_250, 774_456_250, 774_731_250, 853_287_500, 853_300_000, 853_737_500, 853_750_000,
             771_943_750, 772_243_750, 772_543_750, 772_843_750,
             769_206_250, 770_906_250, 773_318_750, 774_068_750, 770_156_250, 770_456_250, 770_706_250, 773_043_750,
             769_406_250, 770_656_250, 773_306_250, 773_593_750,
             151_197_500, 151_452_500, 152_142_500, 152_157_500, 161_837_500, 152_052_500, 152_067_500, 152_127_500]
        case .sanMateo:
            [772_031_250, 772_406_250, 772_706_250, 773_481_250,
             771_356_250, 772_256_250, 773_968_750, 774_631_250, 772_106_250, 772_781_250, 773_406_250, 774_706_250,
             772_181_250, 772_631_250, 772_931_250, 773_881_250]
        case .contraCosta:
            [770_443_750, 773_068_750, 773_568_750, 774_056_250,
             773_906_250, 774_181_250, 774_456_250, 774_731_250,
             853_287_500, 853_300_000, 853_737_500, 853_750_000]
        case .alameda:
            [770_206_250, 770_943_750, 773_543_750, 773_818_750,
             771_943_750, 772_243_750, 772_543_750, 772_843_750,
             772_768_750, 773_668_750, 774_143_750, 774_893_750]
        case .sacramento:
            [769_206_250, 770_906_250, 773_318_750, 774_068_750,
             770_156_250, 770_456_250, 770_706_250, 773_043_750,
             770_206_250, 770_943_750, 773_543_750, 773_818_750]
        case .elDorado:
            [769_406_250, 770_656_250, 773_306_250, 773_593_750]
        case .tahoe:
            [151_197_500, 151_452_500, 152_142_500, 152_157_500, 161_837_500, 152_052_500, 152_067_500, 152_127_500]
        case .manual: []
        }
    }
    var centerHz: Int { scanFrequencies.first ?? 770_000_000 }
}

private enum GMRSChannel: Int, CaseIterable, Identifiable {
    case ch1 = 1, ch2, ch3, ch4, ch5, ch6, ch7, ch8, ch9, ch10, ch11, ch12, ch13, ch14,
         ch15, ch16, ch17, ch18, ch19, ch20, ch21, ch22
    var id: Int { rawValue }
    var frequencyHz: Int {
        switch rawValue {
        case 1...7: 462_562_500 + (rawValue - 1) * 25_000
        case 8...14: 467_562_500 + (rawValue - 8) * 25_000
        default: 462_550_000 + (rawValue - 15) * 25_000
        }
    }
    var label: String { "Channel \(rawValue) · \(String(format: "%.4f", Double(frequencyHz) / 1e6)) MHz" }
}

private enum TPMSBand: String, CaseIterable {
    case northAmerica = "315 MHz · North America"
    case aftermarket433 = "433.920 MHz · selected sensors"
    var centerHz: Int { self == .northAmerica ? 315_000_000 : 433_920_000 }
}

private struct TetraStrengthChart: View {
    let values: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Relative signal level").font(.headline)
                Spacer()
                Text("dBFS · one reading per second while active")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Canvas { context, size in
                for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    let y = size.height * fraction
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                }
                guard values.count > 1 else { return }
                var trace = Path()
                for (index, value) in values.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = size.height * CGFloat(1.0 - min(0, max(-100, value)) / -100.0)
                    let point = CGPoint(x: x, y: y)
                    if index == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
                }
                context.stroke(trace, with: .color(.orange), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 105)
            .overlay(alignment: .leading) {
                VStack { Text("0"); Spacer(); Text("−50"); Spacer(); Text("−100") }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .offset(x: 4)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct IQWaveformChart: View {
    let inPhase: [Double]
    let quadrature: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Received I/Q waveform")
                    .font(.caption.weight(.semibold))
                Spacer()
                Label("I", systemImage: "waveform.path")
                    .foregroundStyle(.cyan)
                Label("Q", systemImage: "waveform.path")
                    .foregroundStyle(.pink)
            }
            Canvas { context, size in
                var grid = Path()
                for row in 0...4 {
                    let y = size.height * CGFloat(row) / 4
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                for column in 0...4 {
                    let x = size.width * CGFloat(column) / 4
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(grid, with: .color(.white.opacity(0.18)), lineWidth: 1)

                func waveform(_ values: [Double], color: Color) {
                    guard values.count > 1 else { return }
                    var path = Path()
                    for (index, sample) in values.enumerated() {
                        let x = CGFloat(index) / CGFloat(values.count - 1) * size.width
                        let y = CGFloat((1 - max(-1, min(1, sample))) / 2) * size.height
                        let point = CGPoint(x: x, y: y)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(color),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }

                waveform(inPhase, color: .cyan)
                waveform(quadrature, color: .pink)
            }
            .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
            .frame(height: 220)
            .accessibilityLabel(inPhase.isEmpty
                                ? "Received I and Q waveform. Start capture to display samples."
                                : "Received I and Q waveform, \(inPhase.count) preview samples")
            Text(inPhase.isEmpty
                 ? "Start capture to display received samples."
                 : "Preview from recent captured samples · I and Q centered on zero")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct RFView: View {
    @StateObject private var monitor: RFMonitor
    @State private var mode = RFMonitor.Mode.sweep
    @State private var frequency = "98.0"
    @State private var bank = ChannelBank.frs462
    @State private var tetraBand = TetraBand.low
    @State private var p25Band = P25Band.route
    @State private var gmrsChannel = GMRSChannel.ch1
    @State private var tpmsBand = TPMSBand.northAmerica
    @State private var threshold = 6
    @State private var selectedPeak: Int?
    @State private var showingRegistryImporter = false
    @State private var registryImportMessage: String?

    init(monitor: RFMonitor? = nil) {
        _monitor = StateObject(wrappedValue: monitor ?? RFMonitor())
    }

    private var requested: Int? {
        guard let value = Double(frequency), (87.5...468.5).contains(value) else { return nil }
        return Int((value * 1e6).rounded())
    }

    private var p25ManualCenter: Int? {
        guard let value = Double(frequency), (24.0...1766.0).contains(value) else { return nil }
        return Int((value * 1e6).rounded())
    }

    private var sdCardStatus: some View {
        let freeSpace = monitor.sdFreeBytes > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(clamping: monitor.sdFreeBytes), countStyle: .file) + " free"
            : "free space unavailable"
        let errorDetail = monitor.sdError.map { " · \($0)" } ?? ""
        return HStack(spacing: 8) {
            Image(systemName: monitor.sdMounted ? "externaldrive.fill" : "externaldrive.badge.xmark")
                .foregroundStyle(monitor.sdMounted ? .green : .secondary)
            if !monitor.sdStatusAvailable {
                Text("SD card status pending")
            } else if !monitor.sdMounted {
                Text("SD card unavailable\(errorDetail)")
            } else {
                Text("SD card · \(freeSpace) · Event logging \(monitor.sdLogging ? "on" : "off")")
                if monitor.sdFAAMasterPresent {
                    Text("FAA MASTER found").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(monitor.sdLogging ? "Pause logging" : "Resume logging") {
                    monitor.setSDLogging(!monitor.sdLogging)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!monitor.ready)
            }
            if !monitor.sdMounted { Spacer(minLength: 0) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    var body: some View {
        let sweep = mode == .sweep
        let watching = mode == .activity
        let adsb = mode == .adsb
        let tetra = mode == .tetra
        let p25 = mode == .p25
        let audio = mode == .audio
        let tpms = mode == .tpms
        let finder = mode == .find
        let half = monitor.sampleRate / 2
        let selected = monitor.signals.first(where: { $0.id == selectedPeak }) ?? monitor.signals.first
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RF Monitor").font(.title2.bold())
                Spacer()
                Text("Mode").foregroundStyle(.secondary)
                Picker("Mode", selection: $mode) {
                    ForEach(RFMonitor.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).labelsHidden().frame(width: 160)
                    .disabled(monitor.running || monitor.stopping)
                Button(monitor.running ? "Stop" : sweep ? "Sweep" : mode == .iq ? "Start Capture" : (adsb || tetra || p25 || audio || tpms) ? "Listen" : finder ? "Find" : "Start") {
                    if monitor.running { monitor.stop() }
                    else {
                        selectedPeak = nil
                        monitor.start(mode, frequency: tetra ? tetraBand.centerHz : p25 ? (p25Band == .manual ? p25ManualCenter ?? p25Band.centerHz : p25Band.centerHz) : audio ? gmrsChannel.frequencyHz : tpms ? tpmsBand.centerHz : requested ?? 98_000_000, bank: bank,
                                      threshold: Double(threshold), p25ScanFrequencies: p25Band.scanFrequencies)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!monitor.ready || monitor.stopping
                          || ((mode == .tune || mode == .iq || finder) && requested == nil && !monitor.running)
                          || (p25 && p25Band == .manual && p25ManualCenter == nil && !monitor.running))
            }
            sdCardStatus
            HStack {
                if adsb {
                    Text("1090 MHz · Local RTL-SDR · receive-only")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else if tetra {
                    Picker("TETRA band", selection: $tetraBand) {
                        ForEach(TetraBand.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.fixedSize().disabled(monitor.running || monitor.stopping)
                    Text("250 kHz slice · 250 kS/s · receive-only")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else if p25 {
                    Picker("P25 scan plan", selection: $p25Band) {
                        ForEach(P25Band.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.fixedSize().disabled(monitor.running || monitor.stopping)
                    Text(p25Band.scanFrequencies.isEmpty ? "250 kHz slice · manual tuning · receive-only" : "\(p25Band.scanFrequencies.count) control-channel candidates · 250 kS/s · receive-only")
                        .foregroundStyle(.secondary)
                    Text("Area selected manually · no GPS required")
                        .font(.caption2).foregroundStyle(.secondary)
                    if p25Band == .manual {
                        TextField("MHz", text: $frequency).frame(width: 95).disabled(monitor.running)
                        Text("MHz")
                    }
                    Spacer()
                } else if audio {
                    Picker("GMRS channel", selection: $gmrsChannel) {
                        ForEach(GMRSChannel.allCases) { channel in Text(channel.label).tag(channel) }
                    }.fixedSize().disabled(monitor.running || monitor.stopping)
                    Text("Narrowband FM · Mac audio · receive only")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else if tpms {
                    Picker("TPMS frequency", selection: $tpmsBand) {
                        ForEach(TPMSBand.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.fixedSize().disabled(monitor.running || monitor.stopping)
                    Text("Schrader family only · CRC checked · receive only")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else if mode == .tune || mode == .iq || finder {
                    Text("Center")
                    TextField("MHz", text: $frequency).frame(width: 95).disabled(monitor.running)
                    Text("MHz")
                    Text(finder ? "±480 kHz · receive-only" : mode == .iq ? "250 kS/s · receive-only" : "960 kS/s · 29.7 dB gain")
                        .foregroundStyle(.secondary)
                    if finder { Spacer() }
                } else {
                    if watching {
                        Picker("Channels", selection: $bank) {
                            ForEach(ChannelBank.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.fixedSize().disabled(monitor.running || monitor.stopping)
                    }
                    Spacer()
                    Picker("Above noise", selection: $threshold) {
                        ForEach([6, 9, 12, 15], id: \.self) { Text("\($0) dB").tag($0) }
                    }.fixedSize().disabled(monitor.running || monitor.stopping)
                }
            }.font(.callout)
            if adsb {
                adsbReadings
            } else if tetra {
                TetraStrengthChart(values: monitor.tetraStrengths)
                tetraReadings
            } else if p25 {
                p25Readings
            } else if audio {
                audioReadings
            } else if tpms {
                tpmsReadings
            } else if finder {
                frequencyFinderReadings
            } else if mode == .iq {
                IQWaveformChart(inPhase: monitor.iqInPhase, quadrature: monitor.iqQuadrature)
            } else {
                SpectrumChart(samples: monitor.trace,
                              low: sweep ? RFMonitor.fmLow : monitor.shownCenter - half,
                              high: sweep ? RFMonitor.fmHigh : monitor.shownCenter + half,
                              marker: sweep ? selected?.peak : nil,
                              markedSpan: selected.map { ($0.span.lowerBound - 12_500)...($0.span.upperBound + 12_500) })
            }
            if let progress = monitor.progress { ProgressView(value: progress) }
            if adsb { adsbCaptureSummary }
            else if tetra { tetraCaptureSummary }
            else if p25 { p25CaptureSummary }
            else if audio { audioCaptureSummary }
            else if tpms { tpmsCaptureSummary }
            else if finder { frequencyFinderSummary }
            else if mode == .iq { iqCaptureSummary }
            if sweep && !monitor.signals.isEmpty {
                detections(selected)
            }
            if watching && !monitor.channels.isEmpty {
                channelReadings
            }
            HStack {
                Text(monitor.status).lineLimit(2)
                Spacer()
                if let selected, sweep, !monitor.stopping {
                    Button("Tune \(RFMonitor.mhz(selected.peak)) MHz") {
                        frequency = RFMonitor.mhz(selected.peak)
                        mode = .tune
                    }
                }
                if let date = monitor.lastUpdated { Text(date, style: .time).monospacedDigit() }
            }.font(.callout)
            Text(adsb ? "Locally received broadcast data · Address and callsign are not independently verified"
                 : tetra ? "Energy-rise candidates only · TETRA is not decoded · dBFS is relative level, not distance or bearing"
                 : p25 ? "P25 control-channel grants and assigned-frequency activity · Receive-only · No voice/audio decoding"
                 : audio ? "Live analog FM receiver audio through Mac speakers · No audio is recorded or saved"
                 : tpms ? "Schrader-family packet decoder only · CRC checked · other sensor protocols may be present but unsupported"
                 : finder ? "A new energy rise near the chosen center only · no signal identity, distance, or direction · approximately 1.9 kHz bins"
                 : monitor.affectedFrames > 0
                 ? "Relative dBFS · \(monitor.affectedFrames) captures had USB drops"
                 : watching ? "Sampled channel energy · Brief transmissions can fall between captures"
                            : "Relative dBFS · Receive only")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 415)
        .onAppear { monitor.connect() }
        .onDisappear { monitor.close() }
        .onChange(of: mode) { oldMode, selectedMode in
            if selectedMode == .find && oldMode != .find { frequency = "315.0" }
            monitor.prepare(selectedMode)
        }
        .onChange(of: bank) { _, _ in monitor.clearTrace() }
        .fileImporter(isPresented: $showingRegistryImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText],
                      allowsMultipleSelection: false) { result in
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }
                let isScanningFAAMaster = try monitor.importADSBRegistry(from: url)
                registryImportMessage = isScanningFAAMaster ? nil : monitor.registryImportMessage
            } catch {
                registryImportMessage = error.localizedDescription
            }
        }
    }

    private func detections(_ selected: SweepSignal?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Detected signals").font(.headline)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(monitor.signals) { signal in
                        Button {
                            selectedPeak = signal.peak
                        } label: {
                            HStack {
                                Text("\(RFMonitor.mhz(signal.peak)) MHz").monospacedDigit()
                                Spacer()
                                Text(widthLabel(signal))
                                Text(String(format: "+%.1f dB", signal.prominence))
                                    .monospacedDigit().frame(width: 85, alignment: .trailing)
                            }
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(signal.id == selected?.id ? Color.accentColor.opacity(0.15) : .clear)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 95)
        }.font(.callout)
    }

    private var iqCaptureSummary: some View {
        HStack(spacing: 18) {
            metric("Sample rate", value: "\(monitor.sampleRate / 1000) kS/s")
            metric("Elapsed", value: elapsedLabel(monitor.iqElapsedMilliseconds))
            metric("Samples captured", value: "\(monitor.iqSamples)")
            metric("Dropped samples", value: "\(monitor.iqDroppedSamples)")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var frequencyFinderSummary: some View {
        HStack(spacing: 18) {
            metric("Search span", value: "±480 kHz")
            metric("Resolution", value: "~1.9 kHz")
            metric("Samples", value: "\(monitor.iqSamples)")
            metric("USB drops", value: "\(monitor.iqDroppedSamples)")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var frequencyFinderReadings: some View {
        VStack(spacing: 10) {
            Image(systemName: monitor.findObservation == nil ? (monitor.running ? "dot.radiowaves.left.and.right" : "waveform") : "scope")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(monitor.findObservation == nil ? (monitor.running ? .green : .secondary) : .orange)
            if let observation = monitor.findObservation {
                Text("New signal near \(RFMonitor.mhz(observation.frequencyHz)) MHz")
                    .font(.title3.bold()).monospacedDigit()
                Text("+\(String(format: "%.1f", observation.riseDB)) dB over learned background · ±\(observation.resolutionHz / 2) Hz bin")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Text("Estimate only; signal type and exact carrier may differ.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(monitor.running ? "Learning the nearby background…" : "Ready to search")
                    .font(.headline)
                Text(monitor.running ? "When the status says Ready, send one brief test transmission inside the shown ±480 kHz span." : "Choose a center frequency close to the signal you want to find, then start listening.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 540)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 145)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    private var adsbCaptureSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 18) {
                metric("Valid messages", value: "\(monitor.adsbValidFrames)")
                metric("Aircraft addresses", value: "\(monitor.adsbObservations.count)")
                metric("Sample rate", value: "\(monitor.sampleRate / 1000) kS/s")
            }
            HStack(spacing: 18) {
                metric("Received samples", value: "\(monitor.iqSamples)")
                metric("Dropped samples", value: "\(monitor.iqDroppedSamples)")
                metric("Elapsed", value: elapsedLabel(monitor.iqElapsedMilliseconds))
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var adsbReadings: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Aircraft observations").font(.headline)
                Spacer()
                Text(monitor.adsbRegistry.isEmpty ? "No local registry loaded" : "\(monitor.adsbRegistry.count) local rows")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Match FAA MASTER on SD") { monitor.matchObservedAircraftToFAAMasterOnSD() }
                    .disabled(!monitor.ready || monitor.running || monitor.registryImporting
                              || !monitor.sdMounted || !monitor.sdFAAMasterPresent)
                Button("Import FAA MASTER / registry CSV…") { showingRegistryImporter = true }
                    .disabled(monitor.registryImporting)
                Button("Export ADS-B to SD") { monitor.exportADSBFramesToSD() }
                    .disabled(!monitor.ready || monitor.running || !monitor.sdMounted)
            }
            if let message = monitor.sdExportMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if monitor.registryImporting, let message = monitor.registryImportMessage {
                ProgressView(message).font(.caption)
            } else if let registryImportMessage {
                Text(registryImportMessage).font(.caption).foregroundStyle(.secondary)
            } else if let message = monitor.registryImportMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text("FAA MASTER matches decoded Mode S addresses; other registry CSVs use icao24, category, source, source_date.")
                .font(.caption2).foregroundStyle(.secondary)
            if monitor.adsbObservations.isEmpty {
                ContentUnavailableView(monitor.running ? "Listening for ADS-B" : "No aircraft decoded",
                                       systemImage: "airplane", description: Text(monitor.running
                                            ? "Waiting for CRC-valid 1090 MHz broadcasts."
                                            : "Start listening to show locally received aircraft broadcasts."))
                    .frame(maxWidth: .infinity, minHeight: 165)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(monitor.adsbObservations) { row in
                            HStack(spacing: 12) {
                                Text(row.address).font(.callout.monospaced()).frame(width: 90, alignment: .leading)
                                Text(row.callsign ?? "Callsign not reported")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(row.callsign == nil ? .secondary : .primary)
                                Text(altitudeLabel(row))
                                    .frame(width: 150, alignment: .trailing)
                                Text("\(row.messages) msg")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 55, alignment: .trailing)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 7)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                            if let match = monitor.registryMatch(for: row) {
                                HStack(spacing: 5) {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.orange)
                                    if let registration = match.registration {
                                        Text("FAA: \(registration)\(match.yearManufactured.map { " · \($0)" } ?? "") · \(match.category)")
                                    } else {
                                        Text("Local registry: \(match.category) · \(match.source) · updated \(match.sourceDate)")
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.bottom, 3)
                            }
                        }
                    }
                }.frame(maxHeight: 180)
            }
        }
    }

    private var tetraCaptureSummary: some View {
        HStack(spacing: 18) {
            metric("Burst candidates", value: "\(monitor.tetraCandidateCount)")
            metric("Current level", value: monitor.tetraCurrentStrength.map { String(format: "%.1f dBFS", $0) } ?? "—")
            metric("Sample rate", value: "\(monitor.sampleRate / 1000) kS/s")
            metric("Dropped samples", value: "\(monitor.iqDroppedSamples)")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var tetraReadings: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Burst candidates").font(.headline)
                Spacer()
                Text("\(RFMonitor.mhz(monitor.shownCenter)) MHz")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if monitor.tetraCandidateHistory.isEmpty {
                ContentUnavailableView(monitor.running ? "Listening for energy rises" : "No burst candidates",
                                       systemImage: "waveform.path",
                                       description: Text(monitor.running
                                            ? "Candidates appear when received energy rises above the measured noise floor."
                                            : "Choose a band and listen to inspect candidate activity."))
                    .frame(maxWidth: .infinity, minHeight: 95)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(monitor.tetraCandidateHistory.enumerated()), id: \.offset) { _, row in
                            HStack {
                                Text("Candidate \(row.id)").font(.callout)
                                Spacer()
                                Text(String(format: "%.1f dBFS", row.strength))
                                    .font(.callout.monospacedDigit())
                            }
                            .padding(.vertical, 4).padding(.horizontal, 7)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }.frame(maxHeight: 78)
            }
        }
    }

    private var p25CaptureSummary: some View {
        HStack(spacing: 18) {
            metric("Valid network IDs", value: "\(monitor.p25ValidNIDs)")
            metric("Control candidates", value: "\(monitor.p25ControlCandidates.count)")
            metric("Channel assignments", value: "\(monitor.p25Grants.count)")
            metric("Sample rate", value: "\(monitor.sampleRate / 1000) kS/s")
            metric("Dropped samples", value: "\(monitor.iqDroppedSamples)")
            metric("Center", value: "\(RFMonitor.mhz(monitor.running ? monitor.shownCenter : p25Band == .manual ? p25ManualCenter ?? p25Band.centerHz : p25Band.centerHz)) MHz")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var p25Readings: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("P25 activity evidence").font(.headline)
            Text("CRC-valid control-channel assignments identify channels the system assigned. This monitor does not retune to verify voice occupancy or decode audio.")
                .font(.caption).foregroundStyle(.secondary)
            if !monitor.p25Grants.isEmpty {
                Text("Recent channel assignments").font(.subheadline)
                ForEach(monitor.p25Grants) { row in
                    HStack {
                        Label("Assigned channel", systemImage: "dot.radiowaves.left.and.right")
                        Text(row.frequencyHz.map { "\(RFMonitor.mhz($0)) MHz" } ?? "Channel 0x\(String(format: "%04X", row.channel)) · frequency unresolved")
                            .font(.callout.monospacedDigit())
                        if let talkgroup = row.talkgroup { Text("TG \(talkgroup)").font(.caption.monospaced()) }
                        Spacer()
                        Text("NAC \(String(format: "%03X", row.nac)) · CC \(RFMonitor.mhz(row.controlHz))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(7).background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            if !monitor.p25ControlCandidates.isEmpty {
                ForEach(monitor.p25ControlCandidates) { row in
                    HStack {
                        Label("Control-channel candidate", systemImage: "dot.radiowaves.left.and.right")
                        Text("NAC \(String(format: "%03X", row.nac))").font(.callout.monospaced())
                        Spacer()
                        Text("\(row.repeatedNIDs)+ headers · \(RFMonitor.mhz(row.centerHz)) MHz")
                            .font(.caption.monospacedDigit())
                    }
                    .padding(7)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            Text("Validated P25 network identifiers").font(.subheadline)
            if monitor.p25Observations.isEmpty {
                ContentUnavailableView(monitor.running ? "Listening for P25" : "No valid P25 network IDs",
                                       systemImage: "dot.radiowaves.left.and.right",
                                       description: Text("A row requires a matching P25 sync, BCH-valid NID, and valid parity."))
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(monitor.p25Observations) { row in
                            HStack {
                                Text("NAC \(String(format: "%03X", row.nac))")
                                    .font(.callout.monospaced()).frame(width: 150, alignment: .leading)
                                Text("DUID \(row.duid)").frame(width: 90, alignment: .leading)
                                Spacer()
                                Text("\(row.frames) valid NID").font(.caption.monospacedDigit())
                                Text("\(RFMonitor.mhz(row.centerHz)) MHz")
                                    .font(.caption.monospacedDigit()).frame(width: 110, alignment: .trailing)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 7)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }.frame(maxHeight: 180)
            }
        }
    }

    private var audioCaptureSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 18) {
            metric("Tuned channel", value: "\(gmrsChannel.rawValue) · \(RFMonitor.mhz(gmrsChannel.frequencyHz)) MHz")
            metric("Audio", value: "8 kHz mono")
            metric("RF samples", value: "\(monitor.audioSamplesReceived)")
            metric("RF drops", value: "\(monitor.audioDroppedSamples)")
          }
          HStack(spacing: 18) {
            metric("FM samples", value: "\(monitor.audioDemodSamples)")
            metric("Blocks from P4", value: "\(monitor.audioFirmwareBlocks)")
            metric("Blocks at Mac", value: "\(monitor.audioBlocksReceived)")
            Spacer(minLength: 0)
          }
          HStack(spacing: 18) {
            metric("Events at Mac", value: "\(monitor.audioEventsReceived)")
            metric("Decode errors", value: "\(monitor.audioPayloadErrors)")
            metric("Late blocks discarded", value: "\(monitor.audioLateEventsDiscarded)")
            Spacer(minLength: 0)
          }
          HStack(spacing: 18) {
            metric("Audio lines at bridge", value: "\(monitor.audioBridgeLines)")
            metric("Bridge bytes", value: "\(monitor.audioBridgeBytes)")
            metric("Bridge parse errors", value: "\(monitor.audioBridgeErrors)")
            Spacer(minLength: 0)
          }
          if !monitor.audioBridgeErrorDetail.isEmpty {
            Text("Last bridge parse error: \(monitor.audioBridgeErrorDetail)")
              .font(.caption.monospaced()).foregroundStyle(.secondary)
          }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var audioReadings: some View {
        VStack(spacing: 10) {
            Image(systemName: monitor.running ? "waveform" : "speaker.wave.2")
                .font(.system(size: 44, weight: .medium)).foregroundStyle(monitor.running ? .green : .secondary)
            Text(monitor.running ? "Playing live receiver audio" : "Ready to listen")
                .font(.headline)
            Text("Use a GMRS channel for your planned test. The receiver only listens; audio stays in memory and is discarded when stopped.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, minHeight: 145)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    private var tpmsCaptureSummary: some View {
        HStack(spacing: 18) {
            metric("Valid packets", value: "\(monitor.tpmsValidPackets)")
            metric("Sample rate", value: "\(monitor.sampleRate / 1000) kS/s")
            metric("Dropped samples", value: "\(monitor.iqDroppedSamples)")
            metric("Center", value: "\(RFMonitor.mhz(monitor.shownCenter)) MHz")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var tpmsReadings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CRC-valid Schrader family packets").font(.headline)
            Text("Packet reception has not yet been confirmed with a known vehicle sensor.")
                .font(.caption).foregroundStyle(.secondary)
            if monitor.tpmsObservations.isEmpty {
                ContentUnavailableView(monitor.running ? "Listening for TPMS packets" : "No TPMS packets yet",
                                       systemImage: "car.rear.road.lane",
                                       description: Text("A quiet result is inconclusive: sensors transmit intermittently, range varies, and other TPMS families are not decoded."))
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(monitor.tpmsObservations) { row in
                            HStack {
                                Text("ID \(row.id)").font(.callout.monospaced()).frame(width: 115, alignment: .leading)
                                Text(String(format: "%.1f kPa", Double(row.pressureHpa) / 10))
                                Text("\(row.temperatureC) °C")
                                Text("flags \(String(format: "%02X", row.flags))").foregroundStyle(.secondary)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(RFMonitor.mhz(row.centerHz)) MHz")
                                    Text(row.lastSeen, style: .time)
                                }
                                .font(.caption.monospacedDigit())
                            }
                            .padding(.vertical, 5).padding(.horizontal, 7)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }.frame(maxHeight: 180)
            }
        }
    }

    private func altitudeLabel(_ row: ADSBObservation) -> String {
        guard let altitude = row.altitudeFeet else { return "Altitude not reported" }
        let kind = row.altitudeKind == "geometric" ? "geometric" : "barometric"
        return "\(altitude.formatted()) ft · \(kind)"
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func elapsedLabel(_ milliseconds: UInt64) -> String {
        let seconds = milliseconds / 1000
        return String(format: "%02llu:%02llu", seconds / 60, seconds % 60)
    }

    private func widthLabel(_ signal: SweepSignal) -> String {
        if signal.clipped { return "Incomplete span" }
        if signal.span.lowerBound == signal.span.upperBound { return "Unresolved · 25 kHz bins" }
        return "≈\((signal.span.upperBound - signal.span.lowerBound + RFMonitor.step) / 1000) kHz above threshold"
    }

    private var channelReadings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(monitor.running ? "Channel activity" : "Last channel readings").font(.headline)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(monitor.channels) { row in
                        HStack {
                            Text("Ch \(row.id)").frame(width: 48, alignment: .leading)
                            Text(String(format: "%.4f MHz", Double(row.channel.frequency) / 1e6))
                            Spacer()
                            Text(row.state.rawValue)
                                .foregroundStyle(row.state == .active ? Color.green : .secondary)
                            Text(row.margin.map { String(format: "%+.1f dB", $0) } ?? "—")
                                .frame(width: 85, alignment: .trailing)
                        }.monospacedDigit()
                    }
                }
            }.frame(maxHeight: 125)
        }.font(.callout)
    }
}

#if !APP_CHOOSER
private final class RFDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct RFMonitorApp: App {
    @NSApplicationDelegateAdaptor(RFDelegate.self) private var delegate

    var body: some Scene {
        Window("Synesthesia RF Monitor", id: "rf") { RFView() }
            .defaultSize(width: 830, height: 500)
    }
}
#endif
