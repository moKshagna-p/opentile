/// First-visited order stays fixed when a workspace is revisited.
public struct WorkspaceStack {
    public private(set) var workspaces: [String]

    public init(workspaces: [String] = []) {
        var seen = Set<String>()
        self.workspaces = workspaces.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Positive means the destination is below the current workspace.
    public mutating func direction(from source: String, to destination: String) -> Int {
        for workspace in [source, destination] where !workspaces.contains(workspace) {
            workspaces.append(workspace)
        }
        let sourceIndex = workspaces.firstIndex(of: source)!
        let destinationIndex = workspaces.firstIndex(of: destination)!
        return destinationIndex == sourceIndex ? 0 : (destinationIndex > sourceIndex ? 1 : -1)
    }
}
