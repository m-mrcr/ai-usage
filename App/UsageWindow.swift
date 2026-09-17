import AppKit
import SwiftUI

/// The window opened from the Dock icon.
/// With just the menu bar residency, clicking the Dock icon has nothing to show, so the same content is also shown in a standalone window.
@MainActor
final class UsageWindowController {
    private var window: NSWindow?

    func show(model: UsageModel) {
        if window == nil {
            let hosting = NSHostingController(
                rootView: UsagePopoverView(model: model, showsQuit: false).frame(width: 340)
            )
            let created = NSWindow(contentViewController: hosting)
            // Keep the title for the "Window" menu and assistive technologies,
            // but don't draw it in the title bar — the heading name lives in the content instead.
            created.title = "AI Usage"
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.setContentSize(NSSize(width: 340, height: 560))
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }
}

/// The settings window. Made standalone since its size doesn't fit inside the menu bar popover.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(model: UsageModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let created = NSWindow(contentViewController: hosting)
            created.title = "AI Usage Settings"
            created.titlebarAppearsTransparent = true
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        window?.title = L10n.text("settings.title", language: model.language)
        window?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func updateLanguage(_ language: AppLanguage) {
        window?.title = L10n.text("settings.title", language: language)
    }
}

/// A standalone window explaining what Stale means and how to fix it per agent.
@MainActor
final class HelpWindowController {
    private var window: NSWindow?

    func show(model: UsageModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: StaleHelpView(model: model))
            let created = NSWindow(contentViewController: hosting)
            created.titlebarAppearsTransparent = true
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.setContentSize(NSSize(width: 500, height: 560))
            created.center()
            window = created
        }
        updateLanguage(model.language)
        window?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func updateLanguage(_ language: AppLanguage) {
        window?.title = L10n.text("help.windowTitle", language: language)
    }
}

/// A delegate that exists only to catch clicks on the Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A reopen request from the Dock. Overridden on the UsageModel side.
    @MainActor static var onReopen: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Self.onReopen?() }
        return true
    }
}
