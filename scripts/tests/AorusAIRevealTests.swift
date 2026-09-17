import Foundation

// How much of an answer is on screen, and where it is safe to stop.
//
// The report this exists for: "дал запрос и ждешь, а после полный ответ появляется" — a turn
// that is not streamed by the server lands in one piece, and a wall of text appearing is not
// reading. So the answer is typed out, and the cut is never made in the middle of a formula.

private var failures: [String] = []

private func expect<Value: Equatable>(_ actual: Value, _ expected: Value, _ what: String) {
    if actual != expected {
        failures.append("\(what)\n      expected: \(expected)\n      actual:   \(actual)")
    }
}

private func expect(_ condition: Bool, _ what: String) {
    if !condition {
        failures.append(what)
    }
}

// MARK: - Pace

private func typesAtAReadablePaceAndNeverStalls() {
    // Caught up: nothing to do, and no going backwards.
    expect(AorusAIReveal.charactersToShow(revealed: 40, available: 40, elapsed: 1), 40,
           "a reveal that has caught up stays where it is")
    expect(AorusAIReveal.charactersToShow(revealed: 90, available: 40, elapsed: 1), 40,
           "and one asked for more than has arrived is clamped to what has")

    // A frame at 30Hz must always move something. At the resting rate that is three
    // characters; a rate that rounded down to nothing would freeze the answer.
    let frame = 1.0 / 30.0
    let step = AorusAIReveal.charactersToShow(revealed: 0, available: 500, elapsed: frame)
    expect(step >= 1, "a frame always reveals at least one character")
    expect(step <= 20, "and never a whole paragraph at the resting pace")

    // Text that really streams is barely touched: a second of arrivals at reading speed is
    // revealed in about a second.
    let second = AorusAIReveal.charactersToShow(revealed: 0, available: 95, elapsed: 1.0)
    expect(second >= 95, "a second's worth of streamed text is shown within the second")

    // A whole answer delivered at once is typed out, not flashed — and not left for minutes
    // either. Ten thousand characters must be on screen inside the stated lag.
    var revealed = 0
    var ticks = 0
    while revealed < 10_000, ticks < 10_000 {
        revealed = AorusAIReveal.charactersToShow(revealed: revealed, available: 10_000, elapsed: frame)
        ticks += 1
    }
    expect(revealed, 10_000, "a ten-thousand-character answer finishes")
    let seconds = Double(ticks) * frame
    expect(seconds <= AorusAIReveal.maximumLag + 0.2,
           "and does so within the lag it promises (took \(seconds)s)")
    expect(ticks > 6, "but is typed rather than dumped in a frame or two")

    // A short answer is not dumped either: 300 characters take a moment to read.
    revealed = 0
    ticks = 0
    while revealed < 300, ticks < 10_000 {
        revealed = AorusAIReveal.charactersToShow(revealed: revealed, available: 300, elapsed: frame)
        ticks += 1
    }
    expect(ticks > 4, "a short answer is typed, not flashed")
}

// MARK: - Where it is safe to stop

private func neverCutsAFormulaInHalf() {
    // The point of the whole exercise: a half-typed fraction is a line of source, and showing
    // it for a frame and then rewriting it is worse than showing nothing.
    let fraction = #"Итак \frac{x+1}{x-1} готово"#
    for limit in 0...fraction.count {
        let length = AorusAIReveal.safeLength(of: fraction, atMost: limit)
        let shown = String(fraction.prefix(length))
        // Not even `\frac{x+1}`, which has a closing brace and is still half a fraction.
        expect(!shown.contains("\\frac") || shown.hasSuffix("}") && shown.contains("}{"),
               "no half of a fraction is shown at limit \(limit): \(shown)")
        expect(length <= limit, "and the cut never runs past what was asked at \(limit)")
    }

    // A cut inside the braces is moved back to before the command.
    expect(AorusAIReveal.safeLength(of: #"a \frac{bb}{cc} d"#, atMost: 10), 2,
           "a cut inside a fraction falls back to before it")
    expect(AorusAIReveal.safeLength(of: #"a \frac{bb}{cc} d"#, atMost: 17), 17,
           "and a cut past the end of it is taken as asked")

    // A dollar delimiter is not a character to stop after.
    expect(AorusAIReveal.safeLength(of: "текст $x+1$ дальше", atMost: 9), 6,
           "a cut inside inline maths falls back to before the dollar")
    expect(AorusAIReveal.safeLength(of: "текст $$x$$ дальше", atMost: 9), 6,
           "and so does one inside display maths")

    // An environment is whole or it is not shown.
    let cases = #"\begin{cases} a \\ b \end{cases}"#
    expect(AorusAIReveal.safeLength(of: cases, atMost: 20), 0,
           "a system half-arrived shows nothing of itself")
    expect(AorusAIReveal.safeLength(of: cases, atMost: cases.count), cases.count,
           "and all of itself once it is there")

    // A code fence is the same shape of problem.
    let fence = "до\n```swift\nlet x = 1\n```\nпосле"
    expect(AorusAIReveal.safeLength(of: fence, atMost: 15) <= 3,
           "an open code fence is not shown half-open")
    expect(AorusAIReveal.safeLength(of: fence, atMost: fence.count), fence.count,
           "a closed one is shown whole")

    // A command whose name is still arriving is not a command yet.
    expect(AorusAIReveal.safeLength(of: #"a \alpha b"#, atMost: 5), 2,
           "a half-typed command is held back")
    expect(AorusAIReveal.safeLength(of: #"a \alpha b"#, atMost: 10), 10,
           "and released when it is whole")

    // Ordinary prose is never held back.
    let prose = "Обычный текст без формул, который просто печатается."
    for limit in 0...prose.count {
        expect(AorusAIReveal.safeLength(of: prose, atMost: limit), limit,
               "prose is revealed character by character at \(limit)")
    }

    // Whatever the limit, the result is a valid prefix length.
    let mixed = #"Пусть $a$ и \sqrt{b}, тогда \begin{cases} x \\ y \end{cases} = \frac{1}{2}."#
    for limit in 0...mixed.count {
        let length = AorusAIReveal.safeLength(of: mixed, atMost: limit)
        expect(length >= 0 && length <= limit && length <= mixed.count,
               "the length is a prefix of the text at \(limit)")
    }
}

private func revealsMonotonically() {
    // The text only ever grows: a longer limit never shows less than a shorter one, or the
    // answer would appear to delete itself as it is typed.
    let source = #"Сначала текст, потом \frac{a}{b}, потом $x^2$, потом \sqrt{y} и конец."#
    var previous = 0
    for limit in 0...source.count {
        let length = AorusAIReveal.safeLength(of: source, atMost: limit)
        expect(length >= previous, "the reveal never goes backwards at \(limit)")
        previous = max(previous, length)
    }
    expect(AorusAIReveal.visibleText(of: source, revealed: source.count), source,
           "and the whole text is the whole text")
    expect(AorusAIReveal.visibleText(of: source, revealed: source.count + 50), source,
           "even asked for more than there is")
}

@main
private enum AorusAIRevealTests {
    static func main() {
        typesAtAReadablePaceAndNeverStalls()
        neverCutsAFormulaInHalf()
        revealsMonotonically()
        guard failures.isEmpty else {
            for failure in failures {
                fputs("AorusAIReveal test failed: \(failure)\n", stderr)
            }
            exit(1)
        }
        print("AorusAIReveal tests: OK")
    }
}
