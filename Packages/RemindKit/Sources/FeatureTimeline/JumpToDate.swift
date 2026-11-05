import CoreAPI
import DesignSystem
import SwiftUI

/// Picks a day and hour to jump to, with days and hours that have nothing dimmed.
public struct JumpToDateView: View {
    private let core: any RemindCore
    private let calendar: Calendar
    private let onJump: (Date) -> Void
    private let today: Date

    @State private var month: Date
    @State private var selectedDay: Date
    @State private var selectedHour: Int
    @State private var activeDays: Set<Date> = []
    @State private var activeHours: Set<Int> = []

    public init(
        core: any RemindCore,
        current: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        onJump: @escaping (Date) -> Void
    ) {
        self.core = core
        self.calendar = calendar
        self.onJump = onJump
        today = now
        let day = calendar.startOfDay(for: current)
        _selectedDay = State(initialValue: day)
        _selectedHour = State(initialValue: calendar.component(.hour, from: current))
        _month = State(initialValue: calendar.dateInterval(of: .month, for: current)?.start ?? day)
    }

    public var body: some View {
        ReadingSurface(cornerRadius: 20) {
            VStack(spacing: 0) {
                Text("Jump to Date & Time")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 14)
                Divider().overlay(.white.opacity(0.08))
                HStack(spacing: 0) {
                    calendarGrid.padding(16)
                    Divider().overlay(.white.opacity(0.08))
                    hours
                }
            }
        }
        .frame(width: 430)
        .task(id: month) { await loadActiveDays() }
        .task(id: selectedDay) { await loadActiveHours() }
    }

    private var calendarGrid: some View {
        VStack(spacing: 8) {
            HStack {
                Button { shiftMonth(by: -1) } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { shiftMonth(by: 1) } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isCurrentMonth)
                .opacity(isCurrentMonth ? 0.3 : 1)
            }
            .foregroundStyle(.white)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(height: 22)
                }
                ForEach(gridDays, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
        .frame(width: 280)
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let hasData = activeDays.contains(day)
        let isFuture = day > today
        return Button {
            selectedDay = day
            jump()
        } label: {
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 14, weight: isSelected ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(
                    isSelected ? AnyShapeStyle(Palette.onVerdigris)
                        : AnyShapeStyle(.white.opacity(inMonth && hasData ? 0.95 : 0.28))
                )
                .frame(width: 34, height: 34)
                .background(isSelected ? AnyShapeStyle(Palette.verdigris) : AnyShapeStyle(.clear), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
    }

    private var hours: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(0..<24, id: \.self) { hour in
                        Button {
                            selectedHour = hour
                            jump()
                        } label: {
                            Text(hourLabel(hour))
                                .font(.system(size: 13, weight: selectedHour == hour ? .bold : .regular))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(
                                    selectedHour == hour ? 1 : (activeHours.contains(hour) ? 0.85 : 0.3)
                                ))
                                .frame(width: 66, height: 28)
                                .background(
                                    selectedHour == hour ? .white.opacity(0.14) : .clear,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .id(hour)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
            }
            .frame(height: 290)
            .onAppear { proxy.scrollTo(selectedHour, anchor: .center) }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: selectedDay) ?? selectedDay
        return date.formatted(.dateTime.hour().minute())
    }

    private var isCurrentMonth: Bool {
        calendar.isDate(month, equalTo: today, toGranularity: .month)
    }

    /// Weekday initials, starting on the first day of the week for this locale.
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Every day shown in the grid, which fills out whole weeks.
    private var gridDays: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -leading, to: interval.start) else { return [] }
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let total = Int((Double(leading + count) / 7).rounded(.up)) * 7
        return (0..<total).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func shiftMonth(by months: Int) {
        if let shifted = calendar.date(byAdding: .month, value: months, to: month) {
            month = shifted
        }
    }

    private func jump() {
        let target = calendar.date(bySettingHour: selectedHour, minute: 0, second: 0, of: selectedDay) ?? selectedDay
        onJump(min(target, today))
    }

    private func loadActiveDays() async {
        let days = gridDays
        let periods = days.compactMap { calendar.dateInterval(of: .day, for: $0) }
        let core = self.core
        let flags = await Task.detached(priority: .userInitiated) { (try? core.activePeriods(periods)) ?? [] }.value
        activeDays = Set(zip(days, flags).filter(\.1).map(\.0))
    }

    private func loadActiveHours() async {
        let day = selectedDay
        let calendar = self.calendar
        let periods = (0..<24).compactMap { hour -> DateInterval? in
            guard let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { return nil }
            return DateInterval(start: start, duration: 3600)
        }
        let core = self.core
        let flags = await Task.detached(priority: .userInitiated) { (try? core.activePeriods(periods)) ?? [] }.value
        activeHours = Set(flags.indices.filter { flags[$0] })
    }
}
