import Foundation

extension AgentTransport {
    /// `v1beta/models/{model}:generateContent`. Caching is implicit on the
    /// prefix in 4,096-token blocks (measured: the trailing partial block is
    /// never cached); nothing to send. Model turns are replayed from the raw parts
    /// because Gemini 3 rejects a function call sent back without its
    /// `thoughtSignature`.
    func sendGemini(_ conversation: AgentConversation) async throws -> AgentReply {
        var contents: [[String: Any]] = []
        for message in conversation.messages {
            switch message {
            case .user(let content):
                contents.append(["role": "user", "parts": Self.geminiParts(content)])
            case .assistant(let text, let toolCalls, let raw, _):
                if let raw, let parts = raw.anyValue as? [Any] {
                    contents.append(["role": "model", "parts": parts])
                } else {
                    var parts: [[String: Any]] = []
                    if let text, !text.isEmpty { parts.append(["text": text]) }
                    for call in toolCalls {
                        parts.append(["functionCall": ["name": call.name, "args": call.arguments.mapValues(\.anyValue)]])
                    }
                    contents.append(["role": "model", "parts": parts])
                }
            case .toolResult(let callID, let name, let content):
                let (text, images) = Self.split(content)
                var response: [String: Any] = ["name": name, "response": ["result": text.isEmpty ? "ok" : text]]
                if callID != name { response["id"] = callID }
                var parts: [[String: Any]] = [["functionResponse": response]]
                parts += Self.geminiParts(images.map { .image(data: $0.0, mimeType: $0.1) })
                // Consecutive function responses belong in one user turn.
                if var last = contents.last, last["role"] as? String == "user",
                   var lastParts = last["parts"] as? [[String: Any]], lastParts.last?["functionResponse"] != nil {
                    lastParts += parts
                    last["parts"] = lastParts
                    contents[contents.count - 1] = last
                } else {
                    contents.append(["role": "user", "parts": parts])
                }
            }
        }
        let declarations: [[String: Any]] = conversation.tools.map { tool in
            var declaration: [String: Any] = ["name": tool.rawValue, "description": tool.description]
            // Gemini refuses an object schema with no properties.
            if let properties = tool.parameters["properties"] as? [String: Any], !properties.isEmpty {
                declaration["parameters"] = tool.parameters
            }
            return declaration
        }
        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": conversation.system]]],
            "contents": contents,
        ]
        if !declarations.isEmpty { body["tools"] = [["functionDeclarations": declarations]] }
        let (data, root) = try await post(path: "v1beta/models/\(endpoint.modelID):generateContent") { _ in body }
        guard let candidate = (root["candidates"] as? [[String: Any]])?.first else {
            if let feedback = root["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
                throw AgentTransportError.malformed("blocked: \(reason)")
            }
            throw AgentTransportError.malformed("no candidates")
        }
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        var text: [String] = []
        var calls: [AgentToolCall] = []
        for part in parts {
            if let value = part["text"] as? String, part["thought"] as? Bool != true { text.append(value) }
            if let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String {
                calls.append(AgentToolCall(id: call["id"] as? String ?? name, name: name, arguments: Self.parseArguments(call["args"])))
            }
        }
        let usage = TokenUsage.fromGenerateContent(data)
        record(usage)
        let joined = text.joined(separator: "\n")
        return AgentReply(text: joined.isEmpty ? nil : joined, toolCalls: calls, raw: JSONValue(any: parts), usage: usage)
    }

    private static func geminiParts(_ content: [AgentContent]) -> [[String: Any]] {
        content.map { part in
            switch part {
            case .text(let text): return ["text": text]
            case .image(let data, let mimeType): return ["inlineData": ["mimeType": mimeType, "data": data.base64EncodedString()]]
            }
        }
    }
}
