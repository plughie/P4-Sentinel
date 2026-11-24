import Foundation

enum SignalFreshness {
    static let retention: TimeInterval = 20

    static func isFresh(lastSeen: Date, at now: Date) -> Bool {
        now.timeIntervalSince(lastSeen) < retention
    }

    static func ageLabel(lastSeen: Date, at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(lastSeen)))
        return seconds == 0 ? "just now" : "\(seconds)s ago"
    }
}
