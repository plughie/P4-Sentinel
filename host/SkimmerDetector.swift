import Foundation

struct SkimmerModuleMatch {
    let category: String
    let evidence: [String]
    let confidence: String
}

enum SkimmerDetector {
    private static let serialPortUUID = "1101"
    private static let moduleNamePattern = #"^(HC-0[356]|HC0[356]|RN42|RN-42|BT04-A)(?:$|[-_ ])"#

    static func bluetoothMatch(name: String, serviceUUIDs: [String]) -> SkimmerModuleMatch? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameMatch = normalizedName.range(of: moduleNamePattern,
                                             options: [.regularExpression, .caseInsensitive]) != nil
        let hasSPP = serviceUUIDs.contains { $0.uppercased() == serialPortUUID }
        guard nameMatch || hasSPP else { return nil }

        var evidence: [String] = []
        if nameMatch {
            evidence.append("Advertised name ‘\(normalizedName)’ matches a known HC-03/05/06, RN42, or BT04-A serial-module pattern")
        }
        if hasSPP {
            evidence.append("Advertised service UUID 0x1101 is Bluetooth Serial Port Profile")
        }
        let confidence: String
        if nameMatch && hasSPP {
            confidence = "Moderate · module name plus serial profile; skimmer use unconfirmed"
        } else {
            confidence = "Low · one serial-module clue; skimmer use unconfirmed"
        }
        return SkimmerModuleMatch(category: "Possible Bluetooth serial module",
                                  evidence: evidence, confidence: confidence)
    }
}
