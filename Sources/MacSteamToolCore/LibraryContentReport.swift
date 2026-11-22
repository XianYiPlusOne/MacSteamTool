import Foundation

public struct LibraryDepotReport: Identifiable, Equatable, Sendable {
    public var id: Int
    public var platform: String
    public var language: String?
    public var hasKey: Bool
}

public struct LibraryContentReport: Identifiable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var isMain: Bool
    public var issues: [String] = []
    public var metadataKnown: Bool
    public var depots: [LibraryDepotReport]
    public var isUnavailableOptionalDLC: Bool {
        !isMain && (!metadataKnown || !issues.isEmpty || !missingDepots.isEmpty)
    }
    public var missingDepots: [Int] { depots.filter { !$0.hasKey }.map(\.id) }
}
