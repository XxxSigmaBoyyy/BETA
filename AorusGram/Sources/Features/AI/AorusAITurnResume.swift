import Foundation

// MARK: - AorusAI V7 RC4 turn control
//
// The durable half of a turn: what the server says about a turn that is already
// running, and the rules for folding a replayed stream into a conversation that may
// already hold part of it.
//
// Kept free of every AorusGram dependency — Foundation only — so the release
// preflight compiles it on its own and proves the contract's rules rather than
// leaving them to be read off the screen an hour into a build.
//
// The contract's own words, and why each matters here:
//
//   - "Один чат → один server turn_id → одно сообщение ассистента."
//     `turn.resume` is metadata, never a second assistant message.
//   - "Дедуп по (turn_id, seq), не по тексту. seq <= lastAppliedSeq — пропуск."
//     Deduplicating on text would drop a delta the model legitimately repeated.
//   - "Серверные started_at_ms / elapsed_ms авторитетны, не сбрасывать таймер в 0
//     после resume." The elapsed time shown to the reader survives the app being
//     closed, because it is the server's number and not a local stopwatch.
//   - "disconnect ≠ done ≠ Stop." A dropped socket leaves the turn resumable.

/// The envelope of one SSE frame, carried alongside the event it holds.
///
/// Separate from `AorusAIEvent` because it describes the frame rather than the thing
/// that happened: the same `response.delta` replayed after a resume is the same event
/// with a different place in the journal, and it is the place that decides whether it
/// has already been applied.
public struct AorusAIFrame: Equatable {
    public let seq: Int?
    public let serverTimeMs: Int64?

    public init(seq: Int? = nil, serverTimeMs: Int64? = nil) {
        self.seq = seq
        self.serverTimeMs = serverTimeMs
    }
}

/// What the server reports at the head of a resumed stream (`event: turn.resume`).
public struct AorusAIResumeInfo: Equatable {
    public enum State: String {
        case starting
        case running
        case done
        case error
        case cancelled
        case interrupted
    }

    public let turnId: String
    public let state: State
    public let startedAtMs: Int64
    public let completedAtMs: Int64?
    public let elapsedMs: Int64
    public let serverNowMs: Int64
    public let lastSeq: Int
    public let eventCount: Int
    public let journalComplete: Bool
    public let acknowledged: Bool
    public let ackRequired: Bool
    public let ackTurnId: String?
    public let cancelRequested: Bool

    public init(
        turnId: String,
        state: State,
        startedAtMs: Int64,
        completedAtMs: Int64?,
        elapsedMs: Int64,
        serverNowMs: Int64,
        lastSeq: Int,
        eventCount: Int,
        journalComplete: Bool,
        acknowledged: Bool,
        ackRequired: Bool,
        ackTurnId: String?,
        cancelRequested: Bool
    ) {
        self.turnId = turnId
        self.state = state
        self.startedAtMs = startedAtMs
        self.completedAtMs = completedAtMs
        self.elapsedMs = elapsedMs
        self.serverNowMs = serverNowMs
        self.lastSeq = lastSeq
        self.eventCount = eventCount
        self.journalComplete = journalComplete
        self.acknowledged = acknowledged
        self.ackRequired = ackRequired
        self.ackTurnId = ackTurnId
        self.cancelRequested = cancelRequested
    }

    /// Whether the turn has stopped for good. A stopped turn is what the reader is
    /// shown as finished and what may then be acknowledged; `starting` and `running`
    /// mean the stream that follows is still live work.
    public var isTerminal: Bool {
        switch state {
        case .starting, .running:
            return false
        case .done, .error, .cancelled, .interrupted:
            return true
        }
    }

    /// Parsed from the `turn.resume` frame. Every field the client acts on must be
    /// present and sane, or this is not a resume envelope and must not be treated as
    /// one — a half-read envelope would silently reset the reader's turn.
    public init?(json: [String: Any]) {
        guard let turnId = json["turn_id"] as? String, !turnId.isEmpty,
              let rawState = json["state"] as? String,
              let state = State(rawValue: rawState) else { return nil }
        self.turnId = turnId
        self.state = state
        self.startedAtMs = AorusAIResumeInfo.int64(json["started_at_ms"]) ?? 0
        self.completedAtMs = AorusAIResumeInfo.int64(json["completed_at_ms"])
        self.elapsedMs = max(0, AorusAIResumeInfo.int64(json["elapsed_ms"]) ?? 0)
        self.serverNowMs = AorusAIResumeInfo.int64(json["server_now_ms"]) ?? 0
        self.lastSeq = max(0, Int(AorusAIResumeInfo.int64(json["last_seq"]) ?? 0))
        self.eventCount = max(0, Int(AorusAIResumeInfo.int64(json["event_count"]) ?? 0))
        self.journalComplete = json["journal_complete"] as? Bool ?? false
        self.acknowledged = json["acknowledged"] as? Bool ?? false
        self.ackRequired = json["ack_required"] as? Bool ?? false
        self.ackTurnId = (json["ack_turn_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.cancelRequested = json["cancel_requested"] as? Bool ?? false
    }

    private static func int64(_ any: Any?) -> Int64? {
        if let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.int64Value
        }
        if let value = any as? Int64 { return value }
        if let value = any as? Int { return Int64(value) }
        if let value = any as? String { return Int64(value) }
        return nil
    }
}

/// The client's view of one turn as it is being applied, live or replayed.
///
/// One instance per assistant turn. It answers two questions and nothing else: may
/// this frame be applied, and how long has the turn been running.
public struct AorusAITurnCursor: Equatable {
    /// The server's id for this turn. Only the server names a turn — the contract is
    /// explicit that the client must not invent one.
    public private(set) var turnId: String?
    /// The highest sequence number already folded into the conversation.
    public private(set) var lastAppliedSeq: Int
    /// When the server says the turn started, in unix milliseconds. Authoritative, and
    /// never replaced by a local clock reading.
    public private(set) var startedAtMs: Int64?
    /// Set once the server has reported the turn finished, so the elapsed time freezes
    /// at what it actually took instead of continuing to climb.
    public private(set) var completedAtMs: Int64?
    /// The offset between this device's clock and the server's, measured from the
    /// resume envelope. Phones are routinely seconds out; without this the displayed
    /// duration of a resumed turn can come out negative.
    public private(set) var serverClockSkewMs: Int64

    public init(
        turnId: String? = nil,
        lastAppliedSeq: Int = 0,
        startedAtMs: Int64? = nil,
        completedAtMs: Int64? = nil,
        serverClockSkewMs: Int64 = 0
    ) {
        self.turnId = turnId
        self.lastAppliedSeq = lastAppliedSeq
        self.startedAtMs = startedAtMs
        self.completedAtMs = completedAtMs
        self.serverClockSkewMs = serverClockSkewMs
    }

    /// What to do with a frame.
    public enum Decision: Equatable {
        /// Fold it into the conversation and remember its sequence number.
        case apply
        /// Already applied — a replayed frame from before the reader closed the app.
        case skipReplayed
        /// It belongs to a different turn than the one being shown.
        case skipForeignTurn
    }

    /// Whether a frame carrying `seq` and belonging to `turnId` should be applied.
    ///
    /// A frame with no sequence number is always applied: that is every stream from
    /// before V7, and refusing those would break the clients already in the field for
    /// the sake of a guarantee their server never offered.
    public mutating func admit(seq: Int?, turnId frameTurnId: String?) -> Decision {
        if let frameTurnId, let current = turnId, frameTurnId != current {
            return .skipForeignTurn
        }
        guard let seq else { return .apply }
        guard seq > lastAppliedSeq else { return .skipReplayed }
        lastAppliedSeq = seq
        return .apply
    }

    /// Starts a new stream of the SAME turn.
    ///
    /// `id:` numbers frames within one SSE response, not within a turn — and a turn is
    /// several responses whenever the agent asks for a tool or a permission, because the
    /// server closes the stream and the client opens the next one. Carrying the previous
    /// stream's high-water mark into the next one made every frame of the continuation
    /// look already-applied: the answer stopped mid-way, the work trail stopped growing,
    /// and the turn sat on three dots for ever. The mark belongs to a stream, so it is
    /// reset when one begins; the turn's identity and its timing are untouched.
    public mutating func beginStream() {
        lastAppliedSeq = 0
    }

    /// Adopt the turn the server named. Called from `agent.start` and from
    /// `turn.resume`, which are the only two places a turn id comes from.
    public mutating func adopt(turnId newTurnId: String) {
        guard turnId != newTurnId else { return }
        turnId = newTurnId
        // A different turn starts its own numbering.
        lastAppliedSeq = 0
        startedAtMs = nil
        completedAtMs = nil
    }

    /// Fold a resume envelope in. The envelope's `last_seq` is NOT adopted as the
    /// cursor: the stream that follows is a full replay, and taking the server's
    /// high-water mark first would make every replayed frame look already-applied and
    /// leave the reader with an empty answer. What it does carry is the turn's
    /// identity and its authoritative timing.
    public mutating func apply(_ info: AorusAIResumeInfo, deviceNowMs: Int64) {
        adopt(turnId: info.turnId)
        startedAtMs = info.startedAtMs > 0 ? info.startedAtMs : startedAtMs
        completedAtMs = info.completedAtMs
        if info.serverNowMs > 0 {
            serverClockSkewMs = info.serverNowMs - deviceNowMs
        }
        // A replay re-sends the journal from the beginning, so the cursor rewinds to
        // accept it. The conversation is rebuilt from that replay rather than appended
        // to — see the reducer.
        lastAppliedSeq = 0
    }

    /// Marks the turn finished at the server's clock.
    public mutating func complete(atServerMs: Int64?) {
        completedAtMs = atServerMs ?? completedAtMs
    }

    /// How long the turn has run, in seconds, for "Работал N".
    ///
    /// Measured entirely on the server's clock: its start, and either its completion
    /// or this device's clock corrected by the measured skew. A turn resumed after the
    /// app was closed for ten minutes therefore reports the real ten minutes rather
    /// than restarting from zero, which is what the contract requires.
    public func elapsedSeconds(deviceNowMs: Int64) -> TimeInterval? {
        guard let startedAtMs, startedAtMs > 0 else { return nil }
        let endMs = completedAtMs ?? (deviceNowMs + serverClockSkewMs)
        let span = endMs - startedAtMs
        guard span >= 0 else { return nil }
        return TimeInterval(span) / 1000.0
    }
}
