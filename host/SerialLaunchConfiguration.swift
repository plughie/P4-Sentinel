import Foundation

struct SerialLaunchConfiguration: Decodable {
    let python: String
    let bridge: String
    let port: String
    let initialScene: String?

    static func load() -> Self? {
        let args = CommandLine.arguments
        if args.count == 4 {
            return Self(python: args[1], bridge: args[2], port: args[3], initialScene: nil)
        }
        guard let url = Bundle.main.url(forResource: "serial-config", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
