import CryptoKit
import Foundation

/// The dictation prompt up to `PromptV1.cacheBoundary` (rules, Dictionary,
/// examples) is the same for every dictation until a setting or the
/// Dictionary changes. Gemini's implicit cache kept only about 4.7k of its
/// 6.7k tokens, so each call read the rest again; an explicit cache of the
/// whole part answered about 0.5 s sooner at the median (2026-11-26).
///
/// The first dictation with a new prefix goes out whole and creates the
/// cache beside it; later ones use the cache for its hour, then one goes out
/// whole again and makes the next. A cache Gemini refuses is forgotten and
/// the call goes out whole, so the cache can only make a dictation faster,
/// never fail it.
actor GeminiPromptCache {
    static let shared = GeminiPromptCache()

    /// How long Gemini keeps a cache.
    static let lifetime: TimeInterval = 3600

    private struct Entry {
        var name: String
        var expires: Date
    }

    private var entries: [String: Entry] = [:]
    private var creating: Set<String> = []
    /// After a failed creation (a key without caching, an outage), the
    /// next tries wait this long so each dictation does not pay a request.
    private var failedAt: [String: Date] = [:]
    static let retryAfterFailure: TimeInterval = 600

    static func key(prefix: String, model: String, endpoint: URL) -> String {
        let digest = SHA256.hash(data: Data("\(endpoint.absoluteString)\n\(model)\n\(prefix)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A cache that will outlive this dictation, or nil.
    func name(for key: String) -> String? {
        guard let entry = entries[key], entry.expires > Date().addingTimeInterval(120) else { return nil }
        return entry.name
    }

    /// Claims the creation of `key`'s cache; false when one is already being made.
    func startCreating(_ key: String) -> Bool {
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < Self.retryAfterFailure { return false }
        return creating.insert(key).inserted
    }

    func finishCreating(_ key: String, name: String?) {
        creating.remove(key)
        if let name {
            entries[key] = Entry(name: name, expires: Date().addingTimeInterval(Self.lifetime))
            failedAt[key] = nil
        } else {
            failedAt[key] = Date()
        }
    }

    func forget(_ key: String) {
        entries[key] = nil
    }
}

extension GeminiClient {
    /// Sends `body` (whose `contents` hold only the part of the prompt after
    /// the boundary) against the cached `prefix` when a cache is ready, and
    /// nil when it is not, after starting one for the next dictation.
    func generateWithPromptCache(prefix: String, body: [String: Any], model: String, endpoint: URL,
                                 deadline: TimeInterval, stage: UsageStage) async throws -> String? {
        let cache = GeminiPromptCache.shared
        let key = GeminiPromptCache.key(prefix: prefix, model: model, endpoint: endpoint)
        guard let name = await cache.name(for: key) else {
            if await cache.startCreating(key) {
                Task.detached { [self] in
                    let created = try? await createPromptCache(prefix: prefix, model: model, endpoint: endpoint)
                    await cache.finishCreating(key, name: created)
                }
            }
            return nil
        }
        var cached = body
        cached["cachedContent"] = name
        do {
            return try await generateContent(body: cached, model: model, endpoint: endpoint,
                                             deadline: deadline, stage: stage)
        } catch TranscriptionError.badRequest, TranscriptionError.modelUnavailable {
            // Gone (expired early, deleted, or the key changed): the whole
            // prompt goes out instead.
            Log.transcription.notice("prompt cache refused; sending the whole prompt")
            await cache.forget(key)
            return nil
        }
    }

    private func createPromptCache(prefix: String, model: String, endpoint: URL) async throws -> String? {
        let body: [String: Any] = [
            "model": "models/\(model)",
            "ttl": "\(Int(GeminiPromptCache.lifetime))s",
            "contents": [["role": "user", "parts": [["text": prefix]]]],
        ]
        let data = try await post(path: "v1beta/cachedContents", body: try JSONSerialization.data(withJSONObject: body),
                                  endpoint: endpoint, deadline: 30, modelLabel: model, modelIsInPath: false,
                                  stage: .cleanup)
        let name = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["name"] as? String
        Log.transcription.notice("prompt cache created: \(name ?? "no name", privacy: .public)")
        return name
    }

}
