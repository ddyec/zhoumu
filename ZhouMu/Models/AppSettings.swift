import Combine
import Foundation
#if os(iOS)
import WidgetKit
#endif

/// 本地设置存储 + 启动时是否需要弹出「开学设置」的判定。
///
/// 弹出规则：
/// - 第一次启动，一定弹；
/// - 之后只在「放假开始月」（1 月、7 月）弹，且每个月只弹一次；
/// - 其余月份启动不弹。
///
/// v1.3 起这里管着：两张课表（正课表 / 晚课表）、主题模式、灵动岛开关。
final class AppSettings: ObservableObject {

    /// 放假开始月：1 月（寒假开始）、7 月（暑假开始）。
    static let vacationStartMonths: Set<Int> = [1, 7]

    // MARK: - 学期

    /// 开学日期。
    @Published var startDate: Date {
        didSet { persist() }
    }

    /// 循环周数（开启循环时生效）。
    @Published var cycleWeeks: Int {
        didSet { persist() }
    }

    /// 是否开启周目循环。
    @Published var cyclingEnabled: Bool {
        didSet { persist() }
    }

    // MARK: - 外观与提醒

    /// 外观模式：跟随系统 / 浅色 / 深色。
    @Published var themeMode: ThemeMode {
        didSet { persist() }
    }

    /// 是否启用灵动岛实时活动（总开关）。
    @Published var liveActivityEnabled: Bool {
        didSet { persist() }
    }

    // MARK: - 两张课表

    /// 正课表。
    @Published var regular: ScheduleTable {
        didSet { persist() }
    }

    /// 晚课表（v1.2 的「课表」迁移而来）。
    @Published var evening: ScheduleTable {
        didSet { persist() }
    }

    // MARK: - 启动弹窗状态

    /// 是否已经完成过首次启动（首次启动必须引导设置）。
    private(set) var hasCompletedFirstLaunch: Bool

    /// 上一次弹出开学设置的月份，格式 "yyyy-MM"。
    private(set) var lastSetupPromptMonth: String?

    private let defaults: UserDefaults

    /// 统一指向共享存储的 key，保证 App 和小组件读写的名字一致。
    private enum Key {
        static let startDate = SharedStorage.Key.startDate
        static let cycleWeeks = SharedStorage.Key.cycleWeeks
        static let cyclingEnabled = SharedStorage.Key.cyclingEnabled
        static let hasLaunched = SharedStorage.Key.hasLaunched
        static let promptMonth = SharedStorage.Key.promptMonth
        static let themeMode = SharedStorage.Key.themeMode
        static let liveActivity = SharedStorage.Key.liveActivityEnabled
        static let legacySchedule = SharedStorage.Key.legacySchedule
    }

    // MARK: - 初始化

    init(defaults: UserDefaults = SharedStorage.defaults) {
        self.defaults = defaults

        // 之前版本写在标准 UserDefaults 里，切到 App Group 后要把旧数据搬过来，避免用户丢设置。
        if defaults === SharedStorage.defaults {
            Self.migrateLegacySettingsIfNeeded(to: defaults)
        }

        let storedInterval = defaults.double(forKey: Key.startDate)
        if storedInterval > 0 {
            startDate = Date(timeIntervalSince1970: storedInterval)
        } else {
            startDate = SemesterCalculator.calendar.startOfDay(for: Date())
        }

        let storedCycle = defaults.integer(forKey: Key.cycleWeeks)
        cycleWeeks = SemesterCalculator.cycleWeeksRange.contains(storedCycle) ? storedCycle : 3
        cyclingEnabled = defaults.object(forKey: Key.cyclingEnabled) as? Bool ?? true
        hasCompletedFirstLaunch = defaults.bool(forKey: Key.hasLaunched)
        lastSetupPromptMonth = defaults.string(forKey: Key.promptMonth)
        themeMode = ThemeMode(rawValue: defaults.string(forKey: Key.themeMode) ?? "") ?? .system
        liveActivityEnabled = defaults.object(forKey: Key.liveActivity) as? Bool ?? true

        // 两张课表：优先读 v1.3 的新格式；读不到就把 v1.2 的旧课表迁到晚课表。
        var regularTable = ScheduleTable.decode(defaults.string(forKey: ScheduleKind.regular.storageKey))
        var eveningTable = ScheduleTable.decode(defaults.string(forKey: ScheduleKind.evening.storageKey))

        if !eveningTable.hasAnySubject && !regularTable.hasAnySubject {
            let legacy = defaults.dictionary(forKey: Key.legacySchedule) as? [String: String] ?? [:]
            if let migrated = ScheduleMigration.eveningTable(fromLegacy: legacy) {
                eveningTable = migrated
            }
        }
        // 正课表默认关闭（老用户没有这张表，不该被一个空表打扰）。
        if !regularTable.hasAnySubject && !regularTable.hasAnyTime {
            regularTable.enabled = false
        }

        regular = regularTable
        evening = eveningTable
    }

    // MARK: - 课表访问

    func table(_ kind: ScheduleKind) -> ScheduleTable {
        switch kind {
        case .regular: return regular
        case .evening: return evening
        }
    }

    func setTable(_ table: ScheduleTable, for kind: ScheduleKind) {
        switch kind {
        case .regular: regular = table
        case .evening: evening = table
        }
    }

    /// 取某格的科目名，空格子返回空字符串（= 无）。
    func subject(_ kind: ScheduleKind, row: Int, day: Int, period: Int) -> String {
        table(kind).subject(row: row, day: day, period: period)
    }

    /// 设置某格的科目名；传空字符串或只有空白，就表示这一格设为「无」。
    func setSubject(_ text: String, kind: ScheduleKind, row: Int, day: Int, period: Int) {
        var t = table(kind)
        t.setSubject(text, row: row, day: day, period: period)
        setTable(t, for: kind)
    }

    /// 只启用了哪几张表。
    var enabledKinds: [ScheduleKind] {
        ScheduleKind.allCases.filter { table($0).enabled }
    }

    /// 是否至少填过一个科目（两张表合计）。
    var hasAnySubject: Bool {
        regular.hasAnySubject || evening.hasAnySubject
    }

    // MARK: - 合并时间轴

    /// 今天显示第几周。
    func displayWeek(referenceDate: Date = Date()) -> Int? {
        guard case .inSession(let info) = SemesterCalculator.phase(startDate: startDate,
                                                                  cycleWeeks: cycleWeeks,
                                                                  cyclingEnabled: cyclingEnabled,
                                                                  referenceDate: referenceDate) else {
            return nil
        }
        return info.displayWeek
    }

    /// 今天的课程时间轴（两张表合并、按时间排序）。
    func classes(for date: Date = Date()) -> [ScheduledClass] {
        guard let week = displayWeek(referenceDate: date) else { return [] }
        return ClassSchedule.classes(for: date,
                                     tables: [.regular: regular, .evening: evening],
                                     displayWeek: week)
    }

    /// 此刻的状态（首页圆环、灵动岛都用它）。
    func state(at date: Date = Date()) -> ClassState {
        ClassSchedule.state(at: date, classes: classes(for: date))
    }

    /// 今天是否填了可用的上课时间——决定灵动岛能不能用。
    var todayHasTimes: Bool {
        let day = SemesterCalculator.dayIndexInWeek(for: Date())
        return enabledKinds.contains { kind in
            let t = table(kind).effective(on: Date(), displayWeek: displayWeek() ?? 1)
            return (0..<t.periodCount(day: day)).contains { t.hasTime(day: day, period: $0) }
        }
    }

    // MARK: - 启动弹窗判定

    /// 本次启动是否应该弹出开学设置。
    var shouldPresentSetupOnLaunch: Bool {
        setupPromptNeeded(at: Date(), calendar: SemesterCalculator.calendar)
    }

    /// 判定逻辑单独抽出，方便测试。
    func setupPromptNeeded(at date: Date, calendar: Calendar = SemesterCalculator.calendar) -> Bool {
        if !hasCompletedFirstLaunch { return true }
        guard Self.isVacationStartMonth(date, calendar: calendar) else { return false }
        return lastSetupPromptMonth != Self.monthKey(date, calendar: calendar)
    }

    /// 弹窗展示后调用：记录「首次启动已完成」以及「本月已弹过」。
    func markSetupPrompted(at date: Date = Date(), calendar: Calendar = SemesterCalculator.calendar) {
        if !hasCompletedFirstLaunch {
            hasCompletedFirstLaunch = true
            defaults.set(true, forKey: Key.hasLaunched)
        }
        if Self.isVacationStartMonth(date, calendar: calendar) {
            let key = Self.monthKey(date, calendar: calendar)
            lastSetupPromptMonth = key
            defaults.set(key, forKey: Key.promptMonth)
        }
    }

    /// 让下次启动重新弹出开学设置（设置页里的手动入口）。
    func resetSetupPromptHistory() {
        hasCompletedFirstLaunch = false
        lastSetupPromptMonth = nil
        defaults.set(false, forKey: Key.hasLaunched)
        defaults.removeObject(forKey: Key.promptMonth)
    }

    // MARK: - 工具

    static func isVacationStartMonth(_ date: Date, calendar: Calendar = SemesterCalculator.calendar) -> Bool {
        vacationStartMonths.contains(calendar.component(.month, from: date))
    }

    static func monthKey(_ date: Date, calendar: Calendar = SemesterCalculator.calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    // MARK: - 持久化

    private func persist() {
        defaults.set(startDate.timeIntervalSince1970, forKey: Key.startDate)
        defaults.set(cycleWeeks, forKey: Key.cycleWeeks)
        defaults.set(cyclingEnabled, forKey: Key.cyclingEnabled)
        defaults.set(themeMode.rawValue, forKey: Key.themeMode)
        defaults.set(liveActivityEnabled, forKey: Key.liveActivity)
        defaults.set(regular.encoded(), forKey: ScheduleKind.regular.storageKey)
        defaults.set(evening.encoded(), forKey: ScheduleKind.evening.storageKey)
        reloadWidgets()
    }

    /// App 里改完设置，让桌面小组件立刻跟着变（不用等系统的刷新周期）。
    private func reloadWidgets() {
        #if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// 把旧版本写在标准 UserDefaults 里的设置搬到 App Group 容器。
    private static func migrateLegacySettingsIfNeeded(to shared: UserDefaults) {
        // 共享容器里已经有开学日期 → 不需要迁移
        guard shared.double(forKey: Key.startDate) <= 0 else { return }

        let legacy = UserDefaults.standard
        guard legacy.double(forKey: Key.startDate) > 0 else { return }

        for key in [Key.startDate, Key.cycleWeeks, Key.cyclingEnabled,
                    Key.hasLaunched, Key.promptMonth, Key.legacySchedule] {
            if let value = legacy.object(forKey: key) {
                shared.set(value, forKey: key)
            }
        }
    }
}

