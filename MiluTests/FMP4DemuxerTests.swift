import Foundation
import Testing
@testable import Milu

private final class BundleToken {}

@Suite struct FMP4DemuxerTests {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "mp4"))
        return try Data(contentsOf: url)
    }

    private func parse(_ data: Data, chunk: Int? = nil) -> (tracks: [FMP4Track], samples: [FMP4Sample]) {
        let demuxer = FMP4Demuxer()
        var tracks: [FMP4Track] = []
        var samples: [FMP4Sample] = []
        func take(_ events: [FMP4Event]) {
            for event in events {
                switch event {
                case .initialization(let value): tracks = value
                case .samples(let value): samples.append(contentsOf: value)
                }
            }
        }
        if let chunk {
            var start = data.startIndex
            while start < data.endIndex {
                let end = min(start + chunk, data.endIndex)
                take(demuxer.feed(data[start..<end]))
                start = end
            }
        } else {
            take(demuxer.feed(data))
        }
        return (tracks, samples)
    }

    @Test func liveH264Tracks() throws {
        let (tracks, _) = parse(try fixture("live-h264"))
        #expect(tracks.count == 2)
        let video = try #require(tracks.first { $0.kind == .video })
        #expect(video.codec == "avc1.640028")
        #expect(video.timescale == 60000)
        #expect(video.width == 1440)
        #expect(video.height == 1080)
        #expect(video.displayWidth == 1920)
        #expect(video.pasp == Data([0, 0, 0, 4, 0, 0, 0, 3]))
        #expect(video.color == FMP4Color(primaries: 1, transfer: 1, matrix: 1, fullRange: false))

        let audio = try #require(tracks.first { $0.kind == .audio })
        #expect(audio.codec == "mp4a.40.2")
        #expect(audio.timescale == 48000)
        #expect(audio.channels == 2)
        #expect(audio.sampleRate == 48000)
    }

    @Test func liveH264Samples() throws {
        let (tracks, samples) = parse(try fixture("live-h264"))
        let video = try #require(tracks.first { $0.kind == .video })
        let audio = try #require(tracks.first { $0.kind == .audio })
        let videos = samples.filter { $0.trackID == video.id }
        let audios = samples.filter { $0.trackID == audio.id }
        #expect(videos.count > 30)
        #expect(audios.count > 30)
        #expect(videos.first?.pts == 0)
        #expect(videos.first?.isKeyframe == true)
        #expect((videos.first?.duration ?? 0) > 0)
        #expect(videos.contains { !$0.isKeyframe })
        #expect(audios.first?.pts == 0)
        #expect(audios.first?.duration == 1024)
        // PTS は前の標本の終わりから続く
        for (previous, next) in zip(videos, videos.dropFirst()).prefix(10) {
            #expect(next.pts == previous.pts + previous.duration)
        }
    }

    @Test func splitAtEveryByteGivesSameResult() throws {
        let data = try fixture("live-h264")
        let prefix = data.prefix(120 * 1024)
        let whole = parse(Data(prefix))
        let split = parse(Data(prefix), chunk: 1)
        #expect(whole.tracks == split.tracks)
        #expect(whole.samples == split.samples)
        #expect(!whole.samples.isEmpty)
    }

    @Test func splitAtOddChunkSizesGivesSameResult() throws {
        let data = try fixture("live-h264")
        let whole = parse(data)
        for chunk in [7, 333, 4096] {
            let split = parse(data, chunk: chunk)
            #expect(whole.tracks == split.tracks)
            #expect(whole.samples == split.samples)
        }
    }

    @Test func recordingStreamStartsAtRulerTime() throws {
        // 録画の stream は tfdt が録画の時刻そのまま (from=0 でも最初のキーフレームの時刻)
        let (tracks, samples) = parse(try fixture("stream-h264"))
        let video = try #require(tracks.first { $0.kind == .video })
        let first = try #require(samples.first { $0.trackID == video.id })
        let seconds = Double(first.pts) / Double(video.timescale)
        #expect(seconds > 0.5)
        #expect(seconds < 1.0)
    }

    @Test func chaseStartsAtZeroRegardlessOfFrom() throws {
        // chase?from=5 で取った fixture でも、tfdt は 0 から始まる (from を土台にしていない)
        let (tracks, samples) = parse(try fixture("chase-h264"))
        let video = try #require(tracks.first { $0.kind == .video })
        let audio = try #require(tracks.first { $0.kind == .audio })
        #expect(samples.first { $0.trackID == video.id }?.pts == 0)
        #expect(samples.first { $0.trackID == audio.id }?.pts == 0)
    }

    @Test func moofWithoutMdatIsSkipped() throws {
        // mdat を挟まず次の moof が来ても、feed が止まらず次へ進む
        let data = try fixture("live-h264")
        let boxes = topBoxes(data)
        let initEnd = try #require(boxes.first { $0.type == "moov" }?.range.upperBound)
        let moof = try #require(boxes.first { $0.type == "moof" }?.range)
        let mdat = try #require(boxes.first { $0.type == "mdat" }?.range)

        var broken = data.prefix(initEnd)
        broken.append(data[moof])
        broken.append(data[moof.lowerBound..<mdat.upperBound])

        let whole = parse(Data(broken))
        #expect(whole.tracks.count == 2)
        #expect(!whole.samples.isEmpty)
        let split = parse(Data(broken), chunk: 7)
        #expect(split.tracks == whole.tracks)
        #expect(split.samples == whole.samples)
    }

    private func topBoxes(_ data: Data) -> [(type: String, range: Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var at = 0
        while at + 8 <= data.count {
            let size = Int(data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: at, as: UInt32.self).bigEndian
            })
            guard size >= 8, at + size <= data.count else { break }
            let type = String(decoding: data[(data.startIndex + at + 4)..<(data.startIndex + at + 8)], as: UTF8.self)
            out.append((type, at..<(at + size)))
            at += size
        }
        return out
    }

    @Test func liveHevcTracks() throws {
        let (tracks, samples) = parse(try fixture("live-hevc"))
        let video = try #require(tracks.first { $0.kind == .video })
        #expect(video.codec.hasPrefix("hvc1."))
        #expect(video.timescale == 60000)
        #expect(video.width == 1440)
        #expect(video.displayWidth == 1920)
        #expect(!samples.isEmpty)
    }
}
