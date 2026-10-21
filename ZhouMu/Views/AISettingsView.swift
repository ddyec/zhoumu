import SwiftUI

struct AISettingsView: View {
    @ObservedObject var store: AIEndpointStore
    @State private var editing: AIEndpoint?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(store.endpoints) { endpoint in
                    HStack {
                        Button {
                            store.selectedID = endpoint.id.uuidString
                        } label: {
                            Label(endpoint.name, systemImage: store.selected?.id == endpoint.id ? "checkmark.circle.fill" : "circle")
                        }
                        Spacer()
                        Button("编辑") { editing = endpoint }.buttonStyle(.borderless)
                    }
                }
                .onDelete { indices in
                    do { for index in indices.sorted(by: >) { try store.remove(store.endpoints[index]) } }
                    catch { self.error = error.localizedDescription }
                }
                Button("添加 API 服务", systemImage: "plus") { editing = AIEndpoint() }
            } header: { Text("服务与模型") } footer: {
                Text("仅在发送消息时，将课表和当前会话发送给所选服务。API Key 保存在此设备钥匙串中，不会写入课表、代码或构建产物。左滑可删除服务。")
            }
        }
        .navigationTitle("AI 服务")
        .sheet(item: $editing) { endpoint in AIEndpointEditor(store: store, endpoint: endpoint) }
        .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct AIEndpointEditor: View {
    @ObservedObject var store: AIEndpointStore
    @Environment(\.dismiss) private var dismiss
    @State var endpoint: AIEndpoint
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("服务名称", text: $endpoint.name)
                Picker("API 格式", selection: $endpoint.format) {
                    ForEach(AIProtocol.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("HTTPS Base URL 或完整端点", text: $endpoint.baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("模型 ID（按服务商提供的名称填写）", text: $endpoint.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("地址示例：https://api.openai.com/v1 或 https://api.anthropic.com/v1。兼容服务可填自己的地址；自动补全 chat/completions 或 messages。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("配置服务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try store.save(endpoint, key: key); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .onAppear { key = AIKeychain.read(endpoint.id) }
        }
    }
}
