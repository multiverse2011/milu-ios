import Foundation
@testable import Milu

/// テスト用の通信。届いた要求を覚えておく。
nonisolated final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let lock = NSLock()
    private var handler: Handler
    private var stored: [URLRequest] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { stored.append(request) }
        return try await handler(request)
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

nonisolated final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

nonisolated func reply(_ request: URLRequest, _ status: Int, _ body: String = "") -> (Data, HTTPURLResponse) {
    (
        Data(body.utf8),
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
}

nonisolated final class StubTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [URL: String]

    init(_ tokens: [URL: String] = [:]) {
        self.tokens = tokens
    }

    func load(for url: URL) -> String? {
        lock.withLock { tokens[url] }
    }

    func save(_ token: String, for url: URL) {
        lock.withLock { tokens[url] = token }
    }

    func delete(for url: URL) {
        lock.withLock { _ = tokens.removeValue(forKey: url) }
    }

    var saved: [URL: String] {
        lock.withLock { tokens }
    }
}

nonisolated final class StubSSETransport: SSETransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> SSEStream
    private let lock = NSLock()
    private var handler: Handler
    private var stored: [URLRequest] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func stream(for request: URLRequest) async throws -> SSEStream {
        lock.withLock { stored.append(request) }
        return try await handler(request)
    }

    var requests: [URLRequest] {
        lock.withLock { stored }
    }
}

nonisolated func sseStream(_ status: Int, _ lines: [String]) -> SSEStream {
    SSEStream(status: status, lines: AsyncThrowingStream { continuation in
        for line in lines { continuation.yield(line) }
        continuation.finish()
    })
}
