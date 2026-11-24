import Combine
import Foundation

enum WatchRuleKind: String, CaseIterable, Codable, Identifiable {
    case bluetoothName
    case wifiName
    case bluetoothAddress
    case wifiAddress
    case signature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bluetoothName: "BLE name"
        case .wifiName: "Wi-Fi name"
        case .bluetoothAddress: "BLE address"
        case .wifiAddress: "Wi-Fi address"
        case .signature: "Detection signature"
        }
    }

    var inputPrompt: String {
        switch self {
        case .bluetoothName: "Exact advertised BLE name"
        case .wifiName: "Exact Wi-Fi network name"
        case .bluetoothAddress: "Exact BLE address"
        case .wifiAddress: "Exact Wi-Fi BSSID"
        case .signature: "Exact signature category"
        }
    }
}

struct WatchRule: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: WatchRuleKind
    var value: String
    var label: String
    var enabled: Bool
}

final class BLEWatchlistStore: ObservableObject {
    @Published private(set) var rules: [WatchRule] = []

    private let defaults: UserDefaults
    private let defaultsKey = "SynesthesiaMotionController.WatchRules.v1"
    private let legacyDefaultsKey = "SynesthesiaMotionController.BLEWatchlistNames"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([WatchRule].self, from: data) {
            rules = decoded
        } else {
            let legacyNames = defaults.stringArray(forKey: legacyDefaultsKey) ?? []
            rules = legacyNames.compactMap { name in
                let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                return WatchRule(id: UUID(), kind: .bluetoothName, value: value,
                                 label: value, enabled: true)
            }
            persist()
        }
    }

    func contains(_ kind: WatchRuleKind, value: String) -> Bool {
        rules.contains { $0.kind == kind && Self.equal($0.kind, $0.value, value) }
    }

    func matchingRules(_ kind: WatchRuleKind, value: String) -> [WatchRule] {
        rules.filter { $0.enabled && $0.kind == kind && Self.equal($0.kind, $0.value, value) }
    }

    @discardableResult
    func add(_ kind: WatchRuleKind, value: String, label: String? = nil) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty, !contains(kind, value: trimmedValue) else { return false }
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        rules.append(WatchRule(id: UUID(), kind: kind, value: trimmedValue,
                               label: (trimmedLabel?.isEmpty == false ? trimmedLabel : nil) ?? trimmedValue,
                               enabled: true))
        sortAndPersist()
        return true
    }

    func toggle(_ kind: WatchRuleKind, value: String) {
        if let rule = rules.first(where: { $0.kind == kind && Self.equal(kind, $0.value, value) }) {
            remove(rule.id)
        } else {
            _ = add(kind, value: value)
        }
    }

    func rename(_ id: UUID, label: String) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].label = label
        persist()
    }

    func setEnabled(_ id: UUID, enabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled = enabled
        persist()
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    func remove(_ kind: WatchRuleKind, value: String) {
        rules.removeAll { $0.kind == kind && Self.equal(kind, $0.value, value) }
        persist()
    }

    private func sortAndPersist() {
        rules.sort {
            let order = $0.kind.title.localizedCaseInsensitiveCompare($1.kind.title)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func equal(_ kind: WatchRuleKind, _ lhs: String, _ rhs: String) -> Bool {
        switch kind {
        case .bluetoothName, .bluetoothAddress, .wifiAddress, .signature:
            lhs.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        case .wifiName:
            lhs.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
