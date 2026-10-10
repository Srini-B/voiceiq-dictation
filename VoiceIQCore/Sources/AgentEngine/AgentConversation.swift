import Foundation

/// A piece of a message: words or a picture.
public enum AgentContent: Equatable, Sendable {
    case text(String)
    case image(data: Data, mimeType: String)

    public var isImage: Bool { if case .image = self { return true }; return false }
}

/// One message in host-neutral form. Each transport renders it in its
/// host's shape and keeps anything the host must see again (`raw`).
public enum AgentMessage: Equatable, Sendable {
    case user([AgentContent])
    /// `raw` is the host's own copy of the turn (Gemini parts with thought
    /// signatures, Anthropic content blocks with thinking), replayed
    /// verbatim because those hosts reject a rebuilt turn. `responseID` is
    /// OpenAI Responses' handle for `previous_response_id`.
    case assistant(text: String?, toolCalls: [AgentToolCall], raw: JSONValue?, responseID: String?)
    /// What a tool returned. Images ride along for hosts that take them in
    /// a tool result and become a following user message elsewhere.
    case toolResult(callID: String, name: String, content: [AgentContent])
}

/// The model's context for one session: the fixed prefix, then the
/// append-only turns. Images are the only thing ever removed, and only
/// in batches, so the cached prefix survives most calls.
public struct AgentConversation: Equatable, Sendable {
    public var system: String
    /// The tools offered on every call. Fixed for the session, like `system`.
    public var tools: [AgentTool]
    public var messages: [AgentMessage]

    public init(system: String, tools: [AgentTool] = AgentTool.allCases, messages: [AgentMessage] = []) {
        self.system = system
        self.tools = tools
        self.messages = messages
    }

    public mutating func append(_ message: AgentMessage) {
        messages.append(message)
        pruneImages()
    }

    /// Images kept at the tail. Pruning waits until two extra have
    /// accumulated, so the prefix changes every third screenshot rather
    /// than every one.
    static let imagesKept = 3
    static let imagesBeforePrune = 5

    public var imageCount: Int {
        messages.reduce(0) { count, message in
            switch message {
            case .user(let content), .toolResult(_, _, let content): return count + content.filter(\.isImage).count
            case .assistant: return count
            }
        }
    }

    private mutating func pruneImages() {
        guard imageCount > Self.imagesBeforePrune else { return }
        var toDrop = imageCount - Self.imagesKept
        for index in messages.indices where toDrop > 0 {
            switch messages[index] {
            case .user(let content):
                let (kept, dropped) = Self.dropImages(content, upTo: toDrop)
                messages[index] = .user(kept)
                toDrop -= dropped
            case .toolResult(let callID, let name, let content):
                let (kept, dropped) = Self.dropImages(content, upTo: toDrop)
                messages[index] = .toolResult(callID: callID, name: name, content: kept)
                toDrop -= dropped
            case .assistant:
                continue
            }
        }
    }

    private static func dropImages(_ content: [AgentContent], upTo limit: Int) -> (kept: [AgentContent], dropped: Int) {
        var dropped = 0
        let kept = content.map { part -> AgentContent in
            guard part.isImage, dropped < limit else { return part }
            dropped += 1
            return .text("[earlier screenshot removed]")
        }
        return (kept, dropped)
    }
}

/// What the host answered.
public struct AgentReply: Equatable, Sendable {
    public var text: String?
    public var toolCalls: [AgentToolCall]
    public var raw: JSONValue?
    public var responseID: String?
    public var usage: TokenUsage?

    public init(text: String?, toolCalls: [AgentToolCall], raw: JSONValue? = nil, responseID: String? = nil, usage: TokenUsage? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.raw = raw
        self.responseID = responseID
        self.usage = usage
    }

    public var asMessage: AgentMessage {
        .assistant(text: text, toolCalls: toolCalls, raw: raw, responseID: responseID)
    }
}

public enum AgentPrompt {
    /// Byte-identical on every call of a session, so hosts can cache it.
    public static let system = """
    You are VoiceiQ Agent, operating the user's Mac on their behalf. The user speaks a command; you see the screen and act with the tools.

    Rules:
    1. Always start from the observation you were given. For questions like "what am I looking at" or "explain this", answer from the screen. For general questions, check whether the screen is relevant (a document, a problem, code, a chart) and anchor the answer to it when it is; otherwise answer generally. Never answer a question about the screen from memory.
    2. Prefer element ids over coordinates. Use click_at only when no element matches, and take the point from the screenshot.
    3. Every action result carries a fresh observation of the screen. Read it before the next decision; do not assume an action worked. If the screen is still loading or has not changed yet, call wait, then read the new observation. Call observe when you need another look.
    4. Keep thoughts short. Before a tool call, say in one sentence what you are about to do and why.
    5. Never send messages, pay, delete, share, log in, accept terms, or solve CAPTCHAs without the user's explicit instruction in this session. If the task needs such a step, stop and explain with answer.
    6. Work before you ask. When the screen does not give you what a question needs, gather it yourself: open the app or window, scroll, use web_search and fetch_page when they are offered. Run several tool calls before answering; ask the user for more only when no tool can get it. Never say that you could have looked something up: look it up.
    7. If something cannot be done after two different attempts, stop and tell the user with answer, and say what you tried.
    8. Finish a task with done and a one-line summary. Finish a question with answer. Both end the turn.
    9. The Dock may be hidden or on any edge, menu bars may be hidden, and windows may be anywhere. Trust the observation, not assumptions about a default Mac.
    10. VoiceiQ's own panel (the one showing this transcript) is never the target. Act on the other apps.
    11. The user cannot see your tool calls as code; the transcript shows your sentences and the action names. Write for a person.
    12. Spoken commands may contain English recognition errors. Use neighboring words, the whole request, and the observed screen to resolve a similar-sounding word only when its intended meaning is clear. Normalized numbers and dates are suggestions, not proof. Never guess names, amounts, negations, or authorization for an action. Ask when ambiguity changes what you would do.

    Answers use short plain prose. Markdown headings and lists are fine for longer explanations. Never write an em dash or an en dash; use a comma, a colon, a period, or parentheses instead.
    """
}
