import AppIntents
import WidgetKit

/// The agent chosen via the widget's "Edit Widget".
struct AgentEntity: AppEntity {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = AgentQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Candidates are pulled from the snapshot the main app writes out. Uninstalled ones aren't shown.
struct AgentQuery: EntityQuery {
    func entities(for identifiers: [AgentEntity.ID]) async throws -> [AgentEntity] {
        available().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AgentEntity] {
        available()
    }

    func defaultResult() async -> AgentEntity? {
        available().first
    }

    private func available() -> [AgentEntity] {
        SnapshotStore.load().agents
            .filter { $0.displayStatus != .notInstalled }
            .map { AgentEntity(id: $0.id, name: $0.name) }
    }
}

struct SelectAgentsIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "AI Usage"
    static let description = IntentDescription(
        "Choose which agents to show. The first one leads. Medium widgets show up to four quota rows, and one agent may use multiple rows."
    )

    @Parameter(title: "Agents")
    var agents: [AgentEntity]?

    /// If unspecified, use the app's order as-is.
    var selectedIDs: [String] { (agents ?? []).map(\.id) }
}
