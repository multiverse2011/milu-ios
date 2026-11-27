import Foundation

/// 裏に回っている間と、表へ戻した直後のやり直しの間だけ映像の標本を控え、流し直す先頭を決める (#32)。
nonisolated enum VideoReplay {
    static let maxSamples = 3600
    static let maxRetries = 3

    /// 裏に入ってから最初に届いたキーフレーム以降だけを貯める。
    nonisolated static func append(
        _ sample: FMP4Sample,
        to buffer: inout [FMP4Sample],
        now: Double,
        maxSamples: Int = maxSamples,
        seconds: (FMP4Sample) -> Double?
    ) {
        guard sample.isKeyframe || !buffer.isEmpty else { return }
        buffer.append(sample)
        if sample.isKeyframe || buffer.count > maxSamples {
            trim(&buffer, now: now, maxSamples: maxSamples, seconds: seconds)
        }
    }

    /// `now` 以前の最後のキーフレームより前を捨て、上限を超えたら末尾のキーフレームより前 (無ければ全部) を捨てる。
    nonisolated static func trim(
        _ buffer: inout [FMP4Sample],
        now: Double,
        maxSamples: Int = maxSamples,
        seconds: (FMP4Sample) -> Double?
    ) {
        guard !buffer.isEmpty else { return }
        var keepFrom: Int?
        for (index, sample) in buffer.enumerated() where sample.isKeyframe {
            if let t = seconds(sample), t <= now {
                keepFrom = index
            }
        }
        if let keepFrom, keepFrom > 0 {
            buffer.removeFirst(keepFrom)
        }
        if buffer.count > maxSamples {
            if let lastKeyframe = buffer.lastIndex(where: \.isKeyframe), lastKeyframe > 0 {
                buffer.removeFirst(lastKeyframe)
            } else {
                buffer.removeAll()
            }
        }
    }

    /// `now` を埋められる流し直し開始キーフレームの位置。`now` 以前の最後のキーフレームを返し、無ければ `nil`。
    nonisolated static func startIndex(
        in buffer: [FMP4Sample],
        now: Double,
        seconds: (FMP4Sample) -> Double?
    ) -> Int? {
        var chosen: Int?
        for (index, sample) in buffer.enumerated() where sample.isKeyframe {
            guard let t = seconds(sample) else { continue }
            if t <= now {
                chosen = index
            }
        }
        return chosen
    }

    /// `now` より後のキーフレームからでも流したい側 (ライブ) が明示的に選ぶための先頭位置。
    nonisolated static func firstKeyframeIndex(in buffer: [FMP4Sample]) -> Int? {
        buffer.firstIndex(where: \.isKeyframe)
    }

    /// 表へ戻った直後の `enqueueVideo` 失敗を次の tick でやり直すか (上限を超えたら次のキーフレーム待ちに落とす)。
    nonisolated static func shouldRetryFailure(retryCount: Int, maxRetries: Int = maxRetries) -> Bool {
        retryCount <= maxRetries
    }
}
