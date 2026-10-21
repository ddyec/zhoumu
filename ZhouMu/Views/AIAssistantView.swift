import SwiftUI

struct AIAssistantView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var services = AIEndpointStore()
    @State private var input = ""
    @State private var history: [AIChatMessage] = []
    @State private var messages: [String] = []
    @State private var pending: SchedulePlan?
    @State private var proposalContext: ScheduleContext?
    @State private var undoBefore: ScheduleContext?
    @State private var undoAfter: ScheduleContext?
    @State private var busy = false
    @State private var error: String?
    @State private var requestTask: Task<Void, Never>?

    private var context: ScheduleContext {
        ScheduleContext(today: ScheduleDate.key(Date()), timeZone: SemesterCalculator.calendar.timeZone.identifier,
                        startDate: ScheduleDate.key(settings.startDate), cycleWeeks: settings.cycleWeeks,
                        cyclingEnabled: settings.cyclingEnabled, regular: settings.regular, evening: settings.evening)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("告诉我你想怎样调整课表")
                        .font(.title2.bold())
                    Text("例如：明天第 2 节和第 4 节互换；下周三全天调休；明天 15:00–16:00 安排班会。临时调整只对指定日期生效。")
                        .foregroundStyle(.secondary)
                    NavigationLink { AISettingsView(store: services) } label: {
                        Label(services.selected.map { "当前服务：\($0.name) · \($0.model)" } ?? "先添加 API 服务", systemImage: "server.rack")
                    }
                    NavigationLink("查看 / 撤销指定日期的临时安排") { TemporaryScheduleView() }
                    Text("发送后，完整课表、学期设置和本次会话将发往所选 API 服务。AI 先提出方案，由你查看后应用。未设置时间的课程无法校验时间冲突。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(Array(messages.enumerated()), id: \.offset) { item in
                        Text(item.element).textSelection(.enabled)
                            .padding().frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if busy { ProgressView("正在分析课表…") }
                    if let plan = pending, let source = proposalContext, !plan.actions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("待确认方案 · \(plan.actions.count) 处调整").font(.headline)
                            ForEach(Array(plan.actions.enumerated()), id: \.offset) { item in
                                Text(source.preview(item.element)).font(.subheadline)
                                Divider()
                            }
                            Text("请检查所有日期、课程和时间。应用会覆盖上面列出的目标格，仅影响这些日期。")
                                .font(.footnote).foregroundStyle(.secondary)
                            HStack {
                                Button("应用方案") { apply(plan, source: source) }.buttonStyle(.borderedProminent)
                                Button("放弃", role: .cancel) { pending = nil; history = []; messages.append("已放弃方案，课表未改动。") }
                            }
                        }.padding().background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if undoBefore != nil { Button("撤销上次应用", role: .destructive) { undo() }.disabled(busy) }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }.padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    TextField("输入调课或临时安排…", text: $input, axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.roundedBorder).disabled(busy)
                    HStack {
                        if busy {
                            Button("取消请求") { requestTask?.cancel() }
                        } else {
                            Button("发送", systemImage: "arrow.up.circle.fill") { send() }
                                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || services.selected == nil)
                        }
                        Spacer()
                        Button("清空会话") { history = []; messages = []; pending = nil; error = nil }.disabled(busy)
                    }
                }.padding().background(.regularMaterial)
            }
            .navigationTitle("AI 排课助理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onDisappear { requestTask?.cancel() }
        }
    }

    private func send() {
        guard let endpoint = services.selected else { return }
        let key = AIKeychain.read(endpoint.id)
        guard !key.isEmpty else { error = "无法读取 API Key，请编辑服务后重新保存。"; return }
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = context
        history.append(AIChatMessage(role: "user", content: prompt))
        messages.append("你：" + prompt)
        let requestHistory = history
        input = ""; error = nil; pending = nil; busy = true
        requestTask = Task { @MainActor in
            defer { busy = false; requestTask = nil }
            do {
                let plan = try await AIClient.propose(endpoint: endpoint, key: key, context: source, history: requestHistory)
                try Task.checkCancellation()
                guard context == source else { throw AssistantFailure("请求期间课表或日期发生变化，请重新发送。") }
                let encoded = try JSONEncoder().encode(plan)
                history.append(AIChatMessage(role: "assistant", content: String(decoding: encoded, as: UTF8.self)))
                messages.append("助理：" + plan.message)
                pending = plan; proposalContext = source
            } catch {
                // 移除失败请求，保证 Anthropic 的 user / assistant 交替。
                if history.last?.role == "user" { history.removeLast() }
                self.error = Task.isCancelled ? "请求已取消，课表未修改。" : error.localizedDescription
            }
        }
    }

    private func apply(_ plan: SchedulePlan, source: ScheduleContext) {
        do {
            guard context == source else { throw AssistantFailure("课表已发生变化，请重新生成方案。") }
            let updated = try source.applying(plan)
            settings.regular = updated.regular
            settings.evening = updated.evening
            undoBefore = source; undoAfter = updated
            pending = nil; history = []
            messages.append("已应用 \(plan.actions.count) 处临时安排。")
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func undo() {
        guard let before = undoBefore, let after = undoAfter else { return }
        guard context.regular == after.regular, context.evening == after.evening else {
            error = "课表在应用后又有修改。请到临时安排列表撤销对应日期，避免覆盖新改动。"; return
        }
        settings.regular = before.regular; settings.evening = before.evening
        undoBefore = nil; undoAfter = nil; pending = nil; history = []
        messages.append("已撤销上次应用。"); error = nil
    }
}

private struct TemporaryScheduleView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var restoring: String?
    private var dates: [String] {
        Set(settings.regular.dateOverrides.keys).union(settings.evening.dateOverrides.keys).sorted()
    }
    var body: some View {
        List {
            if dates.isEmpty { Text("暂无临时安排") }
            ForEach(dates, id: \.self) { date in
                Section(date) {
                    ForEach(ScheduleKind.allCases, id: \.self) { kind in
                        let changes = settings.table(kind).dateOverrides[date] ?? [:]
                        ForEach(changes.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }, id: \.self) { period in
                            if let change = changes[period] {
                                Text("\(kind.label) 第\(period)节：\(change.subject.isEmpty ? "停课 / 休息" : change.subject)")
                            }
                        }
                    }
                    Button("恢复当天常规课表", role: .destructive) { restoring = date }
                }
            }
        }
        .navigationTitle("临时安排")
        .confirmationDialog("恢复当天常规课表？", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible) {
            Button("恢复 \(restoring ?? "")", role: .destructive) {
                guard let date = restoring else { return }
                var regular = settings.regular; var evening = settings.evening
                regular.dateOverrides.removeValue(forKey: date); evening.dateOverrides.removeValue(forKey: date)
                settings.regular = regular; settings.evening = evening; restoring = nil
            }
        } message: { Text("移除此日期的全部临时修改，并重新使用常规循环课表。") }
    }
}
