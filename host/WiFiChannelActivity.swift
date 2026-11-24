import Foundation

struct WiFiChannelObservation {
    let channel: Int
    let rssi: Int
}

struct WiFiChannelSummary: Equatable, Identifiable {
    let channel: Int
    let accessPointCount: Int
    let strongestRSSI: Int?

    var id: Int { channel }
}

enum WiFiChannelActivity {
    static func summarize(_ observations: [WiFiChannelObservation]) -> [WiFiChannelSummary] {
        (1...13).map { channel in
            let accessPoints = observations.filter { $0.channel == channel }
            return WiFiChannelSummary(channel: channel,
                                     accessPointCount: accessPoints.count,
                                     strongestRSSI: accessPoints.map(\.rssi).max())
        }
    }
}
