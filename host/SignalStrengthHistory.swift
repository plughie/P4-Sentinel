import Foundation

struct SignalStrengthSample: Equatable {
    let time: Date
    let rssi: Int
}

struct SignalStrengthHistory: Equatable {
    static let window: TimeInterval = 60
    static let bucketDuration: TimeInterval = 5
    static let maximumSamples = 12

    private(set) var samples: [SignalStrengthSample] = []

    mutating func record(_ rssi: Int, at time: Date) {
        let cutoff = time.addingTimeInterval(-Self.window)
        samples.removeAll { $0.time < cutoff }

        let bucket = floor(time.timeIntervalSince1970 / Self.bucketDuration)
        if let last = samples.last,
           floor(last.time.timeIntervalSince1970 / Self.bucketDuration) == bucket {
            samples[samples.count - 1] = SignalStrengthSample(time: time, rssi: rssi)
        } else {
            samples.append(SignalStrengthSample(time: time, rssi: rssi))
        }

        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }
}
