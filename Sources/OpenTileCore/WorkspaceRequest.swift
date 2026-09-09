import Foundation

public enum WorkspaceRequest: Equatable {
    case workspace(String)
    case backAndForth

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "opentile", parts.host == "workspace",
              parts.path.isEmpty, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil else { return nil }
        let items = parts.queryItems ?? []
        guard items.count == 1, let item = items.first else { return nil }
        if item.name == "name", let name = item.value, !name.isEmpty,
           !name.hasPrefix("-"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            self = .workspace(name)
        } else if item.name == "action", item.value == "back-and-forth" {
            self = .backAndForth
        } else { return nil }
    }

    public var arguments: [String] {
        switch self {
        case .workspace(let name): return ["workspace", name]
        case .backAndForth: return ["workspace-back-and-forth"]
        }
    }
}
