import SwiftUI

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

    static let current = parse(Array(CommandLine.arguments.dropFirst()))

    static func parse(_ args: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--mock":
                if index + 1 < args.count, let value = Double(args[index + 1]) {
                    options.mockUtilization = min(100, max(0, value))
                    index += 1
                } else {
                    options.mockUtilization = 30
                }
            case "--mock-error":
                if index + 1 < args.count, let error = MockError(rawValue: args[index + 1]) {
                    options.mockError = error
                    index += 1
                }
            case "--render-icons":
                if index + 1 < args.count {
                    options.renderIconsDirectory = args[index + 1]
                    index += 1
                }
            case "--api-url":
                // Test hook: the token is only ever sent to loopback hosts or the real endpoint.
                if index + 1 < args.count, let url = URL(string: args[index + 1]),
                   url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") {
                    options.apiURL = url
                    index += 1
                }
            case "--check-token":
                options.checkToken = true
            default:
                break
            }
            index += 1
        }
        return options
    }
}

@main
struct Launcher {
    @MainActor
    static func main() {
        if let directory = LaunchOptions.current.renderIconsDirectory {
            exit(IconRenderer.run(outputDirectory: directory))
        }
        if LaunchOptions.current.checkToken {
            Task {
                exit(await CredentialsReader.printStatus())
            }
            RunLoop.main.run()
        }
        ClaudeUsageBarApp.main()
    }
}

struct ClaudeUsageBarApp: App {
    @StateObject private var store: UsageStore
    private let icons = IconProvider()

    init() {
        let store = UsageStore(options: .current)
        _store = StateObject(wrappedValue: store)
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuBarLabel(store: store, icons: icons)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore
    let icons: IconProvider

    var body: some View {
        HStack(spacing: 4) {
            if let image {
                Image(nsImage: image)
            }
            Text(text).monospacedDigit()
        }
    }

    private var image: NSImage? {
        switch store.status {
        case .loading where store.remaining == nil:
            return icons.loadingImage()
        case .expired, .loginRequired:
            return icons.errorImage(lastRemaining: store.remaining)
        default:
            guard let remaining = store.remaining else { return icons.errorImage(lastRemaining: nil) }
            return icons.image(forRemaining: remaining)
        }
    }

    private var text: String {
        if store.status == .loading && store.remaining == nil { return "…" }
        if store.status.showsErrorIcon { return "?" }
        guard let remaining = store.remaining else { return "?" }
        return store.status.isWarning ? "\(remaining)%!" : "\(remaining)%"
    }
}
