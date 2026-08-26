import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("AorusAISSEParser test failed: \(message)\n", stderr)
        exit(1)
    }
}

private func fragmentedUTF8AndCRLF() {
    let parser = AorusAISSEParser()
    let source = "event: response.delta\r\ndata: {\"data\":{\"text\":\"Привет\"}}\r\n\r\n"
    var events: [AorusAISSEParser.Event] = []
    for byte in source.utf8 {
        events.append(contentsOf: parser.append(Data([byte])))
    }
    require(events.count == 1, "fragmented event count")
    require(events[0].name == "response.delta", "fragmented event name")
    require(String(decoding: events[0].data, as: UTF8.self) == "{\"data\":{\"text\":\"Привет\"}}", "fragmented UTF-8 payload")
}

private func heartbeatMultilineAndMultipleEvents() {
    let parser = AorusAISSEParser()
    let source = ": aorus-agent-ping\n\nevent: status\ndata: {\"label\":\"Build\",\ndata: \"progress\":0.5}\n\nevent: done\ndata: {\"ok\":true}\n\n"
    let events = parser.append(Data(source.utf8))
    require(events.count == 2, "heartbeat and multiple events")
    require(events[0].name == "status", "first event name")
    require(String(decoding: events[0].data, as: UTF8.self) == "{\"label\":\"Build\",\n\"progress\":0.5}", "multiline data")
    require(events[1].name == "done", "second event name")
}

private func eofAndColonlessFields() {
    let parser = AorusAISSEParser()
    let first = parser.append(Data("event\ndata: {}".utf8))
    require(first.isEmpty, "unterminated event waits for EOF")
    let final = parser.finish()
    require(final == [AorusAISSEParser.Event(name: "message", data: Data("{}".utf8))], "EOF and colonless field")
}

@main
private enum AorusAISSEParserTests {
    static func main() {
        fragmentedUTF8AndCRLF()
        heartbeatMultilineAndMultipleEvents()
        eofAndColonlessFields()
        print("AorusAISSEParser tests: OK")
    }
}
