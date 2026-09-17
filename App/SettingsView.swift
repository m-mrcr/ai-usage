import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject private var updater: AppUpdater
    @State private var isSigningIn = false
    @State private var isSigningInCursor = false

    private var language: AppLanguage { model.language }

    /// Shown as elapsed time, e.g. "3 months ago". This maps more directly to
    /// judging whether the session is stale than making the user subtract dates themselves.
    private func relativeSavedAt(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = language.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    init(model: UsageModel) {
        self.model = model
        _updater = ObservedObject(wrappedValue: model.updater)
    }

    var body: some View {
        Form {
            Section(L10n.text("settings.language", language: language)) {
                Picker(
                    L10n.text("settings.language", language: language),
                    selection: Binding(
                        get: { model.language },
                        set: { model.setLanguage($0) }
                    )
                ) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(L10n.text("settings.language.detail", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.text("settings.agents", language: language)) {
                Text(L10n.text("settings.agents.detail", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.allAgents.isEmpty && model.isRefreshing {
                    ProgressView(L10n.text("settings.checkingAgents", language: language))
                        .controlSize(.small)
                } else if model.allAgents.isEmpty {
                    Text(L10n.text("settings.noAgents", language: language))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.allAgents) { agent in
                        AgentToggle(
                            agent: agent,
                            isVisible: !model.isHidden(agent.id),
                            language: language,
                            setVisible: { shouldShow in
                                if shouldShow == model.isHidden(agent.id) {
                                    model.toggleHidden(agent.id)
                                }
                            }
                        )
                        if agent.id == "codex", model.hasModelLimits {
                            VStack(alignment: .leading, spacing: 2) {
                                Toggle(
                                    L10n.text("settings.modelLimits", language: language),
                                    isOn: Binding(
                                        get: { model.showsModelLimits },
                                        set: { model.setShowsModelLimits($0) }
                                    )
                                )
                                .disabled(model.isHidden(agent.id))
                                Text(L10n.text("settings.modelLimits.detail", language: language))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 20)
                        }
                    }
                }
            }

            // Showing/hiding this based on state would make it undiscoverable and hard to find after switching environments. Always show it.
            Section(L10n.text("settings.claudeSession", language: language)) {
                Text(L10n.text("settings.claudeSession.detail", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.text("settings.claudeSession.warning", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let savedAt = model.claudeSessionSavedAt {
                    HStack {
                        Label(
                            L10n.format(
                                "settings.claudeSession.saved.format",
                                language: language,
                                relativeSavedAt(savedAt)
                            ),
                            systemImage: "checkmark.seal"
                        )
                        .font(.caption)
                        Spacer()
                        Button(L10n.text("settings.claudeSession.remove", language: language)) {
                            model.removeClaudeSessionKey()
                        }
                        .controlSize(.small)
                    }
                } else {
                    Button(L10n.text("settings.claudeSession.signIn", language: language)) {
                        isSigningIn = true
                    }
                    .controlSize(.small)
                }
            }

            if model.showsCursorSection {
                Section(L10n.text("settings.cursorAccount", language: language)) {
                    Text(L10n.text("settings.cursorAccount.detail", language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.text("settings.cursorAccount.warning", language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let savedAt = model.cursorSessionSavedAt {
                        HStack {
                            Label(
                                L10n.format(
                                    "settings.cursorAccount.saved.format",
                                    language: language,
                                    relativeSavedAt(savedAt)
                                ),
                                systemImage: "checkmark.seal"
                            )
                            .font(.caption)
                            Spacer()
                            Button(L10n.text("settings.cursorAccount.remove", language: language)) {
                                model.removeCursorSession()
                            }
                            .controlSize(.small)
                        }
                    } else {
                        Button(L10n.text("settings.cursorAccount.signIn", language: language)) {
                            isSigningInCursor = true
                        }
                        .controlSize(.small)
                    }
                }
            }

            if !UnsupportedAgents.detected.isEmpty {
                Section(L10n.text("settings.notSupported", language: language)) {
                    Text(
                        L10n.format(
                            "settings.unsupported.format",
                            language: language,
                            unsupportedAgentNames
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.text("settings.general", language: language)) {
                Toggle(
                    L10n.text("settings.showInDock", language: language),
                    isOn: $model.showsInDock
                )
                    .help(L10n.text("settings.showInDock.help", language: language))

                HStack {
                    Text(L10n.text("settings.cardOrder", language: language))
                    Spacer()
                    if model.agentOrder.isEmpty {
                        Text(L10n.text("settings.automatic", language: language))
                            .foregroundStyle(.secondary)
                    } else {
                        Button(
                            L10n.text("settings.restoreAutomatic", language: language)
                        ) { model.resetOrder() }
                    }
                }
                Text(L10n.text("settings.order.detail", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.text("settings.updates", language: language)) {
                HStack {
                    Text(L10n.text("settings.currentVersion", language: language))
                    Spacer()
                    Text(currentVersion)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    L10n.text("settings.checkUpdatesAutomatically", language: language),
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.setAutomaticallyChecksForUpdates($0) }
                    )
                )

                Button {
                    updater.checkForUpdates()
                } label: {
                    Label(
                        L10n.text("settings.checkForUpdates", language: language),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(!updater.canCheckForUpdates)

                Text(L10n.text("settings.updates.detail", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.text("settings.help", language: language)) {
                Button {
                    model.openHelp()
                } label: {
                    Label(
                        L10n.text("settings.staleHelp", language: language),
                        systemImage: "clock.badge.questionmark"
                    )
                }
                Text(L10n.text("settings.staleHelp.detail", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 650)
        .environment(\.locale, language.locale)
        .sheet(isPresented: $isSigningIn) {
            WebSignInView(
                target: .claude,
                language: language,
                titleKey: "signIn.title",
                onCaptured: {
                    isSigningIn = false
                    model.didCaptureClaudeSessionKey()
                },
                onCancel: { isSigningIn = false }
            )
        }
        .sheet(isPresented: $isSigningInCursor) {
            WebSignInView(
                target: .cursorAccount,
                language: language,
                titleKey: "signIn.cursorAccount.title",
                onCaptured: {
                    isSigningInCursor = false
                    model.didCaptureCursorSession()
                },
                onCancel: { isSigningInCursor = false }
            )
        }
    }

    private var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "—"
        return L10n.format(
            "settings.currentVersion.format",
            language: language,
            version,
            build
        )
    }

    private var unsupportedAgentNames: String {
        UnsupportedAgents.detected.joined(
            separator: language == .japanese ? "、" : " and "
        )
    }
}

@MainActor
private struct AgentToggle: View {
    let agent: AgentUsage
    let isVisible: Bool
    let language: AppLanguage
    let setVisible: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isVisible }, set: setVisible)) {
            HStack(spacing: 7) {
                Circle()
                    .fill(agent.accent)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel(agent.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(L10n.text("settings.visibility.hint", language: language))
    }

    private var accessibilityValue: String {
        let visibility = L10n.text(
            isVisible ? "settings.shown" : "settings.hidden",
            language: language
        )
        return [visibility, subtitle].joined(separator: language == .japanese ? "、" : ", ")
    }

    /// Shows the source and status in one line. Helps decide whether to hide it.
    private var subtitle: String {
        switch agent.displayStatus {
        case .notInstalled:
            return L10n.text("settings.notInstalled", language: language)
        case .unavailable:
            return L10n.agentNote(agent.note, language: language)
                ?? L10n.text("common.noData", language: language)
        case .stale:
            let windows = agent.windows
                .map { L10n.windowLabel($0, language: language) }
                .joined(separator: " · ")
            return L10n.format(
                "settings.staleStatus.format",
                language: language,
                L10n.source(agent.source, language: language),
                windows
            )
        case .ok:
            let windows = agent.windows
                .map { L10n.windowLabel($0, language: language) }
                .joined(separator: " · ")
            return L10n.format(
                "settings.sourceStatus.format",
                language: language,
                L10n.source(agent.source, language: language),
                windows
            )
        }
    }
}
