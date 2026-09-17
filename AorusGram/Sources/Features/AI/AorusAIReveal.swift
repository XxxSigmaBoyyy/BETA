import Foundation

/// How much of an answer is on screen, and where it is safe to stop.
///
/// Why this exists
/// ---------------
/// A turn is supposed to read as it is written. It did not: a reader sent a question, waited,
/// and the finished answer appeared all at once. The client was not the reason — deltas are
/// rendered as they arrive, throttled to about eighteen frames a second — the reason is that
/// not every turn is streamed. A turn that produced files answers with one chat completion,
/// and a turn the server chose to buffer arrives as a single `completion` event. Either way
/// the whole answer lands in one go, and a wall of text appearing is not reading.
///
/// So what is on screen is paced here instead of being taken straight from what has arrived.
/// Text that streams is barely touched — it is already arriving at reading speed. Text that
/// lands in one piece is typed out, at a rate worked out from the answer's own length so that
/// whatever its length it is fully on screen `maximumLag` after its last character arrived. A
/// short answer types at a comfortable rate; a very long one sweeps in, rather than taking a
/// quarter of a minute — which is what a rate proportional to what is LEFT would have done,
/// since that rate decays towards the end and never reaches it.
///
/// Where it is safe to stop
/// ------------------------
/// Not in the middle of a formula. `\frac{x` is not a fraction and `$$` alone is not a
/// delimiter, so a cut there shows a line of source for a frame and then rewrites it — which
/// is worse than showing nothing. `safeLength` walks the text once and returns the last place
/// the syntax was whole: no open brace, no open dollar, no half-typed command, no environment
/// or code fence still waiting for its end.
public enum AorusAIReveal {

    /// Characters a second when the reveal has caught up with the stream.
    public static let restingRate: Double = 95

    /// However long the answer, it is fully on screen this long after its last character
    /// arrived. The pace is worked out from the answer's length so that it is: a constant
    /// rate that finishes on time, rather than one proportional to what is left, which
    /// approaches the end and never reaches it.
    public static let maximumLag: TimeInterval = 2.0

    /// How many characters may be on screen after `elapsed` seconds.
    ///
    /// `available` is what has arrived, `revealed` is what is already shown. The result is
    /// never smaller than `revealed` — the answer only ever grows — and never larger than
    /// what has arrived.
    public static func charactersToShow(revealed: Int, available: Int, elapsed: TimeInterval) -> Int {
        let shown = max(0, min(revealed, available))
        guard available > shown, elapsed > 0 else { return shown }
        // Resting pace, or fast enough to put the whole answer on screen within
        // `maximumLag`, whichever is quicker. Worked out from the answer's LENGTH and not
        // from what is left: a rate proportional to what is left decays towards zero, and a
        // ten-thousand-character answer would take a quarter of a minute to finish arriving.
        let rate = max(restingRate, Double(available) / maximumLag)
        let step = Int((rate * elapsed).rounded(.down))
        // Time passed, so something has to move: at 30 frames a second a resting rate of 95
        // rounds down to three characters, and a rate that rounded to nothing would stall.
        return min(available, shown + max(step, 1))
    }

    /// The largest prefix at or below `limit` that does not cut a construct in half.
    ///
    /// Returns a count of Characters, not of bytes or of UTF-16 units, so the caller may use
    /// it with `prefix(_:)` directly.
    public static func safeLength(of text: String, atMost limit: Int) -> Int {
        let characters = Array(text)
        let ceiling = max(0, min(limit, characters.count))
        guard ceiling > 0 else { return 0 }

        var braceDepth = 0
        var dollarRun = 0          // consecutive dollars, to tell `$` from `$$`
        var openDollars = 0        // dollar delimiters still waiting to be closed
        var backtickRun = 0
        var openFence = false
        // Whether the opening fence's own line has ended. Until it has there is no code yet,
        // only "```swi" — and a language name half-arrived is not something to show.
        var fenceBodyStarted = false
        var inlineCodeOpen = false
        var environmentDepth = 0
        // A command whose arguments have not all arrived. `\frac{x+1}` has a closing brace
        // and a brace depth of zero and is still half a fraction — without this it was shown
        // as source for a frame and then rewritten, which is worse than showing nothing.
        var pendingArguments = 0
        var index = 0
        var safe = 0

        while index < ceiling {
            let character = characters[index]

            // Inside a fenced block nothing is LaTeX: a brace is a brace, a dollar is a
            // dollar, and the code is typed out a character at a time like everything else.
            // Holding the whole block back until its closing fence arrived was the one place
            // an answer still appeared all at once — and a fifty-line listing is exactly
            // where waiting is most obvious.
            if openFence {
                if character == "`" {
                    backtickRun += 1
                    index += 1
                    if index >= ceiling || characters[index] != "`" {
                        if backtickRun >= 3 {
                            openFence = false
                            fenceBodyStarted = false
                            if braceDepth == 0, openDollars == 0, environmentDepth == 0,
                               pendingArguments == 0, !inlineCodeOpen {
                                safe = index
                            }
                        }
                        backtickRun = 0
                    }
                    continue
                }
                if character == "\n" { fenceBodyStarted = true }
                index += 1
                // Not before the fence's own line has ended, and never in the middle of a
                // run of backticks that may turn out to be the closing fence.
                if fenceBodyStarted { safe = index }
                continue
            }

            if character == "\\" {
                // A command, an escape, or a line break. Whatever it is, the text is not
                // whole until it has been read to the end.
                var cursor = index + 1
                if cursor < characters.count, characters[cursor].isLetter {
                    while cursor < characters.count, characters[cursor].isLetter { cursor += 1 }
                    let name = String(characters[(index + 1)..<cursor])
                    if name == "begin" { environmentDepth += 1 }
                    if name == "end" { environmentDepth = max(environmentDepth - 1, 0) }
                    var look = cursor
                    while look < characters.count, characters[look] == " " { look += 1 }
                    if look < characters.count, characters[look] == "{" {
                        pendingArguments = twoArgumentCommands.contains(name) ? 2 : 1
                    }
                } else if cursor < characters.count {
                    cursor += 1
                }
                guard cursor <= ceiling else { break }
                index = cursor
                dollarRun = 0
                backtickRun = 0
                continue
            }

            if character == "$" {
                dollarRun += 1
                index += 1
                // `$$` is one delimiter, not two: only close the run when it ends.
                if index >= ceiling || characters[index] != "$" {
                    openDollars = openDollars == 0 ? dollarRun : 0
                    dollarRun = 0
                }
                continue
            }

            if character == "`" {
                backtickRun += 1
                index += 1
                if index >= ceiling || characters[index] != "`" {
                    if backtickRun >= 3 {
                        openFence.toggle()
                    } else {
                        inlineCodeOpen.toggle()
                    }
                    backtickRun = 0
                }
                continue
            }

            if character == "{" { braceDepth += 1 }
            if character == "}" {
                braceDepth = max(braceDepth - 1, 0)
                if braceDepth == 0, pendingArguments > 0 { pendingArguments -= 1 }
            }
            index += 1

            let whole = braceDepth == 0 && openDollars == 0 && environmentDepth == 0
                && pendingArguments == 0
                && !openFence && !inlineCodeOpen && dollarRun == 0 && backtickRun == 0
            if whole { safe = index }
        }
        return safe
    }

    /// The commands that are only whole once TWO groups have arrived.
    private static let twoArgumentCommands: Set<String> = [
        "frac", "dfrac", "tfrac", "cfrac", "binom", "dbinom", "tbinom",
    ]

    /// The text to show, given how much of it has been revealed.
    public static func visibleText(of text: String, revealed: Int) -> String {
        guard revealed < text.count else { return text }
        return String(text.prefix(safeLength(of: text, atMost: revealed)))
    }
}
