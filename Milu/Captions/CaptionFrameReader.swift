import Foundation

/// 0x40 の通知の JSON (api.md)。`captions`・`clock`・`ping`。知らない `type` は読み捨てる。
struct CaptionNotice: @nonisolated Decodable, Equatable, Sendable {
    var type: String
    /// ライブの `clock` 通知: 映像の時刻 (秒)
    var at: Double?
    /// ライブの `clock` 通知: サーバがその時刻を受け取った UNIX ミリ秒
    var unixMs: Int64?
    /// ライブの `clock` 通知: 送ったときのサーバの時計
    var now: Int64?
}

/// 4.4 のフレーム 1 枚。
struct CaptionFrame: Equatable, Sendable {
    /// 時刻 (90kHz)。放送の PTS は 33 ビットで一周する
    var timestamp90kHz: UInt64
    var content: Content

    nonisolated init(timestamp90kHz: UInt64, content: Content) {
        self.timestamp90kHz = timestamp90kHz
        self.content = content
    }

    enum Content: Equatable, Sendable {
        /// 0x22 字幕の文字の配置。前の 1 枚を丸ごと置き換える
        case page(CaptionPage)
        /// 0x40 通知
        case notice(CaptionNotice)
    }
}

/// 4.4 のフレームの読み。塊の境目で割れて届いても読める。
///
/// `[4: 後ろの長さ (BE)][1: 種別][8: 時刻 (90kHz, BE)][中身]`。後ろの長さは種別・時刻・中身を含む。
/// 知らない種別は読み捨てる。JSON が読めないフレームも捨てる。
struct CaptionFrameReader {
    private var buffer: [UInt8] = []

    init() {}

    nonisolated mutating func append(_ bytes: [UInt8]) -> [CaptionFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [CaptionFrame] = []
        while buffer.count >= 4 {
            let length =
                Int(buffer[0]) << 24 | Int(buffer[1]) << 16
                | Int(buffer[2]) << 8 | Int(buffer[3])
            guard length >= 9 else {
                // 壊れた並び。4 バイトの長さを捨てて、残りから取り直す
                buffer.removeFirst(4)
                continue
            }
            guard buffer.count >= 4 + length else { break }

            let type = buffer[4]
            var timestamp: UInt64 = 0
            for byte in buffer[5..<13] {
                timestamp = timestamp << 8 | UInt64(byte)
            }
            let payload = Array(buffer[13..<(4 + length)])
            buffer.removeFirst(4 + length)

            switch type {
            case 0x22:
                if let page = try? JSONDecoder().decode(CaptionPage.self, from: Data(payload)) {
                    frames.append(CaptionFrame(timestamp90kHz: timestamp, content: .page(page)))
                }
            case 0x40:
                if let notice = try? JSONDecoder().decode(CaptionNotice.self, from: Data(payload)) {
                    frames.append(CaptionFrame(timestamp90kHz: timestamp, content: .notice(notice)))
                }
            default:
                break
            }
        }
        return frames
    }
}
