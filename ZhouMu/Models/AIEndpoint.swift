import Foundation
import Security
import Combine

enum AIProtocol: String, Codable, CaseIterable {
    case openAI, anthropic
    var label: String { self == .openAI ? "OpenAI Chat Completions" : "Anthropic Messages" }
}

struct AIEndpoint: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "自定义服务"
    var format: AIProtocol = .openAI
    var baseURL = "https://api.openai.com/v1"
    var model = ""

    func requestURL() throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantFailure("请填写 HTTPS API 地址和模型名称；地址不能包含账号、查询参数或片段。")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let suffix = format == .openAI ? "/chat/completions" : "/messages"
        if !path.hasSuffix(suffix) {
            if path.isEmpty { path = "/v1" }
            path += suffix
        }
        components.path = path
        guard let url = components.url else { throw AssistantFailure("API 地址无效。") }
        return url
    }
}

enum AIKeychain {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.ddyec.zhoumu.ai") + ".ai-keys" }
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
    static func read(_ id: UUID) -> String {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ key: String, id: UUID) throws {
        let q = query(id)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(q.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw AssistantFailure("API Key 保存失败，请重试。")
            }
        } else if status != errSecSuccess { throw AssistantFailure("API Key 保存失败，请重试。") }
    }
    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AssistantFailure("删除 API Key 失败。") }
    }
}

final class AIEndpointStore: ObservableObject {
    @Published private(set) var endpoints: [AIEndpoint]
    @Published var selectedID: String { didSet { UserDefaults.standard.set(selectedID, forKey: "ai.selected") } }
    init() {
        endpoints = UserDefaults.standard.data(forKey: "ai.endpoints").flatMap { try? JSONDecoder().decode([AIEndpoint].self, from: $0) } ?? []
        selectedID = UserDefaults.standard.string(forKey: "ai.selected") ?? ""
    }
    var selected: AIEndpoint? { endpoints.first { $0.id.uuidString == selectedID } ?? endpoints.first }
    func save(_ endpoint: AIEndpoint, key: String) throws {
        _ = try endpoint.requestURL()
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantFailure("请输入 API Key。") }
        try AIKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), id: endpoint.id)
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) { endpoints[index] = endpoint }
        else { endpoints.append(endpoint) }
        selectedID = endpoint.id.uuidString
        persist()
    }
    func remove(_ endpoint: AIEndpoint) throws {
        try AIKeychain.delete(endpoint.id)
        endpoints.removeAll { $0.id == endpoint.id }
        if selectedID == endpoint.id.uuidString { selectedID = endpoints.first?.id.uuidString ?? "" }
        persist()
    }
    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(endpoints), forKey: "ai.endpoints") }
}
