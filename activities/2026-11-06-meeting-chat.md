# Questions about a meeting (2026-11-06)

**Why.** The owner asked for a chat at the bottom of every transcribed
meeting: questions answered from the raw transcript and the notes by the
selected writing model, with provider caching across questions, every
earlier answer fed into the next turn, and the chat kept so it can be
continued later.

**Decisions.**
- The request goes through `AgentTransport`, which already renders one
  conversation for Gemini `generateContent`, OpenAI Responses and Anthropic
  Messages and already places each vendor's cache fields. A second
  multi-turn client in `GeminiClient` would have duplicated all three
  adapters. The adapters now send no `tools` list when a conversation has
  none (hosts reject an empty one, and the Anthropic breakpoint code indexed
  the last tool), book usage under a stage the caller picks, and take a
  stable OpenAI cache key.
- `AgentEndpoint.writingModel` is the selected provider's writing model
  without Agent mode's custom provider; `resolve` now calls it for the
  non-custom case with Claude's agent model, so Agent mode is unchanged.
- The meeting goes in the system prompt as the Export Markdown (notes above
  the transcript), so the prefix stays byte-identical across questions and
  the cache holds. Only answered questions are saved (`chat.json`), so a
  saved chat is always whole question and answer pairs.

**Verification.**
- lobsters-mac-mini, VoiceIQCore suite: 147 tests, 0 failures, including
  `MeetingChatTests` (each provider's request: turn order, no tool list,
  cache fields; the chat surviving a reopen). macOS and iOS Simulator builds
  clean.
- Signed and notarized `scripts/release.sh` build installed on the same Mac
  (`spctl`: Notarized Developer ID), Claude provider (claude-sonnet-5-5), on a
  real meeting. All five questions answered from the meeting with times; a
  follow-up resolved "that" from the previous answer; a question the meeting
  does not answer got "The meeting doesn't say". The chat survived quit and
  relaunch.
- Caching, from usage.sqlite (stage `meetingChat`): first question 935 input
  tokens, none cached; later questions read 917 to 1,130 tokens from cache
  with 73 to 377 new, and cost fell from $0.0042 to $0.0009 to $0.0021.
- The live test found the narrow layout hiding a pending question after
  sending from the transcript; fixed (scroll on appear) and confirmed on a
  second signed build. The test chat was then removed from that meeting.
