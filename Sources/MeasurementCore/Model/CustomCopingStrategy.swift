import Foundation

/// One shared list across rooms, since what helps in one room usually helps in the next;
/// each room records only whether it's checked.
public struct CustomCopingStrategy: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public var title: String
    public let createdAt: Date

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }

    public static let maximumTitleLength = 40

    /// `nil` when nothing usable is left after trimming.
    public static func normalizedTitle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumTitleLength))
    }
}
