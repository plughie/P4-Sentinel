import Foundation

enum BodyCameraDetector {
    private static let wifiPrefixes = ["AB2-", "AB3-", "AB4-", "AXON-"]
    private static let marker = Array("BWCDEVICE".utf8)
    private static let reversedMarker = Array(marker.reversed())

    static func wifiEvidence(ssid: String) -> [String]? {
        guard let prefix = wifiPrefixes.first(where: { ssid.lowercased().hasPrefix($0.lowercased()) })
        else { return nil }
        return ["Wi-Fi name ‘\(ssid)’ matched body-camera prefix ‘\(prefix)’"]
    }

    static func bluetoothEvidence(name: String, advertisementHex: String?) -> [String]? {
        var evidence: [String] = []
        if name.range(of: "BodyWorn Remote", options: .caseInsensitive) != nil {
            evidence.append("Bluetooth name ‘\(name)’ contains ‘BodyWorn Remote’")
        }
        if let bytes = decodeHex(advertisementHex),
           contains(marker, in: bytes) || contains(reversedMarker, in: bytes) {
            evidence.append("BLE advertisement contains the ‘BWCDEVICE’ body-camera marker")
        }
        return evidence.isEmpty ? nil : evidence
    }

    private static func decodeHex(_ hex: String?) -> [UInt8]? {
        guard let hex, !hex.isEmpty, hex.utf8.count.isMultiple(of: 2) else { return nil }
        let characters = Array(hex)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    private static func contains(_ needle: [UInt8], in bytes: [UInt8]) -> Bool {
        guard bytes.count >= needle.count else { return false }
        return (0...(bytes.count - needle.count)).contains { start in
            zip(bytes[start..<(start + needle.count)], needle).allSatisfy { lhs, rhs in
                lhs == rhs || (0x61...0x7A).contains(lhs) && lhs - 0x20 == rhs
            }
        }
    }
}
