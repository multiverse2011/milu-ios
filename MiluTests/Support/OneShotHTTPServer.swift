import Foundation
import Network

/// 1 回だけ応える 127.0.0.1 の HTTP サーバ。ヘッダと中身の頭の数バイトを先に送り、`bodyDelay` 秒あとに残りを送る
/// (StreamLoader の pacing が 0.5 秒ごとに走るのを、中身が揃う前に通すため。
/// URLSession は中身が 1 バイトも来ないうちは応答を delegate に渡さないので、頭を少しだけ先に送る)
nonisolated final class OneShotHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "one-shot-http")
    private(set) var port: UInt16 = 0

    init(headers: [String: String], body: Data, bodyDelay: Double) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                var head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                for (name, value) in headers { head += "\(name): \(value)\r\n" }
                head += "\r\n"
                let lead = 4  // 箱の大きさの途中まで。demux はまだ何も出さない
                connection.send(content: Data(head.utf8) + body.prefix(lead), completion: .contentProcessed { _ in
                    queue.asyncAfter(deadline: .now() + bodyDelay) {
                        connection.send(content: body.dropFirst(lead), completion: .contentProcessed { _ in })
                    }
                })
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/api/recordings/1/stream")! }

    func stop() { listener.cancel() }
}
