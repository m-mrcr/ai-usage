import SwiftUI
import WidgetKit

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(model: model)
                .environment(\.locale, model.language.locale)
        } label: {
            MenuBarLabel(
                snapshot: model.visibleSnapshot,
                isRefreshing: model.isRefreshing,
                language: model.language
            )
        }
        .menuBarExtraStyle(.window)
    }
}

/// The summary shown in the menu bar. Shows the usage of the most constrained window.
struct MenuBarLabel: View {
    let snapshot: UsageSnapshot
    let isRefreshing: Bool
    let language: AppLanguage

    var body: some View {
        if let headline = snapshot.headline {
            HStack(spacing: 3) {
                if let image = MenuBarGauge.image(percent: headline.window.usedPercent) {
                    Image(nsImage: image)
                } else {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                }
                Text(headline.window.remainingValueText)
                if headline.agent.displayStatus == .stale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                L10n.format(
                    "menubar.summary.format",
                    language: language,
                    headline.agent.name,
                    L10n.windowLabel(headline.window, language: language),
                    headline.window.remainingValueText,
                    headline.agent.displayStatus == .stale
                        ? L10n.text("menubar.staleSuffix", language: language)
                        : ""
                )
            )
        } else {
            HStack(spacing: 3) {
                Image(systemName: isRefreshing
                      ? "arrow.triangle.2.circlepath"
                      : "gauge.with.dots.needle.bottom.50percent")
                Text("—")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                L10n.text(
                    isRefreshing ? "menubar.loading" : "menubar.unavailable",
                    language: language
                )
            )
        }
    }
}

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = SnapshotStore.load()
    @Published private(set) var isRefreshing = false
    @Published private(set) var storageError: String?
    @Published private(set) var helpAgentID: String?

    @Published private(set) var language: AppLanguage = LanguagePreference.load()

    /// The cards laid out on screen. While dragging, only this array is moved to show
    /// where a card will land; it's persisted on mouse-up. Kept separate so the order
    /// doesn't jump on every collection cycle.
    @Published private(set) var orderedAgents: [AgentUsage] = []

    /// The card currently being held. nil means nothing is being dragged.
    @Published var draggingID: String?

    /// Whether to show in the Dock. Launches resident via LSUIElement, and is toggled at runtime.
    @Published var showsInDock: Bool = UserDefaults.standard.bool(forKey: "showsInDock") {
        didSet {
            UserDefaults.standard.set(showsInDock, forKey: "showsInDock")
            applyActivationPolicy()
        }
    }

    /// The display order the user arranged. If empty, leave it to automatic ordering.
    @Published private(set) var agentOrder: [String] =
        UserDefaults.standard.stringArray(forKey: "agentOrder") ?? []

    /// Agents hidden in Settings. Still collected, but never shown anywhere.
    @Published private(set) var hiddenAgentIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "hiddenAgentIDs") ?? [])

    /// Whether to show per-model supplementary windows (e.g. Codex's model-specific limits).
    /// An unused model's window just sits at 0%, so it's hidden by default.
    @Published private(set) var showsModelLimits: Bool =
        UserDefaults.standard.bool(forKey: "showsModelLimits")

    /// If supplementary windows are set to be hidden, drop them before display.
    /// Kept in one place so the menu bar, list, and widget all share the same decision.
    private func presented(_ agents: [AgentUsage]) -> [AgentUsage] {
        guard !showsModelLimits else { return agents }
        return agents.map { agent in
            guard agent.windows.contains(where: \.isSupplementary) else { return agent }
            var copy = agent
            copy.windows = agent.windows.filter { !$0.isSupplementary }
            return copy
        }
    }

    /// For the Settings screen. Includes hidden agents, but keeps the same window filtering as other screens.
    /// If supplementary windows leaked through here, they'd show up in the list even with the toggle off, which would be confusing.
    var allAgents: [AgentUsage] { presented(reordered(snapshot.agents, by: agentOrder)) }

    /// A snapshot narrowed down to only what should be displayed. The menu bar and widget look at this.
    var visibleSnapshot: UsageSnapshot {
        let visible = presented(reordered(snapshot.agents, by: agentOrder))
            .filter { !hiddenAgentIDs.contains($0.id) }
        return UsageSnapshot(
            updatedAt: snapshot.updatedAt,
            agents: visible,
            preferredAgentID: agentOrder.isEmpty
                ? nil
                : visible.first { !$0.windows.isEmpty }?.id
        )
    }

    func isHidden(_ id: String) -> Bool { hiddenAgentIDs.contains(id) }

    /// The claude.ai session. Never exposes the value itself, only when the sign-in happened.
    /// Showing the last few characters wouldn't give the user any way to verify it, so it isn't useful.
    @Published private(set) var claudeSessionSavedAt: Date?

    var hasClaudeSessionKey: Bool { claudeSessionSavedAt != nil }

    func loadClaudeSessionKeyHint() {
        claudeSessionSavedAt = ClaudeSessionKey.load() == nil ? nil : ClaudeSessionKey.savedAt()
    }

    /// Called right after the WebView saves the key. The save itself is already done on the View side.
    func didCaptureClaudeSessionKey() {
        loadClaudeSessionKeyHint()
        refresh(force: true)
    }

    func removeClaudeSessionKey() {
        ClaudeSessionKey.remove()
        loadClaudeSessionKeyHint()
        refresh(force: true)
    }

    /// The cursor.com session. Shared by Grok Bot and Cursor.
    /// As with Claude, never keeps the value itself, only the sign-in time.
    @Published private(set) var cursorSessionSavedAt: Date?

    var hasCursorSession: Bool { cursorSessionSavedAt != nil }

    /// There's no point showing settings in an environment where neither app is installed.
    var showsCursorSection: Bool {
        GrokBotCollector.installed || CursorCollector.installed || hasCursorSession
    }

    func loadCursorSessionSavedAt() {
        cursorSessionSavedAt = CursorSession.load() == nil ? nil : CursorSession.savedAt()
    }

    func didCaptureCursorSession() {
        loadCursorSessionSavedAt()
        refresh(force: true)
    }

    func removeCursorSession() {
        CursorSession.remove()
        loadCursorSessionSavedAt()
        refresh(force: true)
    }

    /// Only show the setting when there's an agent with a supplementary window.
    var hasModelLimits: Bool {
        snapshot.agents.contains { $0.windows.contains(where: \.isSupplementary) }
    }

    func setShowsModelLimits(_ proposed: Bool) {
        guard proposed != showsModelLimits else { return }
        let previous = showsModelLimits
        showsModelLimits = proposed
        syncOrderedAgents()

        // Only commit the setting after the published snapshot update succeeds. For hiding especially,
        // confirm it's actually gone from the widget before saving.
        guard publishVisible(clearOnFailure: true) else {
            showsModelLimits = previous
            syncOrderedAgents()
            publishVisible()
            return
        }
        UserDefaults.standard.set(proposed, forKey: "showsModelLimits")
    }

    func toggleHidden(_ id: String) {
        var proposed = hiddenAgentIDs
        if proposed.contains(id) { proposed.remove(id) }
        else { proposed.insert(id) }
        applyHiddenAgentIDs(proposed)
    }

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var dragEndTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var refreshPending = false
    private var lastPublishedAgents: [AgentUsage]?
    private var lastPublishedPreferredID: String?
    private var privateStorageError: String?
    private var publishedStorageError: String?
    private let windowController = UsageWindowController()
    private let settingsController = SettingsWindowController()
    private let helpController = HelpWindowController()

    init() {
        // On first launch, also commit the value decided from the system language to the App Group, to match the Widget.
        LanguagePreference.save(language)
        if let saved = try? SnapshotStore.loadPrivate() {
            snapshot = saved.expiringStaleData()
        } else if let published = try? SnapshotStore.loadPublished() {
            snapshot = published.expiringStaleData()
        }
        applyActivationPolicy()
        AppDelegate.onReopen = { [weak self] in self?.openWindow() }
        syncOrderedAgents()
        // Even if a hidden item lingers in an old shared snapshot, narrow the published scope right after launch.
        publishVisible(clearOnFailure: true)
        refresh()
        // Claude's statusLine keeps writing constantly while it's running, so poll it at a shorter interval.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(showsInDock ? .regular : .accessory)
        // If removed from the Dock, close the window too — leaving it open would strand it.
        if !showsInDock { windowController.close() }
    }

    /// Called from a click on the Dock icon.
    func openWindow() {
        windowController.show(model: self)
    }

    func openSettings() {
        // The MenuBarExtra popover exists as a panel floating above everything else,
        // so opening a normal-level settings window would just hide behind it. Close it first.
        dismissMenuBarPopover()
        loadClaudeSessionKeyHint()
        loadCursorSessionSavedAt()
        settingsController.show(model: self)
    }

    func openHelp(for agentID: String? = nil) {
        helpAgentID = agentID
        dismissMenuBarPopover()
        helpController.show(model: self)
    }

    func setLanguage(_ proposed: AppLanguage) {
        guard proposed != language else { return }
        LanguagePreference.save(proposed)
        language = proposed
        settingsController.updateLanguage(proposed)
        helpController.updateLanguage(proposed)
        WidgetCenter.shared.reloadTimelines(ofKind: "AIUsageWidget")
    }

    private func dismissMenuBarPopover() {
        for window in NSApp.windows where window.isVisible {
            let kind = String(describing: type(of: window))
            guard kind.contains("MenuBarExtra") || kind.contains("NSStatusBarWindow")
                    || window.level == .popUpMenu
            else { continue }
            window.close()
        }
    }

    /// Share it with hidden items excluded, and notify the widget.
    @discardableResult
    private func publishVisible(clearOnFailure: Bool = false) -> Bool {
        let visible = visibleSnapshot
        do {
            try SnapshotStore.savePublished(visible)
            publishedStorageError = nil

            let changed = lastPublishedAgents != visible.agents
                || lastPublishedPreferredID != visible.preferredAgentID
            lastPublishedAgents = visible.agents
            lastPublishedPreferredID = visible.preferredAgentID
            if changed { WidgetCenter.shared.reloadTimelines(ofKind: "AIUsageWidget") }
            updateStorageError()
            return true
        } catch {
            publishedStorageError = error.localizedDescription
            if clearOnFailure {
                do { try SnapshotStore.removePublished() }
                catch { publishedStorageError = error.localizedDescription }
            }
            updateStorageError()
            return false
        }
    }

    private func updateStorageError() {
        let errors = [privateStorageError, publishedStorageError].compactMap { $0 }
        storageError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    // MARK: - Reordering

    /// SwiftUI's onDrag has no completion callback, so always clear the drag after mouse-up, even if dropped outside the list.
    func beginDrag(_ id: String) {
        draggingID = id
        dragEndTask?.cancel()
        dragEndTask = Task { [weak self] in
            do {
                while NSEvent.pressedMouseButtons & 1 != 0 {
                    try await Task.sleep(for: .milliseconds(100))
                }
                // Give the row's drop delegate a chance to commit first.
                try await Task.sleep(for: .milliseconds(200))
            } catch { return }
            guard let self, self.draggingID == id else { return }
            self.cancelDrag()
        }
    }

    /// The swap while dragging. Only moves the display array, so it's reflected instantly and smoothly.
    func previewMove(_ dragged: String, over target: String) {
        guard dragged != target,
              let from = orderedAgents.firstIndex(where: { $0.id == dragged }),
              let to = orderedAgents.firstIndex(where: { $0.id == target })
        else { return }
        withAnimation(.snappy(duration: 0.22)) {
            let moved = orderedAgents.remove(at: from)
            orderedAgents.insert(moved, at: to)
        }
    }

    /// Commit and save at the moment the mouse is released.
    func commitOrder() {
        dragEndTask?.cancel()
        dragEndTask = nil
        draggingID = nil
        persist(orderedAgents.map(\.id))
        resumePendingRefresh()
    }

    func cancelDrag() {
        dragEndTask?.cancel()
        dragEndTask = nil
        draggingID = nil
        syncOrderedAgents()
        resumePendingRefresh()
    }

    func moveAgent(_ id: String, by offset: Int) {
        guard let from = orderedAgents.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, from + offset), orderedAgents.count - 1)
        guard from != to else { return }
        let moved = orderedAgents.remove(at: from)
        orderedAgents.insert(moved, at: to)
        persist(orderedAgents.map(\.id))
    }

    func resetOrder() {
        persist([])
        refresh(force: true)
    }

    private func persist(_ ids: [String]) {
        agentOrder = ids
        UserDefaults.standard.set(ids, forKey: "agentOrder")
        // Reflect the saved order in the widget too.
        let agents = reordered(snapshot.agents, by: ids)
        snapshot = UsageSnapshot(
            updatedAt: snapshot.updatedAt,
            agents: agents,
            preferredAgentID: ids.isEmpty
                ? nil
                : agents.first { !$0.windows.isEmpty }?.id
        )
        publishVisible()
    }

    private func reordered(_ agents: [AgentUsage], by ids: [String]) -> [AgentUsage] {
        guard !ids.isEmpty else { return agents }
        return agents.enumerated().sorted { lhs, rhs in
            let l = ids.firstIndex(of: lhs.element.id) ?? (ids.count + lhs.offset)
            let r = ids.firstIndex(of: rhs.element.id) ?? (ids.count + rhs.offset)
            return l < r
        }.map(\.element)
    }

    /// Copy the collection results into the display array. Don't touch it while dragging.
    private func syncOrderedAgents() {
        guard draggingID == nil else { return }
        orderedAgents = presented(reordered(snapshot.agents, by: agentOrder)).filter {
            $0.status != .notInstalled && !hiddenAgentIDs.contains($0.id)
        }
    }

    // MARK: - Collection

    func refresh(force: Bool = false) {
        // If the order changed mid-drag, the card being held would jump, so wait.
        guard draggingID == nil else {
            refreshPending = true
            return
        }
        if refreshTask != nil {
            guard force else { return }
            refreshTask?.cancel()
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        let order = agentOrder
        refreshTask = Task { [weak self] in
            let fresh = await Task.detached(priority: .utility) {
                await UsageCollector.collectAll(order: order, force: force)
            }.value
            guard !Task.isCancelled, let self,
                  generation == self.refreshGeneration
            else { return }

            let merged = self.mergingUnavailableAgents(in: fresh, with: self.snapshot)
                .expiringStaleData()
            let currentOrder = self.agentOrder
            let currentAgents = self.reordered(merged.agents, by: currentOrder)
            let normalized = UsageSnapshot(
                updatedAt: merged.updatedAt,
                agents: currentAgents,
                preferredAgentID: currentOrder.isEmpty
                    ? nil
                    : currentAgents.first { !$0.windows.isEmpty }?.id
            )
            self.snapshot = normalized
            do {
                try SnapshotStore.savePrivate(normalized)
                self.privateStorageError = nil
            } catch {
                self.privateStorageError = error.localizedDescription
            }
            self.syncOrderedAgents()
            self.isRefreshing = false
            self.refreshTask = nil
            self.publishVisible()
            self.updateStorageError()
        }
    }

    private func resumePendingRefresh() {
        guard refreshPending else { return }
        refreshPending = false
        refresh(force: true)
    }

    /// Don't discard the last real measurement on a transient Keychain/API/file-read failure; keep it as an explicit stale value instead.
    private func mergingUnavailableAgents(
        in fresh: UsageSnapshot,
        with previous: UsageSnapshot
    ) -> UsageSnapshot {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.agents.map { ($0.id, $0) })
        let agents = fresh.agents.map { agent -> AgentUsage in
            guard agent.status == .unavailable,
                  agent.windows.isEmpty,
                  let old = previousByID[agent.id],
                  !old.windows.isEmpty
            else { return agent }
            return AgentUsage(
                id: agent.id,
                name: agent.name,
                plan: old.plan,
                windows: old.windows,
                observedAt: old.observedAt,
                source: old.source,
                status: .stale,
                note: agent.note
            )
        }
        return UsageSnapshot(updatedAt: fresh.updatedAt, agents: agents,
                             preferredAgentID: fresh.preferredAgentID)
    }

    /// Only commit the setting after narrowing the published snapshot succeeds. Revert the UI too on failure.
    private func applyHiddenAgentIDs(_ proposed: Set<String>) {
        let previous = hiddenAgentIDs
        hiddenAgentIDs = proposed
        syncOrderedAgents()

        guard publishVisible(clearOnFailure: true) else {
            let failure = publishedStorageError ?? "The visible snapshot could not be updated"
            hiddenAgentIDs = previous
            syncOrderedAgents()
            let restored = publishVisible()
            if restored {
                publishedStorageError = "Visibility change was not applied: \(failure)"
                updateStorageError()
            }
            return
        }

        UserDefaults.standard.set(Array(proposed).sorted(), forKey: "hiddenAgentIDs")
    }
}
