import Common
import Foundation

let configDotfileName = ".opentile.toml"
func findCustomConfigUrl() -> ConfigFile {
    let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/")
    let candidates: [URL] = switch serverArgs.configLocation {
        case let configLocation?: [URL(filePath: configLocation)]
        case nil:
            [
                FileManager.default.homeDirectoryForCurrentUser.appending(path: configDotfileName),
                xdgConfigHome.appending(path: "opentile").appending(path: "opentile.toml"),
            ]
    }
    var existingCandidates: [URL] = candidates.filter { (candidate: URL) in FileManager.default.fileExists(atPath: candidate.path) }
    // A dedicated OpenTile config overrides the existing AeroSpace configuration.
    if existingCandidates.isEmpty && serverArgs.configLocation == nil {
        existingCandidates = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".aerospace.toml"),
            xdgConfigHome.appending(path: "aerospace/aerospace.toml"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    let count = existingCandidates.count
    return switch count {
        case 0: .noCustomConfigExists
        case 1: .file(existingCandidates.first.orDie())
        default: .ambiguousConfigError(existingCandidates)
    }
}

enum ConfigFile {
    case file(URL), ambiguousConfigError(_ candidates: [URL]), noCustomConfigExists

    var urlOrNil: URL? {
        return switch self {
            case .file(let url): url
            case .ambiguousConfigError, .noCustomConfigExists: nil
        }
    }
}
