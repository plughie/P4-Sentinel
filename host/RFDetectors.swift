import Foundation

struct SweepSignal: Identifiable {
    let peak: Int
    let span: ClosedRange<Int>
    let prominence: Double
    let clipped: Bool
    var id: Int { peak }
}

enum SweepDetector {
    static func signals(in passes: [[Double?]], low: Int, step: Int, threshold: Double) -> [SweepSignal] {
        guard let count = passes.first?.count, passes.count == 2,
              passes.allSatisfy({ $0.count == count }) else { return [] }

        let margins: [Double?] = (0..<count).map { index in
            let neighborhood = max(0, index - 24)...min(count - 1, index + 24)
            let margins = passes.compactMap { grid -> Double? in
                guard let signal = grid[index] else { return nil }
                let neighbors = neighborhood.compactMap { abs($0 - index) >= 10 ? grid[$0] : nil }
                guard let floor = median(neighbors) else { return nil }
                return signal - floor
            }
            return margins.count == 2 ? margins.min() : nil
        }

        var results: [SweepSignal] = []
        var index = 0
        while index < count {
            guard let level = margins[index], level >= threshold else {
                index += 1
                continue
            }
            let first = index
            var strongest = (bin: index, margin: level)
            while index < count, let margin = margins[index], margin >= threshold {
                if margin > strongest.margin { strongest = (index, margin) }
                index += 1
            }
            let clipped = first == 0 || index == count
                || margins[first - 1] == nil || margins[index] == nil
            results.append(SweepSignal(
                peak: low + strongest.bin * step,
                span: (low + first * step)...(low + (index - 1) * step),
                prominence: strongest.margin,
                clipped: clipped
            ))
        }
        return results.sorted { $0.prominence == $1.prominence ? $0.peak < $1.peak : $0.prominence > $1.prominence }
    }
}

struct RadioChannel: Identifiable {
    let id: Int
    let frequency: Int
}

enum ChannelBank: String, CaseIterable {
    case frs462 = "US FRS · 462 MHz"
    case frs467 = "US FRS · 467 MHz"

    var tunerCenter: Int { self == .frs462 ? 462_475_000 : 467_475_000 }

    // US FRS center frequencies, 47 CFR § 95.563. These channels are shared with GMRS.
    var channels: [RadioChannel] {
        switch self {
        case .frs462:
            return (1...7).map { RadioChannel(id: $0, frequency: 462_562_500 + ($0 - 1) * 25_000) }
                + (15...22).map { RadioChannel(id: $0, frequency: 462_550_000 + ($0 - 15) * 25_000) }
        case .frs467:
            return (8...14).map { RadioChannel(id: $0, frequency: 467_562_500 + ($0 - 8) * 25_000) }
        }
    }
}

struct ChannelObservation: Identifiable {
    enum State: String {
        case unknown = "Unobserved"
        case quiet = "No hit"
        case possible = "One hit"
        case active = "Activity"
    }

    let channel: RadioChannel
    var margin: Double?
    var state = State.unknown
    fileprivate var consecutive = 0
    fileprivate var lastFrame: TimeInterval?
    fileprivate var lastConfirmed: TimeInterval?
    var id: Int { channel.id }
}

struct ChannelDetector {
    var observations: [ChannelObservation]
    let threshold: Double

    init(bank: ChannelBank, threshold: Double) {
        observations = bank.channels.map { ChannelObservation(channel: $0) }
        self.threshold = threshold
    }

    mutating func observe(
        bins: [Int], center: Int, rate: Int, dropped: Bool, time: TimeInterval
    ) {
        let spacing = Double(rate) / Double(bins.count)
        let usable = bins.enumerated().compactMap { index, level -> (frequency: Double, power: Double)? in
            let offset = Double(index - bins.count / 2) * spacing
            guard (15_000...350_000).contains(abs(offset)) else { return nil }
            return (Double(center) + offset, Double(level) / 10)
        }
        for index in observations.indices {
            var row = observations[index]
            let held = row.lastConfirmed.map { time - $0 <= 0.7 } ?? false
            let target = Double(row.channel.frequency)
            let channel = usable.filter { abs($0.frequency - target) <= 6_250 }.map(\.power)
            let neighbors = usable.filter { (25_000...95_000).contains(abs($0.frequency - target)) }.map(\.power)
            let offset = abs(target - Double(center))
            guard !dropped, (21_250...343_750).contains(offset),
                  channel.count >= 5, let floor = median(neighbors) else {
                row.consecutive = 0
                row.lastFrame = nil
                row.margin = nil
                row.state = held ? .active : .unknown
                observations[index] = row
                continue
            }

            let power = channel.reduce(0.0) { $0 + pow(10, $1 / 10) } / Double(channel.count)
            let margin = 10 * log10(power) - floor
            row.margin = margin
            if margin >= threshold {
                if row.lastFrame.map({ time - $0 > 0.75 }) ?? true {
                    row.consecutive = 0
                }
                row.consecutive = min(row.consecutive + 1, 2)
                if row.consecutive >= 2 {
                    row.lastConfirmed = time
                    row.state = .active
                } else {
                    row.state = held ? .active : .possible
                }
            } else {
                row.consecutive = 0
                row.state = held ? .active : .quiet
            }
            row.lastFrame = time
            observations[index] = row
        }
    }
}

private func median(_ values: [Double]) -> Double? {
    guard values.count >= 10 else { return nil }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}
