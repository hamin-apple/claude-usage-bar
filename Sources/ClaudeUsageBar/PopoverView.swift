import AppKit
import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude Limits Remaining").font(.headline)
                Spacer()
                if !store.isMultiAccount, let plan = store.accounts.first?.plan {
                    PlanBadge(plan: plan)
                }
            }

            if store.isMultiAccount {
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, usage in
                    if index > 0 { Divider() }
                    AccountSection(usage: usage, showsHeader: true)
                }
            } else if let usage = store.accounts.first {
                AccountSection(usage: usage, showsHeader: false)
            }

            Divider()

            if store.isMultiAccount {
                Picker("Menu bar", selection: Binding(get: { store.pickerSelection }, set: { store.menuBarChoice = $0 })) {
                    Text("Lowest session").tag(UsageStore.lowestChoice)
                    ForEach(store.accounts) { usage in
                        Text(usage.account.label).tag(usage.account.sources.first?.name ?? usage.id)
                    }
                }
                .controlSize(.small)
            } else {
                HStack {
                    if let updated = store.accounts.first?.lastUpdated {
                        Text("Last updated \(TimeFormat.clock(updated))")
                    } else {
                        Text("Not updated yet")
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button(store.allBackingOff ? "Waiting…" : "Refresh Now") { store.refresh() }
                    .disabled(store.allBackingOff)
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

// One account's rows and notice. With several accounts it gets a header (label, plan) and its own update time.
struct AccountSection: View {
    @ObservedObject var usage: AccountUsage
    let showsHeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: showsHeader ? 8 : 12) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline) {
                    Text(usage.account.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let plan = usage.plan { PlanBadge(plan: plan) }
                }
            }

            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: showsHeader ? 8 : 12) {
                    if usage.rows.isEmpty && usage.status == .loading {
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                    ForEach(usage.rows) { row in
                        LimitRowView(row: row, now: context.date, compact: showsHeader)
                    }
                }
            }

            if let notice = usage.status.notice(configFolder: showsHeader ? usage.account.sources.first : nil) {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(usage.status.isWarning ? Color.orange : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsHeader {
                Text(usage.lastUpdated.map { "Updated \(TimeFormat.clock($0))" } ?? "Not updated yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PlanBadge: View {
    let plan: String

    var body: some View {
        Text(PlanName.display(plan))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

// Compact (several accounts) puts the reset time on the title line to keep the panel on screen.
struct LimitRowView: View {
    let row: LimitRow
    let now: Date
    var compact = false

    var body: some View {
        let remaining = row.remaining(at: now)
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                if compact, let resetsAt = row.resetsAt {
                    Text(ResetText.format(until: resetsAt, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(remaining.map { "\(Int($0.rounded()))% left" } ?? "–").monospacedDigit()
            }
            ProgressView(value: (remaining ?? 0) / 100)
                .tint((remaining ?? 100) <= 20 ? .red : .accentColor)
            if !compact, let resetsAt = row.resetsAt {
                Text(ResetText.format(until: resetsAt, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum PlanName {
    // "pro" -> "Pro", "max_5x" -> "Max 5x"; the raw value is an undocumented string, so never assume a fixed set.
    static func display(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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
