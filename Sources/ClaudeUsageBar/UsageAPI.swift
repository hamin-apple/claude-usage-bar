import Foundation

struct LimitRow: Identifiable, Sendable {
    let id: String
    let title: String
    let utilization: Double?
    let resetsAt: Date?

    // A window whose reset time has passed is treated as unused until the next fetch.
    func remaining(at now: Date) -> Double? {
        guard let utilization else { return nil }
        let used = (resetsAt.map { $0 <= now } ?? false) ? 0 : utilization
        return min(100, max(0, 100 - used))
    }
}

enum FetchOutcome: Sendable {
    case success([LimitRow])
    case unparseable
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network
}

struct BackoffPolicy: Sendable {
    static let normalInterval: TimeInterval = 180
    static let initialBackoff: TimeInterval = 300
    static let maxBackoff: TimeInterval = 1800

    private(set) var current: TimeInterval = BackoffPolicy.initialBackoff

    // Waits the longer of Retry-After and the current backoff, then doubles it for the next consecutive 429.
    mutating func rateLimited(retryAfter: TimeInterval?) -> TimeInterval {
        let wait = max(retryAfter ?? 0, current)
        current = min(current * 2, Self.maxBackoff)
        return wait
    }

    mutating func succeeded() {
        current = Self.initialBackoff
    }
}

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func fetch(token: String, userAgent: String, url: URL = endpoint) async -> FetchOutcome {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .network }
            switch http.statusCode {
            case 200..<300:
                let rows = parse(data)
                return rows.isEmpty ? .unparseable : .success(rows)
            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                return .rateLimited(retryAfter: retryAfter)
            default:
                return .http(http.statusCode)
            }
        } catch {
            return .network
        }
    }

    // Unofficial endpoint: read only what is needed, tolerate anything missing or new.
    static func parse(_ data: Data) -> [LimitRow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let limits = (root["limits"] as? [[String: Any]]) ?? []
        func limit(kind: String) -> [String: Any]? { limits.first { ($0["kind"] as? String) == kind } }

        var rows: [LimitRow] = []
        if let row = row(id: "five_hour", title: "Session (5h)", window: root["five_hour"] as? [String: Any], fallback: limit(kind: "session")) {
            rows.append(row)
        }
        if let row = row(id: "seven_day", title: "Weekly (7d)", window: root["seven_day"] as? [String: Any], fallback: limit(kind: "weekly_all")) {
            rows.append(row)
        }
        let modelWindows: [(key: String, title: String)] = [
            ("seven_day_opus", "Weekly · Opus"),
            ("seven_day_sonnet", "Weekly · Sonnet"),
        ]
        var modelRows: [LimitRow] = []
        for (key, title) in modelWindows {
            if let window = root[key] as? [String: Any],
               let row = row(id: key, title: title, window: window, fallback: nil) {
                modelRows.append(row)
            }
        }
        if modelRows.isEmpty {
            for entry in limits {
                guard let kind = entry["kind"] as? String, kind != "session", kind != "weekly_all",
                      let row = row(id: "limit-\(kind)", title: "Weekly · \((entry["scope"] as? String) ?? kind)",
                                    window: nil, fallback: entry) else { continue }
                modelRows.append(row)
            }
        }
        return rows + modelRows
    }

    private static func row(id: String, title: String, window: [String: Any]?, fallback: [String: Any]?) -> LimitRow? {
        guard window != nil || fallback != nil else { return nil }
        let utilization = number(window?["utilization"]) ?? number(fallback?["percent"])
        let resetsAt = date(window?["resets_at"]) ?? date(fallback?["resets_at"])
        return LimitRow(id: id, title: title, utilization: utilization, resetsAt: resetsAt)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

@MainActor
enum ClaudeVersion {
    private static var cached: String?
    private static let fallback = "claude-code/2.0.0"

    static func userAgent() async -> String {
        if let cached { return cached }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            "\(home)/.claude/local/claude", "\(home)/.local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if let version = await runVersion(path) {
                cached = "claude-code/\(version)"
                return "claude-code/\(version)"
            }
        }
        return fallback
    }

    private nonisolated static func runVersion(_ path: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["--version"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                let text = String(decoding: data, as: UTF8.self)
                let version = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression).map { String(text[$0]) }
                continuation.resume(returning: version)
            }
        }
    }
}
