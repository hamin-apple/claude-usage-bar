import AppKit
import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Limits Remaining").font(.headline)

            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 12) {
                    if store.rows.isEmpty && store.status == .loading {
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                    ForEach(store.rows) { row in
                        LimitRowView(row: row, now: context.date)
                    }
                }
            }

            if let notice = store.status.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(store.status.isWarning ? Color.orange : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                if let updated = store.lastUpdated {
                    Text("Last updated \(updated, style: .time)")
                } else {
                    Text("Not updated yet")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button(store.isBackingOff ? "Waiting…" : "Refresh Now") { store.refresh() }
                    .disabled(store.isBackingOff)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)

            LoginItemToggle()
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct LimitRowView: View {
    let row: LimitRow
    let now: Date

    var body: some View {
        let remaining = row.remaining(at: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.title)
                Spacer()
                Text(remaining.map { "\(Int($0.rounded()))% left" } ?? "–").monospacedDigit()
            }
            ProgressView(value: (remaining ?? 0) / 100)
                .tint((remaining ?? 100) <= 20 ? .red : .accentColor)
            if let resetsAt = row.resetsAt {
                Text(ResetText.format(until: resetsAt, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum ResetText {
    static func format(until date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "Reset" }
        let totalMinutes = seconds / 60
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days >= 1 { return "Resets in \(days)d \(hours)h" }
        if hours >= 1 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(max(minutes, 1))m"
    }
}

struct LoginItemToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at Login", isOn: Binding(get: { enabled }, set: { change(to: $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    // The status read right after register() can lag, so the toggle follows the call's result instead.
    private func change(to newValue: Bool) {
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            enabled = newValue
            let needsApproval = newValue && SMAppService.mainApp.status == .requiresApproval
            errorText = needsApproval ? "Approval needed in System Settings > General > Login Items" : nil
        } catch {
            errorText = error.localizedDescription
            refresh()
        }
    }

    private func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
    }
}
