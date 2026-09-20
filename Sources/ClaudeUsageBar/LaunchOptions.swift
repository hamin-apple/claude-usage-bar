import Foundation

enum MockError: String {
    case expired, login, ratelimit, offline
}

struct LaunchOptions: Sendable {
    var mockUtilization: Double?
    var mockError: MockError?
    var renderIconsDirectory: String?
    var checkToken = false
    var apiURL: URL?

    var isMock: Bool { mockUtilization != nil || mockError != nil }

    static let usage = """
        Usage: ClaudeUsageBar [options]
          --mock [used%]                      show a fake session usage, no API call (default 30)
          --mock-error expired|login|ratelimit|offline
                                              show an error state (combine with --mock)
          --render-icons <dir>                render every icon to PNG and exit
          --check-token                       print token state (never the token) and exit
          --api-url <http://127.0.0.1:port/>  send requests to a local server (loopback only)
          --help                              show this help
        """

    // A misparsed flag must never fall through to real mode, which would call the API.
    static let current: LaunchOptions = {
        do {
            return try parse(Array(CommandLine.arguments.dropFirst()))
        } catch let error as LaunchError {
            FileHandle.standardError.write(Data("ClaudeUsageBar: \(error.message)\n\n\(usage)\n".utf8))
            exit(2)
        } catch {
            exit(2)
        }
    }()

    struct LaunchError: Error {
        let message: String
    }

    static func parse(_ args: [String]) throws -> LaunchOptions {
        var options = LaunchOptions()
        var index = 0
        func value(after flag: String) throws -> String {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                throw LaunchError(message: "\(flag) needs a value")
            }
            index += 1
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--help", "-h":
                print(usage)
                exit(0)
            case "--mock":
                if index + 1 < args.count, let used = Double(args[index + 1]) {
                    options.mockUtilization = min(100, max(0, used))
                    index += 1
                } else {
                    options.mockUtilization = 30
                }
            case "--mock-error":
                let raw = try value(after: arg)
                guard let error = MockError(rawValue: raw) else {
                    throw LaunchError(message: "invalid value '\(raw)' for --mock-error")
                }
                options.mockError = error
            case "--render-icons":
                options.renderIconsDirectory = try value(after: arg)
            case "--api-url":
                let raw = try value(after: arg)
                // The token is only ever sent to loopback hosts or the real endpoint.
                guard let url = URL(string: raw), url.scheme == "http",
                      ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
                    throw LaunchError(message: "--api-url must be an http URL on 127.0.0.1, localhost, or ::1")
                }
                options.apiURL = url
            case "--check-token":
                options.checkToken = true
            default:
                if arg.hasPrefix("--") {
                    throw LaunchError(message: "unknown argument '\(arg)'")
                } else if arg.hasPrefix("-") {
                    // Cocoa-style "-Key value" pairs (e.g. -AppleLanguages) are left to AppKit.
                    if index + 1 < args.count, !args[index + 1].hasPrefix("-") { index += 1 }
                } else {
                    throw LaunchError(message: "unexpected argument '\(arg)'")
                }
            }
            index += 1
        }
        return options
    }
}
