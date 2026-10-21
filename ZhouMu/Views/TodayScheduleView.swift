import SwiftUI

/// 首页第二页：当天完整课表。
///
/// 两种展示方式：
/// - **填了上下课时间**：按时间排出当天的完整时间轴，当前那节高亮。
/// - **没填时间**：排不出时间轴，就按「正课表 → 晚课表」的顺序列出当天的科目。
struct TodayScheduleView: View {
    @EnvironmentObject private var settings: AppSettings
    let now: Date

    private var timedClasses: [ScheduledClass] {
        settings.classes(for: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    if !timedClasses.isEmpty {
                        ForEach(timedClasses) { item in
                            timedRow(item)
                        }
                    } else if !untimedRows.isEmpty {
                        ForEach(Array(untimedRows.enumerated()), id: \.offset) { _, item in
                            untimedRow(item)
                        }
                    } else {
                        emptyState
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - 标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("今天的课")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.primaryText)

            Text(subtitle)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        let weekday = SemesterCalculator.weekdayShortNames[
            SemesterCalculator.dayIndexInWeek(for: now)
        ]
        let date = now.zhoumu_shortText
        if timedClasses.isEmpty && !untimedRows.isEmpty {
            return "\(date) \(weekday) · 未填上下课时间"
        }
        let count = timedClasses.isEmpty ? untimedRows.count : timedClasses.count
        return "\(date) \(weekday) · 共 \(count) 节"
    }

    // MARK: - 有时间轴

    private func timedRow(_ item: ScheduledClass) -> some View {
        let state = ClassSchedule.state(at: now, classes: timedClasses)
        let isCurrent: Bool = {
            if case .inClass(let c, _) = state { return c.id == item.id }
            return false
        }()
        let isPast = item.end <= now && !isCurrent

        return HStack(spacing: 14) {
            VStack(spacing: 1) {
                Text(DurationText.timeOfDay(item.start))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(DurationText.timeOfDay(item.end))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.faintText)
            }
            .foregroundStyle(isCurrent ? Palette.accentDeep : Palette.secondaryText)
            .frame(width: 48, alignment: .leading)

            RoundedRectangle(cornerRadius: 2)
                .fill(isCurrent ? Palette.accent : Palette.line)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.subject)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(isPast ? Palette.faintText : Palette.primaryText)

                Text("\(item.kind.label) · 第 \(item.period) 节")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.secondaryText)
            }

            Spacer(minLength: 0)

            if isCurrent {
                Text("进行中")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.accent))
            } else if isPast {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.accentSoft)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isCurrent ? Palette.accentSoft.opacity(0.6) : Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isCurrent ? Palette.accent.opacity(0.5) : .clear, lineWidth: 1.5)
        )
    }

    // MARK: - 没有时间

    private struct UntimedRow {
        var kind: ScheduleKind
        var period: Int
        var subject: String
    }

    private var untimedRows: [UntimedRow] {
        let day = SemesterCalculator.dayIndexInWeek(for: now)
        let week = settings.displayWeek(referenceDate: now)
        var rows: [UntimedRow] = []

        for kind in ScheduleKind.allCases {
            let table = settings.table(kind).effective(on: now, displayWeek: week ?? 1)
            guard table.enabled else { continue }
            let row = table.rotatesByWeek ? max(0, (week ?? 1) - 1) : 0
            for period in 0..<table.periodCount(day: day) {
                let subject = table.subject(row: row, day: day, period: period)
                guard !subject.isEmpty else { continue }
                rows.append(UntimedRow(kind: kind, period: period + 1, subject: subject))
            }
        }
        return rows
    }

    private func untimedRow(_ item: UntimedRow) -> some View {
        HStack(spacing: 14) {
            Text("\(item.period)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.accentSoft))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.subject)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.primaryText)
                Text("\(item.kind.label) · 第 \(item.period) 节")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.card)
        )
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.accentSoft)
            Text("今天没有课")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

#Preview {
    TodayScheduleView(now: Date()).environmentObject(AppSettings())
}

