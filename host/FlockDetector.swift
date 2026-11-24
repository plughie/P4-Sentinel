import Foundation

enum FlockDetector {
    private static let xuntongCompanyID: UInt16 = 0x09C8
    private static let accessoryUUIDs: Set<String> = [
        "E8CCBB38-9532-46A8-9FE5-1814DF172E6F",
        "20C944C1-ADD2-42D7-A638-967EE9A26FF6",
    ]
    private static let ravenUUIDBaseSuffix = "-0000-1000-8000-00805F9B34FB"

    static func ravenAudioSensorEvidence(serviceUUIDs: [String]) -> [String]? {
        let evidence = serviceUUIDs.compactMap { uuid -> String? in
            guard let shortID = ravenShortID(from: uuid) else { return nil }
            return "Advertised 128-bit BLE service UUID \(uuid.uppercased()) has Raven short ID "
                + String(format: "0x%04X", shortID) + " in the documented 0x3100–0x3500 range"
        }
        return evidence.isEmpty ? nil : evidence
    }

    static func wifiEvidence(ssid: String) -> [String]? {
        guard matches("^Flock-", in: ssid) else { return nil }
        return ["SSID \(quoted(ssid)) matched prefix ‘Flock-’"]
    }

    static func bluetoothEvidence(name: String, companyID: UInt16?,
                                  manufacturerPayload: [UInt8]?, serviceUUIDs: [String]) -> [String]? {
        let advertisedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let isXuntong = companyID == xuntongCompanyID
        var evidence: [String] = []

        if matches("^FS Ext Battery(?:$|[\\s_-])", in: advertisedName) {
            evidence.append("Advertised name \(quoted(advertisedName)) matched ‘FS Ext Battery’")
        } else if matches("^Penguin-[0-9]+$", in: advertisedName) {
            evidence.append("Advertised name \(quoted(advertisedName)) matched ‘Penguin-<digits>’")
            if isXuntong { evidence.append("Company ID 0x09C8 corroborated the name") }
        } else if matches("^FS-[0-9A-Fa-f]+$", in: advertisedName) {
            evidence.append("Advertised name \(quoted(advertisedName)) matched ‘FS-<hex>’")
            if isXuntong { evidence.append("Company ID 0x09C8 corroborated the name") }
        } else if isXuntong && matches("^[0-9]{8,12}$", in: advertisedName) {
            evidence.append("Advertised numeric name \(quoted(advertisedName)) and Company ID 0x09C8 matched a Penguin signature")
        }

        if isXuntong, let manufacturerPayload, containsTNSerial(in: manufacturerPayload) {
            evidence.append("Company ID 0x09C8 manufacturer payload contains a ‘TN<digits>’ serial marker")
        }

        for uuid in serviceUUIDs where accessoryUUIDs.contains(uuid.uppercased()) {
            evidence.append("Advertised service UUID \(uuid) matched a documented Flock accessory signature")
        }

        return evidence.isEmpty ? nil : evidence
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func ravenShortID(from uuid: String) -> UInt16? {
        let normalized = uuid.uppercased()
        guard normalized.count == 36, normalized.hasPrefix("0000"),
              normalized.hasSuffix(ravenUUIDBaseSuffix) else { return nil }
        let shortIDString = normalized.dropFirst(4).prefix(4)
        guard let shortID = UInt16(shortIDString, radix: 16), (0x3100...0x3500).contains(shortID) else {
            return nil
        }
        return shortID
    }

    private static func containsTNSerial(in bytes: [UInt8]) -> Bool {
        guard bytes.count >= 3 else { return false }
        for index in 0..<(bytes.count - 2) {
            if bytes[index] == 0x54, bytes[index + 1] == 0x4E,
               (0x30...0x39).contains(bytes[index + 2]) {
                return true
            }
        }
        return false
    }

    private static func quoted(_ value: String) -> String { "‘\(value)’" }
}
