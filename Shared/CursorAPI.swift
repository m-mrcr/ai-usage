import Foundation

/// Requests to cursor.com's dashboard API. Shared by Grok Bot and Cursor.
///
/// Not a published API. Built on the assumption it can break on a provider-side change, so a
/// failure is simply treated as "unavailable", without leaving a stale value behind.
enum CursorAPI {
    enum Outcome: Sendable {
        case body(Data)
        case unauthorized
        case unavailable
    }

    private static let base = "https://cursor.com/api/dashboard/"
    private static let maximumResponseBytes = 256 * 1_024
    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func post(_ path: String, cookie: String) async -> Outcome {
        guard let url = URL(string: base + path) else { return .unavailable }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Automatically attached to requests originating from the page; the CSRF check looks at this.
        // Without it, even a request with valid auth gets a 403.
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        if let token = csrfToken(in: cookie) {
            request.setValue(token, forHTTPHeaderField: "x-csrf-token")
        }
        // The cookie is built by hand and passed explicitly. Leaving it to URLSession's management would let it be swapped out.
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            switch http.statusCode {
            case 200:
                guard data.count <= maximumResponseBytes else { return .unavailable }
                return .body(data)
            case 401, 403:
                return .unauthorized
            default:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    /// For double-submit-style CSRF protection. Carries the same value as the cookie in a header too.
    static func csrfToken(in cookie: String) -> String? {
        for pair in cookie.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("csrf-token=") else { continue }
            let value = String(trimmed.dropFirst("csrf-token=".count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Comes in as a millisecond epoch, but as a string. A digit mix-up would land tens of thousands of years in the future,
    /// so only values within a plausible range are allowed through.
    static func parseEpochMilliseconds(_ text: String?) -> Date? {
        guard let text, let milliseconds = Double(text), milliseconds.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: milliseconds / 1_000)
        let distance = date.timeIntervalSinceNow
        guard distance.isFinite, distance >= -10 * 365 * 86_400, distance <= 10 * 365 * 86_400
        else { return nil }
        return date
    }
}
