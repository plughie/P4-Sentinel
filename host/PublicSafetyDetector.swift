import Foundation

struct PublicSafetyMatch {
    let category: String
    let evidence: [String]
    let confidence: String
}

enum PublicSafetyDetector {
    private static let zebraPrinterUUIDs: Set<String> = ["FE79", "FD66"]
    private static let motorolaUUIDs: Set<String> = ["FD8E", "FE04"]
    private static let cradlePointBSSIDPrefixes: Set<String> = ["003044", "00E01C"]

    static func wifiMatch(bssid: String) -> PublicSafetyMatch? {
        let compactAddress = bssid.filter(\.isHexDigit).uppercased()
        guard compactAddress.count == 12,
              let prefix = cradlePointBSSIDPrefixes.first(where: { compactAddress.hasPrefix($0) }) else {
            return nil
        }
        let printablePrefix = stride(from: 0, to: prefix.count, by: 2)
            .map { offset in String(prefix.dropFirst(offset).prefix(2)) }
            .joined(separator: ":")
        return PublicSafetyMatch(
            category: "Possible Cradlepoint cellular router",
            evidence: ["Wi-Fi BSSID prefix \(printablePrefix) is registered to CradlePoint, Inc."],
            confidence: "Low · a router vendor identifier; fixed, enterprise, and vehicle use are all possible"
        )
    }

    static func bluetoothMatch(name: String, companyID: UInt16?, serviceUUIDs: [String]) -> PublicSafetyMatch? {
        let normalizedUUIDs = Set(serviceUUIDs.map { $0.uppercased() })
        let zebraUUIDs = normalizedUUIDs.intersection(zebraPrinterUUIDs)
        let motorolaUUIDs = normalizedUUIDs.intersection(motorolaUUIDs)
        let isFactorySerial = name.range(
            of: "^[A-Z0-9]{2}[A-Z]{3}[0-9]{9}$",
            options: .regularExpression.union(.caseInsensitive)
        ) != nil
        var evidence: [String] = []
        var category = "Possible public-safety-related device"
        var confidence = "Low · shared vendor/service identifier; device role unconfirmed"

        if !zebraUUIDs.isEmpty && isFactorySerial {
            category = "Possible fleet printer"
            confidence = "Moderate · printer service and serial-pattern clues; fleet use unconfirmed"
            evidence.append("BLE name ‘\(name)’ matches the factory serial pattern for an unrenamed Zebra printer")
            evidence.append("Service UUID \(zebraUUIDs.sorted().joined(separator: ", ")) matches Zebra printer services")
        } else {
            if !zebraUUIDs.isEmpty {
                category = "Possible Zebra device"
                confidence = "Low · shared printer vendor/service identifier; fleet use unconfirmed"
                evidence.append("Service UUID \(zebraUUIDs.sorted().joined(separator: ", ")) is assigned to Zebra printer services")
            }
            if companyID == 0x01F1 {
                category = "Possible Zebra device"
                confidence = "Low · shared manufacturer identifier; printer and vehicle roles unconfirmed"
                evidence.append("Company ID 0x01F1 is assigned to Zebra Technologies")
            }
        }

        if companyID == 0x04EC {
            category = "Possible Motorola Solutions device"
            confidence = "Low · shared vendor/service identifier; device role unconfirmed"
            evidence.append("Company ID 0x04EC is assigned to Motorola Solutions; this identifier is shared across product types")
        }
        if !motorolaUUIDs.isEmpty {
            category = "Possible Motorola Solutions device"
            confidence = "Low · shared vendor/service identifier; device role unconfirmed"
            evidence.append("Service UUID \(motorolaUUIDs.sorted().joined(separator: ", ")) is assigned to Motorola Solutions")
        }
        if companyID == 0x0755 {
            category = "Possible Brother device"
            confidence = "Low · Brother makes mobile printers and ordinary home/office devices; fleet use unconfirmed"
            evidence.append("Company ID 0x0755 is assigned to Brother Industries, Ltd.")
        }

        return evidence.isEmpty ? nil : PublicSafetyMatch(category: category, evidence: evidence, confidence: confidence)
    }
}
