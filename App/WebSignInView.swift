import SwiftUI
import WebKit

/// Has the user sign in to a target site inside the app, and extracts only what's needed
/// from the cookies the WebView received.
///
/// An entry point so the user never has to open the browser's developer tools. The data store
/// is disposable (`.nonPersistent()`), so the login session never lands on disk —
/// only the extracted value goes into Keychain.
struct WebSignInView: View {
    struct Target {
        let loginURL: URL
        let cookieDomain: String
        /// Builds the string to save from the collected cookies. nil if there isn't enough.
        let extract: ([HTTPCookie]) -> String?
        /// Confirms sign-in succeeded via a real response.
        /// More reliable than hardcoding a cookie name for a target whose cookie names aren't public.
        /// If nil, success is assumed as soon as extract returns a value.
        let verify: ((String) async -> Bool)?
        let save: (String) -> Bool
    }

    let target: Target
    let language: AppLanguage
    let titleKey: String
    let onCaptured: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text(titleKey, language: language))
                    .font(.headline)
                Spacer()
                Button(L10n.text("signIn.cancel", language: language), action: onCancel)
                    .controlSize(.small)
            }
            .padding(12)

            Divider()

            SignInWebView(target: target, onCaptured: onCaptured)

            Divider()

            Text(L10n.text("signIn.detail", language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 660)
        .environment(\.locale, language.locale)
    }
}

private struct SignInWebView: NSViewRepresentable {
    let target: WebSignInView.Target
    let onCaptured: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(target: target, onCaptured: onCaptured)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A disposable store. Never leaves login state on disk.
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let store = configuration.websiteDataStore.httpCookieStore
        store.add(context.coordinator)
        context.coordinator.start(watching: store)
        webView.load(URLRequest(url: target.loginURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKHTTPCookieStoreObserver {
        private let target: WebSignInView.Target
        private let onCaptured: () -> Void
        private var store: WKHTTPCookieStore?
        private var poll: Timer?
        private var delivered = false
        private var checking = false

        init(target: WebSignInView.Target, onCaptured: @escaping () -> Void) {
            self.target = target
            self.onCaptured = onCaptured
        }

        /// Don't rely on change notifications alone. On macOS 26+, a `Set-Cookie` received by the
        /// network process can take a while to show up in the WebView's own store,
        /// so also poll at a fixed interval until it can be read.
        func start(watching store: WKHTTPCookieStore) {
            self.store = store
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.check() }
            }
            RunLoop.main.add(timer, forMode: .common)
            poll = timer
        }

        func stop() {
            poll?.invalidate()
            poll = nil
            if let store { store.remove(self) }
            store = nil
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in self.check() }
        }

        @MainActor
        private func finish(with value: String) {
            guard !delivered, target.save(value) else { return }
            delivered = true
            stop()
            onCaptured()
        }

        @MainActor
        private func check() {
            guard !delivered, !checking, let store else { return }
            let domain = target.cookieDomain
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.delivered else { return }
                let matching = cookies.filter { $0.domain.contains(domain) }
                guard !matching.isEmpty, let value = self.target.extract(matching) else { return }

                guard let verify = self.target.verify else {
                    self.finish(with: value)
                    return
                }
                // Stop first so the next tick doesn't run while verifying. Resume if it fails.
                self.checking = true
                Task { @MainActor in
                    let ok = await verify(value)
                    self.checking = false
                    if ok { self.finish(with: value) }
                }
            }
        }
    }
}
