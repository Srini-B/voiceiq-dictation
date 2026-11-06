import Foundation

extension AgentTransport {
    /// `/v1/messages`. Cache breakpoints: after the tool list and after
    /// the system prompt with the one-hour TTL, and on the last block of
    /// the newest turn with the five-minute one. Anthropic looks back from
    /// each breakpoint for the longest cached prefix, so the moving third
    /// one reads the previous call's write, and a user who returns after a
    /// pause still reads the static prefix.
    func sendAnthropic(_ conversation: AgentConversation) async throws -> AgentReply {
        let (data, root) = try await post(path: "v1/messages") { cacheFields in
            anthropicBody(conversation, breakpoints: cacheFields)
        }
        guard let blocks = root["content"] as? [[String: Any]] else { throw AgentTransportError.malformed("no content") }
        var text: [String] = []
        var calls: [AgentToolCall] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let value = block["text"] as? String { text.append(value) }
            case "tool_use":
                guard let name = block["name"] as? String else { continue }
                calls.append(AgentToolCall(id: block["id"] as? String ?? UUID().uuidString, name: name,
                                           arguments: Self.parseArguments(block["input"])))
            default:
                continue
            }
        }
        let usage = TokenUsage.fromAnthropic(data)
        record(usage)
        let joined = text.joined(separator: "\n")
        return AgentReply(text: joined.isEmpty ? nil : joined, toolCalls: calls, raw: JSONValue(any: blocks), usage: usage)
    }

    private func anthropicBody(_ conversation: AgentConversation, breakpoints: Bool) -> [String: Any] {
        var messages: [[String: Any]] = []
        for message in conversation.messages {
            switch message {
            case .user(let content):
                messages.append(["role": "user", "content": Self.anthropicParts(content)])
            case .assistant(let text, let toolCalls, let raw, _):
                if let raw, let blocks = raw.anyValue as? [Any] {
                    messages.append(["role": "assistant", "content": blocks])
                } else {
                    var blocks: [[String: Any]] = []
                    if let text, !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                    for call in toolCalls {
                        blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": call.arguments.mapValues(\.anyValue)])
                    }
                    messages.append(["role": "assistant", "content": blocks])
                }
            case .toolResult(let callID, _, let content):
                let block: [String: Any] = ["type": "tool_result", "tool_use_id": callID, "content": Self.anthropicParts(content)]
                // Consecutive tool results belong in one user message.
                if var last = messages.last, last["role"] as? String == "user",
                   var blocks = last["content"] as? [[String: Any]], blocks.last?["type"] as? String == "tool_result" {
                    blocks.append(block)
                    last["content"] = blocks
                    messages[messages.count - 1] = last
                } else {
                    messages.append(["role": "user", "content": [block]])
                }
            }
        }
        var tools: [[String: Any]] = conversation.tools.map { tool in
            ["name": tool.rawValue, "description": tool.description, "input_schema": tool.parameters]
        }
        var system: [String: Any] = ["type": "text", "text": conversation.system]
        if breakpoints {
            if !tools.isEmpty { tools[tools.count - 1]["cache_control"] = AgentCachePolicy.staticTTL }
            system["cache_control"] = AgentCachePolicy.staticTTL
            if var last = messages.last, var blocks = last["content"] as? [[String: Any]], !blocks.isEmpty {
                blocks[blocks.count - 1]["cache_control"] = AgentCachePolicy.movingTTL
                last["content"] = blocks
                messages[messages.count - 1] = last
            }
        }
        var body: [String: Any] = [
            "model": endpoint.modelID,
            "max_tokens": 4096,
            "system": [system],
            "messages": messages,
        ]
        // A conversation without tools (a meeting chat) sends no list: hosts
        // reject an empty one.
        if !tools.isEmpty { body["tools"] = tools }
        return body
    }

    private static func anthropicParts(_ content: [AgentContent]) -> [[String: Any]] {
        content.map { part in
            switch part {
            case .text(let text): return ["type": "text", "text": text]
            case .image(let data, let mimeType):
                return ["type": "image", "source": ["type": "base64", "media_type": mimeType, "data": data.base64EncodedString()]]
            }
        }
    }
}
