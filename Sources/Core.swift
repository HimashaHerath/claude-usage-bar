// Usage model, token lookup and the API call. No UI here.
//
// The token Claude Code already stores (Keychain item "Claude Code-credentials",
// then ~/.claude/.credentials.json) is held in memory only, sent only to
// api.anthropic.com/api/oauth/usage, and never logged or written anywhere.

import Foundation
import Security

struct UsageWindow: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let percent: Double          // 0-100
    let resetsAt: Date?
    let length: TimeInterval     // 5 h or 7 d

    /// How far through the window we are, 0-1. Nil without a reset time.
    var elapsed: Double? {
        guard let resetsAt else { return nil }
        let left = resetsAt.timeIntervalSinceNow
        return max(0, min(1, 1 - left / length))
    }

    /// Percent expected at reset if usage continues at the window's average rate.
    var projected: Double? {
        guard let e = elapsed, e > 0.25 else { return nil }   // usage is bursty; too early to extrapolate
        return percent / e
    }

    /// When the limit runs out at the current average rate, if before reset.
    var runsOutAt: Date? {
        guard let e = elapsed, e > 0.25, percent > 0, let resetsAt, (projected ?? 0) > 100 else { return nil }
        let start = resetsAt.addingTimeInterval(-length)
        let secondsSoFar = e * length
        return start.addingTimeInterval(secondsSoFar * 100 / percent)
    }
}

struct Usage: Equatable {
    var session: UsageWindow?
    var weekly: UsageWindow?
    var scoped: [UsageWindow]
    var extraUsageOn: Bool?
}

enum FetchError: Error, Equatable {
    case unauthorized, rateLimited, http(Int), network, badPayload
}

struct Credentials {
    let token: String
    let plan: String?            // "Max 20x", "Pro", ...
}

enum TokenStore {
    private static let services = ["Claude Code-credentials", "Claude Code"]

    static func load() -> Credentials? {
        for service in services {
            if let blob = keychainBlob(service: service), let creds = parse(blob) { return creds }
        }
        let path = NSHomeDirectory() + "/.claude/.credentials.json"
        if let data = FileManager.default.contents(atPath: path), let creds = parse(data) { return creds }
        return nil
    }

    private static func keychainBlob(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return Credentials(token: token, plan: planName(oauth))
    }

    private static func planName(_ oauth: [String: Any]) -> String? {
        guard let sub = (oauth["subscriptionType"] as? String)?.lowercased(), !sub.isEmpty else { return nil }
        let tier = (oauth["rateLimitTier"] as? String)?.lowercased() ?? ""
        if sub == "max" {
            if tier.contains("20x") { return "Max 20x" }
            if tier.contains("5x") { return "Max 5x" }
        }
        return sub.prefix(1).uppercased() + sub.dropFirst()
    }
}

enum UsageAPI {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let session: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 24 * 3600

    static func fetch(token: String) async -> Result<Usage, FetchError> {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-usage-bar", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: req) else {
            return .failure(.network)
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401, 403: return .failure(.unauthorized)
        case 429: return .failure(.rateLimited)
        case let code: return .failure(.http(code))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.badPayload)
        }
        return .success(parse(obj))
    }

    static func parse(_ obj: [String: Any]) -> Usage {
        func window(_ key: String, _ label: String, _ length: TimeInterval) -> UsageWindow? {
            guard let w = obj[key] as? [String: Any], let pct = number(w["utilization"]) else { return nil }
            return UsageWindow(label: label, percent: pct, resetsAt: date(w["resets_at"]), length: length)
        }
        // Per-model weekly caps: the legacy seven_day_<model> keys (null when the
        // plan has none) and the structured `limits` array's weekly_scoped entries.
        var scoped: [UsageWindow] = []
        for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
            if let w = window(key, name, week) { scoped.append(w) }
        }
        for lim in (obj["limits"] as? [[String: Any]]) ?? [] where lim["kind"] as? String == "weekly_scoped" {
            let model = ((lim["scope"] as? [String: Any])?["model"] as? [String: Any])
            guard let name = (model?["display_name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty, let pct = number(lim["percent"]),
                  !scoped.contains(where: { $0.label == name }) else { continue }
            scoped.append(UsageWindow(label: name, percent: pct, resetsAt: date(lim["resets_at"]), length: week))
        }
        return Usage(session: window("five_hour", "Session", session),
                     weekly: window("seven_day", "Weekly", week),
                     scoped: scoped,
                     extraUsageOn: (obj["extra_usage"] as? [String: Any])?["is_enabled"] as? Bool)
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, n.doubleValue.isFinite else { return nil }
        return max(0, min(n.doubleValue, 100))
    }

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// Fake data for screenshots and UI work: `-demo YES` never touches the Keychain.
enum Demo {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "demo") || snapshotting }
    /// `-snapshot <path>` renders the panel to a PNG for the README and exits.
    static var snapshotting: Bool { UserDefaults.standard.string(forKey: "snapshot") != nil }

    static var usage: Usage {
        let now = Date()
        return Usage(
            session: UsageWindow(label: "Session", percent: 82, resetsAt: now.addingTimeInterval(1.6 * 3600), length: UsageAPI.session),
            weekly: UsageWindow(label: "Weekly", percent: 38, resetsAt: now.addingTimeInterval(3.3 * 86400), length: UsageAPI.week),
            scoped: [
                UsageWindow(label: "Fable", percent: 93, resetsAt: now.addingTimeInterval(3.3 * 86400), length: UsageAPI.week),
                UsageWindow(label: "Opus", percent: 41, resetsAt: now.addingTimeInterval(3.3 * 86400), length: UsageAPI.week),
            ],
            extraUsageOn: false)
    }
}
