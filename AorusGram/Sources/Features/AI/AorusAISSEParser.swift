import Foundation

public final class AorusAISSEParser {
    public struct Event: Equatable {
        public let name: String
        public let data: Data
        /// The frame's `id:` — the server's monotonic sequence number for this turn.
        ///
        /// Carried because a resumed stream replays frames the client has already applied,
        /// and the only sound way to tell a replay from new work is the sequence number:
        /// deduplicating on the text would drop a legitimately repeated delta. nil when the
        /// server did not number the frame, which every pre-V7 stream is.
        public let seq: Int?
        /// The frame's `aorus-time:` in unix milliseconds, when the server stamped one.
        public let serverTimeMs: Int64?

        public init(name: String, data: Data, seq: Int? = nil, serverTimeMs: Int64? = nil) {
            self.name = name
            self.data = data
            self.seq = seq
            self.serverTimeMs = serverTimeMs
        }
    }

    /// The longest single SSE line that will be kept. An answer arrives as many small
    /// deltas, so nothing legitimate comes close; a peer that never sends a newline would
    /// otherwise grow this buffer until the app is killed.
    public static let maximumLineBytes = 1 << 20
    /// The largest event body that will be assembled from `data:` lines.
    public static let maximumEventBytes = 4 << 20

    private var buffer = Data()
    private var eventName = "message"
    private var dataLines: [Data] = []
    private var dataBytes = 0
    private var eventSeq: Int?
    private var eventServerTimeMs: Int64?
    /// Set when a line or an event has run past its ceiling. Everything up to the next
    /// event boundary is then discarded rather than accumulated, and the stream carries on
    /// with the next event instead of the connection being torn down.
    private var isDiscardingLine = false
    private var isDiscardingEvent = false

    public init() {}

    public func append(_ data: Data) -> [Event] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: 0x0a) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0d { line.removeLast() }
            if isDiscardingLine {
                // The tail of an over-long line. Its head is already gone, so what is left
                // is not a field and must not be parsed as one.
                isDiscardingLine = false
                isDiscardingEvent = true
                continue
            }
            consume(line: line, into: &events)
        }
        if buffer.count > Self.maximumLineBytes {
            buffer.removeAll(keepingCapacity: false)
            isDiscardingLine = true
        }
        return events
    }

    /// Ends the stream.
    ///
    /// Whatever is still buffered was not terminated by a blank line, so by the
    /// specification it is an incomplete event and must be discarded. It used to be
    /// dispatched instead, which meant a server that wrote `event: done` / `data: {"ok":true}`
    /// and then closed the socket without the terminating blank line produced a `done(ok:
    /// true)` — and a truncated answer was reported to the user as a finished one. Only
    /// events that were completed *during* the stream survive; the trailing fragment is
    /// dropped, and a stream that ends mid-event ends without a `done`, which the transport
    /// correctly reports as a failure.
    public func finish() -> [Event] {
        buffer.removeAll(keepingCapacity: false)
        dataLines.removeAll(keepingCapacity: false)
        dataBytes = 0
        eventName = "message"
        eventSeq = nil
        eventServerTimeMs = nil
        isDiscardingLine = false
        isDiscardingEvent = false
        return []
    }

    private func consume(line: Data, into events: inout [Event]) {
        if line.isEmpty {
            dispatch(into: &events)
            return
        }
        guard line.first != 0x3a else { return }
        guard !isDiscardingEvent else { return }
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
            // An event name is a short identifier; anything longer is not one, and keeping
            // it would put an unbounded server string into every event this parser emits.
            eventName = String(decoding: value.prefix(128), as: UTF8.self)
        } else if field == "data" {
            guard dataBytes + value.count <= Self.maximumEventBytes else {
                dataLines.removeAll(keepingCapacity: false)
                dataBytes = 0
                isDiscardingEvent = true
                return
            }
            dataBytes += value.count + 1
            dataLines.append(value)
        } else if field == "id" {
            // Bounded before it is parsed: an id line is a small integer, and a peer that
            // sent megabytes here would otherwise be handed straight to Int().
            eventSeq = Int(String(decoding: value.prefix(32), as: UTF8.self))
        } else if field == "aorus-time" {
            eventServerTimeMs = Int64(String(decoding: value.prefix(32), as: UTF8.self))
        }
    }

    private func dispatch(into events: inout [Event]) {
        defer {
            isDiscardingEvent = false
            dataBytes = 0
            // Per the SSE specification the id persists across events until the server
            // sends another one; this protocol stamps every frame, so the safe reading is
            // to clear it and report nil rather than attribute one frame's number to the
            // next frame — a wrong sequence number is worse than no sequence number, since
            // the whole point of it is deciding what has already been applied.
            eventSeq = nil
            eventServerTimeMs = nil
        }
        guard !isDiscardingEvent else {
            dataLines.removeAll(keepingCapacity: false)
            eventName = "message"
            return
        }
        guard !dataLines.isEmpty else {
            eventName = "message"
            return
        }
        var joined = Data()
        for index in dataLines.indices {
            if index != dataLines.startIndex { joined.append(0x0a) }
            joined.append(dataLines[index])
        }
        events.append(Event(
            name: eventName.isEmpty ? "message" : eventName,
            data: joined,
            seq: eventSeq,
            serverTimeMs: eventServerTimeMs
        ))
        eventName = "message"
        dataLines.removeAll(keepingCapacity: true)
    }
}
