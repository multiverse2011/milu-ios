import CoreMedia
import Foundation

/// 3.3 の決まりのうち純粋に書けるもの。`P` の組み立て・録画の offers の選び方 (D7)・
/// 画質のメニュー (ライブ・追っかけ・録画)・音声の選び方・繋ぎ直しの待ち・CM 飛ばしの行き先。
/// Offer・AudioTrack・Chapter は API/Models.swift の型を使う。

// MARK: - P (再生できる形式)

enum PlaybackRules {
    /// 3.3 の `P`。ハードのデコーダの有無を引数でもらう (VTIsHardwareDecodeSupported の結果)。
    /// `h264` は必ず入り、`raw` (MPEG-2) は入れない (D8)。
    nonisolated static func playable(hevcSupported: Bool, av1Supported: Bool) -> [OfferCodec] {
        var codecs: [OfferCodec] = [.h264]
        if hevcSupported { codecs.append(.hevc) }
        if av1Supported { codecs.append(.av1) }
        return codecs
    }

    /// コーデックのメニューに出す名前 (3.5.3)。
    nonisolated static func codecName(_ codec: OfferCodec, locale: Locale = .current) -> String {
        switch codec {
        case .av1: "AV1"
        case .hevc: "H.265"
        case .h264: "H.264"
        case .mpeg2: "MPEG-2"
        case .audio: String(localized: LocalizedStringResource("音声", locale: locale))
        }
    }

    // MARK: 録画の offers の選び方 (D7)

    /// 録画の `offers` から観るものを選ぶ (3.3・D7)。`way == "stream"` で `codec` が `playable` にあるものだけを見る。
    /// `broadcast` は `playback` の応答の一番外の項目 (元の録画しか無い 4K の局の録画にだけ `"hevc"`)。
    /// どれも無ければ `nil` (「再生できる形式がありません」)。
    nonisolated static func selectRecordingOffer(offers: [Offer], playable: [OfferCodec], broadcast: String? = nil) -> Offer? {
        let streams = offers.filter { $0.way == .stream && playable.contains($0.codec) }

        // 1. way == "file" の offer と同じ codec のもの (詰め替え)。複数あれば AV1 → H.265 → H.264
        let fileCodecs = Set(offers.filter { $0.way == .file }.map(\.codec))
        let passthrough = streams
            .filter { fileCodecs.contains($0.codec) }
            .sorted { codecPriority($0.codec) < codecPriority($1.codec) }
        if let offer = passthrough.first { return offer }

        // 2. broadcast == "hevc" の録画 (4K の局) の hevc (放送の HEVC の詰め替え)
        if broadcast == "hevc", let offer = streams.first(where: { $0.codec == .hevc }) {
            return offer
        }

        // 3. h264 (変換)
        return streams.first(where: { $0.codec == .h264 })
    }

    /// AV1 → H.265 → H.264 の並び替えに使う順番。
    nonisolated static func codecPriority(_ codec: OfferCodec) -> Int {
        switch codec {
        case .av1: 0
        case .hevc: 1
        case .h264: 2
        case .mpeg2: 3
        case .audio: 4
        }
    }

    // MARK: 画質のメニュー

    /// 画質のメニューの 1 行。`codec` が `nil` なら「自動」。
    struct QualityItem: Equatable, Sendable {
        /// `nil` は「自動」
        var codec: OfferCodec?
        var title: String
    }

    /// 録画の画質のメニュー (D18・3.5.3)。「自動」と、`way == "stream"` で `codec` が `playable` にあるものを
    /// AV1 → H.265 → H.264 の順に全部。MPEG-2 は並べない。
    nonisolated static func recordingQualityMenu(offers: [Offer], playable: [OfferCodec], locale: Locale = .current) -> [QualityItem] {
        var codecs: [OfferCodec] = []
        for codec in [OfferCodec.av1, .hevc, .h264] where playable.contains(codec) {
            if offers.contains(where: { $0.way == .stream && $0.codec == codec }) {
                codecs.append(codec)
            }
        }
        return [QualityItem(codec: nil, title: String(localized: LocalizedStringResource("自動", locale: locale)))]
            + codecs.map { QualityItem(codec: $0, title: codecName($0, locale: locale)) }
    }

    /// ライブ・追っかけの画質のメニュー (3.3)。「自動」と、エンコードするもの 1 つ。
    /// `liveCodecs` の先頭から `playable` にある最初のもの。追っかけ (`chase`) では H.265 を外して選ぶ。
    nonisolated static func liveQualityMenu(
        liveCodecs: [OfferCodec],
        playable: [OfferCodec],
        chase: Bool = false,
        locale: Locale = .current
    ) -> [QualityItem] {
        let candidates = chase ? liveCodecs.filter { $0 != .hevc } : liveCodecs
        let encodable = candidates.first(where: { playable.contains($0) })
        var items = [QualityItem(codec: nil, title: String(localized: LocalizedStringResource("自動", locale: locale)))]
        if let codec = encodable {
            items.append(QualityItem(codec: codec, title: codecName(codec, locale: locale)))
        }
        return items
    }

    /// 覚えた画質を、いまのメニューに当てはめる。覚えたものがメニューに無ければ「自動」として扱う (値は消さない)。
    /// 追っかけは開くたびに「自動」から始めるので、`saved` に `nil` を渡す。
    nonisolated static func resolveQuality(saved: OfferCodec?, menu: [QualityItem]) -> OfferCodec? {
        guard let saved, menu.contains(where: { $0.codec == saved }) else { return nil }
        return saved
    }

    // MARK: 解像度 (段・denpa の `?rung=`)

    /// 解像度の欄の 1 行。`rung` が 0 なら「元のまま」(下げない)
    struct RungItem: Equatable, Sendable {
        var rung: Int
        var title: String
    }

    /// 段 1〜3 の映像の高さ (denpa の src/lib/rungs.ts の RUNG_SPECS)
    nonisolated static let rungHeights = [1: 720, 2: 540, 3: 360]

    /// 解像度の欄。形式とは別に選ぶ。音声だけの観方では出さない (空を返す)
    nonisolated static func rungMenu(currentCodec: OfferCodec?, locale: Locale = .current) -> [RungItem] {
        guard currentCodec != .audio else { return [] }
        return [RungItem(rung: 0, title: String(localized: LocalizedStringResource("元のまま", locale: locale)))]
            + rungHeights.sorted { $0.key < $1.key }.map { RungItem(rung: $0.key, title: "\($0.value)p") }
    }

    /// 0 (元のまま) か 1〜3 か
    nonisolated static func isRung(_ rung: Int) -> Bool {
        rung == 0 || rungHeights[rung] != nil
    }

    /// 覚えた段を読む。1〜3 のほかは 0 (下げない)
    nonisolated static func resolveRung(_ saved: Int) -> Int {
        isRung(saved) ? saved : 0
    }

    /// ライブの応答の `X-Denpa-Codec` のうち、この端末で受け取れるもの。音声だけ・放送のまま・知らない値は nil
    nonisolated static func liveResponseCodec(_ codec: String?) -> OfferCodec? {
        guard let parsed = codec.flatMap(OfferCodec.init(rawValue:)), parsed != .audio, parsed != .mpeg2 else { return nil }
        return parsed
    }

    /// URL に足す `rung=`。段 0 なら付けない (今までと同じ URL)
    nonisolated static func rungQueryItems(_ rung: Int) -> [URLQueryItem] {
        rung == 0 ? [] : [URLQueryItem(name: "rung", value: String(rung))]
    }

    // MARK: 音声の選び方 (3.3)

    /// 選べる音声のうち最初に使うもの。覚えた名前 (`label`) があればそれ。無ければ `main == true` のもの。無ければ先頭。
    /// 選べる音声が無ければ `nil` (呼ぶ側は音声の節を出さない)。
    nonisolated static func pickAudio(tracks: [AudioTrack], savedName: String?) -> AudioTrack? {
        if let savedName, let match = tracks.first(where: { $0.label == savedName }) {
            return match
        }
        if let main = tracks.first(where: { $0.main == true }) {
            return main
        }
        return tracks.first
    }

    // MARK: 繋ぎ直しの待ち (3.3)

    /// 繋ぎ直しの待ち。1 秒から倍々で、上限は 10 秒。最初のコマが映ったら 1 秒に戻す。
    struct ReconnectTimer: Equatable, Sendable {
        private(set) var wait: Double

        nonisolated init() {
            wait = 1
        }

        /// いま待つ秒数を返し、次は倍にする (10 秒で止まる)。
        nonisolated mutating func advance() -> Double {
            let current = wait
            wait = min(wait * 2, 10)
            return current
        }

        /// 最初のコマが映ったら待ちを 1 秒に戻す。
        nonisolated mutating func reset() {
            wait = 1
        }
    }

    // MARK: CM 飛ばしの行き先 (3.3)

    /// 位置が `title == "CM"` の区間に入っていれば、その `end` へ飛ぶ行き先を返す。入っていなければ `nil`。
    /// 区間は半開き `[start, end)`。自動シーク済みの終点までは飛ばし直さない。
    nonisolated static func cmSkipDestination(
        chapters: [Chapter],
        position: Double,
        lastSkippedEnd: Double? = nil
    ) -> Double? {
        for chapter in chapters where chapter.title == "CM" {
            if chapter.start <= position && position < chapter.end {
                if let lastSkippedEnd, chapter.end <= lastSkippedEnd { return nil }
                return chapter.end
            }
        }
        return nil
    }

    // MARK: 裏に回ったときの判断 (#32)

    nonisolated enum AppPhase: Equatable, Sendable {
        case active
        case inactive
        case background
    }

    nonisolated enum LiveLifecycleAction: Equatable, Sendable {
        /// 表に出た (まだ始まっていなければ開き、裏で鳴り続けていたなら映像を戻して一覧を読み直す)
        case activate
        /// 再生中なので接続と音を保ったまま裏へ回る (映像の描画だけ止める)
        case keepInBackground
        /// 接続を閉じ、全画面も閉じる
        case stop
        /// そのまま (Control Center を引き出した `.inactive` や、離れているタブでの前後移動)
        case none
    }

    /// ライブが裏に回ったとき接続を閉じるか。再生中 (`phase == .playing`) のときだけ閉じずに保つ。
    /// PiP の窓に出ている間は、止めていても窓を消さない (#48)
    nonisolated static func shouldCloseLiveOnBackground(phase: PlaybackSession.Phase?, pictureInPicture: Bool = false) -> Bool {
        if pictureInPicture { return false }
        return phase != .playing
    }

    /// 裏に回ったときに映像を流し続けるか。PiP の窓に出ている間は流す (#32・#48)。
    /// それ以外は裏では音だけにする
    nonisolated static func videoEnabled(inBackground: Bool, pictureInPicture: Bool) -> Bool {
        !inBackground || pictureInPicture
    }

    // MARK: ピクチャ・イン・ピクチャ (#48)

    /// 窓に出す観られる範囲。ライブは終わりが無い。始まりは 0
    /// (負の無限を入れると start + duration が NaN になり得る)
    nonisolated static let livePictureInPictureTimeRange = CMTimeRange(start: .zero, duration: .positiveInfinity)

    /// 窓の再生の絵を「一時停止」にするか。止めているときだけにする。
    /// 読み込み中・繋ぎ直しは動き続けている扱い (そうしないと、窓で再生を押した直後に「一時停止」の絵になる)
    nonisolated static func pictureInPictureIsPaused(phase: PlaybackSession.Phase) -> Bool {
        phase == .paused || phase == .stopped || phase == .idle
    }

    /// PiP の窓が閉じたときに、裏の決まり (#32) を引き直して閉じるか
    nonisolated static func shouldCloseOnPictureInPictureEnd(inBackground: Bool, phase: PlaybackSession.Phase?) -> Bool {
        inBackground && shouldCloseLiveOnBackground(phase: phase)
    }

    /// ライブのタブの選択とアプリの前後から、次にすることを決める (#32・a901338)。
    nonisolated static func liveLifecycleAction(
        isSelected: Bool,
        appPhase: AppPhase,
        started: Bool,
        sessionPhase: PlaybackSession.Phase?,
        pictureInPicture: Bool = false
    ) -> LiveLifecycleAction {
        guard isSelected else {
            return started ? .stop : .none
        }
        switch appPhase {
        case .active:
            return .activate
        case .inactive:
            return .none
        case .background:
            guard started else { return .none }
            return shouldCloseLiveOnBackground(phase: sessionPhase, pictureInPicture: pictureInPicture)
                ? .stop
                : .keepInBackground
        }
    }
}
