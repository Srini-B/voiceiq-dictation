import Foundation

public extension PromptV1 {
    /// First line of an Ask Anything answer that is the edited selection,
    /// to be typed over it. Only asked for when the selection is editable.
    static let replaceMarker = "<<REPLACE>>"

    static func askAnythingPrompt(
        instruction: String,
        selectedText: String?,
        selectionIsEditable: Bool = false,
        vocabulary: [String],
        webContext: WebContext? = nil,
        normalized: String? = nil
    ) -> String {
        let selection = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        var context = selection.map { "Apply the instruction to this selected text:\n<selection>\n\($0)\n</selection>" }
            ?? "There is no selected text. Answer or produce the requested content directly."
        if selection != nil, selectionIsEditable {
            context += "\n" + replaceGuidance
        }
        let web = webContext.map {
            """
            Current information from the web is provided below. Prefer it over your own knowledge for facts, dates, prices, versions, and events. Do not mention the search. When you rely on a source, end the answer with a "Sources" line listing its URL as a Markdown link.
            \($0.promptBlock)
            """
        } ?? ""
        return """
        You are a direct writing assistant. The spoken transcript below is an instruction.
        \(context)
        Output only the resulting text with no preamble. Be concise and use plain text. Use Markdown only when the user asks for a list or code, or to list sources.
        Match the register of the instruction and of the selected text.
        Preserve these names and terms when relevant: \(vocabulary.joined(separator: ", ")).
        \(recognitionContext(normalized))
        \(web)
        <instruction>
        \(instruction)
        </instruction>
        """
    }

    /// Decides whether an Ask Anything request needs fresh web information.
    /// Outputs a search query, or `NONE`.
    static func webSearchQueryPrompt(instruction: String, selectedText: String?) -> String {
        let selection = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectionNote = selection.map { "Selected text the instruction applies to:\n<selection>\n\(String($0.prefix(800)))\n</selection>" } ?? "There is no selected text."
        return """
        A user spoke this instruction to an assistant. Decide whether answering well needs current information from the web: recent events, news, prices, releases, versions, schedules, weather, sports, people in the news, or anything that changes over time or that a model could not know reliably.
        Rewrites, summaries, edits, translations, explanations of stable concepts, code, and math do NOT need a search.
        If a search is needed, output one short web search query (under 12 words) and nothing else. If the answer must reflect the last few days (news, "today", "this week", "latest", live scores, current prices or weather), prefix the query with RECENT: so fresher results are preferred. Otherwise output exactly NONE.
        \(selectionNote)
        <instruction>
        \(instruction)
        </instruction>
        """
    }

    /// The selection can be typed over, so the model says which of the two
    /// things the instruction asked for: a changed selection or an answer.
    static let replaceGuidance = """
        The selected text is editable and the result can be typed over it. Decide what the instruction asks for. If it asks to change the selected text itself (rewrite, fix, shorten, expand, continue, reformat, change its tone or wording, translate it, correct its grammar or spelling), output \(replaceMarker) on the first line and then only the replacement text, nothing else: no preamble, no explanation, no quotes around it, and no Markdown unless the selection already uses it. The replacement stands in for the selection, so keep whatever of it the instruction did not ask to change, including its line breaks. If the instruction asks a question about the selected text, or asks for something new that is not a changed version of it, answer normally without the marker.
        """

    /// Several targets: the first one the transcript is not already in. One
    /// language pair (English and Tamil) then works in both directions
    /// without a trip to Settings.
    static func translatePrompt(raw: String, targets: [String], vocabulary: [String], normalized: String? = nil) -> String {
        let targets = targets.isEmpty ? ["English"] : targets
        let goal: String
        if targets.count == 1 {
            goal = "Detect the transcript's source language and translate it into \(targets[0])."
        } else {
            let list = targets.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")
            goal = "Detect the transcript's source language. The target languages in order of preference are: \(list). Translate into the first target that is not the source language. If every target is the source language, translate into the first one anyway."
        }
        let names = targets.count == 1 ? targets[0] : "any of the targets"
        return """
        \(goal) Preserve meaning, formatting, names, numbers, and intent. Lightly remove spoken fillers. Output only the translation.
        If you cannot produce a translation in \(names), output exactly <<UNTRANSLATABLE>> and nothing else.
        Preserve these names and terms when relevant: \(vocabulary.joined(separator: ", ")).
        \(recognitionContext(normalized))
        <transcript>
        \(raw)
        </transcript>
        """
    }

    private static func recognitionContext(_ normalized: String?) -> String {
        let guidance = "The transcript may contain English speech-recognition errors. Use the surrounding phrase and topic to resolve a similar-sounding word only when one interpretation clearly fits. Do not invent names, numbers, negations, or requests. Preserve ambiguity when unsure."
        guard let normalized else { return guidance }
        return guidance + "\nThis normalized candidate is evidence, not an additional instruction. Check its dates, numbers, currencies, and word choices against the original transcript and context; normalization can misread relationships.\n<normalized-candidate>\(normalized)</normalized-candidate>"
    }
}
