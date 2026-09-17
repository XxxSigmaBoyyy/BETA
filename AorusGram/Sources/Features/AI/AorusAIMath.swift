import Foundation

/// LaTeX, as the assistant writes it, turned into something a reader can read.
///
/// Why this is its own file, in the core module
/// --------------------------------------------
/// It is pure text work with no UIKit in it, so it compiles and runs on its own: the
/// preflight puts every rule below through real model output in about two seconds, instead
/// of the hour a full build costs. It used to live inside a seven-thousand-line view
/// controller where nothing could reach it.
///
/// What was wrong with what it replaces
/// ------------------------------------
/// Two things, both of which a reader saw:
///
/// 1. **Commands that were not in the table came out as themselves.** The table listed
///    `\neq` but not `\ne`, so an answer read `x \ne 0`. It listed neither `\quad` nor
///    `\boxed`, so the final answer of a worked solution read `\boxed{x = 2}`. The table was
///    also applied by longest-prefix order, which is a bug waiting to happen: `\le` before
///    `\leftarrow` turns an arrow into `≤ftarrow`. Commands are now matched as whole names —
///    `\\([A-Za-z]+)` and a dictionary lookup — so order cannot matter, and the table covers
///    the Greek alphabet, the relations, the set and logic operators, the arrows, the
///    calculus signs and the function names.
///
/// 2. **Fractions were unreadable.** A short one was set as superscript, fraction slash,
///    subscript — so `\frac{0}{0}`, the indeterminate form at the heart of a limit, rendered
///    `⁰⁄₀`, which at body size is indistinguishable from a percent sign. A long one was set
///    with U+2044 FRACTION SLASH between two bracketed halves, and that glyph is drawn by the
///    system face as a steeply tilted stroke that does not read as division at all. Now: an
///    exact vulgar fraction where one exists (½, ⅔, ⅜ …), and otherwise bracketed halves
///    around an ordinary `/`, which is how a fraction is written inline everywhere else.
///
/// A display equation — one the author set on its own line with `$$…$$` or `\[…\]` — is not
/// flattened at all. `render` lifts it out as `Atom`s so the caller can typeset the fraction
/// properly, stacked, and leaves an OBJECT REPLACEMENT CHARACTER where it belongs.
public enum AorusAIMath {

    // MARK: - Model

    /// A display equation, as much of its structure as matters for setting it.
    public indirect enum Atom: Equatable {
        case text(String)
        case fraction(numerator: [Atom], denominator: [Atom])

        public var isFraction: Bool {
            if case .fraction = self { return true }
            return false
        }
    }

    public struct Rendered: Equatable {
        /// The message text. Every display equation has been replaced by one
        /// `equationPlaceholder`.
        public var text: String
        /// One entry per placeholder in `text`, in the order they appear.
        public var equations: [[Atom]]

        public init(text: String, equations: [[Atom]]) {
            self.text = text
            self.equations = equations
        }
    }

    /// OBJECT REPLACEMENT CHARACTER — what a lifted display equation leaves behind, and what
    /// UIKit itself uses for an attachment, so the caller can put one there directly.
    public static let equationPlaceholder = "\u{FFFC}"

    // MARK: - Entry points

    /// A whole message: display equations lifted out, everything else turned into text.
    public static func render(_ source: String) -> Rendered {
        var equations: [[Atom]] = []
        var lines: [String] = []
        let sourceLines = source.components(separatedBy: .newlines)
        var index = 0
        while index < sourceLines.count {
            let line = sourceLines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // `$$` alone opens a block that runs to the next `$$` alone. Models write display
            // math both ways and the multi-line form is the one a single-line rule misses.
            if trimmed == "$$", let close = closingFenceIndex(after: index, in: sourceLines) {
                let body = sourceLines[(index + 1)..<close].joined(separator: " ")
                lines.append(displayLine(for: body, equations: &equations))
                index = close + 1
                continue
            }
            if let body = displayBody(of: trimmed) {
                lines.append(displayLine(for: body, equations: &equations))
                index += 1
                continue
            }
            lines.append(inlineTextOutsideCode(line))
            index += 1
        }
        return Rendered(text: lines.joined(separator: "\n"), equations: equations)
    }

    /// A whole fragment, code spans left alone, with no display equations lifted out of it.
    /// This is the form for anywhere a text run is all there is — a table cell, a quote.
    public static func typography(_ source: String) -> String {
        return source.components(separatedBy: .newlines)
            .map(inlineTextOutsideCode)
            .joined(separator: "\n")
    }

    /// One fragment of running text. Fractions in it are set inline.
    public static func inlineText(_ source: String) -> String {
        return normalize(source, depth: 0, fraction: inlineFractionHalves(atDepth: 0))
    }

    /// `\frac` inside a code span is code, not maths, and has to survive as written.
    private static func inlineTextOutsideCode(_ line: String) -> String {
        guard line.contains("`") else { return inlineText(line) }
        var result = ""
        var fragment = ""
        var inCode = false
        for character in line {
            if character == "`" {
                result += inCode ? fragment : inlineText(fragment)
                fragment = ""
                result.append(character)
                inCode.toggle()
            } else {
                fragment.append(character)
            }
        }
        result += inCode ? fragment : inlineText(fragment)
        return result
    }

    /// A display equation's structure. Text runs are already normalized.
    public static func atoms(_ source: String) -> [Atom] {
        return parseAtoms(source, depth: 0)
    }

    /// What a display equation reads as when it cannot be typeset — the copy text, the
    /// accessibility label, and the fallback for any caller without a typesetter.
    public static func plainText(_ atoms: [Atom]) -> String {
        var result = ""
        for atom in atoms {
            switch atom {
            case let .text(value):
                result += value
            case let .fraction(numerator, denominator):
                result += inlineFractionText(plainText(numerator), plainText(denominator))
            }
        }
        return result
    }

    /// True when an equation has something in it that only a stacked setting shows properly.
    /// A display equation with no fraction reads perfectly well as ordinary selectable text,
    /// so it is left as text rather than turned into a picture of itself.
    public static func needsTypesetting(_ atoms: [Atom]) -> Bool {
        for atom in atoms where atom.isFraction {
            return true
        }
        return false
    }

    // MARK: - Display detection

    private static func closingFenceIndex(after index: Int, in lines: [String]) -> Int? {
        var cursor = index + 1
        // A runaway opening fence must not swallow the rest of the answer.
        let limit = min(lines.count, index + 40)
        while cursor < limit {
            if lines[cursor].trimmingCharacters(in: .whitespaces) == "$$" { return cursor }
            cursor += 1
        }
        return nil
    }

    /// The body of a line that is nothing but a display equation, or nil.
    private static func displayBody(of trimmed: String) -> String? {
        for (open, close) in [("$$", "$$"), ("\\[", "\\]")] {
            guard trimmed.hasPrefix(open), trimmed.hasSuffix(close),
                  trimmed.count > open.count + close.count else { continue }
            let body = String(trimmed.dropFirst(open.count).dropLast(close.count))
            // `$$a$$ and $$b$$` on one line is two equations with prose between them; it is
            // not a display line, and treating it as one would eat the prose.
            guard !body.contains(open) else { continue }
            return body
        }
        return nil
    }

    private static func displayLine(for body: String, equations: inout [[Atom]]) -> String {
        let parsed = atoms(body)
        guard needsTypesetting(parsed) else {
            // Nothing to stack: plain selectable text beats a picture of text.
            return inlineText(body)
        }
        equations.append(parsed)
        return equationPlaceholder
    }

    // MARK: - Atoms

    private static let fractionMarkerOpen = "\u{E000}"
    private static let fractionMarkerClose = "\u{E001}"

    private static func parseAtoms(_ source: String, depth: Int) -> [Atom] {
        guard depth < 6 else { return [.text(inlineText(source))] }
        var halves: [(String, String)] = []
        let flattened = normalize(source, depth: depth) { numerator, denominator in
            halves.append((numerator, denominator))
            return fractionMarkerOpen + String(halves.count - 1) + fractionMarkerClose
        }
        guard !halves.isEmpty else {
            return flattened.isEmpty ? [] : [.text(flattened)]
        }

        var result: [Atom] = []
        var run = ""
        var scanner = Substring(flattened)
        while let open = scanner.range(of: fractionMarkerOpen) {
            run += scanner[..<open.lowerBound]
            let afterOpen = scanner[open.upperBound...]
            guard let close = afterOpen.range(of: fractionMarkerClose),
                  let slot = Int(afterOpen[..<close.lowerBound]), slot < halves.count else {
                // Not ours to read; keep it as text rather than lose it.
                run += scanner[open.lowerBound...]
                scanner = Substring("")
                break
            }
            if !run.isEmpty {
                result.append(.text(run))
                run = ""
            }
            let half = halves[slot]
            result.append(.fraction(numerator: parseAtoms(half.0, depth: depth + 1),
                                    denominator: parseAtoms(half.1, depth: depth + 1)))
            scanner = afterOpen[close.upperBound...]
        }
        run += scanner
        if !run.isEmpty {
            result.append(.text(run))
        }
        return result
    }

    // MARK: - The pipeline

    /// Each half of a fraction is itself normalized, at one more level of depth, so a
    /// fraction inside a fraction is set correctly and a pathological nesting still ends.
    private static func inlineFractionHalves(atDepth depth: Int) -> (String, String) -> String {
        return { numerator, denominator in
            guard depth < 6 else { return numerator + "/" + denominator }
            let inner = inlineFractionHalves(atDepth: depth + 1)
            return inlineFractionText(normalize(numerator, depth: depth + 1, fraction: inner),
                                      normalize(denominator, depth: depth + 1, fraction: inner))
        }
    }

    private static func normalize(_ source: String, depth: Int,
                                  fraction: (String, String) -> String) -> String {
        var value = protectEscapes(source)
        value = stripDelimiters(value)
        value = expandEnvironments(value)
        value = replacing(pattern: #"\\\\\s*\[[^\]\n]{0,12}\]"#, in: value) { _ in "\n" }
        value = value.replacingOccurrences(of: "\\\\", with: "\n")
        value = value.replacingOccurrences(of: "\\left.", with: "")
        value = value.replacingOccurrences(of: "\\right.", with: "")
        value = expandBraceCommands(value, depth: depth, fraction: fraction)
        value = expandCommands(value)
        value = expandSpacing(value)
        value = expandScripts(value)
        return restoreEscapes(tidySpacing(value, touched: source.contains("\\")))
    }

    /// The spacing commands are decorative, and every one of them leaves a gap behind whether
    /// or not the author already put a space there: `0 \quad ✓` would read `0    ✓`. A line
    /// this pass did not touch — ordinary prose, with no command in it — is left exactly as
    /// written, and so is every line's indentation, which is what markdown reads nesting from.
    private static func tidySpacing(_ value: String, touched: Bool) -> String {
        guard touched else { return value }
        return value.components(separatedBy: "\n").map { line -> String in
            let body = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = line.prefix(line.count - body.count)
            return String(indent) + body.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        }.joined(separator: "\n")
    }

    private static func stripDelimiters(_ source: String) -> String {
        var value = source
        for delimiter in ["\\(", "\\)", "\\[", "\\]"] {
            value = value.replacingOccurrences(of: delimiter, with: "")
        }
        // A PAIR of dollars first: the single-dollar rule would take the opening two and
        // leave the closing pair stranded in the middle of the line.
        value = replacing(pattern: #"\$\$([\s\S]+?)\$\$"#, in: value) { $0[0] }
        value = replacing(pattern: #"(?<!\\)\$([^$\n]+)\$"#, in: value) { $0[0] }
        return value
    }

    /// `\begin{cases} … \end{cases}` and its relatives: the rows become lines and the
    /// alignment marks become spaces.
    ///
    /// `&` is only touched inside one of these. It is an ordinary character in prose — "R&D"
    /// has to survive — and this function runs over the whole message, not just the maths.
    private static func expandEnvironments(_ source: String) -> String {
        let names = "align|aligned|alignat|cases|gather|gathered|split|matrix|pmatrix|bmatrix|Bmatrix|vmatrix|Vmatrix|array|equation|eqnarray"
        let pattern = #"\\begin\{("# + names + #")\*?\}(?:\{[^{}]*\})?([\s\S]*?)\\end\{\1\*?\}"#
        return replacing(pattern: pattern, in: source) { captures in
            var body = captures[1]
            body = body.replacingOccurrences(of: "&", with: " ")
            body = body.replacingOccurrences(of: "\\\\", with: "\n")
            // An alignment mark leaves a run of spaces where it stood, and every row carries
            // the padding the author laid out around it. Neither means anything once the rows
            // are lines.
            return body.components(separatedBy: "\n").map { row in
                row.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    // MARK: Brace commands

    private static func expandBraceCommands(_ source: String, depth: Int,
                                            fraction: (String, String) -> String) -> String {
        guard depth < 8 else { return source }
        var value = source
        var guardCounter = 0
        while guardCounter < 64 {
            guardCounter += 1
            guard let call = firstBraceCommand(in: value) else { break }
            let replacement = expand(call: call, depth: depth, fraction: fraction)
            value = (value as NSString).replacingCharacters(in: call.range, with: replacement)
        }
        return value
    }

    private struct BraceCall {
        var name: String
        var optional: String?
        var arguments: [String]
        var range: NSRange
    }

    /// Commands taking brace arguments, and how many each takes.
    private static let braceArity: [String: Int] = [
        "frac": 2, "dfrac": 2, "tfrac": 2, "cfrac": 2, "binom": 2, "dbinom": 2, "tbinom": 2,
        "sqrt": 1, "text": 1, "textbf": 1, "textit": 1, "textrm": 1, "textsf": 1, "texttt": 1,
        "mathrm": 1, "mathbf": 1, "mathit": 1, "mathsf": 1, "mathtt": 1, "mathbb": 1,
        "mathcal": 1, "mathfrak": 1, "operatorname": 1, "boxed": 1, "underline": 1,
        "overline": 1, "widehat": 1, "widetilde": 1, "hat": 1, "bar": 1, "vec": 1,
        "tilde": 1, "dot": 1, "ddot": 1, "phantom": 1, "hphantom": 1, "vphantom": 1,
        "hspace": 1, "vspace": 1, "label": 1, "tag": 1, "substack": 1,
    ]

    private static let openBracket: unichar = 91   // [
    private static let closeBracket: unichar = 93  // ]
    private static let openBrace: unichar = 123    // {
    private static let closeBrace: unichar = 125   // }
    private static let space: unichar = 32
    private static let backslash: unichar = 92

    private static func firstBraceCommand(in source: String) -> BraceCall? {
        let text = source as NSString
        guard let regex = try? NSRegularExpression(pattern: #"\\([A-Za-z]+)"#) else { return nil }
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: text.length))
        for match in matches {
            let name = text.substring(with: match.range(at: 1))
            guard let arity = braceArity[name] else { continue }
            var cursor = match.range.location + match.range.length
            var optional: String?
            // `\sqrt[3]{x}` — the degree, when the author gave one.
            if cursor < text.length, text.character(at: cursor) == openBracket {
                guard let bracket = matchingIndex(in: text, from: cursor, open: openBracket, close: closeBracket) else { continue }
                optional = text.substring(with: NSRange(location: cursor + 1, length: bracket - cursor - 1))
                cursor = bracket + 1
            }
            var arguments: [String] = []
            var complete = true
            for _ in 0..<arity {
                while cursor < text.length, text.character(at: cursor) == space { cursor += 1 }
                guard cursor < text.length, text.character(at: cursor) == openBrace,
                      let brace = matchingIndex(in: text, from: cursor, open: openBrace, close: closeBrace) else {
                    complete = false
                    break
                }
                arguments.append(text.substring(with: NSRange(location: cursor + 1, length: brace - cursor - 1)))
                cursor = brace + 1
            }
            // An incomplete call — `\frac` with one half, a `\text` with no braces — is left
            // exactly as the author wrote it rather than half-eaten.
            guard complete else { continue }
            return BraceCall(name: name, optional: optional, arguments: arguments,
                             range: NSRange(location: match.range.location,
                                            length: cursor - match.range.location))
        }
        return nil
    }

    /// The index of the bracket closing the one at `start`, honouring nesting.
    private static func matchingIndex(in text: NSString, from start: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 0
        var index = start
        while index < text.length {
            let character = text.character(at: index)
            // A bracket the author escaped is a bracket, not a delimiter.
            let escaped = index > 0 && text.character(at: index - 1) == backslash
            if character == open, !escaped {
                depth += 1
            } else if character == close, !escaped {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// The sets that have a letter of their own. Anything else keeps its plain letter
    /// rather than being approximated by a lookalike.
    private static let doubleStruck: [String: String] = [
        "R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ", "H": "ℍ",
    ]

    private static let combining: [String: String] = [
        "hat": "\u{0302}", "widehat": "\u{0302}", "bar": "\u{0304}", "overline": "\u{0304}",
        "vec": "\u{20D7}", "tilde": "\u{0303}", "widetilde": "\u{0303}",
        "dot": "\u{0307}", "ddot": "\u{0308}",
    ]

    private static func expand(call: BraceCall, depth: Int, fraction: (String, String) -> String) -> String {
        func inner(_ value: String) -> String {
            return normalize(value, depth: depth + 1, fraction: { fraction($0, $1) })
        }
        switch call.name {
        case "frac", "dfrac", "tfrac", "cfrac":
            return fraction(call.arguments[0], call.arguments[1])
        case "binom", "dbinom", "tbinom":
            return "C(" + inner(call.arguments[0]) + ", " + inner(call.arguments[1]) + ")"
        case "sqrt":
            let body = grouped(inner(call.arguments[0]))
            guard let degree = call.optional else { return "√" + body }
            let raised = inner(degree)
            return (canSuperscript(raised) ? superscript(raised) : raised) + "√" + body
        case "phantom", "hphantom", "vphantom":
            return String(repeating: " ", count: min(max(call.arguments[0].count, 1), 8))
        case "hspace", "vspace":
            return " "
        case "label", "tag":
            return ""
        case "underline":
            return inner(call.arguments[0])
        case "mathbb":
            let body = inner(call.arguments[0])
            return doubleStruck[body] ?? body
        default:
            let body = inner(call.arguments[0])
            if let mark = combining[call.name] {
                // A mark belongs over ONE letter. Over a whole expression it lands on the
                // first character and reads as a typo, so a long body simply keeps its text.
                return body.count == 1 ? body + mark : body
            }
            return body
        }
    }

    // MARK: Bare commands

    /// Matched as a whole name, never by prefix.
    ///
    /// The table this replaces was applied in list order, which meant `\le` could reach
    /// `\leftarrow` first and leave `≤ftarrow` behind. Here the regex takes the entire run of
    /// letters and the dictionary decides, so `\le`, `\leq`, `\left` and `\leftarrow` cannot
    /// be confused with one another whatever order they are written in.
    private static func expandCommands(_ source: String) -> String {
        return replacing(pattern: #"\\([A-Za-z]+)"#, in: source) { captures in
            let name = captures[0]
            if let symbol = symbols[name] { return symbol }
            if removed.contains(name) { return "" }
            // `\sin`, `\log`, `\lim`: the name IS the notation, it just is not italic.
            if functions.contains(name) { return name }
            return "\\" + name
        }
    }

    private static func expandSpacing(_ source: String) -> String {
        var value = source
        for (command, replacement) in [("\\,", " "), ("\\;", " "), ("\\:", " "), ("\\ ", " "), ("\\!", "")] {
            value = value.replacingOccurrences(of: command, with: replacement)
        }
        return value
    }

    // MARK: Scripts

    private static func expandScripts(_ source: String) -> String {
        var value = source
        value = replacing(pattern: #"\^\{([^{}]+)\}"#, in: value) { raised($0[0]) }
        value = replacing(pattern: #"\^\(([^()]+)\)"#, in: value) { raised($0[0]) }
        // An ungrouped exponent is ONE term and nothing more.
        //
        // The old rule took every following `+`, `-`, `=` and bracket too, so `x^2+1` — x
        // squared plus one — came out `x²⁺¹`, an exponent of three, and `(x^2+1)` ended `⁾`
        // with the bracket pulled up into the exponent and left unmatched.
        value = replacing(pattern: #"\^([+\-−]?[0-9]+|[A-Za-z](?![A-Za-z]))"#, in: value) { captures in
            return canSuperscript(captures[0]) ? superscript(captures[0]) : "^" + captures[0]
        }
        value = replacing(pattern: #"_\{([^{}]+)\}"#, in: value) { lowered($0[0]) }
        value = replacing(pattern: #"_\(([^()]+)\)"#, in: value) { lowered($0[0]) }
        // A subscript has to sit under something, and must not run into the middle of a
        // word. Without the first condition markdown's own `_italic_` was read as a subscript
        // and came out `ᵢtalic_`, losing both the letter and the emphasis, because this pass
        // runs before the markdown pass; without the second, `file_name` came out `fileₙame`.
        value = replacing(pattern: #"(?<=[0-9A-Za-zА-Яа-яЁё∫∑∏⋃⋂Α-Ωα-ω\)\]\}])_([+\-−]?[0-9]+|[A-Za-z](?![A-Za-z]))"#, in: value) { captures in
            return canSubscript(captures[0]) ? subscripted(captures[0]) : "_" + captures[0]
        }
        return value
    }

    private static func raised(_ value: String) -> String {
        return canSuperscript(value) ? superscript(value) : "^(" + value + ")"
    }

    private static func lowered(_ value: String) -> String {
        return canSubscript(value) ? subscripted(value) : "_(" + value + ")"
    }

    // MARK: - Fractions

    /// The exact single glyphs. Anything outside this set is NOT approximated with one.
    private static let vulgar: [String: String] = [
        "1/2": "½", "1/3": "⅓", "2/3": "⅔", "1/4": "¼", "3/4": "¾",
        "1/5": "⅕", "2/5": "⅖", "3/5": "⅗", "4/5": "⅘", "1/6": "⅙", "5/6": "⅚",
        "1/7": "⅐", "1/8": "⅛", "3/8": "⅜", "5/8": "⅝", "7/8": "⅞",
        "1/9": "⅑", "1/10": "⅒",
    ]

    /// One fraction, inline, set so that it reads as the value it is.
    ///
    /// Not as superscript-slash-subscript. `\frac{0}{0}` set that way is `⁰⁄₀`, and at body
    /// size that is a percent sign — which is what an answer about an indeterminate form
    /// actually showed a reader. Not with U+2044 either: the system face draws it as a steep
    /// stroke that reads as an accent, not a division.
    private static func inlineFractionText(_ numerator: String, _ denominator: String) -> String {
        let top = numerator.trimmingCharacters(in: .whitespaces)
        let bottom = denominator.trimmingCharacters(in: .whitespaces)
        guard !top.isEmpty, !bottom.isEmpty else { return top + "/" + bottom }
        if let glyph = vulgar[top + "/" + bottom] { return glyph }
        return grouped(top) + "/" + grouped(bottom)
    }

    /// Brackets anything that is more than a single term, so a slash cannot silently rebind
    /// it: `x+1` becomes `(x+1)`, because `x+1/2` is a different number.
    private static func grouped(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 1 else { return trimmed }
        if isSingleGroup(trimmed) { return trimmed }
        let breaking = CharacterSet(charactersIn: "+-−±∓×÷·/, ")
        guard trimmed.rangeOfCharacter(from: breaking) != nil else { return trimmed }
        return "(" + trimmed + ")"
    }

    /// True when the whole string is ONE bracketed group.
    ///
    /// `hasPrefix("(") && hasSuffix(")")` is not that test: `(a+b)(c+d)` passes it and is two
    /// groups, so a fraction over it would have bound only the first.
    private static func isSingleGroup(_ value: String) -> Bool {
        guard value.hasPrefix("("), value.hasSuffix(")") else { return false }
        var depth = 0
        for (offset, character) in value.enumerated() {
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return offset == value.count - 1 }
            }
        }
        return false
    }

    // MARK: - Scripts, as characters

    private static func canSuperscript(_ source: String) -> Bool {
        return !source.isEmpty && superscript(source).first != "^"
    }

    private static func canSubscript(_ source: String) -> Bool {
        return !source.isEmpty && subscripted(source).first != "_"
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ",
        "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
        "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ",
        "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

    private static func superscript(_ source: String) -> String {
        guard source.allSatisfy({ superscripts[$0] != nil }) else { return "^(" + source + ")" }
        return String(source.compactMap { superscripts[$0] })
    }

    private static func subscripted(_ source: String) -> String {
        guard source.allSatisfy({ subscripts[$0] != nil }) else { return "_(" + source + ")" }
        return String(source.compactMap { subscripts[$0] })
    }

    // MARK: - Escapes

    private static let escapes: [(String, String, String)] = [
        ("\\{", "\u{E010}", "{"), ("\\}", "\u{E011}", "}"), ("\\%", "\u{E012}", "%"),
        ("\\$", "\u{E013}", "$"), ("\\&", "\u{E014}", "&"), ("\\#", "\u{E015}", "#"),
        ("\\_", "\u{E016}", "_"), ("\\|", "\u{E017}", "|"),
    ]

    /// An escaped character is put beyond reach of every rule below before any of them run.
    /// `\_` is an underscore, not the start of a subscript, and the subscript rule would
    /// otherwise take the letter after it.
    private static func protectEscapes(_ source: String) -> String {
        var value = source
        for (pattern, token, _) in escapes {
            value = value.replacingOccurrences(of: pattern, with: token)
        }
        return value
    }

    private static func restoreEscapes(_ source: String) -> String {
        var value = source
        for (_, token, character) in escapes {
            value = value.replacingOccurrences(of: token, with: character)
        }
        return value
    }

    // MARK: - Tables

    private static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh", "coth", "log", "ln", "lg", "exp", "lim", "limsup",
        "liminf", "max", "min", "sup", "inf", "det", "dim", "ker", "deg", "gcd",
        "lcm", "mod", "bmod", "arg", "Pr", "hom",
    ]

    private static let removed: Set<String> = [
        "left", "right", "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle",
        "limits", "nolimits", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
        "biggl", "biggr", "Biggl", "Biggr", "middle", "mathstrut", "strut", "nonumber",
        "notag", "thinspace", "negthinspace", "negmedspace", "negthickspace",
    ]

    private static let symbols: [String: String] = [
        // Spacing that is wide enough to be worth keeping.
        "quad": " ", "qquad": "  ", "space": " ", "enspace": " ",

        // Relations.
        "ne": "≠", "neq": "≠", "le": "≤", "leq": "≤", "leqslant": "≤",
        "ge": "≥", "geq": "≥", "geqslant": "≥", "ll": "≪", "gg": "≫",
        "approx": "≈", "sim": "∼", "simeq": "≃", "cong": "≅", "equiv": "≡",
        "propto": "∝", "doteq": "≐", "asymp": "≍", "nless": "≮", "ngtr": "≯",
        "nleq": "≰", "ngeq": "≱", "neg": "¬", "lnot": "¬", "nsim": "≁",

        // Sets and logic.
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆",
        "supset": "⊃", "supseteq": "⊇", "nsubseteq": "⊈", "nsupseteq": "⊉",
        "cup": "∪", "cap": "∩", "bigcup": "⋃", "bigcap": "⋂", "setminus": "∖",
        "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃",
        "nexists": "∄", "wedge": "∧", "vee": "∨", "land": "∧", "lor": "∨",
        "therefore": "∴", "because": "∵", "mid": "∣", "nmid": "∤",

        // Operators.
        "times": "×", "cdot": "·", "cdots": "⋯", "ldots": "…", "dots": "…",
        "vdots": "⋮", "ddots": "⋱", "div": "÷", "pm": "±", "mp": "∓",
        "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "∙", "oplus": "⊕",
        "ominus": "⊖", "otimes": "⊗", "odot": "⊙", "sum": "∑", "prod": "∏",
        "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "sqrt": "√", "partial": "∂", "nabla": "∇", "infty": "∞",
        "angle": "∠", "measuredangle": "∡", "perp": "⊥", "parallel": "∥",
        "triangle": "△", "square": "□", "degree": "°", "prime": "′",
        "aleph": "ℵ", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "wp": "℘",
        "checkmark": "✓", "dagger": "†", "ddagger": "‡", "percent": "%",

        // Delimiters that have a glyph of their own.
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋",
        "lceil": "⌈", "rceil": "⌉", "vert": "|", "Vert": "‖", "backslash": "\\",

        // Arrows.
        "to": "→", "gets": "←", "rightarrow": "→", "leftarrow": "←",
        "longrightarrow": "⟶", "longleftarrow": "⟵", "leftrightarrow": "↔",
        "longleftrightarrow": "⟷", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "Longrightarrow": "⟹", "Longleftarrow": "⟸",
        "Longleftrightarrow": "⟺", "implies": "⇒", "impliedby": "⇐", "iff": "⇔",
        "mapsto": "↦", "longmapsto": "⟼", "uparrow": "↑", "downarrow": "↓",
        "updownarrow": "↕", "nearrow": "↗", "searrow": "↘", "swarrow": "↙",
        "nwarrow": "↖", "hookrightarrow": "↪", "hookleftarrow": "↩",

        // Greek, both cases.
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "φ",
        "varphi": "ϕ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    // MARK: - Regex helper

    private static func replacing(pattern: String, in source: String,
                                  transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let result = NSMutableString(string: source)
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
        for match in matches.reversed() {
            var captures: [String] = []
            for index in 1..<match.numberOfRanges {
                let range = match.range(at: index)
                captures.append(range.location == NSNotFound ? "" : (source as NSString).substring(with: range))
            }
            result.replaceCharacters(in: match.range, with: transform(captures))
        }
        return result as String
    }
}
