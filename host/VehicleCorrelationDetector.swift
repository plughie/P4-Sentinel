import Foundation

struct VehicleCorrelationCandidate {
    let id: String
    let label: String
    let signature: String
    let strengthHistory: SignalStrengthHistory
    let lastSeen: Date
}

struct VehicleCorrelationGroup {
    let first: VehicleCorrelationCandidate
    let second: VehicleCorrelationCandidate
    let coefficient: Double
    let sharedSamples: Int
    let span: TimeInterval

    var evidence: String {
        "\(first.signature) ‘\(first.label)’ and \(second.signature) ‘\(second.label)’ had " +
        "\(sharedSamples) aligned RSSI samples over \(Int(span.rounded())) s (r=\(String(format: "%.2f", coefficient)))"
    }
}

enum VehicleCorrelationDetector {
    static let minimumSharedSamples = 4
    static let minimumSpan: TimeInterval = 15
    static let minimumRSSIRange = 6
    static let minimumCorrelation = 0.85
    private static let freshnessWindow: TimeInterval = 20

    static func group(from candidates: [VehicleCorrelationCandidate], at now: Date) -> VehicleCorrelationGroup? {
        let current = candidates.filter { now.timeIntervalSince($0.lastSeen) < freshnessWindow }
        var best: VehicleCorrelationGroup?
        for leftIndex in current.indices {
            for rightIndex in current.indices where rightIndex > leftIndex {
                let first = current[leftIndex]
                let second = current[rightIndex]
                guard first.id != second.id, first.signature != second.signature,
                      let result = correlated(first.strengthHistory, second.strengthHistory),
                      result.count >= minimumSharedSamples,
                      result.span >= minimumSpan,
                      result.firstRange >= minimumRSSIRange,
                      result.secondRange >= minimumRSSIRange,
                      result.coefficient >= minimumCorrelation else { continue }
                let group = VehicleCorrelationGroup(first: first, second: second,
                                                    coefficient: result.coefficient,
                                                    sharedSamples: result.count,
                                                    span: result.span)
                if best == nil || group.coefficient > best!.coefficient { best = group }
            }
        }
        return best
    }

    private static func correlated(_ first: SignalStrengthHistory,
                                   _ second: SignalStrengthHistory) -> (count: Int, span: TimeInterval,
                                                                          coefficient: Double, firstRange: Int,
                                                                          secondRange: Int)? {
        let firstSamples = first.samples.sorted { $0.time < $1.time }
        let secondSamples = second.samples.sorted { $0.time < $1.time }
        var usedSecond = Set<Int>()
        var pairs: [(time: Date, first: Int, second: Int)] = []
        for sample in firstSamples {
            let closest = secondSamples.indices
                .filter { !usedSecond.contains($0)
                    && abs(secondSamples[$0].time.timeIntervalSince(sample.time))
                        <= SignalStrengthHistory.bucketDuration }
                .min {
                    abs(secondSamples[$0].time.timeIntervalSince(sample.time))
                        < abs(secondSamples[$1].time.timeIntervalSince(sample.time))
                }
            guard let closest else { continue }
            usedSecond.insert(closest)
            pairs.append((sample.time, sample.rssi, secondSamples[closest].rssi))
        }
        guard pairs.count >= minimumSharedSamples,
              let start = pairs.first?.time, let end = pairs.last?.time else { return nil }
        let a = pairs.map(\.first)
        let b = pairs.map(\.second)
        let meanA = Double(a.reduce(0, +)) / Double(a.count)
        let meanB = Double(b.reduce(0, +)) / Double(b.count)
        var covariance = 0.0
        var varianceA = 0.0
        var varianceB = 0.0
        for index in a.indices {
            let deltaA = Double(a[index]) - meanA
            let deltaB = Double(b[index]) - meanB
            covariance += deltaA * deltaB
            varianceA += deltaA * deltaA
            varianceB += deltaB * deltaB
        }
        guard varianceA > 0, varianceB > 0 else { return nil }
        return (pairs.count, end.timeIntervalSince(start),
                covariance / sqrt(varianceA * varianceB), (a.max() ?? 0) - (a.min() ?? 0),
                (b.max() ?? 0) - (b.min() ?? 0))
    }
}
