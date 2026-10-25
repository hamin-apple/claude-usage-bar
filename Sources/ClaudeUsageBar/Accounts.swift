import CryptoKit
import Foundation

// One Claude Code config directory: `~/.claude` (the default) or any `~/.claude*` directory used
// through CLAUDE_CONFIG_DIR. Each keeps its own keychain item and its own `.claude.json`.
struct AccountSource: Sendable, Equatable {
    let configDirectory: URL
    let isDefault: Bool

    static let keychainService = "Claude Code-credentials"

    var name: String { configDirectory.lastPathComponent }

    // Claude Code suffixes the item with the first 8 hex digits of SHA-256 of the config path;
    // the default directory uses the plain name.
    var keychainServices: [String] {
        let suffixed = "\(Self.keychainService)-\(Self.pathHash(configDirectory.path))"
        return isDefault ? [Self.keychainService, suffixed] : [suffixed]
    }

    // The default config keeps `.claude.json` in the home directory, not inside `~/.claude`.
    var metadataFile: URL {
        isDefault
            ? configDirectory.deletingLastPathComponent().appendingPathComponent(".claude.json")
            : configDirectory.appendingPathComponent(".claude.json")
    }

    var credentialsFile: URL { configDirectory.appendingPathComponent(".credentials.json") }

    static func pathHash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

// Which login a config directory holds, from `oauthAccount` in its `.claude.json`. Not secret.
struct AccountIdentity: Sendable, Equatable {
    let accountUUID: String
    let organizationUUID: String?
    let email: String?

    static func parse(_ data: Data) -> AccountIdentity? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any],
              let account = oauth["accountUuid"] as? String, !account.isEmpty else { return nil }
        return AccountIdentity(accountUUID: account,
                               organizationUUID: oauth["organizationUuid"] as? String,
                               email: (oauth["emailAddress"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

// Directories logged in to the same account and organization share one rate limit,
// so they become one account and are polled once.
struct Account: Sendable, Identifiable, Equatable {
    let id: String
    let label: String
    let sources: [AccountSource]
}

enum AccountDiscovery {
    static func sources(home: URL, configDirEnv: String?, fileManager: FileManager = .default) -> [AccountSource] {
        var directories: [URL] = []
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        for name in names.sorted() where name == ".claude" || name.hasPrefix(".claude-") {
            var isDirectory: ObjCBool = false
            let url = home.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                directories.append(url)
            }
        }
        if let env = configDirEnv, !env.isEmpty {
            let url = URL(fileURLWithPath: (env as NSString).expandingTildeInPath).standardizedFileURL
            if !directories.contains(where: { $0.path == url.path }) { directories.append(url) }
        }
        let defaultPath = home.appendingPathComponent(".claude").path
        return directories
            .map { AccountSource(configDirectory: $0, isDefault: $0.path == defaultPath) }
            .sorted { ($0.isDefault ? 0 : 1, $0.name) < ($1.isDefault ? 0 : 1, $1.name) }
    }

    // A directory whose `.claude.json` names no account was never logged in and is skipped.
    // With no account at all, the default directory alone is returned so the panel shows "Sign in".
    static func group(_ sources: [AccountSource], home: URL, identity: (AccountSource) -> AccountIdentity?) -> [Account] {
        var order: [String] = []
        var members: [String: [AccountSource]] = [:]
        var labels: [String: String] = [:]
        for source in sources {
            guard let found = identity(source) else { continue }
            let key = "\(found.accountUUID)|\(found.organizationUUID ?? "")"
            if members[key] == nil {
                order.append(key)
                labels[key] = found.email ?? source.name
            }
            members[key, default: []].append(source)
        }
        if order.isEmpty {
            let source = AccountSource(configDirectory: home.appendingPathComponent(".claude"), isDefault: true)
            return [Account(id: "default", label: source.name, sources: [source])]
        }
        return order.map { Account(id: $0, label: labels[$0] ?? $0, sources: members[$0] ?? []) }
    }

    static func discover() -> [Account] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let found = sources(home: home, configDirEnv: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"])
        return group(found, home: home) { source in
            (try? Data(contentsOf: source.metadataFile)).flatMap(AccountIdentity.parse)
        }
    }
}
