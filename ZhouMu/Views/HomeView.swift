import SwiftUI

/// 主界面 v1.3：两页。
///
/// - **第一页**：圆环（按课程完成进度填充）+ 周目 + 三行倒计时
///   （距下节课还有多久 / 这节还有多久结束 / 下节是什么）。
/// - **第二页**：当天完整课表。
struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    @State private var isShowingSettings = false
    @State private var isShowingAssistant = false
    @State private var now = Date()
    @State private var page = 0

    /// 每秒走一格，驱动倒计时和圆环。
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var phase: SemesterPhase {
        SemesterCalculator.phase(startDate: settings.startDate,
                                 cycleWeeks: settings.cycleWeeks,
                                 cyclingEnabled: settings.cyclingEnabled,
                                 referenceDate: now)
    }

    private var ring: ClassSchedule.RingContent {
        ClassSchedule.ringContent(at: now,
                                  tables: [.regular: settings.regular, .evening: settings.evening],
                                  displayWeek: settings.displayWeek(referenceDate: now))
    }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                TabView(selection: $page) {
                    firstPage.tag(0)
                    TodayScheduleView(now: now).tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageDots
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView().environmentObject(settings)
        }
        .sheet(isPresented: $isShowingAssistant) {
            AIAssistantView().environmentObject(settings)
        }
        .onAppear {
            presentSetupIfNeeded()
            syncLiveActivity()
        }
        .onReceive(ticker) { now = $0 }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                now = Date()
                syncLiveActivity()
            } else if newPhase == .background {
                // 切后台前刷一次：把通知排好，并给实时活动安排「到点自动移除」。
                syncLiveActivity(goingToBackground: true)
            }
        }
        .onChange(of: settings.regular) { _, _ in syncLiveActivity() }
        .onChange(of: settings.evening) { _, _ in syncLiveActivity() }
        .onChange(of: settings.startDate) { _, _ in syncLiveActivity() }
        .onChange(of: settings.liveActivityEnabled) { _, _ in syncLiveActivity() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            now = Date()
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack {
            Text("周目")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.accent)

            Spacer()

            Button { isShowingAssistant = true } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("AI 排课助理")

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Palette.accentSoft.opacity(0.7)))
            }
            .accessibilityLabel("设置")
        }
    }

    // MARK: - 第一页

    private var firstPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            ringView

            Spacer(minLength: 14)

            cycleIndicator

            Spacer(minLength: 14)

            CountdownCard(content: ring.countdown, hasTimes: settings.todayHasTimes)

            Spacer(minLength: 6)
        }
    }

    private var ringView: some View {
        ZStack {
            Circle()
                .stroke(Palette.accentSoft, style: StrokeStyle(lineWidth: 16))

            Circle()
                .trim(from: 0, to: ring.progress)
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))

            ringText
        }
        .frame(width: 246, height: 246)
        .animation(.easeInOut(duration: 0.4), value: ring.progress)
    }

    @ViewBuilder
    private var ringText: some View {
        switch phase {
        case .notStarted(let days):
            VStack(spacing: 6) {
                Text("未开学")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.accent)
                Text("还有 \(days) 天")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.secondaryText)
            }

        case .inSession:
            VStack(spacing: 4) {
                Text(ring.caption)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.secondaryText)

                Text(ring.subject)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.accent)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.4)
                    .padding(.horizontal, 28)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(ring.caption)，\(ring.subject)")
        }
    }

    @ViewBuilder
    private var cycleIndicator: some View {
        if case .inSession(let info) = phase {
            VStack(spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("第").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("\(info.displayWeek)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("周").font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Palette.accent)

                if info.isCycling && info.cycleWeeks <= 12 {
                    CycleDots(total: info.cycleWeeks, current: info.displayWeek)
                }

                Text(info.isCycling
                     ? "开学第 \(info.rawWeek) 周 · \(info.cycleWeeks) 周循环"
                     : "开学第 \(info.rawWeek) 周")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
    }

    // MARK: - 翻页指示

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<2, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Palette.accent : Palette.accentSoft)
                    .frame(width: index == page ? 18 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.22), value: page)
            }
        }
        .accessibilityHidden(true)
    }

    /// 刷新灵动岛实时活动 + 重排今天的上课提醒。
    private func syncLiveActivity(goingToBackground: Bool = false) {
        let snapshot = settings
        // 顺手给系统排一个后台刷新：课后找机会醒一次，把过期的实时活动清理掉。
        BackgroundRefresh.schedule(settings: snapshot)
        Task {
            await LiveActivityManager.shared.sync(settings: snapshot,
                                                  goingToBackground: goingToBackground)
        }
    }

    // MARK: - 启动引导

    private func presentSetupIfNeeded() {
        guard settings.shouldPresentSetupOnLaunch else { return }
        settings.markSetupPrompted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            isShowingSettings = true
        }
    }
}

// MARK: - 三行倒计时

/// 第一屏圆环下方的三行：距下节课 / 本节剩余 / 下节是什么。
private struct CountdownCard: View {
    let content: ClassSchedule.CountdownLines
    let hasTimes: Bool

    var body: some View {
        VStack(spacing: 12) {
            if !hasTimes {
                // 一节时间都没填：无法排时间轴，给出明确指引
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                    Text("填入每节上下课时间后，这里显示倒计时与灵动岛提醒")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                row(icon: "bell.badge",
                    label: "距下节课",
                    value: content.untilNextStart.map { "还有 \(DurationText.human($0))" },
                    detail: content.nextSubject,
                    highlighted: content.untilNextStart != nil)

                Divider().overlay(Palette.line)

                row(icon: "hourglass",
                    label: "这节还剩",
                    value: content.untilCurrentEnd.map { DurationText.human($0) },
                    detail: nil,
                    highlighted: content.untilCurrentEnd != nil)

                Divider().overlay(Palette.line)

                row(icon: "text.book.closed",
                    label: "下节",
                    value: content.nextSubject,
                    detail: nil,
                    highlighted: content.nextSubject != nil)
            }
        }
        .cardStyle(padding: 18, radius: 24)
    }

    private func row(icon: String, label: String, value: String?, detail: String?, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(highlighted ? Palette.accent : Palette.faintText)
                .frame(width: 22)

            Text(label)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.secondaryText)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(value ?? "—")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(highlighted ? Palette.accentDeep : Palette.faintText)
                    .monospacedDigit()

                if let detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
        }
    }
}

// MARK: - 子视图

/// 循环中的位置：一排圆点，当前周目高亮。
private struct CycleDots: View {
    let total: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(1...max(total, 1)), id: \.self) { index in
                Circle()
                    .fill(index == current ? Palette.accent : Palette.accentSoft)
                    .frame(width: index == current ? 13 : 9,
                           height: index == current ? 13 : 9)
            }
        }
        .frame(height: 16)
        .animation(.easeInOut(duration: 0.25), value: current)
        .accessibilityHidden(true)
    }
}

#Preview {
    HomeView().environmentObject(AppSettings())
}

