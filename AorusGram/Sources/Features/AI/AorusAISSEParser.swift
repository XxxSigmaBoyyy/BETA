import Foundation

public final class AorusAISSEParser {
    public struct Event: Equatable {
        public let name: String
        public let data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    private var buffer = Data()
    private var eventName = "message"
    private var dataLines: [Data] = []

    public init() {}

    public func append(_ data: Data) -> [Event] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: 0x0a) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0d { line.removeLast() }
            consume(line: line, into: &events)
        }
        return events
    }

    public func finish() -> [Event] {
        var events: [Event] = []
        if !buffer.isEmpty {
            var line = buffer
            buffer.removeAll(keepingCapacity: false)
            if line.last == 0x0d { line.removeLast() }
            consume(line: line, into: &events)
        }
        dispatch(into: &events)
        return events
    }

    private func consume(line: Data, into events: inout [Event]) {
        if line.isEmpty {
            dispatch(into: &events)
            return
        }
        guard line.first != 0x3a else { return }
        let field: String
        let value: Data
        if let colon = line.firstIndex(of: 0x3a) {
            field = String(decoding: line[..<colon], as: UTF8.self)
            var valueStart = line.index(after: colon)
            if valueStart < line.endIndex, line[valueStart] == 0x20 {
                valueStart = line.index(after: valueStart)
            }
            value = Data(line[valueStart...])
        } else {
            // SSE fields without ':' have an empty value.
            field = String(decoding: line, as: UTF8.self)
            value = Data()
        }
        if field == "event" {
            eventName = String(decoding: value, as: UTF8.self)
        } else if field == "data" {
            dataLines.append(value)
        }
    }

    private func dispatch(into events: inout [Event]) {
        guard !dataLines.isEmpty else {
            eventName = "message"
            return
        }
        var joined = Data()
        for index in dataLines.indices {
            if index != dataLines.startIndex { joined.append(0x0a) }
            joined.append(dataLines[index])
        }
        events.append(Event(name: eventName.isEmpty ? "message" : eventName, data: joined))
        eventName = "message"
        dataLines.removeAll(keepingCapacity: true)
    }
}
