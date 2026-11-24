import Foundation

struct SmartGlassesMatch {
    let category: String
    let evidence: [String]
    let confidence: String
}

enum SmartGlassesDetector {
    private static let vendorNames: [UInt16: String] = [
        0x01AB: "Meta Platforms",
        0x0D53: "Luxottica",
        0x03C2: "Snapchat",
        0x060C: "Vuzix",
    ]
    private static let heyCyanUUID = "7905FFF0-B5CE-4E99-A40F-4B1E122D00D0"
    private static let metaUUIDs: Set<String> = ["FEB7", "FEB8"]

    static func bluetoothMatch(name: String, companyID: UInt16?,
                               manufacturerPayload: [UInt8]?, serviceUUIDs: [String]) -> SmartGlassesMatch? {
        let normalizedUUIDs = Set(serviceUUIDs.map { $0.uppercased() })
        var evidence: [String] = []
        var certainty = "Low · shared vendor or name clue; glasses use unconfirmed"

        if let companyID, let vendor = vendorNames[companyID] {
            evidence.append(String(format: "Company ID 0x%04X is registered to %@", companyID, vendor))
            certainty = "Low · vendor identifier shared across products; glasses use unconfirmed"
        }
        if normalizedUUIDs.contains(heyCyanUUID) {
            evidence.append("Advertised 128-bit service UUID \(heyCyanUUID) matches the HeyCyan glasses SDK signature")
            certainty = "Moderate · product-family service signature; exact device unconfirmed"
        }
        if normalizedUUIDs.contains("FE45") {
            evidence.append("Advertised service UUID 0xFE45 matches the published Vuzix glasses signature")
            certainty = "Low · shared service signature; exact product unconfirmed"
        }
        if !normalizedUUIDs.isDisjoint(with: metaUUIDs) {
            evidence.append("Advertised service UUID \(normalizedUUIDs.intersection(metaUUIDs).sorted().joined(separator: ", ")) is a Meta service signature (also used by non-glasses devices)")
            certainty = "Low · Meta device clue; headset or glasses role unconfirmed"
        }
        if companyID == 0x058E, containsToken("META_RB_GLASS", in: manufacturerPayload) {
            evidence.append("Company ID 0x058E and manufacturer token META_RB_GLASS matched the specific Meta glasses signature")
            certainty = "Moderate · specific broadcast signature; exact identity unconfirmed"
        }

        let lowerName = name.lowercased()
        let nameTokens = ["ray-ban", "rayban", "spectacles", "vuzix", "heycyan"]
        let hasProductName = nameTokens.contains(where: { lowerName.contains($0) })
        if let token = nameTokens.first(where: { lowerName.contains($0) }) {
            evidence.append("Advertised name ‘\(name)’ contains ‘\(token)’; name alone is not confirmation")
            if evidence.count == 1 {
                certainty = "Very low · name-only clue; easily changed or imitated"
            }
        }

        guard !evidence.isEmpty else { return nil }
        let hasMetaOnlyClue = companyID == 0x01AB || !normalizedUUIDs.isDisjoint(with: metaUUIDs)
        let hasProductSignature = hasProductName || normalizedUUIDs.contains(heyCyanUUID)
            || normalizedUUIDs.contains("FE45")
            || (companyID == 0x058E && containsToken("META_RB_GLASS", in: manufacturerPayload))
        let category = hasMetaOnlyClue && !hasProductSignature
            ? "Possible Meta device (glasses or headset)"
            : "Possible smart glasses"
        return SmartGlassesMatch(category: category, evidence: evidence, confidence: certainty)
    }

    private static func containsToken(_ token: String, in payload: [UInt8]?) -> Bool {
        guard let payload, !payload.isEmpty else { return false }
        let text = String(decoding: payload, as: UTF8.self).uppercased()
        return text.contains(token)
    }
}
