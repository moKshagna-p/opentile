import Foundation

public struct AppMapping: Equatable {
    public let key: String
    public let application: String

    /// Import only the active Caps Lock → O variable layer and plain app launches.
    /// Shell commands are parsed as data, never executed.
    public static func read(_ data: Data) -> [AppMapping] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profiles"] as? [[String: Any]],
              let profile = profiles.first(where: { $0["selected"] as? Bool == true }) ?? (profiles.count == 1 && profiles[0]["selected"] == nil ? profiles[0] : nil),
              let modifications = profile["complex_modifications"] as? [String: Any],
              let rules = modifications["rules"] as? [[String: Any]] else { return [] }
        let manipulators = rules.flatMap { $0["manipulators"] as? [[String: Any]] ?? [] }
        func key(_ item: [String: Any]) -> String? { (item["from"] as? [String: Any])?["key_code"] as? String }
        func enabledVariables(_ item: [String: Any]) -> [String] {
            (item["to"] as? [[String: Any]] ?? []).compactMap {
                guard let variable = $0["set_variable"] as? [String: Any], variable["value"] as? Int == 1 else { return nil }
                return variable["name"] as? String
            }
        }
        func requires(_ item: [String: Any], _ names: Set<String>) -> Bool {
            (item["conditions"] as? [[String: Any]] ?? []).contains {
                $0["type"] as? String == "variable_if" && $0["value"] as? Int == 1 && names.contains($0["name"] as? String ?? "")
            }
        }
        let caps = Set(manipulators.filter { key($0) == "caps_lock" }.flatMap(enabledVariables))
        let layer = Set(manipulators.filter { key($0) == "o" && requires($0, caps) }.flatMap(enabledVariables))
        let expression = try! NSRegularExpression(pattern: #"^open\s+-a\s+(?:'([^'\n]+)'|"([^"\n$`]+)"|([A-Za-z0-9_./-]+))\s*$"#)
        var found: [String: Set<String>] = [:]
        for item in manipulators where requires(item, layer) {
            // Context-dependent shortcuts cannot be represented by a global drawing.
            let conditions = item["conditions"] as? [[String: Any]] ?? []
            guard conditions.allSatisfy({ $0["type"] as? String == "variable_if" && $0["value"] as? Int == 1 && layer.contains($0["name"] as? String ?? "") }),
                  let symbol = key(item), symbol.range(of: "^[a-z0-9]$", options: .regularExpression) != nil,
                  let actions = item["to"] as? [[String: Any]], actions.count == 1,
                  let command = actions[0]["shell_command"] as? String,
                  let match = expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { continue }
            for index in 1...3 where match.range(at: index).location != NSNotFound {
                let name = String(command[Range(match.range(at: index), in: command)!])
                found[symbol, default: []].insert(name)
            }
        }
        return found.keys.sorted().compactMap { key in
            guard let names = found[key], names.count == 1, let name = names.first else { return nil }
            return AppMapping(key: key, application: name)
        }
    }
}

/// Once a second finger appears, give the entire Option session to resizing.
public struct AppDrawingGate {
    private var resizing = false
    public init() {}
    public mutating func ownsDrawing(optionOnly: Bool, contactCounts: [Int]) -> Bool {
        guard optionOnly else { resizing = false; return false }
        if contactCounts.contains(where: { $0 > 1 }) { resizing = true }
        return !resizing
    }
}
