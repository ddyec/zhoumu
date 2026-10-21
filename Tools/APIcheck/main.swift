import Foundation

func check(_ result: @autoclosure () -> Bool, _ label: String) {
    guard result() else { fatalError(label) }
    print("PASS: \(label)")
}
let context = ScheduleContext(today: "2026-10-21", timeZone: "Asia/Shanghai", startDate: "2026-09-01",
                              cycleWeeks: 3, cyclingEnabled: true, regular: .empty(), evening: .empty())
let openAI = AIEndpoint(name: "test", format: .openAI, baseURL: "https://example.com/v1/", model: "model-test")
let anthropic = AIEndpoint(name: "test", format: .anthropic, baseURL: "https://example.com/v1/messages", model: "model-test")
let conversation = (0..<13).map { AIChatMessage(role: $0 % 2 == 0 ? "user" : "assistant", content: "test") }
let request = try AIClient.makeRequest(endpoint: openAI, key: "fixture-key", context: context, history: conversation)
check(request.url?.absoluteString == "https://example.com/v1/chat/completions", "OpenAI URL")
check(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key", "OpenAI Bearer")
check(request.value(forHTTPHeaderField: "x-api-key") == nil, "OpenAI does not use Anthropic header")
let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
let messages = json["messages"] as! [[String: String]]
check(messages.first?["role"] == "system", "OpenAI system message")
check(messages.dropFirst().first?["role"] == "user", "Truncated history starts at user")
let aRequest = try AIClient.makeRequest(endpoint: anthropic, key: "fixture-key", context: context, history: conversation)
check(aRequest.url?.absoluteString == "https://example.com/v1/messages", "Anthropic full URL not duplicated")
check(aRequest.value(forHTTPHeaderField: "x-api-key") == "fixture-key", "Anthropic key header")
check(aRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Anthropic API version")
let aJSON = try JSONSerialization.jsonObject(with: aRequest.httpBody!) as! [String: Any]
check(aJSON["system"] is String && aJSON["max_tokens"] as? Int == 8192, "Anthropic system and max_tokens")
check((aJSON["messages"] as? [[String: String]])?.first?["role"] == "user", "Anthropic conversation starts at user")
let responseText = "{\"message\":\"请问需要调整到哪一天？\",\"actions\":[]}"
let oData = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": responseText]]]])
let oPlan = try AIClient.decode(oData, format: .openAI, context: context)
check(oPlan.actions.isEmpty, "OpenAI clarification fixture")
let aData = try JSONSerialization.data(withJSONObject: ["stop_reason": "end_turn", "content": [["type": "text", "text": "```json\n" + responseText + "\n```"]]])
let aPlan = try AIClient.decode(aData, format: .anthropic, context: context)
check(aPlan.message == oPlan.message, "Anthropic text block and fenced JSON fixture")
var invalid = openAI
invalid.baseURL = "http://example.com/v1"
do { _ = try invalid.requestURL(); fatalError("HTTP URL accepted") } catch { print("PASS: reject HTTP before sending Key") }
invalid.baseURL = "https://example.com/v1?key=secret"
do { _ = try invalid.requestURL(); fatalError("Query URL accepted") } catch { print("PASS: reject query-string credentials") }
let incomplete = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "length", "message": ["content": responseText]]]])
do { _ = try AIClient.decode(incomplete, format: .openAI, context: context); fatalError("Truncated response accepted") }
catch { print("PASS: reject truncated response") }
print("All API format checks passed")
