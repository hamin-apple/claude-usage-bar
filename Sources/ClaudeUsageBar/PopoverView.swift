import AppKit
import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude 사용량").font(.headline)

            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 12) {
                    if store.rows.isEmpty && store.status == .loading {
                        Text("불러오는 중…").foregroundStyle(.secondary)
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
                    Text("마지막 업데이트 \(updated, style: .time)")
                } else {
                    Text("아직 업데이트되지 않음")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button(store.isBackingOff ? "대기 중…" : "지금 새로고침") { store.refresh() }
                    .disabled(store.isBackingOff)
                Spacer()
                Button("종료") { NSApplication.shared.terminate(nil) }
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
                Text(remaining.map { "\(Int($0.rounded()))%" } ?? "–").monospacedDigit()
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
        guard seconds > 0 else { return "리셋됨" }
        let totalMinutes = seconds / 60
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days >= 1 { return "\(days)일 \(hours)시간 후 리셋" }
        if hours >= 1 { return "\(hours)시간 \(minutes)분 후 리셋" }
        return "\(max(minutes, 1))분 후 리셋"
    }
}

struct LoginItemToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("로그인 시 실행", isOn: Binding(
                get: { enabled },
                set: { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        errorText = nil
                    } catch {
                        errorText = error.localizedDescription
                    }
                    enabled = SMAppService.mainApp.status == .enabled
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
