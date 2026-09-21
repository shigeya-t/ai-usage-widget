import Foundation

protocol UsageProvider: Sendable {
    var id: String { get }
    var displayNameKey: String { get }
    var dashboardURL: URL { get }
    var credentialNameKey: String { get }
    var authNeededKey: String { get }
    var usingAppKey: String { get }
    func fetchSnapshot() async throws -> UsageSnapshot
    func loadManualCredential() -> String?
    func saveManualCredential(_ raw: String) throws
    func clearManualCredential()
}

enum UsageProviderRegistry {
    static let all: [any UsageProvider] = [
        CursorProvider(),
        ClaudeProvider(),
        ChatGPTProvider()
    ]

    static func provider(id: String) -> (any UsageProvider)? {
        all.first { $0.id == id }
    }

    static var defaultProviderID: String { CursorProvider.id }
}
