import AppIntents
import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    let language: AppLanguage
    /// Agents chosen via "Edit Widget". If empty, follows the main app's order.
    let selectedIDs: [String]
}

struct UsageProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(
            date: Date(), snapshot: .sample,
            language: LanguagePreference.load(), selectedIDs: []
        )
    }

    func snapshot(for configuration: SelectAgentsIntent,
                  in context: Context) async -> UsageEntry {
        return UsageEntry(
            date: Date(),
            // The gallery never needs personal usage values. Keep previews deterministic
            // and read the App Group only for a real widget snapshot.
            snapshot: context.isPreview ? .sample : current(),
            language: LanguagePreference.load(),
            selectedIDs: configuration.selectedIDs
        )
    }

    func timeline(for configuration: SelectAgentsIntent,
                  in context: Context) async -> Timeline<UsageEntry> {
        let entry = UsageEntry(
            date: Date(), snapshot: current(),
            language: LanguagePreference.load(),
            selectedIDs: configuration.selectedIDs
        )
        // This is a best-effort request. WidgetKit may delay it to preserve the
        // system update budget; the containing app also requests reloads on changes.
        return Timeline(entries: [entry],
                        policy: .after(Date().addingTimeInterval(10 * 60)))
    }

    /// The extension can't read ~/.codex inside its sandbox.
    /// It only reads the snapshot written out by the main app (the menu bar app).
    private func current() -> UsageSnapshot {
        SnapshotStore.load()
    }
}

@main
struct AIUsageWidgetBundle: WidgetBundle {
    var body: some Widget { AIUsageWidget() }
}

struct AIUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "AIUsageWidget",
            intent: SelectAgentsIntent.self,
            provider: UsageProvider()
        ) { entry in
            UsageWidgetView(
                snapshot: entry.snapshot,
                language: entry.language,
                selectedIDs: entry.selectedIDs
            )
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AI Usage")
        .description(LocalizedStringKey("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// The displayed number is consistently remaining allowance (gas-tank style), while the bar's
/// color intensity still tracks usage. A short window like the 5-hour one kicks in first during
/// a session, so it's given emphasis.
struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: UsageSnapshot
    let language: AppLanguage
    var selectedIDs: [String] = []

    /// The maximum number of rows that can be drawn. The limit that fits in the medium size.
    private static let maxRows = 4

    /// The selected order if there is one, otherwise the main app's order. Items with no windows are also used to explain the empty state.
    private var configuredAgents: [AgentUsage] {
        guard !selectedIDs.isEmpty else { return snapshot.agents }
        return selectedIDs.compactMap { id in snapshot.agents.first { $0.id == id } }
    }

    private var orderedAgents: [AgentUsage] {
        configuredAgents.filter { !$0.windows.isEmpty }
    }

    /// Packs from the top and cuts off at 4 rows. Counted by row, since one agent can have multiple windows.
    private var visibleGroups: [(agent: AgentUsage, windows: [UsageWindow])] {
        var groups: [(AgentUsage, [UsageWindow])] = []
        var rows = 0
        for agent in orderedAgents {
            guard rows < Self.maxRows else { break }
            // Since row count is capped, take plan windows before supplementary ones.
            let take = Array(agent.displayWindows.prefix(Self.maxRows - rows))
            guard !take.isEmpty else { continue }
            groups.append((agent, take))
            rows += take.count
        }
        return groups
    }

    /// The headline. If there's a selection, feature its first agent.
    private var headline: (agent: AgentUsage, window: UsageWindow)? {
        if !selectedIDs.isEmpty {
            guard let first = orderedAgents.first,
                  let window = first.headlineWindow
            else { return nil }
            return (agent: first, window: window)
        }
        return snapshot.headline
    }

    private var headlineSecondary: UsageWindow? {
        guard let headline else { return nil }
        return headline.agent.windows.first { $0.id != headline.window.id }
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
        .environment(\.locale, language.locale)
    }

    // MARK: - Small: feature the 5-hour window

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let headline = headline {
                HStack(spacing: 6) {
                    ServiceMark(agent: headline.agent, size: 18)
                    Text(headline.agent.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if headline.agent.displayStatus == .stale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .accessibilityLabel(
                                L10n.text("widget.stale.accessibility", language: language)
                            )
                    }
                    Spacer(minLength: 0)
                    WindowChip(window: headline.window, emphasized: true, language: language)
                }

                Spacer(minLength: 4)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(headline.window.remainingValueText)
                        .font(.system(size: 50, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .accessibilityLabel(
                            L10n.format(
                                "widget.remaining.accessibility.format",
                                language: language,
                                headline.window.remainingValueText
                            )
                        )
                }

                UsageBar(percent: headline.window.usedPercent, height: 8, language: language)
                    .padding(.top, 3)
                    .accessibilityHidden(true)

                if let resetDate = headline.window.resetsAt {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .accessibilityHidden(true)
                        Text(resetDate, style: .relative)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        L10n.format(
                            "popover.reset.accessibility.format",
                            language: language,
                            relativeText(resetDate)
                        )
                    )
                }

                Spacer(minLength: 0)

                // Show the same agent's longer window as a subtle addition
                if let secondary = headlineSecondary {
                    Divider().padding(.vertical, 4)
                    HStack(spacing: 5) {
                        Text(L10n.windowLabel(secondary, language: language))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        UsageBar(percent: secondary.usedPercent, height: 5, language: language)
                            .accessibilityHidden(true)
                        Text(secondary.remainingValueText)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .accessibilityLabel(
                                L10n.format(
                                    "widget.remaining.accessibility.format",
                                    language: language,
                                    secondary.remainingValueText
                                )
                            )
                    }
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Medium: group by agent

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            if visibleGroups.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleGroups, id: \.agent.id) { group in
                        AgentGroupRow(
                            agent: group.agent,
                            windows: group.windows,
                            language: language
                        )
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Large: full detail, one card per agent

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            if orderedAgents.isEmpty {
                emptyState
            } else {
                ForEach(orderedAgents.prefix(4)) { agent in
                    AgentDetailCard(
                        agent: agent,
                        windows: agent.displayWindows,
                        language: language
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(emptyMessage.title)
                .font(.caption.weight(.semibold))
            Text(emptyMessage.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyMessage: (title: String, detail: String) {
        if snapshot.updatedAt == .distantPast {
            return message("widget.empty.noSnapshot.title", "widget.empty.noSnapshot.detail")
        }
        if !selectedIDs.isEmpty && configuredAgents.isEmpty {
            return message(
                "widget.empty.selectedUnavailable.title",
                "widget.empty.selectedUnavailable.detail"
            )
        }
        if snapshot.agents.isEmpty {
            return message("widget.empty.noVisible.title", "widget.empty.noVisible.detail")
        }
        if configuredAgents.allSatisfy({ $0.displayStatus == .notInstalled }) {
            return message("widget.empty.noSupported.title", "widget.empty.noSupported.detail")
        }
        if let unavailable = configuredAgents.first(where: { $0.windows.isEmpty }) {
            return (
                L10n.text("widget.empty.unavailable.title", language: language),
                L10n.agentNote(unavailable.note, language: language)
                    ?? L10n.text("widget.empty.unavailable.detail", language: language)
            )
        }
        return message("widget.empty.noData.title", "widget.empty.noData.detail")
    }

    private func message(_ titleKey: String, _ detailKey: String) -> (String, String) {
        (
            L10n.text(titleKey, language: language),
            L10n.text(detailKey, language: language)
        )
    }

    private func relativeText(_ date: Date) -> String {
        date.formatted(
            Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .abbreviated)
                .locale(language.locale)
        )
    }

}

/// Groups a single agent into one card.
/// The left color stripe and faint background make it clear at a glance where one app's rows begin and end.
struct AgentGroupRow: View {
    let agent: AgentUsage
    /// The windows after being narrowed down by the row cap. The caller passes them sorted shortest-first.
    let windows: [UsageWindow]
    let language: AppLanguage

    /// The name column's width. Used to wrap the EXTRAS row at the same position.
    private static let leadingColumnWidth: CGFloat = 3 + 8 + 22 + 6 + 84 + 8

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                // The left color stripe. Stretched the full height of the card to show which agent it belongs to.
                Capsule()
                    .fill(agent.accent)
                    .frame(width: 3)

                ServiceMark(agent: agent, size: 22)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(agent.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if agent.displayStatus == .stale {
                            Image(systemName: "clock.badge.exclamationmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.orange)
                                .accessibilityLabel(
                                    L10n.text("widget.stale.accessibility", language: language)
                                )
                        }
                    }
                    if let plan = agent.plan {
                        Text(plan)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(width: 84, alignment: .leading)

                VStack(spacing: 4) {
                    ForEach(windows) { window in
                        HStack(spacing: 6) {
                            WindowChip(
                                window: window,
                                emphasized: window.isShortWindow,
                                language: language
                            )
                            UsageBar(percent: window.usedPercent, height: 7, language: language)
                            Text(window.remainingValueText)
                                .font(.system(size: 13, weight: .bold).monospacedDigit())
                                .foregroundStyle(.primary)
                                .frame(width: 38, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            L10n.format(
                                "widget.agentRemaining.accessibility.format",
                                language: language,
                                L10n.windowLabel(window, language: language),
                                window.remainingValueText
                            )
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if let extras = agent.extrasText(language: language) {
                Text(extras)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.leading, Self.leadingColumnWidth)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(agent.accent.opacity(0.10))
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The large widget's full-detail card: logo, name, every window with its reset time, and extras.
struct AgentDetailCard: View {
    let agent: AgentUsage
    let windows: [UsageWindow]
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Capsule().fill(agent.accent).frame(width: 3, height: 26)
                ServiceMark(agent: agent, size: 26)
                HStack(spacing: 5) {
                    Text(agent.name)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                    if let plan = agent.plan {
                        Text(plan)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if agent.displayStatus == .stale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                            .accessibilityLabel(
                                L10n.text("widget.stale.accessibility", language: language)
                            )
                    }
                }
                Spacer(minLength: 0)
            }

            ForEach(windows) { window in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        WindowChip(
                            window: window,
                            emphasized: window.isShortWindow,
                            language: language
                        )
                        UsageBar(percent: window.usedPercent, height: 9, language: language)
                        Text(window.remainingValueText)
                            .font(.system(size: 16, weight: .bold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    if let resetDate = window.resetsAt {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text(resetDate, style: .relative)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.leading, 38)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    L10n.format(
                        "widget.agentRemaining.accessibility.format",
                        language: language,
                        L10n.windowLabel(window, language: language),
                        window.remainingValueText
                    )
                )
            }

            if let extras = agent.extrasText(language: language) {
                Text(extras)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(agent.accent.opacity(0.10))
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension UsageSnapshot {
    /// For the gallery preview.
    static let sample = UsageSnapshot(updatedAt: Date(), agents: [
        AgentUsage(id: "claude-code", name: "Claude Code", plan: "Max",
                   windows: [
                       UsageWindow(id: "five_hour", label: "5h", usedPercent: 27,
                                   resetsAt: Date().addingTimeInterval(9_000),
                                   windowSeconds: 5 * 3_600),
                       UsageWindow(id: "seven_day", label: "7d", usedPercent: 30,
                                   resetsAt: Date().addingTimeInterval(320_000),
                                   windowSeconds: 7 * 86_400),
                   ],
                   observedAt: Date(), source: "usage API", status: .ok, note: nil,
                   extraUsage: ExtraUsage(used: 5.16, limit: 20)),
        AgentUsage(id: "codex", name: "Codex", plan: "Pro",
                   windows: [
                       UsageWindow(id: "w10080", label: "7d", usedPercent: 88,
                                   resetsAt: Date().addingTimeInterval(560_000),
                                   windowSeconds: 7 * 86_400),
                   ],
                   observedAt: Date(), source: "session log", status: .ok, note: nil,
                   resetCredits: ResetCredits(available: 2)),
        AgentUsage(id: "grok", name: "Grok", plan: "X Premium+",
                   windows: [
                       UsageWindow(id: "grok_period", label: "7d", usedPercent: 0,
                                   resetsAt: Date().addingTimeInterval(120_000),
                                   windowSeconds: 7 * 86_400),
                   ],
                   observedAt: Date(), source: "billing log", status: .ok, note: nil),
    ])
}
