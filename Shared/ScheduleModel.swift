import Foundation

// MARK: - 课表种类

/// 两张课表：正课表（白天）与晚课表。
enum ScheduleKind: String, Codable, CaseIterable, Sendable {
    case regular   // 正课表
    case evening   // 晚课表（原「课表」改名而来）

    var label: String {
        switch self {
        case .regular: return "正课表"
        case .evening: return "晚课表"
        }
    }

    var storageKey: String {
        switch self {
        case .regular: return "schedule.regular"
        case .evening: return "schedule.evening"
        }
    }
}

// MARK: - 节次时间

/// 一节课的上下课时间，单位是「从 0:00 起的分钟数」。
///
/// 用分钟数而不是 `Date`，是因为它和具体日期无关——
/// 同一个「第 3 节」在周一到周日都是同一个时间段。
struct PeriodTime: Codable, Equatable, Sendable {
    var start: Int
    var end: Int

    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// 时间是否可用：必须 start < end，且落在一天之内。
    var isValid: Bool {
        start >= 0 && end <= 24 * 60 && end > start
    }

    /// 按分钟数取时间；和 `minutes` 互转，方便存 UserDefaults。
    static func from(_ date: Date, calendar: Calendar = SemesterCalculator.calendar) -> PeriodTime? {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        guard let h = c.hour, let m = c.minute else { return nil }
        let mins = h * 60 + m
        return PeriodTime(start: mins, end: mins)
    }
}

// MARK: - 时间安排方式

/// 上下课时间怎么排：所有天共用一套，还是每天各一套。
enum TimeMode: String, Codable, CaseIterable, Sendable {
    /// 所有天共用一套时间。
    case unified
    /// 每天各有一套时间。
    case perDay

    var label: String {
        switch self {
        case .unified: return "统一"
        case .perDay:  return "每天单独"
        }
    }
}

// MARK: - 一张课表

/// 一张课表的完整配置。
///
/// 存成 JSON 字符串放进共享 UserDefaults，App 和小组件都能读。
struct ScheduleTable: Codable, Equatable, Sendable {

    /// 这张表是否启用（可单独关闭）。
    var enabled: Bool

    /// 排布方式：`true` = 按周目轮换（每周一换），`false` = 固定（每周一样）。
    var rotatesByWeek: Bool

    /// 每天几节。索引 0 = 周一 … 6 = 周日。
    var periodsPerDay: [Int]

    /// 时间安排方式：统一（所有天共用）或每天单独。
    var timeMode: TimeMode

    /// 每节的上下课时间，索引 0 = 第 1 节。可选填，`nil` 表示没填。
    /// `timeMode == .unified` 时用这一份。
    var periodTimes: [PeriodTime?]

    /// 每天各自的时间，索引 0 = 周一 … 6 = 周日。
    /// 每个子数组索引 0 = 第 1 节。`timeMode == .perDay` 时用这一份。
    var dailyPeriodTimes: [[PeriodTime?]]

    /// 科目表。key 格式 `"排-日-节"`（都是 0 基），value 是科目名；没有 key = 该格为「无」。
    var subjects: [String: String]

    /// 指定日期的临时例外；不修改每周循环。空科目表示该日停课。
    var dateOverrides: [String: [String: ScheduleOverride]] = [:]

    // MARK: 约束

    static let minPeriods = 1
    static let maxPeriods = 12
    static let defaultPeriods = 8
    static let dayCount = 7

    // MARK: 构造

    init(enabled: Bool = true,
                rotatesByWeek: Bool = true,
                periodsPerDay: [Int]? = nil,
                timeMode: TimeMode = .unified,
                periodTimes: [PeriodTime?] = [],
                dailyPeriodTimes: [[PeriodTime?]] = [],
                subjects: [String: String] = [:]) {
        self.enabled = enabled
        self.rotatesByWeek = rotatesByWeek
        self.periodsPerDay = periodsPerDay ?? Array(repeating: Self.defaultPeriods, count: Self.dayCount)
        self.timeMode = timeMode
        self.periodTimes = periodTimes
        self.dailyPeriodTimes = dailyPeriodTimes
        self.subjects = subjects
        self.normalize()
    }

    /// 把各个数组补齐到合法长度，并清掉越界的科目。
    mutating func normalize() {
        if periodsPerDay.count != Self.dayCount {
            var fixed = Array(periodsPerDay.prefix(Self.dayCount))
            while fixed.count < Self.dayCount { fixed.append(Self.defaultPeriods) }
            periodsPerDay = fixed
        }
        periodsPerDay = periodsPerDay.map { min(max($0, Self.minPeriods), Self.maxPeriods) }

        // 时间数组补齐到「最多节数」
        let maxP = periodsPerDay.max() ?? Self.defaultPeriods
        if periodTimes.count < maxP {
            periodTimes.append(contentsOf: Array(repeating: nil, count: maxP - periodTimes.count))
        }

        // 每天单独模式：7 个子数组，各自补齐到该天的节数
        if dailyPeriodTimes.count != Self.dayCount {
            var fixed = Array(dailyPeriodTimes.prefix(Self.dayCount))
            while fixed.count < Self.dayCount { fixed.append([]) }
            dailyPeriodTimes = fixed
        }
        for day in 0..<Self.dayCount {
            let want = periodCount(day: day)
            if dailyPeriodTimes[day].count < want {
                dailyPeriodTimes[day].append(contentsOf:
                    Array(repeating: nil, count: want - dailyPeriodTimes[day].count))
            } else if dailyPeriodTimes[day].count > want {
                dailyPeriodTimes[day] = Array(dailyPeriodTimes[day].prefix(want))
            }
        }
    }

    /// 一张全新的空表。
    static func empty() -> ScheduleTable {
        ScheduleTable()
    }

    // MARK: 查询

    /// 某天有几节（0 基的日索引）。
    func periodCount(day: Int) -> Int {
        guard periodsPerDay.indices.contains(day) else { return Self.defaultPeriods }
        return periodsPerDay[day]
    }

    /// 需要几排：轮换时 = 循环周数，固定时 = 1 排。
    func rowCount(cycleWeeks: Int) -> Int {
        rotatesByWeek ? max(1, cycleWeeks) : 1
    }

    /// 某天某节的时间；没填或非法都返回 `nil`。
    ///
    /// `day` 传 `nil` 时按统一模式取（每天单独模式下会返回 `nil`，
    /// 因为那种情况下"哪一节"不足以确定时间）。
    func time(forPeriod period: Int, day: Int? = nil) -> PeriodTime? {
        if timeMode == .perDay, let day, dailyPeriodTimes.indices.contains(day) {
            let list = dailyPeriodTimes[day]
            guard list.indices.contains(period), let t = list[period], t.isValid else { return nil }
            return t
        }
        guard periodTimes.indices.contains(period), let t = periodTimes[period], t.isValid else { return nil }
        return t
    }

    /// 这张表是否填过任何时间（灵动岛可用性的前提）。
    var hasAnyTime: Bool {
        if timeMode == .perDay {
            return dailyPeriodTimes.contains { list in list.contains { $0?.isValid == true } }
        }
        return periodTimes.contains { $0?.isValid == true }
    }

    /// 某个格子是否填了时间（用于判断「今天这节课能不能做提醒」）。
    func hasTime(day: Int, period: Int) -> Bool {
        period < periodCount(day: day) && time(forPeriod: period, day: day) != nil
    }

    /// 读写某天某节的时间。统一模式下改的是共用那份；每天单独模式下改当天的。
    mutating func setTime(_ value: PeriodTime?, day: Int, period: Int) {
        if timeMode == .perDay, dailyPeriodTimes.indices.contains(day) {
            guard dailyPeriodTimes[day].indices.contains(period) else { return }
            dailyPeriodTimes[day][period] = value
        } else {
            guard periodTimes.indices.contains(period) else { return }
            periodTimes[period] = value
        }
    }

    /// 切换到「每天单独」时，把当前统一的时间当作每天的初始值，避免用户白填。
    mutating func seedDailyTimesFromUnified() {
        guard timeMode == .perDay else { return }
        for day in 0..<Self.dayCount {
            let want = periodCount(day: day)
            var list = Array(repeating: PeriodTime?.none, count: want)
            for period in 0..<want where periodTimes.indices.contains(period) {
                list[period] = periodTimes[period]
            }
            dailyPeriodTimes[day] = list
        }
    }

    // MARK: 科目读写

    static func subjectKey(row: Int, day: Int, period: Int) -> String {
        "\(row)-\(day)-\(period)"
    }

    /// 取某格科目；空格返回空字符串。
    func subject(row: Int, day: Int, period: Int) -> String {
        subjects[Self.subjectKey(row: row, day: day, period: period)] ?? ""
    }

    /// 写某格科目；传空白等于设为「无」。
    mutating func setSubject(_ text: String, row: Int, day: Int, period: Int) {
        let key = Self.subjectKey(row: row, day: day, period: period)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            subjects.removeValue(forKey: key)
        } else {
            subjects[key] = trimmed
        }
    }

    /// 这张表里有没有填过科目。
    var hasAnySubject: Bool {
        !subjects.isEmpty
    }

    /// 某一天（跨所有排）有没有课。
    func hasClass(day: Int, row: Int) -> Bool {
        (0..<periodCount(day: day)).contains { !subject(row: row, day: day, period: $0).isEmpty }
    }

    // MARK: 序列化

    // MARK: 编解码

    /// v1.5 新增了 `timeMode` 和 `dailyPeriodTimes`。
    /// 老版本存下来的 JSON 里没有这两个键，直接用合成的解码器会**整体失败**
    /// （结果就是用户的课表被清空）。所以这里手写一份，缺键时给默认值。
    enum CodingKeys: String, CodingKey {
        case enabled, rotatesByWeek, periodsPerDay, timeMode, periodTimes, dailyPeriodTimes, subjects, dateOverrides
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        rotatesByWeek = try c.decodeIfPresent(Bool.self, forKey: .rotatesByWeek) ?? true
        periodsPerDay = try c.decodeIfPresent([Int].self, forKey: .periodsPerDay)
            ?? Array(repeating: Self.defaultPeriods, count: Self.dayCount)
        timeMode = try c.decodeIfPresent(TimeMode.self, forKey: .timeMode) ?? .unified
        periodTimes = try c.decodeIfPresent([PeriodTime?].self, forKey: .periodTimes) ?? []
        dailyPeriodTimes = try c.decodeIfPresent([[PeriodTime?]].self, forKey: .dailyPeriodTimes) ?? []
        subjects = try c.decodeIfPresent([String: String].self, forKey: .subjects) ?? [:]
        dateOverrides = try c.decodeIfPresent([String: [String: ScheduleOverride]].self, forKey: .dateOverrides) ?? [:]
        normalize()
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func decode(_ text: String?) -> ScheduleTable {
        guard let text, !text.isEmpty,
              let data = text.data(using: .utf8),
              let table = try? JSONDecoder().decode(ScheduleTable.self, from: data) else {
            return .empty()
        }
        var t = table
        t.normalize()
        return t
    }
}

// MARK: - 合并后的一节课

/// 从两张表里合并出来的一节具体课程（带真实日期时间）。
struct ScheduledClass: Equatable, Sendable, Identifiable {
    var kind: ScheduleKind
    var subject: String
    var period: Int          // 1 基
    var start: Date
    var end: Date

    var id: String { "\(kind.rawValue)-\(period)-\(start.timeIntervalSince1970)" }

    init(kind: ScheduleKind, subject: String, period: Int, start: Date, end: Date) {
        self.kind = kind
        self.subject = subject
        self.period = period
        self.start = start
        self.end = end
    }
}

// MARK: - 当前状态

/// 一天之中此刻处于什么状态——首页圆环和灵动岛都靠它。
enum ClassState: Equatable, Sendable {
    /// 今天没课（或两张表都关了）。
    case noClass
    /// 还没到第一节课。
    case beforeSchool(next: ScheduledClass)
    /// 正在上课。
    case inClass(current: ScheduledClass, next: ScheduledClass?)
    /// 课间休息。
    case resting(justEnded: ScheduledClass, next: ScheduledClass)
    /// 当天的课已经全部上完。
    case finished(last: ScheduledClass)

    /// 圆环进度 0…1。
    ///
    /// - 上课中：这节课已过的比例
    /// - 课间：**整个环闭合**（需求里明确要求课间也让环闭合）
    /// - 未开始 / 已结束：0 或 1
    func ringProgress(at now: Date) -> Double {
        switch self {
        case .noClass:
            return 0
        case .beforeSchool:
            return 0
        case .inClass(let current, _):
            let total = current.end.timeIntervalSince(current.start)
            guard total > 0 else { return 1 }
            return min(max(now.timeIntervalSince(current.start) / total, 0), 1)
        case .resting:
            return 1     // 课间：环闭合
        case .finished:
            return 1
        }
    }

    /// 上课中才有「当前科目」；没填时间时由 `ClassSchedule.ringContent` 回退到晚课表。
    var currentSubject: String? {
        switch self {
        case .inClass(let current, _): return current.subject
        default: return nil
        }
    }
}

// MARK: - 一天的课表计算

enum ClassSchedule {

    /// 把两张表合并成某一天按时间排序的课程列表。
    ///
    /// - 只包含 **填了合法时间** 的节次——没时间就无法排进时间轴。
    /// - 两张表各自按自己的排布方式取排：轮换用 `displayWeek - 1`，固定用第 0 排。
    static func classes(for date: Date,
                               tables: [ScheduleKind: ScheduleTable],
                               displayWeek: Int) -> [ScheduledClass] {
        let day = SemesterCalculator.dayIndexInWeek(for: date)
        let calendar = SemesterCalculator.calendar
        let dayStart = calendar.startOfDay(for: date)
        var result: [ScheduledClass] = []

        for kind in ScheduleKind.allCases {
            guard let original = tables[kind] else { continue }
            let table = original.effective(on: date, displayWeek: displayWeek)
            guard table.enabled else { continue }
            let row = table.rotatesByWeek ? max(0, displayWeek - 1) : 0
            let count = table.periodCount(day: day)

            for period in 0..<count {
                let subject = table.subject(row: row, day: day, period: period)
                guard !subject.isEmpty, let time = table.time(forPeriod: period, day: day) else { continue }
                guard let start = calendar.date(byAdding: .minute, value: time.start, to: dayStart),
                      let end = calendar.date(byAdding: .minute, value: time.end, to: dayStart) else { continue }
                result.append(ScheduledClass(kind: kind, subject: subject,
                                             period: period + 1, start: start, end: end))
            }
        }

        return result.sorted { $0.start < $1.start }
    }

    /// 判断此刻处于什么状态。
    static func state(at now: Date, classes: [ScheduledClass]) -> ClassState {
        guard !classes.isEmpty else { return .noClass }

        // 正在上课
        if let current = classes.first(where: { $0.start <= now && now < $0.end }) {
            let next = classes.first { $0.start >= current.end }
            return .inClass(current: current, next: next)
        }

        // 还没开始
        if let next = classes.first(where: { now < $0.start }) {
            // 上一节刚结束 → 课间
            if let ended = classes.last(where: { $0.end <= now }) {
                // 只有当下一节还没到时才算课间
                if now < next.start {
                    return .resting(justEnded: ended, next: next)
                }
            }
            return .beforeSchool(next: next)
        }

        // 全部上完
        if let last = classes.last {
            return .finished(last: last)
        }
        return .noClass
    }

    // MARK: - 第一屏圆环内容

    /// 第一屏圆环下方的三行倒计时。
    struct CountdownLines: Equatable {
        /// 距下节课开始还有多久；没有下节课时为 nil。
        var untilNextStart: TimeInterval?
        /// 这节课还有多久结束；不在上课时为 nil。
        var untilCurrentEnd: TimeInterval?
        /// 下节是什么（科目名）；没有下一节时为 nil。
        var nextSubject: String?

        var isEmpty: Bool {
            untilNextStart == nil && untilCurrentEnd == nil && nextSubject == nil
        }
    }

    /// 圆环 + 三行倒计时的完整内容。
    ///
    /// 除了给人看的文案，还带上**具体时间点**——
    /// 实时活动（灵动岛）要靠这些时间点让系统自己跑倒计时和进度条。
    struct RingContent: Equatable {
        /// 圈内大字。
        var subject: String
        /// 圈内小字（周几，或回退时的「当日晚课」）。
        var caption: String
        /// 环进度 0…1。
        var progress: Double
        /// 下方三行。
        var countdown: CountdownLines

        /// 本节起止（只有上课中才有）。
        var currentStart: Date?
        var currentEnd: Date?
        /// 下节开始时间。
        var nextStart: Date?
        /// 状态标签，实时活动用来挑图标：before / in / rest / done / none。
        var phase: String
    }

    /// 计算第一屏要显示的内容。
    ///
    /// 需求关键点：
    /// - **填了时间**：能排出时间轴，圈内显示当前科目（只有上课中才有），三行倒计时照常。
    /// - **一节时间都没填**：排不出时间轴，无法知道「当前是第几节」，
    ///   于是圈内改为显示**当天晚课表的科目名**（例如「晚自习」），小字标「当日晚课」，
    ///   三行倒计时全部为空。
    static func ringContent(at now: Date,
                            tables: [ScheduleKind: ScheduleTable],
                            displayWeek: Int?) -> RingContent {
        let day = SemesterCalculator.dayIndexInWeek(for: now)
        let weekday = SemesterCalculator.weekdayShortNames[day]

        let timeline = displayWeek.map {
            classes(for: now, tables: tables, displayWeek: $0)
        } ?? []

        // 没有可用的时间轴 → 回退到「当日晚课」
        if timeline.isEmpty {
            let effective = tables.mapValues { $0.effective(on: now, displayWeek: displayWeek ?? 1) }
            let fallback = eveningSubject(day: day, tables: effective, displayWeek: displayWeek)
            return RingContent(subject: fallback ?? "无课",
                               caption: fallback == nil ? weekday : "当日晚课",
                               progress: 0,
                               countdown: CountdownLines(),
                               phase: fallback == nil ? "none" : "evening")
        }

        let state = state(at: now, classes: timeline)
        var lines = CountdownLines()

        switch state {
        case .noClass:
            return RingContent(subject: "无课", caption: weekday, progress: 0,
                               countdown: lines, phase: "none")

        case .beforeSchool(let next):
            lines.untilNextStart = next.start.timeIntervalSince(now)
            lines.nextSubject = next.subject
            return RingContent(subject: next.subject, caption: weekday,
                               progress: 0, countdown: lines,
                               nextStart: next.start, phase: "before")

        case .inClass(let current, let next):
            lines.untilCurrentEnd = current.end.timeIntervalSince(now)
            if let next {
                lines.untilNextStart = next.start.timeIntervalSince(now)
                lines.nextSubject = next.subject
            }
            // 上课中：环随这节课的完成进度填充
            return RingContent(subject: current.subject, caption: weekday,
                               progress: state.ringProgress(at: now), countdown: lines,
                               currentStart: current.start, currentEnd: current.end,
                               nextStart: next?.start, phase: "in")

        case .resting(_, let next):
            // 课间：环闭合，圈内预告下一节
            lines.untilNextStart = next.start.timeIntervalSince(now)
            lines.nextSubject = next.subject
            return RingContent(subject: next.subject, caption: "课间",
                               progress: 1, countdown: lines,
                               nextStart: next.start, phase: "rest")

        case .finished:
            // 全部上完：环闭合，不再显示具体科目
            return RingContent(subject: "完课", caption: weekday, progress: 1,
                               countdown: lines, phase: "done")
        }
    }

    /// 某张表某一天的第一个非空科目；没启用或没课返回 nil。
    ///
    /// 单表场景（比如手表版只有一张课表）靠它做「没填时间时显示什么」的回退。
    static func firstSubject(day: Int,
                             table: ScheduleTable,
                             displayWeek: Int?) -> String? {
        guard table.enabled else { return nil }
        let row = table.rotatesByWeek ? max(0, (displayWeek ?? 1) - 1) : 0
        for period in 0..<table.periodCount(day: day) {
            let subject = table.subject(row: row, day: day, period: period)
            if !subject.isEmpty { return subject }
        }
        return nil
    }

    /// 当天晚课表里第一个非空科目；没启用或没课返回 nil。
    static func eveningSubject(day: Int,
                               tables: [ScheduleKind: ScheduleTable],
                               displayWeek: Int?) -> String? {
        guard let table = tables[.evening] else { return nil }
        return firstSubject(day: day, table: table, displayWeek: displayWeek)
    }
}

// MARK: - v1.2 → v1.3 迁移

enum ScheduleMigration {

    /// 把 v1.2 那张扁平课表（key = "排-日"，每天一节）搬进晚课表。
    ///
    /// v1.2 的课表本来就是「按周目轮换」的，所以 `rotatesByWeek = true`，
    /// 每天 1 节，没有时间。
    static func eveningTable(fromLegacy dict: [String: String]) -> ScheduleTable? {
        guard !dict.isEmpty else { return nil }

        var table = ScheduleTable(
            enabled: true,
            rotatesByWeek: true,
            periodsPerDay: Array(repeating: 1, count: ScheduleTable.dayCount),
            periodTimes: [nil],
            subjects: [:]
        )

        for (key, value) in dict {
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            table.setSubject(value, row: parts[0], day: parts[1], period: 0)
        }
        return table.hasAnySubject ? table : nil
    }
}

