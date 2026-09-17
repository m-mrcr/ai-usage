import SwiftUI
import UniformTypeIdentifiers

struct UsagePopoverView: View {
    @ObservedObject var model: UsageModel
    /// In resident-only mode there's no app menu, so the popover is the only way to quit.
    /// The window only opens in Dock mode, which has the standard app menu and Cmd+Q, so it's unneeded there.
    var showsQuit: Bool = true

    private var visibleAgents: [AgentUsage] { model.orderedAgents }
    private var language: AppLanguage { model.language }

    private var isInitialLoading: Bool {
        model.isRefreshing && model.snapshot.updatedAt == .distantPast
    }

    private var allInstalledAgentsAreHidden: Bool {
        let installed = model.allAgents.filter { $0.displayStatus != .notInstalled }
        return !installed.isEmpty && installed.allSatisfy { model.isHidden($0.id) }
    }

    /// Give MenuBarExtra a stable intrinsic height while still capping long lists.
    private var listHeight: CGFloat {
        guard !visibleAgents.isEmpty else { return model.storageError == nil ? 78 : 126 }
        let rows = visibleAgents.reduce(CGFloat.zero) { total, agent in
            let windowCount = max(1, agent.windows.count)
            let windowGaps = CGFloat(max(0, windowCount - 1)) * 7
            return total + 41 + CGFloat(windowCount) * 31 + windowGaps
        }
        let gaps = CGFloat(max(0, visibleAgents.count - 1)) * 8
        let storageNotice: CGFloat = model.storageError == nil ? 0 : 44
        let signInNotices = CGFloat(visibleAgents.filter(\.needsClaudeSignIn).count) * 34
        // Font metrics can differ by a few points from the compact row estimate.
        // Leave per-card room so a fully visible list does not retain a tiny scroll range.
        let fittingAllowance = CGFloat(visibleAgents.count) * 8
        return min(460, rows + gaps + storageNotice + signInNotices + 24 + fittingAllowance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(visibleAgents.enumerated()), id: \.element.id) { index, agent in
                        AgentRow(
                            agent: agent,
                            isFirst: agent.id == visibleAgents.first?.id,
                            isDragging: model.draggingID == agent.id,
                            canMoveUp: index > 0,
                            canMoveDown: index < visibleAgents.count - 1,
                            language: language,
                            moveUp: { model.moveAgent(agent.id, by: -1) },
                            moveDown: { model.moveAgent(agent.id, by: 1) },
                            showStaleHelp: { model.openHelp(for: agent.id) },
                            recheck: { model.refresh(force: true) },
                            isRefreshing: model.isRefreshing
                        )
                        .onDrag {
                            model.beginDrag(agent.id)
                            return NSItemProvider(object: agent.id as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: ReorderDropDelegate(targetID: agent.id, model: model)
                        )
                    }
                    if visibleAgents.isEmpty {
                        emptyState
                    }
                    if model.storageError != nil {
                        storageErrorBanner
                    }
                }
                .padding(12)
            }
            .frame(height: listHeight)
            .scrollBounceBehavior(.basedOnSize)

            Divider()

            footer
        }
        .frame(width: 320)
        .onExitCommand {
            if model.draggingID != nil { model.cancelDrag() }
        }
        .onDisappear {
            if model.draggingID != nil { model.cancelDrag() }
        }
        .environment(\.locale, language.locale)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isInitialLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("popover.checking.title", language: language))
                        .font(.callout.weight(.semibold))
                    Text(L10n.text("popover.checking.detail", language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.text("popover.checking.accessibility", language: language))
        } else if allInstalledAgentsAreHidden {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("popover.hidden.title", language: language))
                    .font(.callout.weight(.semibold))
                Text(L10n.text("popover.hidden.detail", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.text("popover.openSettings", language: language)) {
                    model.openSettings()
                }
                    .buttonStyle(.link)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("popover.unsupported.title", language: language))
                    .font(.callout.weight(.semibold))
                Text(L10n.text("popover.unsupported.detail", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var storageErrorBanner: some View {
        Label(
            L10n.text("popover.storageUnavailable", language: language),
            systemImage: "exclamationmark.triangle.fill"
        )
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            .help(L10n.text("popover.storageUnavailable.detail", language: language))
            .accessibilityHint(
                L10n.text("popover.storageUnavailable.detail", language: language)
            )
    }

    private var header: some View {
        HStack {
            Text("AI Usage")
                .font(.headline)
            Spacer()
            Button {
                model.refresh(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help(L10n.text("common.refreshNow", language: language))
            .accessibilityLabel(
                L10n.text(
                    model.isRefreshing ? "popover.refreshing" : "popover.refresh.help",
                    language: language
                )
            )

            Button {
                model.openHelp()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("common.help", language: language))
            .accessibilityLabel(L10n.text("popover.help.help", language: language))

            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("common.settings", language: language))
            .accessibilityLabel(L10n.text("popover.settings.help", language: language))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Lets you confirm from an absolute time whether the collection process itself is actually running.
    private var footer: some View {
        HStack {
            Text(checkedText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(L10n.text("popover.checked.help", language: language))
            Spacer()
            if showsQuit {
                Button(L10n.text("common.quit", language: language)) {
                    NSApplication.shared.terminate(nil)
                }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var checkedText: String {
        guard model.snapshot.updatedAt != .distantPast else {
            return L10n.text("popover.notChecked", language: language)
        }
        let date = model.snapshot.updatedAt
        let style = Calendar.current.isDateInToday(date)
            ? Date.FormatStyle(date: .omitted, time: .standard)
            : Date.FormatStyle(date: .abbreviated, time: .standard)
        let formatted = date.formatted(style.locale(language.locale))
        return L10n.format("popover.checked.format", language: language, formatted)
    }

}

/// Passing over another card while dragging swaps the order right there, so you can see where it will land.
struct ReorderDropDelegate: DropDelegate {
    let targetID: String
    let model: UsageModel

    func dropEntered(info: DropInfo) {
        guard let dragged = model.draggingID else { return }
        model.previewMove(dragged, over: targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard model.draggingID != nil, info.hasItemsConforming(to: [.text]) else {
            return false
        }
        model.commitOrder()
        return true
    }
}

struct AgentRow: View {
    let agent: AgentUsage
    var isFirst: Bool = false
    var isDragging: Bool = false
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    let language: AppLanguage
    let moveUp: () -> Void
    let moveDown: () -> Void
    let showStaleHelp: () -> Void
    let recheck: () -> Void
    var isRefreshing: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // Shows which agent this belongs to via a left color stripe, same as the widget.
            Capsule()
                .fill(agent.accent)
                .frame(width: 3)

            content
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(agent.accent.opacity(isFirst ? 0.16 : 0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(agent.accent.opacity(isFirst ? 0.5 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .opacity(isDragging ? 0.35 : 1)
        .scaleEffect(isDragging ? 0.97 : 1)
        .animation(.snappy(duration: 0.18), value: isDragging)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            L10n.format("popover.agentUsage.format", language: language, agent.name)
        )
        .modifier(
            ReorderAccessibilityActions(
                canMoveUp: canMoveUp,
                canMoveDown: canMoveDown,
                language: language,
                moveUp: moveUp,
                moveDown: moveDown
            )
        )
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(agent.name)
                    .font(.subheadline.weight(.semibold))
                if let plan = agent.plan {
                    Text(plan)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if agent.displayStatus == .stale {
                    Button(action: showStaleHelp) {
                        Label(
                            L10n.text("common.stale", language: language),
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("popover.stale.help", language: language))
                    .accessibilityLabel(
                        L10n.text("popover.stale.accessibility", language: language)
                    )
                }
                Menu {
                    Button(L10n.text("popover.moveUp", language: language), action: moveUp)
                        .disabled(!canMoveUp)
                    Button(L10n.text("popover.moveDown", language: language), action: moveDown)
                        .disabled(!canMoveDown)
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.text("popover.reorder.help", language: language))
                .accessibilityLabel(
                    L10n.format(
                        "popover.reorder.accessibility.format",
                        language: language,
                        agent.name
                    )
                )
            }

            if agent.windows.isEmpty {
                Text(
                    L10n.agentNote(agent.note, language: language)
                        ?? L10n.text("common.noData", language: language)
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(agent.displayWindows) { window in
                    WindowBar(window: window, language: language)
                }
            }

            if let action = agent.attentionAction {
                // A plain text link alone wouldn't be noticed as tappable.
                // Surface the two actions needed to recover (read the guidance / check again) as buttons right here.
                // A filled tint would sink the text when it overlaps the popover's translucent background.
                // Keep the fill at its default and put the attention color only on the icon.
                HStack(spacing: 6) {
                    Button(action: showStaleHelp) {
                        HStack(spacing: 4) {
                            Image(systemName: action.symbol)
                                .foregroundStyle(.orange)
                            Text(L10n.text(action.labelKey, language: language))
                        }
                        .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.bordered)

                    Button(action: recheck) {
                        Label(
                            L10n.text("common.checkAgain", language: language),
                            systemImage: "arrow.clockwise"
                        )
                        .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshing)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .help(
                    L10n.agentNote(agent.note, language: language)
                        ?? L10n.text("popover.stale.help", language: language)
                )
            }
        }
    }
}

private extension AgentUsage {
    struct AttentionAction {
        let labelKey: String
        let symbol: String
    }

    /// Only show a button for states that have a defined recovery action.
    /// When a terminal sign-in is required, re-signing-in in the app won't fix it, so use different wording.
    var attentionAction: AttentionAction? {
        switch note {
        case "Claude usage needs a terminal Claude Code sign-in; run claude in Terminal, then check again",
             "Claude credentials expired; run claude in Terminal to refresh them, then check again":
            return AttentionAction(labelKey: "popover.claudeTerminalSignIn", symbol: "terminal")
        case "Claude sign-in expired and could not be refreshed; sign in to Claude Code again, then check again",
             "Claude credentials were rejected; sign in to Claude Code again",
             "Claude usage data expired; sign in to Claude Code again, then check again":
            return AttentionAction(labelKey: "popover.claudeSignIn", symbol: "person.badge.key")
        default:
            return nil
        }
    }

    var needsClaudeSignIn: Bool { attentionAction != nil }
}

struct WindowBar: View {
    let window: UsageWindow
    let language: AppLanguage


    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                WindowChip(
                    window: window,
                    emphasized: window.isShortWindow,
                    language: language
                )

                UsageBar(percent: window.usedPercent, height: 7, language: language)

                Text(window.usedText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, alignment: .trailing)
            }

            HStack(spacing: 5) {
                Text(
                    L10n.format(
                        "common.left.format",
                        language: language,
                        window.remainingValueText
                    )
                )
                if let resetDate = window.resetsAt {
                    Text("·")
                    Text(L10n.text("common.reset", language: language))
                    Text(resetDate, style: .relative)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 32)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.format(
                "popover.quota.accessibility.format",
                language: language,
                L10n.windowLabel(window, language: language)
            )
        )
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var values = [
            L10n.format(
                "popover.used.accessibility.format",
                language: language,
                window.usedText
            ),
            L10n.format(
                "common.left.format",
                language: language,
                window.remainingValueText
            )
        ]
        if let resetDate = window.resetsAt {
            let relative = resetDate.formatted(
                Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .abbreviated)
                    .locale(language.locale)
            )
            values.append(
                L10n.format(
                    "popover.reset.accessibility.format",
                    language: language,
                    relative
                )
            )
        }
        return values.joined(separator: ", ")
    }
}

private struct ReorderAccessibilityActions: ViewModifier {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let language: AppLanguage
    let moveUp: () -> Void
    let moveDown: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canMoveUp && canMoveDown {
            content
                .accessibilityAction(
                    named: Text(L10n.text("popover.moveUp", language: language)),
                    moveUp
                )
                .accessibilityAction(
                    named: Text(L10n.text("popover.moveDown", language: language)),
                    moveDown
                )
        } else if canMoveUp {
            content.accessibilityAction(
                named: Text(L10n.text("popover.moveUp", language: language)),
                moveUp
            )
        } else if canMoveDown {
            content.accessibilityAction(
                named: Text(L10n.text("popover.moveDown", language: language)),
                moveDown
            )
        } else {
            content
        }
    }
}
