import Foundation

struct Credentials: Sendable {
    enum Source: String, Sendable {
        case keychain, file
    }

    let accessToken: String
    let expiresAt: Date?
    let source: Source
    let subscriptionType: String?
}

enum TokenState: Sendable {
    case valid(Credentials)
    case expired(Credentials.Source, expiredAt: Date?)
    case notFound
}

enum CredentialsReader {
    static let expiryMargin: TimeInterval = 60

    // Always re-reads: Claude Code may have refreshed the token since the last call.
    static func read(_ source: AccountSource, now: Date = Date()) async -> TokenState {
        for service in source.keychainServices {
            if let json = await keychainJSON(service: service), let state = interpret(json, source: .keychain, now: now) {
                return state
            }
        }
        if let json = try? Data(contentsOf: source.credentialsFile), let state = interpret(json, source: .file, now: now) {
            return state
        }
        return .notFound
    }

    // Directories of one account share its limit: use the valid token that expires last.
    static func read(_ account: Account, now: Date = Date()) async -> TokenState {
        var states: [TokenState] = []
        for source in account.sources {
            states.append(await read(source, now: now))
        }
        return best(states)
    }

    static func best(_ states: [TokenState]) -> TokenState {
        var valid: [Credentials] = []
        var expired: TokenState?
        for state in states {
            switch state {
            case .valid(let credentials): valid.append(credentials)
            case .expired: expired = expired ?? state
            case .notFound: break
            }
        }
        if let newest = valid.max(by: { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }) {
            return .valid(newest)
        }
        return expired ?? .notFound
    }

    static func interpret(_ data: Data, source: Credentials.Source, now: Date) -> TokenState? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let plan = (oauth["subscriptionType"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let credentials = Credentials(accessToken: token, expiresAt: expiresAt, source: source, subscriptionType: plan)
        if let expiresAt, expiresAt < now.addingTimeInterval(expiryMargin) {
            return .expired(source, expiredAt: expiresAt)
        }
        return .valid(credentials)
    }

    // Goes through /usr/bin/security so the keychain "Always Allow" stays bound to a stable caller.
    private static func keychainJSON(service: String) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["find-generic-password", "-s", service, "-w"]
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
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: trimmed.isEmpty ? nil : Data(trimmed.utf8))
            }
        }
    }

    // --check-token: prints token state only, never the token itself. One line per config directory,
    // labeled by directory name; directories with the same `account=` number share one limit.
    static func printStatus() async -> Int32 {
        for (index, account) in AccountDiscovery.discover().enumerated() {
            for source in account.sources {
                let prefix = "account=\(index + 1) config=\(source.name)"
                switch await read(source) {
                case .valid(let c):
                    let remaining = c.expiresAt.map { "\(Int($0.timeIntervalSinceNow))s" } ?? "unknown"
                    print("\(prefix) state=valid source=\(c.source.rawValue) plan=\(c.subscriptionType ?? "unknown") expiresIn=\(remaining) tokenLength=\(c.accessToken.count)")
                case .expired(let source, let expiredAt):
                    let ago = expiredAt.map { "\(Int(-$0.timeIntervalSinceNow))s ago" } ?? "unknown"
                    print("\(prefix) state=expired source=\(source.rawValue) expired=\(ago)")
                case .notFound:
                    print("\(prefix) state=notfound")
                }
            }
        }
        return 0
    }
}
