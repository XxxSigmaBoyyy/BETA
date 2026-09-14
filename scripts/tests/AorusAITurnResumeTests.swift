import Foundation

// The AorusAI V7 RC4 turn-control rules, exercised by the release preflight instead
// of by a device. Every check below quotes the contract clause it enforces, so a
// future edit that breaks one fails the build with the reason attached.

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("AorusAITurnResume test failed: \(message)\n", stderr)
        exit(1)
    }
}

private let envelope: [String: Any] = [
    "protocol": "AORUS_AGENT_EVENTS_V1",
    "timeline_version": 2,
    "turn_id": "turn-7",
    "state": "running",
    "mode": "full_replay",
    "server_now_ms": 1_700_000_090_000,
    "started_at_ms": 1_700_000_000_000,
    "completed_at_ms": NSNull(),
    "elapsed_ms": 90_000,
    "last_seq": 42,
    "event_count": 43,
    "journal_complete": true,
    "acknowledged": false,
    "ack_required": false,
    "ack_turn_id": "turn-7",
    "cancel_requested": false,
]

private func parsesTheResumeEnvelope() {
    guard let info = AorusAIResumeInfo(json: envelope) else {
        fputs("AorusAITurnResume test failed: the documented envelope did not parse\n", stderr)
        exit(1)
    }
    require(info.turnId == "turn-7", "the server turn id is read")
    require(info.state == .running, "the state is read")
    require(!info.isTerminal, "a running turn is not terminal")
    require(info.startedAtMs == 1_700_000_000_000, "started_at_ms is read")
    require(info.completedAtMs == nil, "a null completed_at_ms is nil, not zero")
    require(info.lastSeq == 42 && info.eventCount == 43, "the journal counters are read")
    require(info.journalComplete && !info.acknowledged && !info.ackRequired, "the flags are read")
    require(info.ackTurnId == "turn-7", "the ack turn id is read")

    for state in ["done", "error", "cancelled", "interrupted"] {
        var terminal = envelope
        terminal["state"] = state
        require(AorusAIResumeInfo(json: terminal)?.isTerminal == true, "\(state) is terminal")
    }
    for state in ["starting", "running"] {
        var live = envelope
        live["state"] = state
        require(AorusAIResumeInfo(json: live)?.isTerminal == false, "\(state) is not terminal")
    }
}

private func refusesAHalfEnvelope() {
    // A half-read envelope must not be treated as one: acting on it would reset the
    // reader's turn to a state the server never reported.
    var noTurn = envelope
    noTurn["turn_id"] = ""
    require(AorusAIResumeInfo(json: noTurn) == nil, "an empty turn id is refused")

    var noState = envelope
    noState.removeValue(forKey: "state")
    require(AorusAIResumeInfo(json: noState) == nil, "a missing state is refused")

    var badState = envelope
    badState["state"] = "sleeping"
    require(AorusAIResumeInfo(json: badState) == nil, "an unknown state is refused")
}

private func deduplicatesBySequenceNotByText() {
    // "Дедуп по (turn_id, seq), не по тексту. seq <= lastAppliedSeq — пропуск."
    var cursor = AorusAITurnCursor()
    cursor.adopt(turnId: "turn-7")
    require(cursor.admit(seq: 1, turnId: "turn-7") == .apply, "the first frame applies")
    require(cursor.admit(seq: 2, turnId: "turn-7") == .apply, "the next frame applies")
    require(cursor.admit(seq: 2, turnId: "turn-7") == .skipReplayed, "an equal seq is skipped")
    require(cursor.admit(seq: 1, turnId: "turn-7") == .skipReplayed, "a lower seq is skipped")
    require(cursor.admit(seq: 3, turnId: "turn-7") == .apply, "a higher seq still applies")

    // The same text twice is two real deltas when the numbers differ — deduplicating
    // on the text would swallow the second one.
    require(cursor.admit(seq: 4, turnId: "turn-7") == .apply, "a repeated delta with a new seq applies")

    require(cursor.admit(seq: 99, turnId: "turn-other") == .skipForeignTurn,
            "a frame from another turn is not folded into this one")

    // Streams from before V7 carry no id at all and must keep working.
    var legacy = AorusAITurnCursor()
    require(legacy.admit(seq: nil, turnId: nil) == .apply, "an unnumbered frame applies")
    require(legacy.admit(seq: nil, turnId: nil) == .apply, "and keeps applying")
}

private func aReplayIsReappliedFromTheStart() {
    // The replay re-sends the journal from the beginning. If the envelope's last_seq
    // were adopted as the cursor, every replayed frame would look already-applied and
    // the reader would be left with an empty answer.
    var cursor = AorusAITurnCursor()
    cursor.adopt(turnId: "turn-7")
    _ = cursor.admit(seq: 1, turnId: "turn-7")
    _ = cursor.admit(seq: 2, turnId: "turn-7")

    guard let info = AorusAIResumeInfo(json: envelope) else { exit(1) }
    cursor.apply(info, deviceNowMs: 1_700_000_090_000)
    require(cursor.admit(seq: 1, turnId: "turn-7") == .apply, "the replay starts over at seq 1")
    require(cursor.admit(seq: 42, turnId: "turn-7") == .apply, "and runs to the journal head")
}

private func theTimerIsTheServersAndSurvivesResume() {
    // "Серверные started_at_ms / elapsed_ms авторитетны, не сбрасывать таймер в 0
    // после resume."
    var cursor = AorusAITurnCursor()
    guard let info = AorusAIResumeInfo(json: envelope) else { exit(1) }
    cursor.apply(info, deviceNowMs: 1_700_000_090_000)

    let elapsed = cursor.elapsedSeconds(deviceNowMs: 1_700_000_090_000)
    require(elapsed == 90.0, "a resumed turn reports the ninety seconds it really ran")
    require(elapsed != 0.0, "the timer is not reset to zero by the resume")

    let later = cursor.elapsedSeconds(deviceNowMs: 1_700_000_100_000)
    require(later == 100.0, "a still-running turn keeps climbing")

    // A device clock that is thirty seconds behind the server must not make the turn
    // look shorter than it is: the skew measured from the envelope corrects it.
    var skewed = AorusAITurnCursor()
    skewed.apply(info, deviceNowMs: 1_700_000_060_000)
    require(skewed.elapsedSeconds(deviceNowMs: 1_700_000_060_000) == 90.0,
            "a device clock behind the server still reports the true elapsed time")

    // Once finished the figure freezes at what it took.
    var finished = envelope
    finished["state"] = "done"
    finished["completed_at_ms"] = 1_700_000_075_000
    guard let doneInfo = AorusAIResumeInfo(json: finished) else { exit(1) }
    var doneCursor = AorusAITurnCursor()
    doneCursor.apply(doneInfo, deviceNowMs: 1_700_000_090_000)
    require(doneCursor.elapsedSeconds(deviceNowMs: 1_700_000_500_000) == 75.0,
            "a finished turn's duration stops climbing")
}

private func adoptingANewTurnStartsClean() {
    var cursor = AorusAITurnCursor()
    cursor.adopt(turnId: "turn-7")
    _ = cursor.admit(seq: 10, turnId: "turn-7")
    cursor.adopt(turnId: "turn-8")
    require(cursor.admit(seq: 1, turnId: "turn-8") == .apply,
            "a new turn numbers itself from the start")
}

private func neverInventsATurnId() {
    // "Turn: только server turn_id. Не создавать client uuid / client_turn_id."
    let cursor = AorusAITurnCursor()
    require(cursor.turnId == nil, "a fresh cursor has no turn id until the server names one")
    require(cursor.elapsedSeconds(deviceNowMs: 1_700_000_000_000) == nil,
            "and no elapsed time to report")
}

@main
private enum AorusAITurnResumeTests {
    static func main() {
        parsesTheResumeEnvelope()
        refusesAHalfEnvelope()
        deduplicatesBySequenceNotByText()
        aReplayIsReappliedFromTheStart()
        theTimerIsTheServersAndSurvivesResume()
        adoptingANewTurnStartsClean()
        neverInventsATurnId()
        print("AorusAITurnResume tests: OK")
    }
}
