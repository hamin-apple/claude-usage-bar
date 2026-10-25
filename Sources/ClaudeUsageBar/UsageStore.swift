import AppKit
import Combine
import Foundation

enum UsageStatus: Equatable {
    case loading
    case ok
    case expired
    case loginRequired
    case rateLimited
    case offline(httpStatus: Int?)

    var showsErrorIcon: Bool { self == .expired || self == .loginRequired }
    var isWarning: Bool {
        switch self {
        case .rateLimited, .offline: return true
        default: return false
        }
    }

    // A non-default folder's token is refreshed only by running claude with that folder.
    func notice(configFolder: AccountSource?) -> String? {
        guard let folder = configFolder, !folder.isDefault else { return notice }
        switch self {
        case .expired: return "Token expired. Run \"CLAUDE_CONFIG_DIR=~/\(folder.name) claude\" once in Terminal to refresh it."
        case .loginRequired: return "Sign in with \"CLAUDE_CONFIG_DIR=~/\(folder.name) claude\"."
        default: return notice
        }
    }

    var notice: String? {
        switch self {
        case .loading, .ok: return nil
        case .expired: return "Token expired. Run \"claude\" once in Terminal to refresh it."
        case .loginRequired: return "Sign in to Claude Code with your subscription account."
        case .rateLimited: return "Rate limited. Will retry automatically shortly."
        case .offline(let code):
            return code.map { "Can't connect (HTTP \($0))" } ?? "Can't connect"
        }
    }
}

@MainActor
final class AccountUsage: ObservableObject, Identifiable {
    private static let minManualInterval: TimeInterval = 10

    @Published private(set) var status: UsageStatus = .loading
    @Published private(set) var rows: [LimitRow] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var plan: String?

    private(set) var account: Account
    private let options: LaunchOptions
    private let startDelay: TimeInterval
    private let mockIndex: Int
    private var policy = BackoffPolicy()
    private var pollTask: Task<Void, Never>?
    private var nextPollAt = Date.distantPast
    private var backoffUntil: Date?
    private var isPolling = false
    private var lastCallAt: Date?
    private var wakeObserver: NSObjectProtocol?

    nonisolated let id: String

    init(account: Account, options: LaunchOptions, startDelay: TimeInterval = 0, mockIndex: Int = 0) {
        self.id = account.id
        self.account = account
        self.options = options
        self.startDelay = startDelay
        self.mockIndex = mockIndex
        nextPollAt = Date().addingTimeInterval(startDelay)
    }

    var sessionRow: LimitRow? { rows.first { $0.id == "five_hour" } }

    var remaining: Int? {
        sessionRow?.remaining(at: Date()).map { Int($0.rounded()) }
    }

    var isBackingOff: Bool { status == .rateLimited }

    func start() {
        if options.isMock {
            applyMock()
            return
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
        runLoop()
    }

    // Same login, different directories (one was added or removed): keep the backoff and the data.
    func update(_ account: Account) {
        self.account = account
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    // Manual refresh is ignored during a 429 backoff: retrying would only extend the limit.
    func refresh() {
        if options.isMock {
            if !isBackingOff { applyMock() }
            return
        }
        guard !isBackingOff, !isPolling else { return }
        if let last = lastCallAt, Date().timeIntervalSince(last) < Self.minManualInterval { return }
        nextPollAt = Date().addingTimeInterval(startDelay)
        runLoop()
    }

    // Task.sleep does not advance while the Mac sleeps, so on wake the loop is rebuilt from the absolute deadline.
    private func handleWake() {
        guard !isPolling else { return }
        runLoop()
    }

    private func runLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = self.nextPollAt.timeIntervalSinceNow
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        return
                    }
                }
                if Task.isCancelled { return }
                await self.poll()
            }
        }
    }

    private func poll() async {
        isPolling = true
        defer { isPolling = false }

        if let until = backoffUntil, Date() < until {
            nextPollAt = until
            return
        }
        switch await CredentialsReader.read(account) {
        case .notFound:
            status = .loginRequired
            scheduleNormalPoll()
        case .expired:
            status = .expired
            scheduleNormalPoll()
        case .valid(let credentials):
            plan = credentials.subscriptionType
            let userAgent = await ClaudeVersion.userAgent()
            lastCallAt = Date()
            let outcome = await UsageAPI.fetch(
                token: credentials.accessToken, userAgent: userAgent, url: options.apiURL ?? UsageAPI.endpoint)
            apply(outcome)
        }
    }

    private func apply(_ outcome: FetchOutcome) {
        switch outcome {
        case .success(let newRows):
            rows = newRows
            lastUpdated = Date()
            status = .ok
            policy.succeeded()
            backoffUntil = nil
            scheduleNormalPoll()
        case .unparseable:
            status = .offline(httpStatus: 200)
            scheduleNormalPoll()
        case .rateLimited(let retryAfter):
            let until = Date().addingTimeInterval(policy.rateLimited(retryAfter: retryAfter))
            backoffUntil = until
            nextPollAt = until
            status = .rateLimited
        case .http(let code):
            status = .offline(httpStatus: code)
            scheduleNormalPoll()
        case .network:
            status = .offline(httpStatus: nil)
            scheduleNormalPoll()
        }
    }

    private func scheduleNormalPoll() {
        nextPollAt = Date().addingTimeInterval(BackoffPolicy.normalInterval)
    }

    // Mock accounts after the first get fixed values; --mock-error applies to the first account only.
    private func applyMock() {
        let now = Date()
        plan = mockIndex == 1 ? "pro" : "max"
        let sessionUsed: Double? = mockIndex == 0 ? options.mockUtilization : [62, 8, 95][(mockIndex - 1) % 3]
        if let used = sessionUsed {
            rows = [
                LimitRow(id: "five_hour", title: "Session (5h)", utilization: used,
                         resetsAt: now.addingTimeInterval(2 * 3600 + 44 * 60)),
                LimitRow(id: "seven_day", title: "Weekly (7d)", utilization: 41,
                         resetsAt: now.addingTimeInterval(4 * 86400 + 9 * 3600)),
                LimitRow(id: "seven_day_sonnet", title: "Weekly · Sonnet", utilization: 12,
                         resetsAt: now.addingTimeInterval(4 * 86400 + 9 * 3600)),
            ]
            lastUpdated = now
        }
        switch mockIndex == 0 ? options.mockError : nil {
        case .expired: status = .expired
        case .login: status = .loginRequired
        case .ratelimit: status = .rateLimited
        case .offline: status = .offline(httpStatus: nil)
        case nil: status = .ok
        }
    }
}

// All accounts, plus which one the menu bar shows.
@MainActor
final class UsageStore: ObservableObject {
    static let lowestChoice = "lowest"
    private static let choiceKey = "menuBarAccount"
    private static let pollSpacing: TimeInterval = 5
    private static let mockLabels = ["you@example.com", "work@example.com", "team@example.com", "lab@example.com"]

    @Published private(set) var accounts: [AccountUsage] = []
    @Published var menuBarChoice: String {
        didSet { UserDefaults.standard.set(menuBarChoice, forKey: Self.choiceKey) }
    }

    private let options: LaunchOptions
    private var forwarders: [String: AnyCancellable] = [:]

    init(options: LaunchOptions) {
        self.options = options
        menuBarChoice = UserDefaults.standard.string(forKey: Self.choiceKey) ?? Self.lowestChoice
    }

    var isMultiAccount: Bool { accounts.count > 1 }

    // The pinned account if it still exists, otherwise the one with the least session left.
    // The choice is stored as a config folder name (e.g. ".claude-work"), never an account id or email.
    var menuBarAccount: AccountUsage? {
        if let pinned = accounts.first(where: { $0.account.sources.contains { $0.name == menuBarChoice } }) { return pinned }
        return accounts
            .filter { $0.remaining != nil }
            .min { ($0.remaining ?? 0) < ($1.remaining ?? 0) } ?? accounts.first
    }

    // A stored folder that no longer exists shows as "Lowest session", which is what the menu bar uses then.
    var pickerSelection: String {
        accounts.contains { $0.account.sources.contains { $0.name == menuBarChoice } } ? menuBarChoice : Self.lowestChoice
    }

    var allBackingOff: Bool { !accounts.isEmpty && accounts.allSatisfy(\.isBackingOff) }

    func start() {
        // Mock mode never discovers accounts: discovery reads the keychain.
        if options.isMock {
            let count = options.mockAccounts
            set((0..<count).map { index in
                let label = count == 1 ? ".claude" : Self.mockLabels[index % Self.mockLabels.count]
                let source = AccountSource(configDirectory: URL(fileURLWithPath: "/mock/.claude-\(index)"), isDefault: index == 0)
                return Account(id: "mock-\(index)", label: label, sources: [source])
            })
            return
        }
        set(AccountDiscovery.discover())
    }

    // Re-discovers accounts (a new login may have appeared), then refreshes each one not backing off.
    func refresh() {
        if !options.isMock { set(AccountDiscovery.discover()) }
        accounts.forEach { $0.refresh() }
    }

    private func set(_ discovered: [Account]) {
        let existing = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var next: [AccountUsage] = []
        for (index, account) in discovered.enumerated() {
            if let kept = existing[account.id] {
                kept.update(account)
                next.append(kept)
                continue
            }
            // Requests are spaced out so several accounts never hit the endpoint at the same moment.
            let usage = AccountUsage(account: account, options: options,
                                     startDelay: Double(index) * Self.pollSpacing, mockIndex: index)
            forwarders[account.id] = usage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            usage.start()
            next.append(usage)
        }
        for gone in accounts where !next.contains(where: { $0 === gone }) {
            gone.stop()
            forwarders[gone.id] = nil
        }
        accounts = next
    }
}
