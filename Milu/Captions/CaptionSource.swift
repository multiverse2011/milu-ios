import Foundation
import os

/// ライブの字幕 (3.5.2)。`api/services/<id>/captions` のフレームを読み、`CaptionFrameReader` に渡す。
/// 映像をリクエストし直したら、こちらも作り直す。
@MainActor
final class CaptionSource {
    private static let logger = Logger(subsystem: "com.ayushio.milu", category: "playback")

    private let baseURL: URL
    private let token: String?
    private let serviceID: Int64
    private let codec: String
    private let audioID: String?
    /// 映像の応答が返した段 (`X-Denpa-Rung`)。映像が段を渡していなければ nil
    private let rung: String?
    private let onFrame: (CaptionFrame) -> Void
    private var task: Task<Void, Never>?

    init(
        baseURL: URL,
        token: String?,
        serviceID: Int64,
        codec: String,
        audioID: String?,
        rung: String?,
        onFrame: @escaping (CaptionFrame) -> Void
    ) {
        self.baseURL = baseURL
        self.token = token
        self.serviceID = serviceID
        self.codec = codec
        self.audioID = audioID
        self.rung = rung
        self.onFrame = onFrame
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// 映像と同じ codec・audio・rung を渡す。違うと別のストリームの時刻になる (api.md)。
    /// `rung` は映像の応答の `X-Denpa-Rung`。無ければ付けない (design.md 3.5.2)
    nonisolated static func url(baseURL: URL, serviceID: Int64, codec: String, audioID: String?, rung: String?) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appending(path: "api/services/\(serviceID)/captions"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        var items = [URLQueryItem(name: "codec", value: codec)]
        if let audioID { items.append(URLQueryItem(name: "audio", value: audioID)) }
        if let rung { items.append(URLQueryItem(name: "rung", value: rung)) }
        components.queryItems = items
        return components.url
    }

    private func run() async {
        guard !DemoServer.isDemo(baseURL) else { return }
        guard let url = Self.url(baseURL: baseURL, serviceID: serviceID, codec: codec, audioID: audioID, rung: rung) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                Self.logger.info("captions closed status=\(status, privacy: .public)")
                return
            }
            var reader = CaptionFrameReader()
            for try await byte in bytes {
                if Task.isCancelled { return }
                for frame in reader.append([byte]) {
                    onFrame(frame)
                }
            }
        } catch is CancellationError {
            // 映像を開き直した
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            Self.logger.info("captions failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
