import Foundation
import Testing
@testable import Milu

@Suite struct TVLiveTextTests {
    private static func service(_ id: Int64) -> Service {
        Service(
            id: id,
            type: .GR,
            name: "局\(id)",
            remoteControlKey: nil,
            logo: nil,
            live: "api/services/\(id)/live",
            airing: true,
            video: true,
            now: nil
        )
    }

    private static let services = [service(1), service(2), service(3)]

    /// 2026-11-19 15:00 から 30 分の番組
    private static func program(start: Int64 = 1_795_042_800_000, minutes: Int64 = 30) -> CurrentProgram {
        CurrentProgram(
            id: 1,
            title: "番組",
            startAt: start,
            endAt: start + minutes * 60_000,
            reserved: false,
            recording: false,
            audios: []
        )
    }

    @Test func 左右で前後の局を選ぶ() {
        #expect(TVLiveText.neighbor(of: Self.services[1], in: Self.services, by: 1)?.id == 3)
        #expect(TVLiveText.neighbor(of: Self.services[1], in: Self.services, by: -1)?.id == 1)
    }

    @Test func 端は回り込む() {
        #expect(TVLiveText.neighbor(of: Self.services[2], in: Self.services, by: 1)?.id == 1)
        #expect(TVLiveText.neighbor(of: Self.services[0], in: Self.services, by: -1)?.id == 3)
    }

    @Test func 局が無ければ何も選ばない() {
        #expect(TVLiveText.neighbor(of: nil, in: [], by: 1) == nil)
    }

    @Test func いまの局が一覧に無ければ先頭を選ぶ() {
        #expect(TVLiveText.neighbor(of: nil, in: Self.services, by: 1)?.id == 1)
        #expect(TVLiveText.neighbor(of: Self.service(99), in: Self.services, by: 1)?.id == 1)
    }

    @Test func 進みは番組の前後と端で止まる() {
        let program = Self.program()
        let start = Date(timeIntervalSince1970: Double(program.startAt) / 1000)
        #expect(TVLiveText.progress(program, now: start.addingTimeInterval(-60)) < 0)
        #expect(TVLiveText.progress(program, now: start) == 0)
        #expect(TVLiveText.progress(program, now: start.addingTimeInterval(15 * 60)) == 0.5)
        #expect(TVLiveText.progress(program, now: start.addingTimeInterval(30 * 60)) == 1)
    }

    @Test func 長さの無い番組の進みは0() {
        #expect(TVLiveText.progress(Self.program(minutes: 0), now: Date()) == 0)
        #expect(TVLiveText.progress(nil, now: Date()) == 0)
    }

    @Test func 画質のボタンの名前() {
        let auto = PlaybackRules.QualityItem(codec: nil, title: "自動")
        let encoded = PlaybackRules.QualityItem(codec: .h264, title: "H.264")
        let ja = Locale(identifier: "ja_JP")
        #expect(TVLiveText.qualityItemTitle(auto, session: nil, locale: ja) == "自動")
        #expect(TVLiveText.qualityItemTitle(encoded, session: nil, locale: ja) == "H.264")
        #expect(TVLiveText.quality(selected: nil, current: nil, locale: ja) == "自動")
        #expect(TVLiveText.quality(selected: nil, current: .h264, locale: ja) == "自動 (H.264)")
        #expect(TVLiveText.quality(selected: .hevc, current: .h264, locale: ja) == "H.265")
    }
}
