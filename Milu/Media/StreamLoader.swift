import Foundation
import os

/// ストリームの失敗。`status` が nil なら通信のエラー。
nonisolated struct StreamFailure: Equatable, Sendable {
    var status: Int?
    var message: String?
    var errorCode: String?

    var isNetwork: Bool { status == nil }
}

/// ライブ・録画・追っかけの fMP4 を読み、demux したものを `media` の列で渡す (3.2・D11)。
/// 録画・追っかけでは、溜まりが多すぎるときだけ `task.suspend()` する (ライブは止めない)。
nonisolated final class StreamLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Mode: Sendable {
        case live
        case buffered
    }

    private static let logger = Logger(subsystem: "com.ayushio.milu", category: "playback")
    private static let overAhead: Double = 30
    private static let underAhead: Double = 20
    private static let overBytes = 64 * 1024 * 1024

    let url: URL
    private let mode: Mode
    private let token: String?
    /// `media` の列でだけ呼ぶ。いまの再生位置より先にどれだけ溜まっているか (秒)
    private let pace: @Sendable () -> Double
    private let demuxer = FMP4Demuxer()

    var onResponse: (@Sendable (String?, String?) -> Void)?
    var onInitialization: (@Sendable ([FMP4Track]) -> Void)?
    var onSamples: (@Sendable ([FMP4Sample]) -> Void)?
    var onFailure: (@Sendable (StreamFailure) -> Void)?
    /// 200 のまま閉じたとき。`true` なら中身が 1 つも来ていない (3.3)
    var onFinish: (@Sendable (Bool) -> Void)?
    /// `holding` の接続で、初期化と最初の映像の標本が揃ったとき 1 度だけ。応答の `X-Denpa-Codec`・`X-Denpa-Rung` を渡す
    var onReady: (@Sendable (String?, String?) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var demo: DemoStream?
    private var statusCode = 0
    private var errorBody = Data()
    private var receivedData = false
    // shortcut: pendingBytes は「最後に suspend/resume してから受けた量」で、いま溜まっている量そのものではない。64 MB の判定は近似
    private var pendingBytes = 0
    private var suspended = false
    private var timer: DispatchSourceTimer?
    /// cancel のあとに、もう列に積まれていた delegate のコールバックを捨てる印。古い接続の標本が新しいレンダラに混ざらないように
    private var cancelled = false
    /// 段を試している接続 (`holding: true`) は、`release()` まで初期化・標本を渡さずに溜めておく
    private var holding: Bool
    private var held: [FMP4Event] = []
    private var heldInitialization = false
    private var readyFired = false
    private var responseCodec: String?
    private var responseRung: String?

    /// テストで、閉じられていないかを確かめる
    var isCancelled: Bool { MediaQueue.media.sync { cancelled } }

    init(url: URL, mode: Mode, token: String? = nil, holding: Bool = false, pace: @escaping @Sendable () -> Double) {
        self.url = url
        self.mode = mode
        self.token = token
        self.holding = holding
        self.pace = pace
        super.init()
    }

    /// 溜めていた初期化・標本を渡し、以後はそのまま渡す。レンダラの reset のあとに呼ぶ (同じ media の列で順に走る)
    func release() {
        MediaQueue.media.async { [self] in
            holding = false
            let events = held
            held = []
            for event in events { deliver(event) }
        }
    }

    /// media の列で呼ぶ (テストからも呼ぶ)
    func deliver(_ event: FMP4Event) {
        guard !cancelled else { return }
        if holding {
            held.append(event)
            switch event {
            case .initialization: heldInitialization = true
            case .samples(let samples):
                // 映像の標本を待つ (音声だけの塊が先に来て、映像が来ないまま終わるときに採用しない)
                if heldInitialization, samples.contains(where: { $0.kind == .video }), !readyFired {
                    readyFired = true
                    onReady?(responseCodec, responseRung)
                }
            }
            return
        }
        switch event {
        case .initialization(let tracks): onInitialization?(tracks)
        case .samples(let samples): onSamples?(samples)
        }
    }

    func start() {
        MediaQueue.media.async { [self] in
            if DemoServer.isDemo(url) {
                let stream = DemoStream(
                    url: url,
                    mode: mode,
                    pace: pace,
                    onResponse: { [weak self] codec, rung in
                        self?.responseCodec = codec
                        self?.responseRung = rung
                        self?.onResponse?(codec, rung)
                    },
                    onInitialization: { [weak self] in self?.deliver(.initialization($0)) },
                    onSamples: { [weak self] in self?.deliver(.samples($0)) },
                    onFailure: onFailure,
                    onFinish: onFinish
                )
                demo = stream
                stream.start()
                return
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.underlyingQueue = MediaQueue.media
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            self.session = session
            var request = URLRequest(url: url)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        MediaQueue.media.async { [self] in
            cancelled = true
            held = []
            demo?.cancel()
            demo = nil
            timer?.cancel()
            timer = nil
            task?.cancel()
            session?.invalidateAndCancel()
            task = nil
            session = nil
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !cancelled else {
            completionHandler(.cancel)
            return
        }
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        Self.logger.info("stream response status=\(self.statusCode, privacy: .public)")
        if statusCode == 200 {
            receivedData = false
            let http = response as? HTTPURLResponse
            responseCodec = http?.value(forHTTPHeaderField: "X-Denpa-Codec")
            responseRung = http?.value(forHTTPHeaderField: "X-Denpa-Rung")
            onResponse?(responseCodec, responseRung)
            if mode == .buffered { startPacing() }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !cancelled else { return }
        guard statusCode == 200 else {
            if errorBody.count < 64 * 1024 { errorBody.append(data) }
            return
        }
        receivedData = true
        pendingBytes += data.count
        for event in demuxer.feed(data) { deliver(event) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        timer?.cancel()
        timer = nil
        guard !cancelled else {
            finishSession()
            return
        }
        if let error {
            if (error as? URLError)?.code != .cancelled {
                onFailure?(StreamFailure(status: nil, message: error.localizedDescription, errorCode: nil))
            }
            finishSession()
            return
        }
        if statusCode == 200 {
            Self.logger.info("stream closed")
            onFinish?(!receivedData)
        } else {
            let response = DenpaClient.errorResponse(errorBody)
            onFailure?(StreamFailure(status: statusCode, message: response?.message, errorCode: response?.error))
        }
        finishSession()
    }

    /// 終わったら URLSession を手放す。持ったままだと loader と delegate が残る
    private func finishSession() {
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
        suspended = false
    }

    // MARK: - 溜める量

    private func startPacing() {
        let timer = DispatchSource.makeTimerSource(queue: MediaQueue.media)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.checkPacing() }
        timer.resume()
        self.timer = timer
    }

    private func checkPacing() {
        guard let task else { return }
        let ahead = pace()
        // 試しの接続 (holding) は止めない。`pace` は今のレンダラの溜まりで、一時停止中は上限を超えたままなので、
        // 止めると ready まで進まない。採用までは初期化と最初の映像の標本だけで、release のあとは今までどおり
        if !suspended, !holding, (ahead > Self.overAhead || pendingBytes > Self.overBytes) {
            if task.state == .running {
                task.suspend()
                suspended = true
                pendingBytes = 0
                Self.logger.info("suspend: ahead=\(ahead, privacy: .public)")
            }
        } else if suspended, task.state == .suspended, ahead < Self.underAhead {
            task.resume()
            suspended = false
            pendingBytes = 0
            Self.logger.info("resume: ahead=\(ahead, privacy: .public)")
        }
    }

}
