import Foundation

func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError(label) }
    print("PASS: \(label)")
}
func rejected(_ label: String, _ work: () throws -> Void) {
    do { try work(); fatalError("Expected rejection: \(label)") }
    catch { print("PASS: \(label)") }
}
let date = ScheduleDate.parse("2026-10-21")!
let nextWeek = ScheduleDate.parse("2026-10-28")!
let day = SemesterCalculator.dayIndexInWeek(for: date)
var regular = ScheduleTable(enabled: true, rotatesByWeek: false)
regular.setSubject("数学", row: 0, day: day, period: 0)
regular.setSubject("语文", row: 0, day: day, period: 1)
regular.setTime(PeriodTime(start: 480, end: 525), day: day, period: 0)
regular.setTime(PeriodTime(start: 540, end: 585), day: day, period: 1)
let source = ScheduleContext(today: "2026-10-21", timeZone: "Asia/Shanghai", startDate: "2026-09-01",
                             cycleWeeks: 3, cyclingEnabled: true, regular: regular,
                             evening: ScheduleTable(enabled: false))
func action(_ period: Int, _ subject: String, start: Int? = nil, end: Int? = nil) -> ScheduleAction {
    ScheduleAction(date: "2026-10-21", kind: .regular, period: period, subject: subject, start: start, end: end)
}
func plan(_ actions: [ScheduleAction]) -> SchedulePlan { SchedulePlan(message: "临时调整", actions: actions) }
let swapped = try source.applying(plan([action(1, "语文"), action(2, "数学")]))
let result = ClassSchedule.classes(for: date, tables: [.regular: swapped.regular], displayWeek: 1)
check(result.map(\.subject) == ["语文", "数学"], "当天交换")
check(ClassSchedule.classes(for: nextWeek, tables: [.regular: swapped.regular], displayWeek: 1).map(\.subject) == ["数学", "语文"], "下周课表保持常规")
check(source.regular == regular, "应用在副本上完成")
let holiday = try source.applying(plan([action(1, ""), action(2, "")]))
check(ClassSchedule.classes(for: date, tables: [.regular: holiday.regular], displayWeek: 1).isEmpty, "指定日期调休")
let meeting = try source.applying(plan([action(9, "班会", start: 900, end: 960)]))
check(ClassSchedule.classes(for: date, tables: [.regular: meeting.regular], displayWeek: 1).count == 3, "新增临时事项并扩展节次")
check(ScheduleTable.decode(meeting.regular.encoded()) == meeting.regular, "例外存储往返")
check(ScheduleDate.parse("2026-02-30") == nil, "拒绝无效日期")
rejected("拒绝重复目标格") { _ = try source.applying(plan([action(1, "甲"), action(1, "乙")])) }
rejected("拒绝反向时间") { _ = try source.applying(plan([action(1, "甲", start: 600, end: 500)])) }
rejected("拒绝新时间冲突") { _ = try source.applying(plan([action(3, "甲", start: 510, end: 560)])) }
rejected("拒绝不完整时间") { _ = try source.applying(plan([action(3, "甲", start: 600)])) }
rejected("拒绝越界节次") { _ = try source.applying(plan([action(13, "甲")])) }
var oldJSON = try JSONSerialization.jsonObject(with: Data(regular.encoded().utf8)) as! [String: Any]
oldJSON.removeValue(forKey: "dateOverrides")
let legacy = try JSONDecoder().decode(ScheduleTable.self, from: JSONSerialization.data(withJSONObject: oldJSON))
check(legacy == regular, "兼容旧版课表数据")
var rotating = regular
rotating.rotatesByWeek = true
rotating.setSubject("化学", row: 2, day: day, period: 0)
rotating.dateOverrides["2026-10-21"] = ["1": ScheduleOverride(subject: "体育", time: nil)]
check(rotating.effective(on: date, displayWeek: 3).subject(row: 2, day: day, period: 0) == "体育", "例外覆盖正确循环排")
var disabled = ScheduleTable(enabled: false)
disabled.dateOverrides["2026-10-21"] = ["1": ScheduleOverride(subject: "活动", time: PeriodTime(start: 1000, end: 1030))]
check(ClassSchedule.classes(for: date, tables: [.evening: disabled], displayWeek: 1).count == 1, "关闭的课表可单日添加活动")
check(!disabled.effective(on: nextWeek, displayWeek: 1).enabled, "活动不启用未来课表")
let renamedMeeting = try meeting.applying(plan([action(9, "临时讨论")]))
check(renamedMeeting.regular.dateOverrides["2026-10-21"]?["9"]?.time == PeriodTime(start: 900, end: 960), "修改临时事项名称保留已设时间")
var hidden = regular
hidden.enabled = false
hidden.dateOverrides["2026-10-21"] = ["3": ScheduleOverride(subject: "活动", time: PeriodTime(start: 900, end: 960))]
check(ClassSchedule.classes(for: date, tables: [.regular: hidden], displayWeek: 1).map(\.subject) == ["活动"], "单日活动不启用已关闭模板的其他课程")
print("All assistant checks passed")
