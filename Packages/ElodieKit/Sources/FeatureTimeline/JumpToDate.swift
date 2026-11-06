import CoreAPI
import DesignSystem
import SwiftUI

/// Points at the time pill below the panel.
struct PanelCaret: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.midX - 3, y: rect.minY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX + 3, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Picks a day and hour to jump to, with days and hours that have nothing dimmed.
public struct JumpToDateView: View {
    private let core: any ElodieCore
    private let calendar: Calendar
    private let onJump: (Date) -> Void
    private let onClose: () -> Void
    private let today: Date

    @State private var month: Date
    @State private var selectedDay: Date
    @State private var selectedHour: Int
    @State private var activeDays: Set<Date> = []
    @State private var activeHours: Set<Int> = []
    @State private var phrase = ""
    @State private var phraseFailed = false

    public init(
        core: any ElodieCore,
        current: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        onJump: @escaping (Date) -> Void,
        onClose: @escaping () -> Void = {}
    ) {
        self.core = core
        self.calendar = calendar
        self.onJump = onJump
        self.onClose = onClose
        today = now
        let day = calendar.startOfDay(for: current)
        _selectedDay = State(initialValue: day)
        _selectedHour = State(initialValue: calendar.component(.hour, from: current))
        _month = State(initialValue: calendar.dateInterval(of: .month, for: current)?.start ?? day)
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                HStack(alignment: .top, spacing: 0) {
                    calendarGrid
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
                    hours
                }
                .frame(height: Self.bodyHeight)
                .background(.black, in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous))
            }
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1)))
            PanelCaret()
                .fill(.black)
                .frame(width: 40, height: 14)
        }
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
        .environment(\.colorScheme, .dark)
        .task(id: month) { await loadActiveDays() }
        .task(id: selectedDay) { await loadActiveHours() }
    }

    private static let bodyHeight: CGFloat = 372

    private var header: some View {
        VStack(spacing: 8) {
            Text("Jump to Date & Time")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            TextField("Try “yesterday 3pm”", text: $phrase)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(phraseFailed ? Palette.marker : .white)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(.white.opacity(0.08), in: Capsule())
                .frame(width: 240)
                .onSubmit(jumpToPhrase)
                .onExitCommand(perform: onClose)
                .onChange(of: phrase) { phraseFailed = false }
                .accessibilityLabel("Type a date and time")
        }
        .padding(.horizontal, 18)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    private func jumpToPhrase() {
        guard let date = NaturalDate.parse(phrase, now: today) else {
            phraseFailed = true
            return
        }
        selectedDay = calendar.startOfDay(for: date)
        selectedHour = calendar.component(.hour, from: date)
        month = calendar.dateInterval(of: .month, for: date)?.start ?? selectedDay
        phrase = ""
        onJump(date)
    }

    private var calendarGrid: some View {
        VStack(spacing: 10) {
            HStack {
                Button { shiftMonth(by: -1) } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(month.formatted(
                    calendar.isDate(month, equalTo: today, toGranularity: .year)
                        ? .dateTime.month(.wide)
                        : .dateTime.month(.wide).year()
                ))
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
            LazyVGrid(columns: columns, spacing: 6) {
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
                        : AnyShapeStyle(.white.opacity(inMonth && hasData ? 0.95 : 0.38))
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
                                    selectedHour == hour ? 1 : (activeHours.contains(hour) ? 0.85 : 0.38)
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
