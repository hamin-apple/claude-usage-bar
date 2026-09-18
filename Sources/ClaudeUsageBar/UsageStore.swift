import AppKit
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

    var notice: String? {
        switch self {
        case .loading, .ok: return nil
        case .expired: return "터미널에서 `claude`를 한 번 실행하면 복구됩니다"
        case .loginRequired: return "Claude Code에 구독 계정으로 로그인하세요"
        case .rateLimited: return "요청 제한에 걸렸습니다. 잠시 후 자동으로 다시 시도합니다"
        case .offline(let code):
            return code.map { "연결할 수 없습니다 (HTTP \($0))" } ?? "연결할 수 없습니다"
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    private static let minManualInterval: TimeInterval = 10

    @Published private(set) var status: UsageStatus = .loading
    @Published private(set) var rows: [LimitRow] = []
    @Published private(set) var lastUpdated: Date?

    private let options: LaunchOptions
    private var policy = BackoffPolicy()
    private var pollTask: Task<Void, Never>?
    private var nextPollAt = Date.distantPast
    private var backoffUntil: Date?
    private var isPolling = false
    private var lastCallAt: Date?
    private var wakeObserver: NSObjectProtocol?

    init(options: LaunchOptions) {
        self.options = options
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

    // Manual refresh is ignored during a 429 backoff: retrying would only extend the limit.
    func refresh() {
        if options.isMock {
            if !isBackingOff { applyMock() }
            return
        }
        guard !isBackingOff, !isPolling else { return }
        if let last = lastCallAt, Date().timeIntervalSince(last) < Self.minManualInterval { return }
        nextPollAt = .distantPast
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
        switch await CredentialsReader.read() {
        case .notFound:
            status = .loginRequired
            scheduleNormalPoll()
        case .expired:
            status = .expired
            scheduleNormalPoll()
        case .valid(let credentials):
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

    private func applyMock() {
        let now = Date()
        if let used = options.mockUtilization {
            rows = [
                LimitRow(id: "five_hour", title: "세션 (5시간)", utilization: used,
                         resetsAt: now.addingTimeInterval(2 * 3600 + 44 * 60)),
                LimitRow(id: "seven_day", title: "주간 (7일)", utilization: 41,
                         resetsAt: now.addingTimeInterval(4 * 86400 + 9 * 3600)),
                LimitRow(id: "seven_day_sonnet", title: "주간 · Sonnet", utilization: 12,
                         resetsAt: now.addingTimeInterval(4 * 86400 + 9 * 3600)),
            ]
            lastUpdated = now
        }
        switch options.mockError {
        case .expired: status = .expired
        case .login: status = .loginRequired
        case .ratelimit: status = .rateLimited
        case .offline: status = .offline(httpStatus: nil)
        case nil: status = .ok
        }
    }
}
