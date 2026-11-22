import Network
import XCTest
@testable import VoiceIQCore

/// The model-request transport: a connection lost before any response gets
/// one immediate attempt on a new connection, every attempt carries the same
/// client request ID, and every attempt is written to transport.jsonl.
final class TransportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TransportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileLayout.overrideRoot = root
    }

    override func tearDownWithError() throws {
        FileLayout.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testLostConnectionRetriesOnceOnANewConnection() async throws {
        let server = try ScriptedServer(dropFirst: 1)
        defer { server.stop() }
        let client = GeminiClient(apiKey: { "test" })

        let data = try await client.post(path: "v1beta/models/m:generateContent", body: Data("{}".utf8),
                                         endpoint: server.url, deadline: 10, modelLabel: "m", stage: .transcribe)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), ScriptedServer.okBody)
        let requests = server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests[0].connection, requests[1].connection, "the retry must not reuse the lost connection")
        let ids = requests.compactMap { $0.headers["x-client-request-id"] }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 1, "both attempts are one logical request")

        TransportLog.flush()
        let events = try transportEvents()
        XCTAssertEqual(events.map(\.attempt), [1, 2])
        XCTAssertEqual(events.map(\.outcome), ["connection_lost", "ok"])
        XCTAssertEqual(Set(events.map(\.requestID)), Set(ids))
        XCTAssertEqual(events.last?.status, 200)
    }

    func testTwoLostConnectionsReportOffline() async throws {
        let server = try ScriptedServer(dropFirst: 2)
        defer { server.stop() }
        let client = GeminiClient(apiKey: { "test" })

        do {
            _ = try await client.post(path: "x", body: Data("{}".utf8), endpoint: server.url, deadline: 10,
                                      modelLabel: "m", stage: .transcribe)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .offline)
        }
        XCTAssertEqual(server.requests.count, 2, "exactly one retry")
    }

    func testEveryRequestOpensItsOwnConnection() async throws {
        let server = try ScriptedServer(dropFirst: 0)
        defer { server.stop() }
        let client = GeminiClient(apiKey: { "test" })
        for _ in 0..<2 {
            _ = try await client.post(path: "x", body: Data("{}".utf8), endpoint: server.url, deadline: 10,
                                      modelLabel: "m", stage: .cleanup)
        }
        let requests = server.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests[0].connection, requests[1].connection, "no pooled connection is reused")
        TransportLog.flush()
        XCTAssertEqual(try transportEvents().compactMap(\.reusedConnection), [false, false])
    }

    private func transportEvents() throws -> [TransportEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: TransportLog.fileURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(TransportEvent.self, from: Data($0.utf8)) }
    }
}

/// A local HTTP/1.1 server that reads each request, then closes the first
/// `dropFirst` connections without answering (the client sees -1005) and
/// answers the rest with 200 and `reply`.
final class ScriptedServer: @unchecked Sendable {
    static let okBody = #"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#

    struct Request {
        let connection: Int
        let headers: [String: String]
        let body: Data

        var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "scripted-server")
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var dropsLeft: Int
    private let reply: String
    private var connectionCount = 0
    private(set) var url: URL!

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }

    init(dropFirst: Int = 0, reply: String = ScriptedServer.okBody) throws {
        dropsLeft = dropFirst
        self.reply = reply
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw URLError(.cannotConnectToHost)
        }
        url = URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        lock.lock(); connectionCount += 1; let number = connectionCount; lock.unlock()
        connection.start(queue: queue)
        read(connection, number: number, buffer: Data())
    }

    private func read(_ connection: NWConnection, number: Int, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let (headers, body) = Self.parse(buffer) {
                self.respond(connection, number: number, headers: headers, body: body)
            } else if !done, error == nil {
                self.read(connection, number: number, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, number: Int, headers: [String: String], body: Data) {
        lock.lock()
        recorded.append(Request(connection: number, headers: headers, body: body))
        let drop = dropsLeft > 0
        if drop { dropsLeft -= 1 }
        lock.unlock()
        if drop {
            connection.forceCancel()
            return
        }
        let body = Data(reply.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in })
    }

    /// Headers (lowercased names) and body once the whole request is in.
    private static func parse(_ buffer: Data) -> ([String: String], Data)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        var headers: [String: String] = [:]
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.count - end.upperBound >= length else { return nil }
        return (headers, Data(buffer[end.upperBound..<(end.upperBound + length)]))
    }
}
