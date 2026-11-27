import Foundation
import Testing

@testable import Milu

/// 4.1 の応答の読み。fixture は api.md の例をそのまま使う。
struct ModelsTests {
    private let decoder = JSONDecoder()

    // MARK: 局の一覧

    private let serviceJSON = """
    [
      {
        "id": 3227310008,
        "type": "GR",
        "name": "TOKYO MX",
        "remoteControlKey": 9,
        "logo": "api/services/3227310008/logo",
        "live": "api/services/3227310008/live",
        "jikkyo": "jk9",
        "airing": true,
        "video": true,
        "now": {
          "id": 32736103210001,
          "title": "ニュース",
          "startAt": 1790000000000,
          "endAt": 1790001800000,
          "reserved": false,
          "recording": false,
          "audios": [
            { "id": "0:main", "stream": 0, "side": "main", "label": "主音声 (日本語)", "main": true },
            { "id": "0:sub", "stream": 0, "side": "sub", "label": "副音声 (英語)" }
          ]
        }
      },
      { "id": 1, "type": "NEWTYPE", "name": "将来の局", "live": "api/services/1/live", "airing": true, "video": true, "now": null }
    ]
    """

    @Test func services() throws {
        let services = try decoder.decodeArrayDroppingUnknowns([Service].self, from: Data(serviceJSON.utf8))
        // 知らない種別の局は捨てる
        #expect(services.count == 1)
        let service = try #require(services.first)
        #expect(service.type == .GR)
        #expect(service.id == 3227310008)
        #expect(service.remoteControlKey == 9)
        #expect(service.logo == "api/services/3227310008/logo")
        #expect(service.airing && service.video)
        let now = try #require(service.now)
        #expect(now.id == 32736103210001)
        #expect(!now.reserved && !now.recording)
        #expect(now.audios.count == 2)
        #expect(now.audios[0].main == true)
        #expect(now.audios[1].main == nil)
    }

    @Test func serviceWithoutNow() throws {
        let json = #"""
        [{ "id": 3274201072, "type": "GR", "name": "テレ東", "remoteControlKey": 7,
           "logo": null, "live": "api/services/3274201072/live", "now": null,
           "airing": true, "video": true, "jikkyo": null }]
        """#
        let services = try decoder.decodeArrayDroppingUnknowns([Service].self, from: Data(json.utf8))
        #expect(services.count == 1)
        #expect(services[0].now == nil)
        #expect(services[0].logo == nil)
    }

    // MARK: 番組表

    private let guideJSON = """
    {
      "type": "GR",
      "from": 1790013600000,
      "to": 1790100000000,
      "until": 1790600000000,
      "services": [
        {
          "id": 3227310008,
          "name": "TOKYO MX",
          "mainId": null,
          "remoteControlKey": 9,
          "logo": "api/services/3227310008/logo",
          "programs": [
            {
              "id": 32736103210001,
              "name": "[新]番組 第1話[字]",
              "startAt": 1790013600000,
              "endAt": 1790015400000,
              "description": "番組の概要",
              "genre": 7,
              "copyNever": false,
              "reservation": { "state": "conflict", "reason": "チューナーが足りません", "ruleId": 2 },
              "recordingId": null
            },
            {
              "id": 32736103210002,
              "name": "終わった番組",
              "startAt": 1790000000000,
              "endAt": 1790003600000,
              "genre": null,
              "copyNever": false,
              "reservation": { "state": "done", "reason": null, "ruleId": null },
              "recordingId": 12
            }
          ]
        }
      ]
    }
    """

    @Test func guide() throws {
        let guide = try decoder.decode(GuideResponse.self, from: Data(guideJSON.utf8))
        #expect(guide.type == .GR)
        #expect(guide.from == 1790013600000)
        #expect(guide.until == 1790600000000)
        #expect(guide.services.count == 1)
        let program = guide.services[0].programs[0]
        #expect(program.name == "[新]番組 第1話[字]")
        #expect(program.genre == 7)
        let reservation = try #require(program.reservation)
        #expect(reservation.state == .conflict)
        #expect(reservation.reason == "チューナーが足りません")
        #expect(reservation.ruleId == 2)
        let ended = guide.services[0].programs[1]
        #expect(ended.genre == nil)
        #expect(ended.recordingId == 12)
        #expect(ended.reservation?.state == .done)
    }

    @Test func unknownReservationStateKeepsProgram() throws {
        let json = """
        {
          "type": "BS", "from": 1790013600000, "to": 1790100000000, "until": null,
          "services": [
            { "id": 1, "name": "BS", "mainId": null, "remoteControlKey": 101, "logo": null,
              "programs": [
                { "id": 10, "name": "番組", "startAt": 1790013600000, "endAt": 1790017200000,
                  "description": "", "genre": 0, "copyNever": false,
                  "reservation": { "state": "brand_new_state", "reason": "理由", "ruleId": null },
                  "recordingId": null }
              ] }
          ]
        }
        """
        let guide = try decoder.decode(GuideResponse.self, from: Data(json.utf8))
        let reservation = try #require(guide.services[0].programs[0].reservation)
        #expect(reservation.state == nil)
        #expect(reservation.stateRaw == "brand_new_state")
        #expect(reservation.reason == "理由")
    }

    // MARK: 番組の中身 (snake_case)

    private let programDetailJSON = """
    {
      "name": "[新]番組 第1話[字]",
      "service_name": "TOKYO MX",
      "start_at": 1790000000000,
      "end_at": 1790001800000,
      "description": "番組の概要",
      "extended": { "番組内容": "…", "出演者": "…" },
      "genre_detail": [{ "lv1": 7, "lv2": 0 }],
      "audios": [
        { "componentType": 3, "langs": ["jpn"], "main": true },
        { "componentType": 3, "langs": ["jpn"], "text": "解説ステレオ" }
      ],
      "video_type": "mpeg2",
      "video_resolution": "1080i",
      "is_free": true,
      "copy_never": false,
      "series_episode": 1,
      "series_last_episode": 12,
      "series_repeat": 0
    }
    """

    @Test func programDetail() throws {
        let detail = try decoder.decode(ProgramDetail.self, from: Data(programDetailJSON.utf8))
        #expect(detail.serviceName == "TOKYO MX")
        #expect(detail.startAt == 1790000000000)
        #expect(detail.extended?["番組内容"] == "…")
        #expect(detail.genreDetail == [GenreDetail(lv1: 7, lv2: 0)])
        #expect(detail.audios?.count == 2)
        #expect(detail.audios?[1].text == "解説ステレオ")
        #expect(detail.videoType == "mpeg2")
        #expect(detail.isFree && !detail.copyNever)
        #expect(detail.seriesEpisode == 1 && detail.seriesLastEpisode == 12 && detail.seriesRepeat == 0)
    }

    // MARK: 録る・取り消す

    @Test func recordResponses() throws {
        let record = try decoder.decode(RecordResponse.self, from: Data(#"""
        { "recorded": "ニュース", "programId": 32736103210001, "reserved": true, "state": "scheduled", "reason": null }
        """#.utf8))
        #expect(record.recorded == "ニュース")
        #expect(record.programId == 32736103210001)
        #expect(record.reserved)
        #expect(record.state == .scheduled)

        let conflicted = try decoder.decode(RecordResponse.self, from: Data(#"""
        { "recorded": "ニュース", "programId": 32736103210001, "reserved": false, "state": "conflict", "reason": "チューナーが足りません" }
        """#.utf8))
        #expect(!conflicted.reserved)
        #expect(conflicted.state == .conflict)
        #expect(conflicted.reason == "チューナーが足りません")

        let cancel = try decoder.decode(CancelResponse.self, from: Data(#"{ "stopped": false }"#.utf8))
        #expect(!cancel.stopped)
    }

    // MARK: 録画の一覧

    private let recordingJSON = """
    [
      {
        "id": 12,
        "title": "番組 第1話",
        "name": "[新]番組 第1話[字]",
        "serviceId": 3227310008,
        "serviceName": "TOKYO MX",
        "startAt": 1790000000000,
        "endAt": 1790001800000,
        "durationMs": 1800000,
        "resumeMs": 754000,
        "watchedAt": null,
        "recording": false,
        "chase": "api/recordings/12/chase",
        "cmReliable": true,
        "poster": "api/recordings/12/poster",
        "files": [
          { "source": "encoded", "codec": "av1", "url": "api/recordings/12/file?source=encoded" },
          { "source": "hevc", "codec": "hevc", "url": "api/recordings/12/file?source=hevc" },
          { "source": "alt", "codec": "h264", "url": "api/recordings/12/file?source=alt" },
          { "source": "ts", "codec": "mpeg2", "url": "api/recordings/12/file?source=ts" }
        ],
        "audio": "api/recordings/12/file?audio=only",
        "audios": [
          { "id": "0:both", "stream": 0, "side": "both", "label": "ステレオ (日本語)", "main": true }
        ]
      }
    ]
    """

    @Test func recordings() throws {
        let recordings = try decoder.decodeArrayDroppingUnknowns([Recording].self, from: Data(recordingJSON.utf8))
        let recording = try #require(recordings.first)
        #expect(recording.id == 12)
        #expect(recording.durationMs == 1800000)
        #expect(recording.resumeMs == 754000)
        #expect(recording.watchedAt == nil)
        #expect(recording.chase == "api/recordings/12/chase")
        #expect(recording.cmReliable)
        #expect(recording.files.map(\.source) == ["encoded", "hevc", "alt", "ts"])
        #expect(recording.files.map(\.codec) == [.av1, .hevc, .h264, .mpeg2])
        #expect(recording.audios[0].id == "0:both")
    }

    @Test func recordingWhileRecording() throws {
        let json = """
        [{
          "id": 13, "title": "いま録っている", "name": "いま録っている",
          "serviceId": 3227310008, "serviceName": "TOKYO MX",
          "startAt": 1790000000000, "endAt": 1790001800000,
          "durationMs": null, "resumeMs": null, "watchedAt": null,
          "recording": true, "chase": "api/recordings/13/chase", "cmReliable": false,
          "poster": null,
          "files": [{ "source": "ts", "codec": "mpeg2", "url": "api/recordings/13/file?source=ts" }],
          "audio": "api/recordings/13/file?audio=only",
          "audios": [{ "id": "0:both", "stream": 0, "side": "both", "label": "音声" }]
        }]
        """
        let recording = try decoder.decodeArrayDroppingUnknowns([Recording].self, from: Data(json.utf8))[0]
        #expect(recording.recording)
        #expect(recording.durationMs == nil)
        #expect(recording.poster == nil)
    }

    @Test func unknownFileCodecIsDropped() throws {
        let json = """
        [{
          "id": 12, "title": "番組", "name": "番組",
          "serviceId": 3227310008, "serviceName": "TOKYO MX",
          "startAt": 1790000000000, "endAt": 1790001800000,
          "durationMs": 1800000, "resumeMs": null, "watchedAt": null,
          "recording": false, "chase": null, "cmReliable": true, "poster": null,
          "files": [
            { "source": "ts", "codec": "h266", "url": "api/recordings/12/file?source=ts" },
            { "source": "ts", "codec": "mpeg2", "url": "api/recordings/12/file?source=ts" }
          ],
          "audio": "api/recordings/12/file?audio=only",
          "audios": []
        }]
        """
        let recording = try decoder.decodeArrayDroppingUnknowns([Recording].self, from: Data(json.utf8))[0]
        #expect(recording.files.count == 1)
        #expect(recording.files[0].codec == .mpeg2)
    }

    // MARK: 録画の中身・状態

    @Test func recordingDetail() throws {
        let detail = try decoder.decode(RecordingDetail.self, from: Data(#"""
        { "id": 12, "title": "番組 第1話", "name": "[新]番組 第1話[字]",
          "description": "番組の概要", "extended": { "出演者": "…", "番組内容": "…" } }
        """#.utf8))
        #expect(detail.id == 12)
        #expect(detail.description == "番組の概要")
        #expect(detail.extended["出演者"] == "…")
    }

    @Test func recordingStatus() throws {
        let status = try decoder.decode(RecordingStatus.self, from: Data(#"""
        { "id": 12, "encoded": false, "state": "recording", "durationMs": null,
          "jikkyo": { "channel": "jk9", "head": 1790000000000, "end": 1790001815000 } }
        """#.utf8))
        #expect(!status.encoded)
        #expect(status.state == .recording)
        #expect(status.durationMs == nil)
        #expect(status.jikkyo?.channel == "jk9")

        let encoded = try decoder.decode(RecordingStatus.self, from: Data(#"""
        { "id": 12, "encoded": true, "state": "available", "durationMs": 65416, "jikkyo": null }
        """#.utf8))
        #expect(encoded.state == .available)
        #expect(encoded.jikkyo == nil)
    }

    // MARK: 録画の観方

    private let playbackJSON = """
    {
      "duration": 1790.5,
      "axis": "encoded",
      "audios": [
        { "id": "0", "label": "主音声" },
        { "id": "1", "label": "副音声" }
      ],
      "offers": [
        { "codec": "av1", "way": "file", "source": "encoded", "codecs": "av01.0.08M.08,opus" },
        { "codec": "h264", "way": "stream", "codecs": "avc1.640029,mp4a.40.2" },
        { "codec": "av1", "way": "stream", "codecs": "av01.0.08M.08,Opus" },
        { "codec": "mpeg2", "way": "raw" }
      ],
      "ruler": { "kept": null, "skip": 0.5 }
    }
    """

    @Test func playback() throws {
        let playback = try decoder.decode(Playback.self, from: Data(playbackJSON.utf8))
        #expect(playback.duration == 1790.5)
        #expect(playback.axis == .encoded)
        #expect(playback.audios.map(\.id) == ["0", "1"])
        #expect(playback.offers.map(\.way) == [.file, .stream, .stream, .raw])
        #expect(playback.offers[0].source == "encoded")
        #expect(playback.offers[0].codecs == "av01.0.08M.08,opus")
        #expect(playback.offers[3].codec == .mpeg2)
        #expect(playback.ruler?.kept == nil)
        #expect(playback.ruler?.skip == 0.5)
        // broadcast は応答の一番外の項目 (MPEG-2 の録画では省く)
        #expect(playback.broadcast == nil)
        #expect(playback.video == nil)
        #expect(playback.auto == nil)
    }

    @Test func playbackDropsUnknownOffers() throws {
        let json = """
        {
          "duration": 100, "axis": "ts", "broadcast": "hevc",
          "audios": [], "offers": [
            { "codec": "h266", "way": "stream" },
            { "codec": "h264", "way": "stream", "codecs": "avc1.640029,mp4a.40.2" },
            { "codec": "hevc", "way": "file", "source": "hevc" }
          ]
        }
        """
        let playback = try decoder.decode(Playback.self, from: Data(json.utf8))
        #expect(playback.axis == .ts)
        #expect(playback.offers.map(\.codec) == [.h264, .hevc])
        // broadcast は offer の中ではなく、応答の一番外の項目
        #expect(playback.broadcast == "hevc")
        #expect(playback.ruler == nil)
    }

    // MARK: 観るときの決まり

    @Test func playbackOptions() throws {
        let options = try decoder.decode(PlaybackOptions.self, from: Data(#"""
        { "indoor": true, "liveCodecs": ["hevc", "h264"], "hidden": ["av1", "h264"], "hevc": true }
        """#.utf8))
        #expect(options.indoor)
        #expect(options.liveCodecs == [.hevc, .h264])
        #expect(options.hidden == [.av1, .h264])
        #expect(options.hevc)

        let oldServer = try decoder.decode(PlaybackOptions.self, from: Data(#"""
        { "indoor": false, "liveCodecs": ["h266", "h264"], "hidden": [], "hevc": false }
        """#.utf8))
        #expect(!oldServer.indoor)
        // 知らない codec は捨てる
        #expect(oldServer.liveCodecs == [.h264])
    }

    // MARK: チャプター

    @Test func chapters() throws {
        let chapters = try decoder.decode(Chapters.self, from: Data(#"""
        { "chapters": [
            { "start": 0, "end": 612.4, "title": "本編" },
            { "start": 612.4, "end": 702.4, "title": "CM" },
            { "start": 702.4, "end": 1790.5, "title": "本編" }
        ] }
        """#.utf8))
        #expect(chapters.chapters.count == 3)
        #expect(chapters.chapters[1].title == "CM")

        let empty = try decoder.decode(Chapters.self, from: Data(#"{ "chapters": [] }"#.utf8))
        #expect(empty.chapters.isEmpty)
    }

    // MARK: 検索の候補 (api/search)

    @Test func searchSuggestions() throws {
        // api.md の例。予約とルールの節は読まない
        let response = try decoder.decode(SearchResponse.self, from: Data(#"""
        {
          "q": "でんぱ",
          "programs": {
            "more": true,
            "rows": [
              {
                "id": 3227310008123,
                "name": "でんぱ劇場",
                "service_name": "でんぱテレビ",
                "start_at": 1790000000000,
                "end_at": 1790001800000,
                "reservation_state": null
              }
            ]
          },
          "recordings": {
            "more": false,
            "rows": [
              {
                "id": 12,
                "name": "でんぱ劇場 #1",
                "service_name": "でんぱテレビ",
                "start_at": 1789000000000,
                "state": "available",
                "watch": "watch/12"
              }
            ]
          },
          "reservations": { "more": false, "rows": [] },
          "rules": { "more": false, "rows": [] }
        }
        """#.utf8))

        #expect(response.q == "でんぱ")
        #expect(response.programs.more)
        let program = try #require(response.programs.rows.first)
        #expect(program.id == 3227310008123)
        #expect(program.name == "でんぱ劇場")
        #expect(program.serviceName == "でんぱテレビ")
        #expect(program.startAt == 1790000000000)
        #expect(program.endAt == 1790001800000)
        #expect(program.reservationState == nil)
        #expect(!response.recordings.more)
        let recording = try #require(response.recordings.rows.first)
        #expect(recording.id == 12)
        #expect(recording.name == "でんぱ劇場 #1")
        #expect(recording.serviceName == "でんぱテレビ")
        #expect(recording.startAt == 1789000000000)
        #expect(recording.state == "available")
        #expect(recording.watch == "watch/12")
        #expect(!response.isEmpty)
    }

    @Test func searchReservationStateAndMissingWatch() throws {
        let response = try decoder.decode(SearchResponse.self, from: Data(#"""
        {
          "q": "",
          "programs": { "more": false, "rows": [
            { "id": 1, "name": "番組", "service_name": "局", "start_at": 1, "end_at": 2, "reservation_state": "recording" }
          ] },
          "recordings": { "more": false, "rows": [
            { "id": 2, "name": "録画", "service_name": "局", "start_at": 1, "state": "failed", "watch": null }
          ] }
        }
        """#.utf8))
        let program = try #require(response.programs.rows.first)
        #expect(program.reservationState == "recording")
        let recording = try #require(response.recordings.rows.first)
        #expect(recording.watch == nil)
        // 追っかけの観る先
        let chase = try decoder.decode(SearchRecording.self, from: Data(#"""
        { "id": 12, "name": "録画", "service_name": "局", "start_at": 1789000000000, "state": "recording", "watch": "chase/12" }
        """#.utf8))
        #expect(chase.watch == "chase/12")
        #expect(chase.state == "recording")

        let empty = try decoder.decode(SearchResponse.self, from: Data(#"""
        { "q": "", "programs": { "more": false, "rows": [] }, "recordings": { "more": false, "rows": [] } }
        """#.utf8))
        #expect(empty.isEmpty)
    }

    // MARK: ペアリング・エラー

    @Test func pairing() throws {
        let code = try decoder.decode(DeviceCode.self, from: Data(#"""
        { "deviceCode": "abc", "userCode": "ABCD-EFGH", "verificationUri": "device",
          "verificationUriComplete": "device?code=ABCD-EFGH", "expiresIn": 600, "interval": 5 }
        """#.utf8))
        #expect(code.deviceCode == "abc")
        #expect(code.userCode == "ABCD-EFGH")
        #expect(code.verificationUriComplete == "device?code=ABCD-EFGH")
        #expect(code.expiresIn == 600 && code.interval == 5)

        let token = try decoder.decode(DeviceToken.self, from: Data(#"""
        { "token": "denpa_xxx", "tokenType": "Bearer" }
        """#.utf8))
        #expect(token.token == "denpa_xxx")
        #expect(token.tokenType == "Bearer")
    }

    @Test func errorBodies() throws {
        let message = try decoder.decode(ErrorResponse.self, from: Data(#"{ "message": "番組 ID が不正です" }"#.utf8))
        #expect(message.message == "番組 ID が不正です")
        #expect(message.error == nil)

        let unauthorized = try decoder.decode(ErrorResponse.self, from: Data(#"{ "error": "unauthorized" }"#.utf8))
        #expect(unauthorized.errorCode == .unauthorized)
        #expect(unauthorized.message == nil)

        #expect(ErrorResponse(message: nil, error: "invalid_token").errorCode == .invalidToken)
        #expect(ErrorResponse(message: nil, error: "too_many_pending").errorCode == .tooManyPending)
        #expect(ErrorResponse(message: nil, error: "authorization_pending").errorCode == .authorizationPending)
        #expect(ErrorResponse(message: nil, error: "slow_down").errorCode == .slowDown)
        #expect(ErrorResponse(message: nil, error: "expired_token").errorCode == .expiredToken)
        #expect(ErrorResponse(message: nil, error: "invalid_grant").errorCode == .invalidGrant)
        #expect(ErrorResponse(message: nil, error: "謎").errorCode == nil)
    }
}
