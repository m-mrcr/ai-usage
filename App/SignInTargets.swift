import Foundation

/// A target for in-app sign-in. Only the extracted value and where it's saved differ.
extension WebSignInView.Target {
    static var claude: WebSignInView.Target {
        WebSignInView.Target(
            loginURL: URL(string: "https://claude.ai/login")!,
            cookieDomain: "claude.ai",
            extract: { cookies in
                cookies.first { $0.name == "sessionKey" }
                    .map(\.value)
                    .flatMap { ClaudeSessionKey.isValid($0) ? $0 : nil }
            },
            verify: nil,
            save: ClaudeSessionKey.save
        )
    }

    /// The cursor.com account shared by Grok Bot and Cursor.
    /// The session cookie is HttpOnly and its name isn't publicly documented, so instead of hardcoding a name,
    /// success is judged by whether a real response comes back using the collected cookies.
    static var cursorAccount: WebSignInView.Target {
        WebSignInView.Target(
            loginURL: URL(string: "https://cursor.com/dashboard")!,
            cookieDomain: "cursor.com",
            extract: { cookies in
                let value = cookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                return CursorSession.isValid(value) ? value : nil
            },
            verify: { await GrokBotCollector.sessionWorks(cookie: $0) },
            save: CursorSession.save
        )
    }
}
