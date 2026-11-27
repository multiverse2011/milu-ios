import Testing
@testable import Milu

@Suite struct SSEParserTests {
    @Test func eventAndData() {
        var parser = SSEParser()
        #expect(parser.consume(line: "event: recordings") == nil)
        #expect(parser.consume(line: "data: {\"a\":1}") == nil)
        #expect(parser.consume(line: "") == SSEEvent(event: "recordings", data: "{\"a\":1}"))
    }

    @Test func multipleDataLinesJoinWithNewline() {
        var parser = SSEParser()
        _ = parser.consume(line: "event: chapters")
        _ = parser.consume(line: "data: line1")
        _ = parser.consume(line: "data: line2")
        #expect(parser.consume(line: "") == SSEEvent(event: "chapters", data: "line1\nline2"))
    }

    @Test func commentsAndCRLF() {
        var parser = SSEParser()
        #expect(parser.consume(line: ": ping") == nil)
        _ = parser.consume(line: "data: x\r")
        #expect(parser.consume(line: "") == SSEEvent(event: "message", data: "x"))
    }

    @Test func emptyDataIsNotDispatched() {
        var parser = SSEParser()
        _ = parser.consume(line: "event: ping")
        #expect(parser.consume(line: "") == nil)
    }

    @Test func eventResetsAfterDispatch() {
        var parser = SSEParser()
        _ = parser.consume(line: "event: a")
        _ = parser.consume(line: "data: 1")
        _ = parser.consume(line: "")
        _ = parser.consume(line: "data: 2")
        #expect(parser.consume(line: "") == SSEEvent(event: "message", data: "2"))
    }

    @Test func unknownFieldsAreIgnored() {
        var parser = SSEParser()
        _ = parser.consume(line: "id: 3")
        _ = parser.consume(line: "retry: 1000")
        _ = parser.consume(line: "data: ok")
        #expect(parser.consume(line: "") == SSEEvent(event: "message", data: "ok"))
    }
}
