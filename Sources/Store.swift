// Polling and state. The menu bar label and the panel both observe this.

import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var usage: Usage?
    @Published private(set) var plan: String?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var problem: String?
    @Published private(set) var refreshing = false
    /// Bumped each time the panel opens, so the rings and bars animate in again.
    @Published private(set) var openCount = 0

    func panelOpened() { openCount += 1 }

    private var token: String?
    private var timer: Timer?
    private let normalInterval: TimeInterval = 180
    private let backoffInterval: TimeInterval = 600

    func start() {
        if Demo.enabled {
            usage = Demo.usage
            plan = "Max 20x"
            lastSuccess = Date().addingTimeInterval(-70)
            return
        }
        refresh()
    }

    /// Refresh if the numbers are over a minute old (panel opened, Mac woke).
    func refreshIfStale() {
        guard let last = lastSuccess else { return refresh() }
        if -last.timeIntervalSinceNow > 60 { refresh() }
    }

    func refresh() {
        guard !refreshing, !Demo.enabled else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            if token == nil { await loadCredentials() }
            guard let current = token else {
                return fail("Not signed in. Run claude once in Terminal.", next: normalInterval)
            }
            var result = await UsageAPI.fetch(token: current)
            if case .failure(.unauthorized) = result {
                // Claude Code refreshes its token and rewrites the Keychain item.
                await loadCredentials()
                if let fresh = token, fresh != current { result = await UsageAPI.fetch(token: fresh) }
            }
            switch result {
            case .success(let u):
                usage = u
                lastSuccess = Date()
                problem = nil
                schedule(after: normalInterval)
            case .failure(.unauthorized):
                token = nil
                fail("Sign-in expired. Open Claude Code to renew it.", next: normalInterval)
            case .failure(.rateLimited):
                fail("Anthropic is rate limiting. Showing the last numbers.", next: backoffInterval)
            case .failure(.http(let code)):
                fail("Anthropic returned an error (\(code)).", next: normalInterval)
            case .failure(.network):
                fail("Can't reach Anthropic. Check the connection.", next: normalInterval)
            case .failure(.badPayload):
                fail("Anthropic sent something unexpected.", next: normalInterval)
            }
        }
    }

    private func loadCredentials() async {
        // The Keychain read can block on a consent prompt; keep it off the main thread.
        let creds = await Task.detached { TokenStore.load() }.value
        token = creds?.token
        if let p = creds?.plan { plan = p }
    }

    private func fail(_ message: String, next: TimeInterval) {
        problem = message
        schedule(after: next)
    }

    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}
