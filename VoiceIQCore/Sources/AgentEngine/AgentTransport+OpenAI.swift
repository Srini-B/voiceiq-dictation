import Foundation

extension AgentTransport {
    /// OpenAI spreads a session's calls over many machines and only the one
    /// that served the previous call holds the prefix; measured, three of
    /// four calls missed without this. The key pins the session to one
    /// cache. Sent for GPT models on any host: CLIProxyAPI forwards it, and
    /// a host that rejects it gets the plain body on retry.
    var promptCacheKey: String? {
        cachePolicy.sendsPromptCacheKey ? hostState.promptCacheKey : nil
    }

    // MARK: - Chat Completions

    /// `/v1/chat/completions` on OpenAI or a custom endpoint such as
    /// CLIProxyAPI. GPT and Gemini models cache the prefix on their own. A
    /// Claude model on this path (a proxy) needs Anthropic breakpoints,
    /// which proxies accept as `cache_control` on content parts: one on
    /// the system text, which also covers the tools before it, and one on
    /// the last part of the newest message.
    func sendOpenAIChat(_ conversation: AgentConversation) async throws -> AgentReply {
        let (data, root) = try await post(path: "v1/chat/completions") { cacheFields in
            var body = chatBody(conversation, breakpoints: cacheFields && cachePolicy.sendsAnthropicBreakpoints)
            if cacheFields, let cacheKey = promptCacheKey { body["prompt_cache_key"] = cacheKey }
            return body
        }
        guard let choice = (root["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw AgentTransportError.malformed("no choices")
        }
        let text = (message["content"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { item -> AgentToolCall? in
            guard let function = item["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            return AgentToolCall(id: item["id"] as? String ?? UUID().uuidString, name: name,
                                 arguments: Self.parseArguments(function["arguments"]))
        }
        let usage = TokenUsage.fromOpenAI(data)
        record(usage)
        return AgentReply(text: text, toolCalls: calls, usage: usage)
    }

    private func chatBody(_ conversation: AgentConversation, breakpoints: Bool) -> [String: Any] {
        // Plain string system content for hosts that take nothing else; the
        // part form only when a breakpoint has to sit on it.
        let system: Any = breakpoints
            ? [["type": "text", "text": conversation.system, "cache_control": AgentCachePolicy.staticTTL]]
            : conversation.system
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for message in conversation.messages {
            switch message {
            case .user(let content):
                messages.append(["role": "user", "content": Self.chatParts(content)])
            case .assistant(let text, let toolCalls, _, _):
                var item: [String: Any] = ["role": "assistant", "content": text ?? ""]
                if !toolCalls.isEmpty {
                    item["tool_calls"] = toolCalls.map { call in
                        ["id": call.id, "type": "function",
                         "function": ["name": call.name, "arguments": Self.argumentsString(call.arguments)]]
                    }
                }
                messages.append(item)
            case .toolResult(let callID, _, let content):
                let (text, images) = Self.split(content)
                messages.append(["role": "tool", "tool_call_id": callID, "content": text.isEmpty ? "ok" : text])
                // A tool message carries only text here; the picture follows
                // as the user showing it.
                if !images.isEmpty {
                    messages.append(["role": "user", "content": Self.chatParts(images.map { .image(data: $0.0, mimeType: $0.1) })])
                }
            }
        }
        if breakpoints, var last = messages.last {
            // The newest message's last part. A tool message carries a
            // string, which becomes one text part so it can hold the mark.
            var parts = last["content"] as? [[String: Any]] ?? [["type": "text", "text": last["content"] as? String ?? ""]]
            parts[parts.count - 1]["cache_control"] = AgentCachePolicy.movingTTL
            last["content"] = parts
            messages[messages.count - 1] = last
        }
        return [
            "model": endpoint.modelID,
            "messages": messages,
            "tools": conversation.tools.map { tool in
                ["type": "function", "function": ["name": tool.rawValue, "description": tool.description, "parameters": tool.parameters]]
            },
        ]
    }

    private static func chatParts(_ content: [AgentContent]) -> [[String: Any]] {
        content.map { part in
            switch part {
            case .text(let text): return ["type": "text", "text": text]
            case .image(let data, let mimeType): return ["type": "image_url", "image_url": ["url": dataURL(data, mimeType: mimeType)]]
            }
        }
    }

    // MARK: - Responses

    /// `/v1/responses`, the whole conversation every call. `previous_response_id`
    /// would send only the new items, but measured on gpt-4.1-mini it cached
    /// 2 of 16 continuation calls where resending the conversation cached
    /// 28–47 % of input; the stored-context path costs more than it saves.
    func sendOpenAIResponses(_ conversation: AgentConversation) async throws -> AgentReply {
        try await postResponses(conversation, items: Self.responseItems(conversation.messages))
    }

    private func postResponses(_ conversation: AgentConversation, items: [[String: Any]]) async throws -> AgentReply {
        let (data, root) = try await post(path: "v1/responses") { cacheFields in
            var body: [String: Any] = [
                "model": endpoint.modelID,
                "instructions": conversation.system,
                "input": items,
                "tools": conversation.tools.map { tool in
                    ["type": "function", "name": tool.rawValue, "description": tool.description, "parameters": tool.parameters]
                },
            ]
            if cacheFields, let cacheKey = promptCacheKey { body["prompt_cache_key"] = cacheKey }
            return body
        }
        var text: [String] = []
        var calls: [AgentToolCall] = []
        for item in root["output"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "message":
                for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
                    if let value = part["text"] as? String { text.append(value) }
                }
            case "function_call":
                guard let name = item["name"] as? String else { continue }
                calls.append(AgentToolCall(id: item["call_id"] as? String ?? item["id"] as? String ?? UUID().uuidString,
                                           name: name, arguments: Self.parseArguments(item["arguments"])))
            default:
                continue
            }
        }
        let usage = TokenUsage.fromOpenAIResponses(data)
        record(usage)
        let joined = text.joined(separator: "\n")
        return AgentReply(text: joined.isEmpty ? nil : joined, toolCalls: calls, responseID: root["id"] as? String, usage: usage)
    }

    private static func responseItems(_ messages: [AgentMessage]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for message in messages {
            switch message {
            case .user(let content):
                items.append(["role": "user", "content": responseParts(content)])
            case .assistant(let text, let toolCalls, _, _):
                if let text, !text.isEmpty {
                    items.append(["role": "assistant", "content": [["type": "output_text", "text": text]]])
                }
                for call in toolCalls {
                    items.append(["type": "function_call", "call_id": call.id, "name": call.name,
                                  "arguments": argumentsString(call.arguments)])
                }
            case .toolResult(let callID, _, let content):
                let (text, images) = split(content)
                items.append(["type": "function_call_output", "call_id": callID, "output": text.isEmpty ? "ok" : text])
                if !images.isEmpty {
                    items.append(["role": "user", "content": responseParts(images.map { .image(data: $0.0, mimeType: $0.1) })])
                }
            }
        }
        return items
    }

    private static func responseParts(_ content: [AgentContent]) -> [[String: Any]] {
        content.map { part in
            switch part {
            case .text(let text): return ["type": "input_text", "text": text]
            case .image(let data, let mimeType): return ["type": "input_image", "image_url": dataURL(data, mimeType: mimeType)]
            }
        }
    }
}
