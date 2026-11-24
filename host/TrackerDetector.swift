import Foundation
import CryptoKit

struct TrackerMatch {
    let category: String
    let evidence: String
    let confidence: String
}

enum TrackerDetector {
    static let keyRotationInterval: TimeInterval = 15 * 60

    static func bluetoothMatch(companyID: UInt16?, manufacturerPayload: [UInt8]?) -> TrackerMatch? {
        guard companyID == 0x004C,
              let manufacturerPayload,
              manufacturerPayload.count >= 27,
              manufacturerPayload[0] == 0x12,
              manufacturerPayload[1] == 0x19 else { return nil }
        return TrackerMatch(
            category: "Possible Apple Find My network accessory",
            evidence: "Apple company ID 0x004C with Find My message type 0x12 and 25-byte key payload",
            confidence: "Protocol-format match · accessory type and identity unconfirmed"
        )
    }

    static let simulatedAdvertisement = "1EFF4C0012190102030405060708090A0B0C0D0E0F10111213141516171819"

    static func payloadFingerprint(companyID: UInt16?, manufacturerPayload: [UInt8]?) -> String? {
        guard let companyID, let manufacturerPayload,
              bluetoothMatch(companyID: companyID, manufacturerPayload: manufacturerPayload) != nil else {
            return nil
        }
        let bytes = [UInt8(companyID & 0xFF), UInt8(companyID >> 8)] + manufacturerPayload
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02X", $0) }.joined()
    }
}
