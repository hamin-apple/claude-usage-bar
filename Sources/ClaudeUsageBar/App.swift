import SwiftUI

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
        guard let usage = store.menuBarAccount else { return icons.loadingImage() }
        switch usage.status {
        case .loading where usage.remaining == nil:
            return icons.loadingImage()
        case .expired, .loginRequired:
            return icons.errorImage(lastRemaining: usage.remaining)
        default:
            guard let remaining = usage.remaining else { return icons.errorImage(lastRemaining: nil) }
            return icons.image(forRemaining: remaining)
        }
    }

    private var text: String {
        guard let usage = store.menuBarAccount else { return "…" }
        if usage.status == .loading && usage.remaining == nil { return "…" }
        if usage.status.showsErrorIcon { return "?" }
        guard let remaining = usage.remaining else { return "?" }
        return usage.status.isWarning ? "\(remaining)%!" : "\(remaining)%"
    }
}
