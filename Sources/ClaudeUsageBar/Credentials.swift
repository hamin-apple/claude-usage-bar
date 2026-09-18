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
    static let keychainService = "Claude Code-credentials"
    static let expiryMargin: TimeInterval = 60

    // Always re-reads: Claude Code may have refreshed the token since the last call.
    static func read(now: Date = Date()) async -> TokenState {
        if let json = await keychainJSON(), let state = interpret(json, source: .keychain, now: now) {
            return state
        }
        if let json = fileJSON(), let state = interpret(json, source: .file, now: now) {
            return state
        }
        return .notFound
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
    private static func keychainJSON() async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
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

    private static func fileJSON() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }

    // --check-token: prints token state only, never the token itself.
    static func printStatus() async -> Int32 {
        switch await read() {
        case .valid(let c):
            let remaining = c.expiresAt.map { "\(Int($0.timeIntervalSinceNow))s" } ?? "unknown"
            print("state=valid source=\(c.source.rawValue) plan=\(c.subscriptionType ?? "unknown") expiresIn=\(remaining) tokenLength=\(c.accessToken.count)")
            return 0
        case .expired(let source, let expiredAt):
            let ago = expiredAt.map { "\(Int(-$0.timeIntervalSinceNow))s ago" } ?? "unknown"
            print("state=expired source=\(source.rawValue) expired=\(ago)")
            return 0
        case .notFound:
            print("state=notfound")
            return 0
        }
    }
}
