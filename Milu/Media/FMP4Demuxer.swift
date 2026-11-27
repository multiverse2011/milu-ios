import Foundation

/// fMP4 の初期化セグメント (`ftyp` `moov`) から読んだトラック。
/// CoreMedia の型には触れず、純粋な値だけにする (D11・8 節)。
nonisolated struct FMP4Track: Equatable, Sendable {
    enum Kind: Sendable {
        case video
        case audio
    }

    let id: UInt32
    let kind: Kind
    /// 1 秒あたりの刻み (`mdhd`。ffmpeg は映像 60000・音声 48000 などを出す)
    let timescale: UInt32
    /// WebCodecs の書き方のコーデック (`avc1.640029`・`mp4a.40.2` など)
    let codec: String
    /// `avcC` / `hvcC` / `av1C` の中身、または音声の AudioSpecificConfig / OpusHead
    let config: Data
    let width: Int
    let height: Int
    /// `pasp` を幅に掛けた見せる幅 (1440x1080 の SAR 4:3 なら 1920)
    let displayWidth: Int?
    /// `pasp` の中身 (そのまま形式の拡張に入れる)
    let pasp: Data?
    let color: FMP4Color?
    /// 音声だけ。映像では 0
    var channels: Int = 0
    var sampleRate: Double = 0
}

nonisolated struct FMP4Color: Equatable, Sendable {
    let primaries: UInt16
    let transfer: UInt16
    let matrix: UInt16
    let fullRange: Bool
}

nonisolated struct FMP4Sample: Equatable, Sendable {
    let trackID: UInt32
    let kind: FMP4Track.Kind
    let dts: Int64
    let pts: Int64
    let duration: Int64
    let isKeyframe: Bool
    let data: Data
}

nonisolated enum FMP4Event: Sendable {
    case initialization([FMP4Track])
    case samples([FMP4Sample])
}

/// fragmented MP4 を少しずつ読む。箱が塊の境目で割れて届いても、続けて渡せば同じ結果になる。
/// denpa の `src/lib/ts/fmp4.ts` の読み方に合わせる (`default-base-is-moof`・tfhd→trex の順)。
nonisolated final class FMP4Demuxer {
    private struct Defaults {
        var duration: UInt32 = 0
        var size: UInt32 = 0
        var flags: UInt32 = 0
    }

    private struct Box {
        let type: String
        /// 中身 (ヘッダの 8 バイトを除く) の位置
        let body: Int
        let length: Int
    }

    private var buffer = Data()
    private var tracks: [FMP4Track] = []
    private var trackByID: [UInt32: FMP4Track] = [:]
    private var defaults: [UInt32: Defaults] = [:]
    private var hasInit = false

    func feed(_ data: Data) -> [FMP4Event] {
        buffer.append(data)
        var events: [FMP4Event] = []
        var at = 0

        while buffer.count - at >= 8 {
            let size32 = u32(at)
            var header = 8
            var size = Int(size32)
            if size32 == 1 {
                guard buffer.count - at >= 16 else { break }
                header = 16
                let large = u64(at + 8)
                guard large <= UInt64(Int.max) else {
                    buffer.removeAll()
                    return events
                }
                size = Int(large)
            } else if size32 == 0 {
                // 大きさ 0 は「ここから最後まで」。ストリームでは来ないので、来たら読むのをやめる
                break
            }
            guard size >= header else {
                // 壊れた大きさ。以降を詰めるとずれたまま読み続けるので捨てる
                buffer.removeAll()
                return events
            }
            guard buffer.count - at >= size else { break }

            let type = ascii(at + 4, 4)
            switch type {
            case "moov":
                parseInit(offset: at, size: size)
                events.append(.initialization(tracks))
                hasInit = true
                at += size
            case "moof":
                // この moof に続く mdat まで揃ってから 1 つの塊として読む
                switch mediaEnd(after: at, moofSize: size) {
                case .found(let end):
                    events.append(.samples(parseFragment(origin: at, end: end)))
                    at = end
                case .needsMore:
                    // mdat がまだ届いていない
                    buffer.removeFirst(at)
                    return events
                case .skipMoof:
                    // mdat を挟まず次の moof が来た。この moof は読めないので捨てて次へ
                    at += size
                }
            default:
                at += size
            }
        }

        if at > 0 { buffer.removeFirst(at) }
        return events
    }

    private enum MediaEnd {
        /// `mdat` の終わり (この位置まで読んだ)
        case found(Int)
        /// 箱がまだ届いていない。次を待つ
        case needsMore
        /// この `moof` には `mdat` が続かない。この `moof` を捨てて次へ進む
        case skipMoof
    }

    /// `moof` の後ろの `mdat` の終わり
    private func mediaEnd(after moof: Int, moofSize: Int) -> MediaEnd {
        var at = moof + moofSize
        while buffer.count - at >= 8 {
            let size32 = u32(at)
            var header = 8
            var size = Int(size32)
            if size32 == 1 {
                guard buffer.count - at >= 16 else { return .needsMore }
                header = 16
                guard u64(at + 8) <= UInt64(Int.max) else { return .skipMoof }
                size = Int(u64(at + 8))
            } else if size32 == 0 {
                // 大きさ 0 は「ここから最後まで」。mdat の終わりが決められない
                return .needsMore
            }
            guard size >= header else { return .skipMoof }
            guard buffer.count - at >= size else { return .needsMore }
            let type = ascii(at + 4, 4)
            if type == "mdat" { return .found(at + size) }
            if type == "moof" { return .skipMoof }
            at += size
        }
        return .needsMore
    }

    // MARK: - init (ftyp + moov)

    private func parseInit(offset: Int, size: Int) {
        tracks.removeAll()
        trackByID.removeAll()
        defaults.removeAll()

        let moovChildren = boxes(body: offset + 8, length: size - 8)
        if let mvex = moovChildren.first(where: { $0.type == "mvex" }) {
            for trex in boxes(body: mvex.body, length: mvex.length) where trex.type == "trex" {
                guard trex.length >= 24 else { continue }
                let id = u32(trex.body + 4)
                defaults[id] = Defaults(
                    duration: u32(trex.body + 12),
                    size: u32(trex.body + 16),
                    flags: u32(trex.body + 20)
                )
            }
        }

        for trak in moovChildren where trak.type == "trak" {
            guard
                let tkhd = boxes(body: trak.body, length: trak.length).first(where: { $0.type == "tkhd" }),
                let mdhd = path(trak, ["mdia", "mdhd"]),
                let stsd = path(trak, ["mdia", "minf", "stbl", "stsd"]),
                stsd.length >= 8
            else { continue }

            let version = byte(tkhd.body)
            let id = u32(tkhd.body + (version == 1 ? 20 : 12))
            let timescale = u32(mdhd.body + (byte(mdhd.body) == 1 ? 20 : 12))
            guard timescale > 0 else { continue }

            let entries = boxes(body: stsd.body + 8, length: stsd.length - 8)
            guard let entry = entries.first, let track = readEntry(entry, id: id, timescale: timescale) else {
                continue
            }
            tracks.append(track)
            trackByID[id] = track
        }
    }

    private func readEntry(_ entry: Box, id: UInt32, timescale: UInt32) -> FMP4Track? {
        switch entry.type {
        case "avc1", "hvc1", "hev1", "av01":
            return readVideoEntry(entry, id: id, timescale: timescale)
        case "mp4a", "Opus":
            return readAudioEntry(entry, id: id, timescale: timescale)
        default:
            // 字幕などの知らないトラックは捨てる
            return nil
        }
    }

    private func readVideoEntry(_ entry: Box, id: UInt32, timescale: UInt32) -> FMP4Track? {
        // VisualSampleEntry の決まった並びは 78 バイト (幅 24・高さ 26)
        guard entry.length >= 78 else { return nil }
        let configBox: String = switch entry.type {
        case "avc1": "avcC"
        case "av01": "av1C"
        default: "hvcC"
        }
        let children = boxes(body: entry.body + 78, length: entry.length - 78)
        guard let config = children.first(where: { $0.type == configBox }) else { return nil }
        let configData = slice(config.body, config.length)
        let width = Int(u16(entry.body + 24))
        let height = Int(u16(entry.body + 26))

        var pasp: Data?
        var displayWidth: Int?
        if let box = children.first(where: { $0.type == "pasp" }), box.length >= 8 {
            let horizontal = u32(box.body)
            let vertical = u32(box.body + 4)
            if horizontal > 0, vertical > 0 {
                pasp = slice(box.body, 8)
                let width = Int((Double(width) * Double(horizontal) / Double(vertical)).rounded())
                if width >= 1, width <= 0xffff { displayWidth = width }
            }
        }

        var color: FMP4Color?
        if let box = children.first(where: { $0.type == "colr" }), box.length >= 10, ascii(box.body, 4) == "nclx" {
            color = FMP4Color(
                primaries: u16(box.body + 4),
                transfer: u16(box.body + 6),
                matrix: u16(box.body + 8),
                fullRange: box.length >= 11 && (byte(box.body + 10) & 0x80) != 0
            )
        }

        let codec: String
        switch entry.type {
        case "avc1":
            guard configData.count >= 4 else { return nil }
            codec = String(format: "avc1.%02X%02X%02X", Int(configData[configData.startIndex + 1]),
                           Int(configData[configData.startIndex + 2]), Int(configData[configData.startIndex + 3]))
        case "av01":
            guard configData.count >= 4 else { return nil }
            codec = av1Codec(configData)
        default:
            guard configData.count >= 13 else { return nil }
            codec = hevcCodec(entry.type, configData)
        }

        return FMP4Track(
            id: id, kind: .video, timescale: timescale, codec: codec, config: configData,
            width: width, height: height, displayWidth: displayWidth, pasp: pasp, color: color
        )
    }

    private func readAudioEntry(_ entry: Box, id: UInt32, timescale: UInt32) -> FMP4Track? {
        // AudioSampleEntry の中身のボックスは 28 から
        guard entry.length >= 28 else { return nil }
        let children = boxes(body: entry.body + 28, length: entry.length - 28)
        let config: Data
        let codec: String
        let channels: Int
        let rate: Double
        if entry.type == "Opus" {
            guard let dOps = children.first(where: { $0.type == "dOps" }), dOps.length >= 11 else { return nil }
            guard let head = opusHead(slice(dOps.body, dOps.length)) else { return nil }
            config = head
            codec = "opus"
            channels = Int(byte(dOps.body + 1))
            rate = 48000
        } else {
            guard let esds = children.first(where: { $0.type == "esds" }),
                  let asc = audioSpecificConfig(box: esds), asc.count >= 2
            else { return nil }
            config = asc
            codec = "mp4a.40.\(asc[asc.startIndex] >> 3)"
            channels = Int((asc[asc.startIndex + 1] >> 3) & 0x0f)
            rate = Self.sampleRate(asc)
        }
        // AudioSampleEntry のチャンネル数と標本化周波数 (16.16)。ASC が 0 のときの控え
        let entryChannels = Int(u16(entry.body + 16))
        let entryRate = Double(u32(entry.body + 24) >> 16)
        return FMP4Track(
            id: id, kind: .audio, timescale: timescale, codec: codec, config: config,
            width: 0, height: 0, displayWidth: nil, pasp: nil, color: nil,
            channels: channels > 0 ? channels : entryChannels,
            sampleRate: rate > 0 ? rate : entryRate
        )
    }

    // MARK: - moof

    private func parseFragment(origin: Int, end: Int) -> [FMP4Sample] {
        var samples: [FMP4Sample] = []
        let moofSize = boxSize(at: origin)
        guard let moof = optionalBox(at: origin), moof.type == "moof" else { return [] }
        let mdatBody = mdatBodyStart(from: origin + moofSize, end: end)

        for traf in boxes(body: moof.body, length: moof.length) where traf.type == "traf" {
            guard let tfhd = boxes(body: traf.body, length: traf.length).first(where: { $0.type == "tfhd" }),
                  tfhd.length >= 8
            else { continue }
            let flags = u32(tfhd.body) & 0x00ff_ffff
            let trackID = u32(tfhd.body + 4)
            guard let track = trackByID[trackID] else { continue }
            var base = Defaults(
                duration: defaults[trackID]?.duration ?? 0,
                size: defaults[trackID]?.size ?? 0,
                flags: defaults[trackID]?.flags ?? 0
            )

            var at = tfhd.body + 8
            if flags & 0x01 != 0 { at += 8 } // base-data-offset は扱わない
            if flags & 0x02 != 0 { at += 4 }
            func field(_ bit: UInt32, _ fallback: UInt32) -> UInt32 {
                guard flags & bit != 0, at + 4 <= tfhd.body + tfhd.length else { return fallback }
                defer { at += 4 }
                return u32(at)
            }
            base.duration = field(0x08, base.duration)
            base.size = field(0x10, base.size)
            base.flags = field(0x20, base.flags)

            var dts: Int64 = 0
            if let tfdt = boxes(body: traf.body, length: traf.length).first(where: { $0.type == "tfdt" }) {
                if byte(tfdt.body) == 1, tfdt.length >= 12 {
                    dts = Int64(bitPattern: u64(tfdt.body + 4))
                } else if tfdt.length >= 8 {
                    dts = Int64(u32(tfdt.body + 4))
                }
            }

            for trun in boxes(body: traf.body, length: traf.length) where trun.type == "trun" {
                guard trun.length >= 8 else { continue }
                let tflags = u32(trun.body) & 0x00ff_ffff
                let count = Int(u32(trun.body + 4))
                var p = trun.body + 8
                var offset = mdatBody
                if tflags & 0x01 != 0 {
                    offset = origin + Int(Int32(bitPattern: u32(p)))
                    p += 4
                }
                var first: UInt32?
                if tflags & 0x04 != 0 {
                    first = u32(p)
                    p += 4
                }
                let each = [0x100, 0x200, 0x400, 0x800].reduce(0) { $1 != 0 && tflags & $1 != 0 ? $0 + 4 : $0 }
                guard p + each * count <= trun.body + trun.length else { continue }
                let signedOffsets = byte(trun.body) == 1
                func next(_ signed: Bool = false) -> Int64 {
                    let value = u32(p)
                    p += 4
                    return signed ? Int64(Int32(bitPattern: value)) : Int64(value)
                }

                var position = offset
                for i in 0..<count {
                    let duration = tflags & 0x100 != 0 ? next() : Int64(base.duration)
                    let size = tflags & 0x200 != 0 ? Int(next()) : Int(base.size)
                    let sampleFlags = tflags & 0x400 != 0 ? UInt32(next()) : (i == 0 ? (first ?? base.flags) : base.flags)
                    let shift = tflags & 0x800 != 0 ? next(signedOffsets) : 0
                    guard size >= 0, position >= 0, position + size <= buffer.count else { break }
                    samples.append(FMP4Sample(
                        trackID: trackID,
                        kind: track.kind,
                        dts: dts,
                        pts: dts + shift,
                        duration: duration,
                        isKeyframe: sampleFlags & 0x0001_0000 == 0,
                        data: slice(position, size)
                    ))
                    position += size
                    dts += duration
                }
            }
        }
        return samples
    }

    private func mdatBodyStart(from start: Int, end: Int) -> Int {
        var at = start
        while at + 8 <= end {
            let type = ascii(at + 4, 4)
            if type == "mdat" { return at + 8 }
            let size = boxSize(at: at)
            guard size >= 8 else { break }
            at += size
        }
        return start
    }

    // MARK: - 箱を読む

    private func boxes(body: Int, length: Int) -> [Box] {
        var out: [Box] = []
        var at = body
        let end = body + length
        while at + 8 <= end {
            let size32 = u32(at)
            var header = 8
            var size = Int(size32)
            if size32 == 1 {
                guard at + 16 <= end else { break }
                header = 16
                guard u64(at + 8) <= UInt64(Int.max) else { break }
                size = Int(u64(at + 8))
            }
            guard size >= header, at + size <= end else { break }
            out.append(Box(type: ascii(at + 4, 4), body: at + header, length: size - header))
            at += size
        }
        return out
    }

    private func path(_ box: Box, _ types: [String]) -> Box? {
        var current: Box? = box
        for type in types {
            guard let body = current else { return nil }
            current = boxes(body: body.body, length: body.length).first(where: { $0.type == type })
        }
        return current
    }

    private func optionalBox(at: Int) -> Box? {
        guard at + 8 <= buffer.count else { return nil }
        let size32 = u32(at)
        var header = 8
        var size = Int(size32)
        if size32 == 1 {
            guard at + 16 <= buffer.count else { return nil }
            header = 16
            guard u64(at + 8) <= UInt64(Int.max) else { return nil }
            size = Int(u64(at + 8))
        }
        guard size >= header, at + size <= buffer.count else { return nil }
        return Box(type: ascii(at + 4, 4), body: at + header, length: size - header)
    }

    private func boxSize(at: Int) -> Int {
        guard at + 8 <= buffer.count else { return 0 }
        let size32 = u32(at)
        if size32 == 1, at + 16 <= buffer.count { return Int(u64(at + 8)) }
        return Int(size32)
    }

    // MARK: - バイト列

    private func byte(_ at: Int) -> UInt8 {
        buffer[buffer.startIndex + at]
    }

    private func u16(_ at: Int) -> UInt16 {
        (UInt16(byte(at)) << 8) | UInt16(byte(at + 1))
    }

    private func u32(_ at: Int) -> UInt32 {
        (UInt32(byte(at)) << 24) | (UInt32(byte(at + 1)) << 16) | (UInt32(byte(at + 2)) << 8) | UInt32(byte(at + 3))
    }

    private func u64(_ at: Int) -> UInt64 {
        (UInt64(u32(at)) << 32) | UInt64(u32(at + 4))
    }

    private func ascii(_ at: Int, _ length: Int) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        for i in 0..<length { bytes.append(byte(at + i)) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func slice(_ at: Int, _ length: Int) -> Data {
        let start = buffer.startIndex + at
        return buffer.subdata(in: start..<(start + length))
    }

    // MARK: - コーデックの書き方

    private static func sampleRate(_ asc: Data) -> Double {
        let index = Int(((asc[asc.startIndex] & 0x07) << 1) | (asc[asc.startIndex + 1] >> 7))
        let table: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        if index < table.count { return table[index] }
        // 周波数を値で書いたもの (番号 15) は読まない。入れ物の値を使う
        return 0
    }

    private func hevcCodec(_ type: String, _ hvcC: Data) -> String {
        let b = { (i: Int) -> UInt8 in hvcC[hvcC.startIndex + i] }
        let space = ["", "A", "B", "C"][Int(b(1) >> 6)]
        let tier = (b(1) >> 5) & 1 == 1 ? "H" : "L"
        let profile = b(1) & 0x1f
        var flags: UInt32 = 0
        for i in 0..<4 { flags = (flags << 8) | UInt32(b(2 + i)) }
        var reversed: UInt32 = 0
        for i in 0..<32 { reversed = (reversed << 1) | ((flags >> UInt32(i)) & 1) }
        var constraints = Array(hvcC[(hvcC.startIndex + 6)..<(hvcC.startIndex + 12)])
        while constraints.last == 0 { constraints.removeLast() }
        let tail = constraints.map { ".\(String($0, radix: 16, uppercase: true))" }.joined()
        return "\(type).\(space)\(profile).\(String(reversed, radix: 16, uppercase: true)).\(tier)\(b(12))\(tail)"
    }

    private func av1Codec(_ av1C: Data) -> String {
        let b = { (i: Int) -> UInt8 in av1C[av1C.startIndex + i] }
        let profile = b(1) >> 5
        let level = b(1) & 0x1f
        let tier = b(2) >> 7 == 1 ? "H" : "M"
        let high = (b(2) >> 6) & 1
        let twelve = (b(2) >> 5) & 1
        let depth = high == 0 ? 8 : (twelve == 1 ? 12 : 10)
        return "av01.\(profile).\(String(format: "%02d", level))\(tier).\(String(format: "%02d", depth))"
    }

    /// esds から AudioSpecificConfig を抜く (ES_Descriptor → DecoderConfigDescriptor → DecoderSpecificInfo)
    private func audioSpecificConfig(box: Box) -> Data? {
        let data = slice(box.body, box.length)
        var at = 4 // version+flags
        func descriptor() -> (tag: Int, start: Int, end: Int)? {
            guard at < data.count else { return nil }
            let tag = Int(data[data.startIndex + at])
            at += 1
            var length = 0
            for _ in 0..<4 where at < data.count {
                let byte = data[data.startIndex + at]
                at += 1
                length = (length << 7) | Int(byte & 0x7f)
                if byte & 0x80 == 0 { break }
            }
            return (tag, at, min(data.count, at + length))
        }
        guard let es = descriptor(), es.tag == 0x03 else { return nil }
        let flags = at + 2 < data.count ? data[data.startIndex + at + 2] : 0
        at += 3
        if flags & 0x80 != 0 { at += 2 }
        if flags & 0x40 != 0 { at += 1 + (at < data.count ? Int(data[data.startIndex + at]) : 0) }
        if flags & 0x20 != 0 { at += 2 }
        guard let config = descriptor(), config.tag == 0x04 else { return nil }
        at = config.start + 13
        while at < config.end {
            guard let info = descriptor() else { return nil }
            if info.tag == 0x05 {
                return data.subdata(in: (data.startIndex + info.start)..<(data.startIndex + info.end))
            }
            at = info.end
        }
        return nil
    }

    /// dOps を、`AVSampleBufferAudioRenderer` が受ける OpusHead の並びに直す
    private func opusHead(_ dOps: Data) -> Data? {
        if dOps.count >= 19, String(decoding: dOps.prefix(8), as: UTF8.self) == "OpusHead" {
            return dOps
        }
        guard dOps.count >= 11 else { return nil }
        var out = Data("OpusHead".utf8)
        out.append(1)
        out.append(dOps[dOps.startIndex + 1])
        let inputRate = (UInt32(dOps[dOps.startIndex + 4]) << 24) | (UInt32(dOps[dOps.startIndex + 5]) << 16)
            | (UInt32(dOps[dOps.startIndex + 6]) << 8) | UInt32(dOps[dOps.startIndex + 7])
        let preSkip = (UInt16(dOps[dOps.startIndex + 2]) << 8) | UInt16(dOps[dOps.startIndex + 3])
        out.append(UInt8(preSkip & 0xff))
        out.append(UInt8(preSkip >> 8))
        for shift in [0, 8, 16, 24] { out.append(UInt8((inputRate >> shift) & 0xff)) }
        out.append(contentsOf: [0, 0]) // 音量の補正
        out.append(dOps[dOps.startIndex + 10])
        if dOps.count > 11 { out.append(dOps.suffix(from: dOps.startIndex + 11)) }
        return out
    }
}
