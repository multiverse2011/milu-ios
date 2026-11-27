import Foundation

/// 4.1 の応答の `Codable` (api.md を正とする)。時刻は UNIX ミリ秒の整数のまま持つ。
///
/// 知らない `codec`・`type` が来た要素は捨てる (設計書 5 節)。知らない `state` が来ても
/// 全体の読みは失敗しない (生の字を持ち、型へはアクセサで変える)。
/// どれも非隔離で読める (D11 と同じ考え方)。

/// 1 つの要素が読めなくても、配列の残りを読むための包み。知らない codec・type を捨てるのに使う。
struct LossyDecodable<Value: Decodable & Sendable>: Decodable {
    nonisolated var value: Value?

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(Value.self)
    }
}

extension KeyedDecodingContainer {
    /// 知らしい codec を持たない要素を捨てて配列を読む。
    nonisolated func decodeDroppingUnknowns<Value: Decodable & Sendable>(_ type: [Value].Type, forKey key: Key, default defaultValue: [Value] = []) -> [Value] {
        guard let lossy = try? decode([LossyDecodable<Value>].self, forKey: key) else { return defaultValue }
        return lossy.compactMap(\.value)
    }
}

extension JSONDecoder {
    /// 一番外の配列の要素 1 つが読めなくても、残りを読む ([Service] など)。
    nonisolated func decodeArrayDroppingUnknowns<Value: Decodable & Sendable>(_ type: [Value].Type, from data: Data) throws -> [Value] {
        try decode([LossyDecodable<Value>].self, from: data).compactMap(\.value)
    }
}

// MARK: - 局の一覧 (api/services)

/// 局の種別。知らない値が来た局は捨てる (3.5 の並びどおり GR・BS・CS・CATV・SKY)。
enum ServiceType: String, Equatable, Sendable, CaseIterable {
    case GR, BS, CS, CATV, SKY
}

extension ServiceType: @nonisolated Decodable {
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = ServiceType(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "知らない種別: \(raw)")
        }
        self = value
    }
}

struct Service: @nonisolated Decodable, Equatable, Sendable {
    var id: Int64
    var type: ServiceType
    var name: String
    var remoteControlKey: Int?
    /// 局ロゴの相対 URL。まだ取得できていなければ `null`
    var logo: String?
    /// ライブの相対 URL
    var live: String
    /// ブラウザのライブの一覧に出る局か
    var airing: Bool
    /// 映像のある局か (ラジオ・データ放送の局は false。D25)
    var video: Bool
    /// いま放送中の番組。番組表に無ければ `null`
    var now: CurrentProgram?
}

/// 局のいまの番組 (`now`)。
struct CurrentProgram: @nonisolated Decodable, Equatable, Sendable {
    var id: Int64
    var title: String
    var startAt: Int64
    var endAt: Int64
    /// その番組を録る予定か (競合で弾かれたものは false)
    var reserved: Bool
    /// いま録っている最中か
    var recording: Bool
    /// その番組で選べる音声
    var audios: [AudioTrack]
}

/// 選べる音声 1 つ (局の `now.audios`・録画の `audios` で同じ形式)。
struct AudioTrack: @nonisolated Decodable, Equatable, Sendable {
    /// 選ぶときに渡す値 (`<stream>:<side>`)
    var id: String
    /// 何本目の音声か (0 から)
    var stream: Int
    /// `both` はそのまま、`main` / `sub` はデュアルモノの片側
    var side: String
    /// 画面と同じ名前
    var label: String
    /// 放送が主音声と言っているか (言っていなければキーごと無い)
    var main: Bool?
}

// MARK: - 番組表 (api/programs)

struct GuideResponse: @nonisolated Decodable, Equatable, Sendable {
    var type: ServiceType
    var from: Int64
    var to: Int64
    /// その種別でいちばん遅い番組の終わり。番組表が空なら `null`
    var until: Int64?
    var services: [GuideService]
}

struct GuideService: @nonisolated Decodable, Equatable, Sendable {
    var id: Int64
    var name: String
    /// サブチャンネルなら本チャンネルの id (本チャンネルは `null`)。v1 は本チャンネルだけを出す
    var mainId: Int64?
    var remoteControlKey: Int?
    var logo: String?
    var programs: [GuideProgram]
}

struct GuideProgram: @nonisolated Decodable, Equatable, Sendable {
    var id: Int64
    /// 放送のままの名前 (記号 `[字]` などを含む)
    var name: String
    var startAt: Int64
    var endAt: Int64
    var description: String?
    /// ジャンルの大分類 (ARIB の lv1)。無ければ `null`
    var genre: Int?
    var copyNever: Bool
    /// 予約が立っていればその状態。取り消した予約と無い番組は `null`
    var reservation: ReservationInfo?
    /// その番組のそのまま観られる録画。無ければ `null`
    var recordingId: Int64?
}

/// 予約の状態 (`reservation`)。`state` の生の字も持ち、知らない値が来ても読みは落ちない。
struct ReservationInfo: @nonisolated Decodable, Equatable, Sendable {
    var stateRaw: String
    var reason: String?
    var ruleId: Int64?

    nonisolated var state: ReservationState? { ReservationState(rawValue: stateRaw) }

    enum CodingKeys: String, CodingKey {
        case stateRaw = "state"
        case reason
        case ruleId
    }
}

// MARK: - 番組の中身 (api/programs/<id>。キーは snake_case)

struct ProgramDetail: @nonisolated Decodable, Equatable, Sendable {
    var name: String
    var serviceName: String
    var startAt: Int64
    var endAt: Int64
    var description: String?
    var extended: [String: String]?
    var genreDetail: [GenreDetail]?
    var audios: [ProgramAudio]?
    var videoType: String?
    var videoResolution: String?
    var isFree: Bool
    var copyNever: Bool
    var seriesEpisode: Int?
    var seriesLastEpisode: Int?
    var seriesRepeat: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case serviceName = "service_name"
        case startAt = "start_at"
        case endAt = "end_at"
        case description
        case extended
        case genreDetail = "genre_detail"
        case audios
        case videoType = "video_type"
        case videoResolution = "video_resolution"
        case isFree = "is_free"
        case copyNever = "copy_never"
        case seriesEpisode = "series_episode"
        case seriesLastEpisode = "series_last_episode"
        case seriesRepeat = "series_repeat"
    }
}

struct GenreDetail: @nonisolated Decodable, Equatable, Sendable {
    var lv1: Int
    var lv2: Int
}

struct ProgramAudio: @nonisolated Decodable, Equatable, Sendable {
    /// ARIB の音声の構成 (2 がデュアルモノ、3 がステレオ)
    var componentType: Int
    var componentTag: Int?
    var langs: [String]?
    var samplingRate: Int?
    /// 放送が付けた名前 (「主音声ステレオ」など)
    var text: String?
    /// 主音声か。解説放送はこちらが立っていないほう
    var main: Bool?
}

// MARK: - 録る・取り消す (api/programs/<id>/record)

struct RecordResponse: @nonisolated Decodable, Equatable, Sendable {
    var recorded: String?
    var programId: Int64?
    /// `false` なら予約はあるものの録らない状態 (たいえば競合)
    var reserved: Bool
    var stateRaw: String?
    var reason: String?

    nonisolated var state: ReservationState? { stateRaw.flatMap(ReservationState.init(rawValue:)) }

    enum CodingKeys: String, CodingKey {
        case recorded
        case programId
        case reserved
        case stateRaw = "state"
        case reason
    }
}

struct CancelResponse: @nonisolated Decodable, Equatable, Sendable {
    /// 録画中の録画を止めたか
    var stopped: Bool
}

// MARK: - 録画の一覧 (api/recordings)

struct Recording: @nonisolated Decodable, Equatable, Sendable, Identifiable {
    var id: Int64
    /// 記号 (`[字]` など) を落とした名前
    var title: String
    /// 放送のままの名前
    var name: String
    var serviceId: Int64
    var serviceName: String
    var startAt: Int64
    var endAt: Int64
    /// 録画中は `null`
    var durationMs: Int64?
    /// 続きから観る位置。観ていなければ `null`
    var resumeMs: Int64?
    /// 末尾まで観た時刻。まだなら `null`
    var watchedAt: Int64?
    /// いま録っている最中か
    var recording: Bool
    /// 追っかけ再生の相対 URL。元の TS が無ければ `null`
    var chase: String?
    /// CM 飛ばしを観はじめに入れてよいか
    var cmReliable: Bool
    /// サムネイルの相対 URL。無ければ `null`
    var poster: String?
    var files: [RecordingFile]
    /// 主音声だけの相対 URL
    var audio: String
    var audios: [AudioTrack]

    enum CodingKeys: String, CodingKey {
        case id, title, name, serviceId, serviceName, startAt, endAt
        case durationMs, resumeMs, watchedAt, recording, chase, cmReliable, poster
        case files, audio, audios
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        name = try container.decode(String.self, forKey: .name)
        serviceId = try container.decode(Int64.self, forKey: .serviceId)
        serviceName = try container.decode(String.self, forKey: .serviceName)
        startAt = try container.decode(Int64.self, forKey: .startAt)
        endAt = try container.decode(Int64.self, forKey: .endAt)
        durationMs = try container.decodeIfPresent(Int64.self, forKey: .durationMs)
        resumeMs = try container.decodeIfPresent(Int64.self, forKey: .resumeMs)
        watchedAt = try container.decodeIfPresent(Int64.self, forKey: .watchedAt)
        recording = try container.decode(Bool.self, forKey: .recording)
        chase = try container.decodeIfPresent(String.self, forKey: .chase)
        cmReliable = try container.decode(Bool.self, forKey: .cmReliable)
        poster = try container.decodeIfPresent(String.self, forKey: .poster)
        // 知らない codec のファイルは捨てる (設計書 5 節)
        files = container.decodeDroppingUnknowns([RecordingFile].self, forKey: .files)
        audio = try container.decode(String.self, forKey: .audio)
        audios = try container.decode([AudioTrack].self, forKey: .audios)
    }
}

struct RecordingFile: @nonisolated Decodable, Equatable, Sendable {
    /// `encoded` / `hevc` / `alt` / `ts`
    var source: String
    var codec: FileCodec
    var url: String
}

/// 録画のファイルのコーデック。知らない値が来たファイルは捨てる。
enum FileCodec: String, Equatable, Sendable {
    case av1, hevc, h264, mpeg2
    /// 映像の無い局の録画の元の TS
    case none
}

extension FileCodec: @nonisolated Decodable {
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = FileCodec(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "知らない codec: \(raw)")
        }
        self = value
    }
}

// MARK: - 録画の中身 (api/recordings/<id>/detail)

struct RecordingDetail: @nonisolated Decodable, Equatable, Sendable {
    var id: Int64
    var title: String
    var name: String
    /// 短い説明。無ければ `""`
    var description: String
    /// 放送の詳細 (見出し → 本文)。無ければ `{}`
    var extended: [String: String]
}

// MARK: - 録画の状態 (api/recordings/<id>)

struct RecordingStatus: @nonisolated Decodable, Equatable, Sendable {
    var id: Int64
    /// エンコード済みのファイルがあるか
    var encoded: Bool
    var stateRaw: String
    var durationMs: Int64?
    var jikkyo: JikkyoTimes?

    var state: RecordingCondition? { RecordingCondition(rawValue: stateRaw) }

    enum CodingKeys: String, CodingKey {
        case id
        case encoded
        case stateRaw = "state"
        case durationMs
        case jikkyo
    }
}

enum RecordingCondition: String, Equatable, Sendable {
    case recording
    case recorded
    case available
    case failed
}

struct JikkyoTimes: @nonisolated Decodable, Equatable, Sendable {
    var channel: String
    /// 元の TS の先頭 (再生位置 0 の手前) の放送時刻
    var head: Int64
    /// 録画の終わりの放送時刻 (予定)
    var end: Int64
}

// MARK: - 録画の観方 (api/recordings/<id>/playback)

struct Playback: @nonisolated Decodable, Equatable, Sendable {
    /// 尺 (秒)
    var duration: Double
    /// 時刻の物差し (`encoded` / `ts`)
    var axis: PlaybackAxis
    var audios: [PlaybackAudio]
    var offers: [Offer]
    /// 放送のままのコーデック。元の録画しか無い 4K の局の録画にだけ `"hevc"` が付く (MPEG-2 では省く)
    var broadcast: String?
    /// 物差しの時刻を元の TS の時刻に戻すための情報 (`axis` が `encoded` のときだけ)
    var ruler: Ruler?
    /// 映像の無い録画だけ `false` で付く
    var video: Bool?
    /// `?playable=` を付けたときのサーバの選んだ観方。選べなければ `null`
    var auto: AutoOffer?

    enum CodingKeys: String, CodingKey {
        case duration, axis, audios, offers, broadcast, ruler, video, auto
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duration = try container.decode(Double.self, forKey: .duration)
        axis = try container.decode(PlaybackAxis.self, forKey: .axis)
        audios = try container.decode([PlaybackAudio].self, forKey: .audios)
        offers = container.decodeDroppingUnknowns([Offer].self, forKey: .offers)
        broadcast = try container.decodeIfPresent(String.self, forKey: .broadcast)
        ruler = try container.decodeIfPresent(Ruler.self, forKey: .ruler)
        video = try container.decodeIfPresent(Bool.self, forKey: .video)
        auto = try? container.decodeIfPresent(AutoOffer.self, forKey: .auto) ?? nil
    }
}

enum PlaybackAxis: String, Equatable, Sendable {
    case encoded
    case ts
}

extension PlaybackAxis: @nonisolated Decodable {
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = PlaybackAxis(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "知らない物差し: \(raw)")
        }
        self = value
    }
}

struct PlaybackAudio: @nonisolated Decodable, Equatable, Sendable {
    var id: String
    var label: String
}

struct Offer: @nonisolated Decodable, Equatable, Sendable {
    var codec: OfferCodec
    var way: OfferWay
    /// `way == "file"` のときの `source` (`encoded` / `hevc` / `alt`)
    var source: String?
    /// 入れ物の中身 (読めなければ無い)
    var codecs: String?
}

struct AutoOffer: @nonisolated Decodable, Equatable, Sendable {
    var way: OfferWay
    var codec: OfferCodec
    var source: String?
}

/// 観方の `codec`。知らない値が来た offer は捨てる。
enum OfferCodec: String, Equatable, Sendable {
    case av1, hevc, h264, mpeg2
    /// 音声だけの観方
    case audio
}

extension OfferCodec: @nonisolated Decodable {
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = OfferCodec(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "知らない codec: \(raw)")
        }
        self = value
    }
}

enum OfferWay: String, Equatable, Sendable {
    case file
    case stream
    case raw
}

extension OfferWay: @nonisolated Decodable {
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = OfferWay(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "知らない観方: \(raw)")
        }
        self = value
    }
}

struct Ruler: @nonisolated Decodable, Equatable, Sendable {
    /// v2.37 までに CM を切ってエンコードしたときに残した区間 (元の TS の時刻)。切っていなければ `null`
    var kept: [RulerInterval]?
    /// 切っていないときにエンコードで捨てた先頭の長さ (秒)
    var skip: Double
}

struct RulerInterval: @nonisolated Decodable, Equatable, Sendable {
    var start: Double
    var end: Double
}

// MARK: - 観るときの決まり (api/playback/options)

struct PlaybackOptions: @nonisolated Decodable, Equatable, Sendable {
    /// リクエストしたホスト名が家の中か
    var indoor: Bool
    /// ライブでその場でエンコードできるコーデック (AV1 → H.265 → H.264 の順)
    var liveCodecs: [OfferCodec]
    /// コーデックのメニューから外すもの
    var hidden: [OfferCodec]
    /// ライブで H.265 を出せるか
    var hevc: Bool

    enum CodingKeys: String, CodingKey {
        case indoor, liveCodecs, hidden, hevc
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        indoor = try container.decode(Bool.self, forKey: .indoor)
        liveCodecs = container.decodeDroppingUnknowns([OfferCodec].self, forKey: .liveCodecs)
        hidden = container.decodeDroppingUnknowns([OfferCodec].self, forKey: .hidden)
        hevc = try container.decode(Bool.self, forKey: .hevc)
    }
}

// MARK: - 録画のチャプター (api/recordings/<id>/chapters)

struct Chapters: @nonisolated Decodable, Equatable, Sendable {
    var chapters: [Chapter]
}

struct Chapter: @nonisolated Decodable, Equatable, Sendable {
    /// `playback` の物差しの時刻 (秒)
    var start: Double
    var end: Double
    var title: String
}

// MARK: - 検索の候補 (api/search。キーは snake_case)

/// 検索の候補の応答 (3.5・D31)。使うのは `programs` と `recordings` だけ
/// (`reservations`・`rules` は読まない)。
struct SearchResponse: @nonisolated Decodable, Sendable {
    var q: String
    var programs: SearchSection<SearchProgram>
    var recordings: SearchSection<SearchRecording>

    nonisolated var isEmpty: Bool {
        programs.rows.isEmpty && recordings.rows.isEmpty
    }
}

/// 節ごとの先頭の行と、その先にもあるか (`more`)。件数は返らない
struct SearchSection<Row: Decodable & Sendable>: @nonisolated Decodable, Sendable {
    var more: Bool
    var rows: [Row]
}

/// これからの放送の行。局の id とジャンルは返らない
struct SearchProgram: @nonisolated Decodable, Sendable, Identifiable {
    var id: Int64
    var name: String
    var serviceName: String
    var startAt: Int64
    var endAt: Int64
    /// 予約が立っていればその状態 (番組表の `reservation.state` と同じ物差し)
    var reservationState: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case serviceName = "service_name"
        case startAt = "start_at"
        case endAt = "end_at"
        case reservationState = "reservation_state"
    }
}

/// 録画の行。一覧の録画と違って尺・続き・ポスターを持たない
struct SearchRecording: @nonisolated Decodable, Sendable, Identifiable {
    var id: Int64
    var name: String
    var serviceName: String
    var startAt: Int64
    /// 録画の状態 (`recording` `recorded` `available` `failed`)
    var state: String
    /// 観る画面。録っている最中は `chase/<id>`、観られなければ `null`
    var watch: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case serviceName = "service_name"
        case startAt = "start_at"
        case state, watch
    }
}

// MARK: - ペアリング (api/device/code・api/device/token)

struct DeviceCode: @nonisolated Decodable, Equatable, Sendable {
    var deviceCode: String
    var userCode: String
    var verificationUri: String
    var verificationUriComplete: String
    var expiresIn: Int
    var interval: Int
}

struct DeviceToken: @nonisolated Decodable, Equatable, Sendable {
    var token: String
    var tokenType: String
}

// MARK: - エラーの本文

/// エラーの JSON。`{"message": "..."}` と `{"error": "..."}` のどちらも読む。
struct ErrorResponse: @nonisolated Decodable, Equatable, Sendable {
    /// 画面に出せる理由 (4xx・5xx)
    var message: String?
    /// 認証・ペアリングの合図 (`unauthorized` / `invalid_token` / `too_many_pending` など)
    var error: String?

    nonisolated var errorCode: ErrorCode? { error.flatMap(ErrorCode.init(rawValue:)) }
}

enum ErrorCode: String, Equatable, Sendable {
    /// 資格が無い (トークン無しで保護された API)
    case unauthorized
    /// 無効・知らないアクセストークン
    case invalidToken = "invalid_token"
    /// ペアリングの許可待ちが多すぎる
    case tooManyPending = "too_many_pending"
    /// ペアリングの許可を待っている
    case authorizationPending = "authorization_pending"
    /// ペアリングの訪ねが早すぎる
    case slowDown = "slow_down"
    /// ペアリングのコードが切れた
    case expiredToken = "expired_token"
    /// 知らない・使い終えたコード
    case invalidGrant = "invalid_grant"
}
