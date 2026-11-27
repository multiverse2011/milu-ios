import Foundation
import Testing

@testable import Milu

struct CaptionPageTests {
    private let json = """
    {
      "v": 1,
      "plane": [960, 540],
      "duration": 3000,
      "runs": [
        {
          "x": 250, "y": 450, "w": 40, "h": 60,
          "fx": 2, "fy": 12,
          "size": 36,
          "scaleX": 1,
          "text": "字幕です",
          "fg": "#ffffffff",
          "bg": "#00000080"
        },
        {
          "x": 410, "y": 450, "w": 40, "h": 60,
          "fx": 2, "fy": 12,
          "size": 36,
          "scaleX": 0.5,
          "text": "〓",
          "drcs": "65569",
          "fg": "#ffffffff",
          "bg": "#00000080",
          "stroke": "#000000ff",
          "flash": true,
          "joined": true,
          "box": 15,
          "ruby": true,
          "underline": true,
          "bold": true,
          "italic": true
        }
      ],
      "drcs": {
        "65569": { "w": 72, "h": 72, "depth": 16, "bits": 4, "data": "AAAA", "md5": "0123" }
      }
    }
    """

    @Test func decodesExample() throws {
        let page = try JSONDecoder().decode(CaptionPage.self, from: Data(json.utf8))
        #expect(page.v == 1)
        #expect(page.isSupported)
        #expect(page.planeWidth == 960)
        #expect(page.planeHeight == 540)
        #expect(page.duration == 3000)
        #expect(page.runs.count == 2)

        let run = page.runs[0]
        #expect(run.x == 250 && run.y == 450 && run.w == 40 && run.h == 60)
        #expect(run.fx == 2 && run.fy == 12)
        #expect(run.size == 36)
        #expect(run.scaleX == 1)
        #expect(run.text == "字幕です")
        #expect(run.fg == "#ffffffff")
        #expect(run.bg == "#00000080")
        #expect(run.stroke == nil)
        #expect(run.drcs == nil)
        #expect(run.flash == nil)

        let decorated = page.runs[1]
        #expect(decorated.scaleX == 0.5)
        #expect(decorated.drcs == "65569")
        #expect(decorated.stroke == "#000000ff")
        #expect(decorated.flash == true)
        #expect(decorated.joined == true)
        #expect(decorated.box == 15)
        #expect(decorated.ruby == true)
        #expect(decorated.underline == true)
        #expect(decorated.bold == true)
        #expect(decorated.italic == true)

        let drcs = try #require(page.drcs?["65569"])
        #expect(drcs.w == 72 && drcs.h == 72)
        #expect(drcs.depth == 16 && drcs.bits == 4)
        #expect(drcs.data == "AAAA")
        #expect(drcs.md5 == "0123")
    }

    @Test func durationNullMeansUntilNext() throws {
        let page = try JSONDecoder().decode(
            CaptionPage.self,
            from: Data(#"{"v": 1, "plane": [960, 540], "duration": null, "runs": []}"#.utf8)
        )
        #expect(page.duration == nil)
        #expect(page.runs.isEmpty)
        #expect(page.drcs == nil)
    }

    @Test func unknownVersionIsNotSupported() throws {
        let page = try JSONDecoder().decode(
            CaptionPage.self,
            from: Data(#"{"v": 2, "plane": [960, 540], "duration": null, "runs": []}"#.utf8)
        )
        #expect(!page.isSupported)
    }

    @Test func omitsRunAndDrcs() throws {
        let page = try JSONDecoder().decode(
            CaptionPage.self,
            from: Data(##"{"v": 1, "plane": [960, 540], "duration": 1000, "runs": [{"x":0,"y":0,"w":10,"h":10,"fx":0,"fy":0,"size":10,"scaleX":1,"text":"字","fg":"#ffffffff","bg":"#000000ff"}]}"##.utf8)
        )
        #expect(page.runs[0].joined == nil)
        #expect(page.runs[0].stroke == nil)
        #expect(page.drcs == nil)
    }
}
