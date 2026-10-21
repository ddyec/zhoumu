import Foundation

struct ScheduleAction: Codable, Equatable {
    var date: String
    var kind: ScheduleKind
    var period: Int // 1 基
    var subject: String // 空字符串 = 该日该节停课
    var start: Int?
    var end: Int?
}

struct SchedulePlan: Codable {
    var message: String
    var actions: [ScheduleAction]
}

struct AssistantFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 纯值快照：预览、校验、应用和撤销都基于同一份课表。
struct ScheduleContext: Equatable, Encodable {
    var today: String
    var timeZone: String
    var startDate: String
    var cycleWeeks: Int
    var cyclingEnabled: Bool
    var regular: ScheduleTable
    var evening: ScheduleTable

    func week(on date: Date) -> Int? {
        guard let start = ScheduleDate.parse(startDate),
              case .inSession(let info) = SemesterCalculator.phase(startDate: start, cycleWeeks: cycleWeeks,
                 cyclingEnabled: cyclingEnabled, referenceDate: date) else { return nil }
        return info.displayWeek
    }

    func table(_ kind: ScheduleKind) -> ScheduleTable { kind == .regular ? regular : evening }

    func preview(_ action: ScheduleAction) -> String {
        guard let date = ScheduleDate.parse(action.date) else { return action.date }
        let effective = table(action.kind).effective(on: date, displayWeek: week(on: date) ?? 1)
        let day = SemesterCalculator.dayIndexInWeek(for: date)
        let row = effective.rotatesByWeek ? max(0, (week(on: date) ?? 1) - 1) : 0
        let before = effective.enabled ? effective.subject(row: row, day: day, period: action.period - 1) : ""
        func clock(_ t: PeriodTime?) -> String {
            guard let t else { return "（时间未设置）" }
            return String(format: " %02d:%02d–%02d:%02d", t.start / 60, t.start % 60, t.end / 60, t.end % 60)
        }
        let oldTime = effective.time(forPeriod: action.period - 1, day: day)
        let newTime = action.start.flatMap { start in action.end.map { PeriodTime(start: start, end: $0) } } ?? oldTime
        return "\(action.date) \(action.kind.label) 第\(action.period)节\n\(before.isEmpty ? "无" : before)\(clock(oldTime)) → \(action.subject.isEmpty ? "停课 / 休息" : action.subject)\(clock(newTime))"
    }

    func applying(_ plan: SchedulePlan) throws -> ScheduleContext {
        guard !plan.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              plan.actions.count <= 200 else { throw AssistantFailure("AI 返回的方案格式不正确或修改过多，请缩小范围。") }
        var copy = self
        var seen = Set<String>()
        var affected = Set<String>()
        guard let reference = ScheduleDate.parse(today) else { throw AssistantFailure("当前日期不可用。") }
        for action in plan.actions {
            guard let date = ScheduleDate.parse(action.date), week(on: date) != nil,
                  abs(SemesterCalculator.calendar.dateComponents([.day], from: reference, to: date).day ?? 9999) <= 366,
                  (1...ScheduleTable.maxPeriods).contains(action.period), action.subject.count <= 100,
                  (action.start == nil) == (action.end == nil) else {
                throw AssistantFailure("方案含无效日期、节次或时间；只能安排开学后、距今天一年内的课程。")
            }
            let key = "\(action.date)-\(action.kind.rawValue)-\(action.period)"
            guard seen.insert(key).inserted else { throw AssistantFailure("方案重复修改了同一个课表格，请重新生成。") }
            let time = action.start.flatMap { start in action.end.map { PeriodTime(start: start, end: $0) } }
            guard time?.isValid != false else { throw AssistantFailure("起止时间必须在当天范围内，且结束晚于开始。") }
            var table = copy.table(action.kind)
            table.dateOverrides[action.date, default: [:]][String(action.period)] = ScheduleOverride(
                subject: action.subject.trimmingCharacters(in: .whitespacesAndNewlines),
                time: time ?? table.dateOverrides[action.date]?[String(action.period)]?.time)
            if action.kind == .regular { copy.regular = table } else { copy.evening = table }
            affected.insert(action.date)
        }
        // 只拒绝方案新引入的重叠；允许原课表已有的冲突被逐步解决。
        for day in affected {
            let date = ScheduleDate.parse(day)!
            func overlaps(_ context: ScheduleContext) -> Set<String> {
                let list = ClassSchedule.classes(for: date, tables: [.regular: context.regular, .evening: context.evening],
                                                 displayWeek: context.week(on: date) ?? 1)
                var pairs = Set<String>()
                for i in list.indices {
                    for j in list.indices where j > i && list[i].start < list[j].end && list[j].start < list[i].end {
                        pairs.insert(["\(list[i].kind.rawValue)-\(list[i].period)", "\(list[j].kind.rawValue)-\(list[j].period)"].sorted().joined(separator: "/"))
                    }
                }
                return pairs
            }
            guard overlaps(copy).subtracting(overlaps(self)).isEmpty else {
                throw AssistantFailure("\(day) 的新安排与其他课程时间重叠，请要求 AI 同时移动冲突课程。")
            }
        }
        return copy
    }
}
