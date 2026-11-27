import Foundation
import Testing

@testable import Milu

struct CaptionFrameReaderTests {
    private func frame(type: UInt8, timestamp: UInt64, payload: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        let length = 1 + 8 + payload.count
        out.append(UInt8(length >> 24))
        out.append(UInt8(length >> 16))
        out.append(UInt8(length >> 8))
        out.append(UInt8(length & 0xff))
        out.append(type)
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((timestamp >> UInt64(shift)) & 0xff))
        }
        out.append(contentsOf: payload)
        return out
    }

    private let pageJSON = Data(#"{"v":1,"plane":[960,540],"duration":3000,"runs":[]}"#.utf8)
    private let timestamp: UInt64 = 0x0102_0304_0506_0708

    @Test func readsSingleFrame() {
        var reader = CaptionFrameReader()
        let frames = reader.append(frame(type: 0x22, timestamp: timestamp, payload: Array(pageJSON)))
        #expect(frames.count == 1)
        #expect(frames[0].timestamp90kHz == timestamp)
        guard case .page(let page) = frames[0].content else {
            Issue.record("page でない")
            return
        }
        #expect(page.planeWidth == 960)
        #expect(page.duration == 3000)
    }

    @Test func readsFrameSplitAcrossChunks() {
        let bytes = frame(type: 0x22, timestamp: timestamp, payload: Array(pageJSON))
        var reader = CaptionFrameReader()
        var frames: [CaptionFrame] = []
        // 1 バイトずつ届いても読める
        for byte in bytes {
            frames.append(contentsOf: reader.append([byte]))
        }
        #expect(frames.count == 1)
        #expect(frames[0].timestamp90kHz == timestamp)
    }

    @Test func readsMultipleFramesInOneChunk() {
        var reader = CaptionFrameReader()
        let bytes =
            frame(type: 0x40, timestamp: 1, payload: Array(#"{"type":"ping"}"#.utf8))
            + frame(type: 0x40, timestamp: 2, payload: Array(#"{"type":"clock","at":1.0}"#.utf8))
        let frames = reader.append(bytes)
        #expect(frames.count == 2)
        #expect(frames[0].timestamp90kHz == 1)
        #expect(frames[1].timestamp90kHz == 2)
        guard case .notice(let notice) = frames[1].content else {
            Issue.record("notice でない")
            return
        }
        #expect(notice.type == "clock")
    }

    @Test func unknownTypeIsDiscarded() {
        var reader = CaptionFrameReader()
        let frames = reader.append(frame(type: 0x99, timestamp: 1, payload: [1, 2, 3]))
        #expect(frames.isEmpty)
        // バッファは消費し、続きが読める
        let next = reader.append(frame(type: 0x40, timestamp: 2, payload: Array(#"{"type":"ping"}"#.utf8)))
        #expect(next.count == 1)
    }

    @Test func undecodableJSONIsDiscarded() {
        var reader = CaptionFrameReader()
        let frames = reader.append(frame(type: 0x22, timestamp: 1, payload: Array("not json".utf8)))
        #expect(frames.isEmpty)
    }

    @Test func resyncsAfterBrokenLength() {
        var reader = CaptionFrameReader()
        // 長さが 9 未満の壊れた並び (4 バイトの長さだけ) のあとに正しいフレームが来る
        let broken: [UInt8] = [0, 0, 0, 1]
        let good = frame(type: 0x40, timestamp: 7, payload: Array(#"{"type":"ping"}"#.utf8))
        let frames = reader.append(broken + good)
        #expect(frames.count == 1)
        #expect(frames[0].timestamp90kHz == 7)
    }

    @Test func timestampIsBigEndian90kHz() {
        var reader = CaptionFrameReader()
        let frames = reader.append(frame(type: 0x40, timestamp: 90_000, payload: Array(#"{"type":"ping"}"#.utf8)))
        #expect(frames[0].timestamp90kHz == 90_000)
    }
}
