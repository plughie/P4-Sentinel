import Foundation

struct DroneIDMatch {
    let messageType: String
    let protocolVersion: Int
    let fields: [String]
    let evidence: String
}

enum DroneIDDetector {
    // Bluetooth legacy Remote ID: service data UUID 0xFFFA, OpenDroneID app
    // code 0x0D, one rolling counter byte, then one 25-byte ODID message.
    static func decode(serviceData: [String: [UInt8]]) -> DroneIDMatch? {
        guard let bytes = serviceData["FFFA"], bytes.count == 27,
              bytes[0] == 0x0D else { return nil }
        let message = Array(bytes[2..<27])
        let type = message[0] >> 4
        let version = Int(message[0] & 0x0F)
        guard version <= 2 else { return nil }

        switch type {
        case 0:
            let idType = message[1] >> 4
            let aircraftType = message[1] & 0x0F
            let identifierBytes = Array(message[2..<22].prefix { $0 != 0 })
            guard !identifierBytes.isEmpty else { return nil }
            let identifier: String
            if idType == 3 || idType == 4 {
                identifier = identifierBytes.map { String(format: "%02X", $0) }.joined()
            } else {
                identifier = String(decoding: identifierBytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard identifier.unicodeScalars.allSatisfy({ (0x20...0x7E).contains(Int($0.value)) }) else {
                    return nil
                }
            }
            let idDescription: String
            switch idType {
            case 1: idDescription = "Serial number"
            case 2: idDescription = "CAA registration ID"
            case 3: idDescription = "UTM-assigned ID"
            case 4: idDescription = "Session ID"
            default: idDescription = "ID type \(idType)"
            }
            return DroneIDMatch(messageType: "Basic ID", protocolVersion: version,
                                fields: ["\(idDescription): \(identifier)",
                                         "Aircraft type: \(aircraftTypeLabel(aircraftType))"],
                                evidence: "Bluetooth Remote ID service data 0xFFFA · OpenDroneID app code 0x0D · Basic ID message")

        case 1:
            let latitudeRaw = int32LE(message, at: 5)
            let longitudeRaw = int32LE(message, at: 9)
            let latitude = Double(latitudeRaw) * 1e-7
            let longitude = Double(longitudeRaw) * 1e-7
            guard latitudeRaw != Int32.max, longitudeRaw != Int32.max,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            let status = message[1] >> 4
            let direction = message[2]
            let horizontalSpeed = message[3]
            let verticalSpeed = Int8(bitPattern: message[4])
            let ewDirection = (message[1] & 0x02) != 0
            let speedMultiplier = (message[1] & 0x01) != 0
            var fields = [String(format: "Aircraft position: %.7f, %.7f", latitude, longitude),
                          "Flight status: \(statusLabel(status))"]
            if direction != 255 {
                fields.append("Direction: \(Int(direction) + (ewDirection ? 180 : 0))°")
            }
            if horizontalSpeed != 255 {
                let speed = speedMultiplier
                    ? Double(horizontalSpeed) * 0.75 + 63.75
                    : Double(horizontalSpeed) * 0.25
                fields.append("Horizontal speed: \(String(format: "%.2f", speed)) m/s")
            }
            if verticalSpeed != 63 {
                fields.append("Vertical speed: \(String(format: "%.2f", Double(verticalSpeed) * 0.5)) m/s")
            }
            let geometricAltitude = uint16LE(message, at: 15)
            if geometricAltitude != 0 {
                fields.append("Geometric altitude: \(String(format: "%.1f", Double(geometricAltitude) * 0.5 - 1000)) m")
            }
            return DroneIDMatch(messageType: "Location/Vector", protocolVersion: version,
                                fields: fields,
                                evidence: "Bluetooth Remote ID service data 0xFFFA · OpenDroneID app code 0x0D · Location/Vector message")
        default:
            return nil
        }
    }

    private static func int32LE(_ bytes: [UInt8], at offset: Int) -> Int32 {
        let value = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        return Int32(bitPattern: value)
    }

    private static func uint16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func aircraftTypeLabel(_ value: UInt8) -> String {
        let labels = ["None", "Aeroplane/fixed-wing", "Helicopter/multirotor", "Gyroplane",
                      "Hybrid lift", "Ornithopter", "Glider", "Kite", "Free balloon",
                      "Captive balloon", "Airship", "Free fall/parachute", "Rocket",
                      "Tethered powered aircraft", "Ground obstacle", "Other"]
        return labels[Int(value)]
    }

    private static func statusLabel(_ value: UInt8) -> String {
        switch value {
        case 1: return "On the ground"
        case 2: return "Airborne"
        case 3: return "Emergency"
        case 4: return "Remote ID system failure"
        default: return "Undeclared/unknown"
        }
    }
}
