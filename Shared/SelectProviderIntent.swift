import AppIntents
import WidgetKit

struct ProviderEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")
    static var defaultQuery = ProviderEntityQuery()

    var id: String
    var displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

// EntityStringQuery にして、編集画面の選択肢を検索つきリストで出す。
// 素の EntityQuery だとポップアップメニューになり、macOS 27.2.1 では選んだ値が
// 編集画面に反映されず、閉じたあとウィジェットの右クリックも効かなくなる。
struct ProviderEntityQuery: EntityStringQuery {
    func entities(for identifiers: [ProviderEntity.ID]) async throws -> [ProviderEntity] {
        identifiers.compactMap { id in
            guard let provider = UsageProviderRegistry.provider(id: id) else { return nil }
            return ProviderEntity(
                id: provider.id,
                displayName: L10n.string(provider.displayNameKey)
            )
        }
    }

    func suggestedEntities() async throws -> [ProviderEntity] {
        UsageProviderRegistry.all.map {
            ProviderEntity(id: $0.id, displayName: L10n.string($0.displayNameKey))
        }
    }

    func entities(matching string: String) async throws -> [ProviderEntity] {
        let all = try await suggestedEntities()
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    func defaultResult() async -> ProviderEntity? {
        let id = UsageProviderRegistry.defaultProviderID
        guard let provider = UsageProviderRegistry.provider(id: id) else { return nil }
        return ProviderEntity(id: provider.id, displayName: L10n.string(provider.displayNameKey))
    }
}

struct SelectProviderIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Select Provider" }
    static var description: IntentDescription { "Choose which AI service usage to show." }

    @Parameter(title: "Provider")
    var provider: ProviderEntity?

    init() {}

    init(provider: ProviderEntity?) {
        self.provider = provider
    }

    var resolvedProviderID: String {
        if let id = provider?.id, UsageProviderRegistry.provider(id: id) != nil {
            return id
        }
        return UsageProviderRegistry.defaultProviderID
    }
}
