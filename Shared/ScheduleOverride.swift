import Foundation

struct ScheduleOverride: Codable, Equatable, Sendable {
    var subject: String
    /// nil 保留该节常规时间；有值时只修改该日期的时间。
    var time: PeriodTime?
}

enum ScheduleDate {
    static func key(_ date: Date) -> String {
        let c = SemesterCalculator.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func parse(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = SemesterCalculator.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              key(date) == text else { return nil }
        return date
    }
}

extension ScheduleTable {
    /// 在副本上把当天例外展开，所有显示和时间轴使用相同结果。
    func effective(on date: Date, displayWeek: Int) -> ScheduleTable {
        guard let changes = dateOverrides[ScheduleDate.key(date)], !changes.isEmpty else { return self }
        var copy = self
        let day = SemesterCalculator.dayIndexInWeek(for: date)
        let row = rotatesByWeek ? max(0, displayWeek - 1) : 0
        let periods = changes.keys.compactMap(Int.init).filter { (1...Self.maxPeriods).contains($0) }
        copy.periodsPerDay[day] = max(periodCount(day: day), periods.max() ?? 1)
        copy.normalize()
        if !enabled {
            for period in 0..<copy.periodCount(day: day) {
                copy.setSubject("", row: row, day: day, period: period)
            }
        }
        if copy.timeMode == .unified {
            copy.timeMode = .perDay
            copy.seedDailyTimesFromUnified()
        }
        for period in periods {
            guard let change = changes[String(period)] else { continue }
            copy.setSubject(change.subject, row: row, day: day, period: period - 1)
            if let time = change.time { copy.setTime(time, day: day, period: period - 1) }
        }
        if changes.values.contains(where: { !$0.subject.isEmpty }) { copy.enabled = true }
        copy.dateOverrides = [:]
        return copy
    }
}
