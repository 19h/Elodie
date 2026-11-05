import AppKit
import Charts
import CoreAPI
import DesignSystem
import FeatureAsk
import SwiftUI

/// One day of activity: how much, in which apps, and the long stretches of focus. All
/// of this comes from local data, with no model involved.
public struct RecapView: View {
    private let core: any RemindCore
    private let calendar: Calendar
    private let onOpenMoment: (Date) -> Void

    @State private var day: Date
    @State private var recap: Recap?

    public init(core: any RemindCore, day: Date = Date(), calendar: Calendar = .current, onOpenMoment: @escaping (Date) -> Void) {
        self.core = core
        self.calendar = calendar
        self.onOpenMoment = onOpenMoment
        _day = State(initialValue: calendar.startOfDay(for: day))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if let recap, recap.totalActive > 0 {
                    content(recap).padding(20)
                } else if recap != nil {
                    empty
                } else {
                    ProgressView().padding(60)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 620)
        .tint(Palette.verdigris)
        .task(id: day) { await load() }
    }

    private var header: some View {
        HStack {
            Button { move(by: -1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.system(size: 20, design: .serif))
            Spacer()
            Button { move(by: 1) } label: { Image(systemName: "chevron.right") }
                .disabled(calendar.isDateInToday(day))
        }
        .buttonStyle(.borderless)
        .padding(16)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("Nothing recorded on this day")
                .font(.headline)
            Text("Recordings appear here once Remind has been running.")
                .foregroundStyle(.secondary)
        }
        .padding(80)
    }

    private func content(_ recap: Recap) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.duration(recap.totalActive))
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                Text("on screen")
                    .foregroundStyle(.secondary)
            }

            Chart(Array(recap.activity.enumerated()), id: \.offset) { hour, seconds in
                BarMark(
                    x: .value("Hour", hour),
                    y: .value("Minutes", seconds / 60)
                )
                .foregroundStyle(Palette.verdigris)
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text(hourLabel(hour))
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 110)

            section("Apps") {
                ForEach(recap.apps.prefix(8)) { app in
                    AppTimeRow(app: app, longest: recap.apps.first?.duration ?? 1)
                }
            }

            if !recap.blocks.isEmpty {
                section("Longest stretches") {
                    ForEach(recap.blocks.sorted { $0.end.timeIntervalSince($0.start) > $1.end.timeIntervalSince($1.start) }.prefix(10)) { block in
                        Button { onOpenMoment(block.start) } label: {
                            HStack {
                                Text(block.window ?? Self.appName(block.bundleID) ?? "Unknown")
                                    .lineLimit(1)
                                Spacer()
                                Text(block.start.formatted(.dateTime.hour().minute()))
                                    .foregroundStyle(.secondary)
                                Text(Self.duration(block.end.timeIntervalSince(block.start)))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 66, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        return date.formatted(.dateTime.hour())
    }

    private func move(by days: Int) {
        if let next = calendar.date(byAdding: .day, value: days, to: day) {
            day = next
        }
    }

    private func load() async {
        recap = nil
        let start = day
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let core = self.core
        recap = await Task.detached(priority: .userInitiated) {
            try? core.recap(from: start, to: end, bucket: 3600)
        }.value ?? Recap(totalActive: 0, apps: [], activity: [], blocks: [])
    }

    static func appName(_ bundleID: String?) -> String? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }
}

private struct AppTimeRow: View {
    let app: AppTime
    let longest: TimeInterval

    var body: some View {
        HStack(spacing: 10) {
            if let bundleID = app.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
            }
            Text(RecapView.appName(app.bundleID) ?? "Unknown").lineLimit(1)
            Spacer()
            Text(RecapView.duration(app.duration))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
