import Combine
import Foundation

struct DeviceAnnotation: Identifiable, Codable, Equatable {
    var id: String
    var radio: String
    var name: String
    var address: String
    var note: String
    var lastSeenAt: Date?
    var location: SightingLocation?
}

struct SightingLocation: Codable, Equatable {
    var source: String
    var latitude: Double
    var longitude: Double
    var accuracyMeters: Double?
}

final class DeviceAnnotationStore: ObservableObject {
    @Published private(set) var annotations: [DeviceAnnotation] = []

    private let defaults: UserDefaults
    private let defaultsKey = "SynesthesiaMotionController.DeviceAnnotations.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([DeviceAnnotation].self, from: data) else { return }
        annotations = saved
    }

    func annotation(radio: String, address: String) -> DeviceAnnotation? {
        annotations.first { $0.id == Self.identity(radio: radio, address: address) }
    }

    func isFavorite(radio: String, address: String) -> Bool {
        annotation(radio: radio, address: address) != nil
    }

    func toggleFavorite(radio: String, name: String, address: String, seenAt: Date = Date()) {
        let id = Self.identity(radio: radio, address: address)
        if annotations.contains(where: { $0.id == id }) {
            annotations.removeAll { $0.id == id }
        } else {
            annotations.append(DeviceAnnotation(id: id, radio: radio, name: name,
                                                address: address, note: "",
                                                lastSeenAt: seenAt, location: nil))
        }
        sortAndPersist()
    }

    func updateSighting(radio: String, address: String, at date: Date,
                        location: SightingLocation? = nil) {
        let id = Self.identity(radio: radio, address: address)
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        if let lastSeen = annotations[index].lastSeenAt,
           date.timeIntervalSince(lastSeen) < 1 { return }
        annotations[index].lastSeenAt = date
        if let location { annotations[index].location = location }
        persist()
    }

    func updateNote(radio: String, name: String, address: String, note: String) {
        let id = Self.identity(radio: radio, address: address)
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].name = name
        annotations[index].note = note
        persist()
    }

    func updateNameIfFavorite(radio: String, name: String, address: String) {
        let id = Self.identity(radio: radio, address: address)
        guard let index = annotations.firstIndex(where: { $0.id == id }),
              annotations[index].name != name else { return }
        annotations[index].name = name
        persist()
    }

    func remove(_ id: String) {
        annotations.removeAll { $0.id == id }
        persist()
    }

    private func sortAndPersist() {
        annotations.sort {
            let radioOrder = $0.radio.localizedCaseInsensitiveCompare($1.radio)
            if radioOrder != .orderedSame { return radioOrder == .orderedAscending }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(annotations) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func identity(radio: String, address: String) -> String {
        "\(radio.lowercased())|\(address.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())"
    }
}
