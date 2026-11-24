import Foundation

enum WiFiBSSIDVendorEvidence {
    static func description(bssid: String, vendorMatchEvidence: String? = nil) -> String {
        if let vendorMatchEvidence, !vendorMatchEvidence.isEmpty {
            return vendorMatchEvidence
        }
        let octets = bssid.split(separator: ":")
        guard octets.count == 6,
              let firstOctet = UInt8(octets[0], radix: 16),
              octets.allSatisfy({ UInt8($0, radix: 16) != nil }) else {
            return "BSSID format unavailable; vendor cannot be determined."
        }
        if firstOctet & 0x02 != 0 {
            return "Locally administered BSSID; manufacturer cannot be inferred from this address."
        }
        return "No supported vendor signature matches this BSSID; general OUI lookup is unavailable."
    }
}
