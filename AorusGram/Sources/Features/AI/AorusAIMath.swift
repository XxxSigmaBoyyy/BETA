import Foundation

/// LaTeX, as the assistant writes it, turned into something a reader can read.
///
/// What this is
/// ------------
/// A parser. Not a list of substitutions — that is what it replaces, and the substitutions
/// were why every answer came out looking like source code with the backslashes filed off:
/// `(a)/(b)` for a fraction, `√(x+1)` for a root, `^(n+1)` for an exponent, `_(x → 0)` for the
/// condition under a limit. Each of those is what you write when you cannot draw the thing.
///
/// So the maths is parsed into a tree — fractions, roots, scripts, operators with limits,
/// delimiters that have to grow with what is inside them, and the rows of a system or a
/// matrix — and the tree is handed to `AorusAIMathTypesetter`, which draws it. Everything
/// around the maths stays text a reader can select, and anything that reads perfectly well as
/// text still is text: ½ is a character, `x²` is a character, `∫₀¹` is three.
///
/// Why it lives here, in the core module, with no UIKit in it
/// ----------------------------------------------------------
/// So it compiles and runs on its own. The preflight puts the whole of it through real model
/// output in about two seconds, instead of the hour a full build costs.
public enum AorusAIMath {

    // MARK: - Model

    /// One piece of set maths. `text` is the only one that is never drawn.
    public indirect enum Atom: Equatable {
        case text(String)
        case fraction(numerator: [Atom], denominator: [Atom])
        /// `degree` is empty for a square root.
        case radical(degree: [Atom], body: [Atom])
        /// A base with either or both of its scripts; an empty list means that one is absent.
        case script(base: [Atom], upper: [Atom], lower: [Atom])
        /// A symbol whose limits belong above and below it: ∑, ∏, lim, max.
        case bigOperator(symbol: String, upper: [Atom], lower: [Atom])
        /// Brackets that grow to whatever they contain. `open`/`close` may be empty.
        case delimited(open: String, close: String, body: [Atom])
        /// A system or a matrix. `open` is the bracket drawn down its left side, or empty.
        case stack(open: String, rows: [[Atom]])

        public var isText: Bool {
            if case .text = self { return true }
            return false
        }
    }

    public struct Rendered: Equatable {
        /// The message text. Everything that has to be drawn was replaced by one
        /// `drawablePlaceholder`.
        public var text: String
        /// One entry per placeholder in `text`, in the order they appear.
        public var drawables: [Atom]

        public init(text: String, drawables: [Atom]) {
            self.text = text
            self.drawables = drawables
        }
    }

    /// OBJECT REPLACEMENT CHARACTER — what a lifted construct leaves behind, and what UIKit
    /// itself uses for an attachment, so the caller can put one there directly.
    public static let drawablePlaceholder = "\u{FFFC}"

    // MARK: - Entry points

    /// A whole message, ready to be set: everything that has to be drawn lifted out as
    /// structure, everything else turned into text.
    public static func render(_ source: String) -> Rendered {
        var drawables: [Atom] = []
        var lines: [String] = []
        for line in source.components(separatedBy: .newlines) {
            // A display fence on a line of its own is a delimiter, not content.
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine == "$$" || trimmedLine == "\\[" || trimmedLine == "\\]" { continue }
            var text = ""
            forEachFragment(of: line) { fragment, isCode in
                if isCode {
                    text += fragment
                } else {
                    emit(parse(fragment), into: &text, drawables: &drawables)
                }
            }
            lines.append(tidy(text, touched: line.contains("\\")))
        }
        return Rendered(text: lines.joined(separator: "\n"), drawables: drawables)
    }

    /// The text form of a whole fragment: for a table cell, a quote, anywhere a run of text is
    /// all there is and a drawing has nowhere to go.
    public static func typography(_ source: String) -> String {
        return source.components(separatedBy: .newlines)
            .map { line -> String in
                var text = ""
                forEachFragment(of: line) { fragment, isCode in
                    text += isCode ? fragment : plainText(parse(fragment))
                }
                return tidy(text, touched: line.contains("\\"))
            }
            .joined(separator: "\n")
    }

    /// One fragment of running text, as text.
    public static func inlineText(_ source: String) -> String {
        return typography(source)
    }

    /// The structure of one fragment.
    public static func parse(_ source: String) -> [Atom] {
        var scanner = Scanner(withoutMathDelimiters(source))
        return parseAtoms(&scanner, depth: 0, stop: [])
    }

    /// `$$…$$` and `$…$` say "this is maths" and are not content. A lone `$` says five
    /// dollars, so only a PAIR is removed — and the pair of dollars first, because the
    /// single-dollar rule would take the opening two and strand the closing two mid-line.
    private static func withoutMathDelimiters(_ source: String) -> String {
        // `\(…\)` and `\[…\]` are the other pair of delimiters, and they are not escapes:
        // without this they reached the reader as literal brackets round the formula.
        var value = source
        for delimiter in ["\\(", "\\)", "\\[", "\\]"] {
            value = value.replacingOccurrences(of: delimiter, with: "")
        }
        for pattern in [#"\$\$([\s\S]+?)\$\$"#, #"(?<!\\)\$([^$\n]+)\$"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let text = NSMutableString(string: value)
            let matches = regex.matches(in: value, range: NSRange(location: 0, length: (value as NSString).length))
            for match in matches.reversed() {
                let inner = (value as NSString).substring(with: match.range(at: 1))
                text.replaceCharacters(in: match.range, with: inner)
            }
            value = text as String
        }
        return value
    }

    /// What a construct reads as when it is not drawn — the copy text, the accessibility
    /// label, and the fallback for any caller without a typesetter.
    public static func plainText(_ atoms: [Atom]) -> String {
        var result = ""
        for atom in atoms {
            switch atom {
            case let .text(value):
                result += value
            case let .fraction(numerator, denominator):
                result += fractionText(plainText(numerator), plainText(denominator))
            case let .radical(degree, body):
                let index = plainText(degree)
                let raised = index.isEmpty ? "" : (canSuperscript(index) ? superscript(index) : index)
                result += raised + "√" + grouped(plainText(body))
            case let .script(base, upper, lower):
                result += plainText(base) + scriptText(upper: plainText(upper), lower: plainText(lower))
            case let .bigOperator(symbol, upper, lower):
                result += symbol + scriptText(upper: plainText(upper), lower: plainText(lower))
            case let .delimited(open, close, body):
                result += open + plainText(body) + close
            case let .stack(_, rows):
                result += rows.map { plainText($0) }.joined(separator: "\n")
            }
        }
        return result
    }

    /// The maths written back as LaTeX, for a reader who wants to paste it somewhere that
    /// understands it.
    ///
    /// Not the source the model sent — that is gone by the time anything is on screen, and
    /// keeping it would mean carrying a second copy of every answer. This is the tree written
    /// out again, so what comes back is equivalent rather than identical: `\dfrac` comes back
    /// as `\frac`, `≠` as `\ne`, `x²` as `x^{2}`. It parses to the same tree.
    public static func latex(_ atoms: [Atom]) -> String {
        var result = ""
        for atom in atoms {
            switch atom {
            case let .text(value):
                result += latexText(value)
            case let .fraction(numerator, denominator):
                result += "\\frac{" + latex(numerator) + "}{" + latex(denominator) + "}"
            case let .radical(degree, body):
                let index = degree.isEmpty ? "" : "[" + latex(degree) + "]"
                result += "\\sqrt" + index + "{" + latex(body) + "}"
            case let .script(base, upper, lower):
                result += latex(base)
                if !lower.isEmpty { result += "_{" + latex(lower) + "}" }
                if !upper.isEmpty { result += "^{" + latex(upper) + "}" }
            case let .bigOperator(symbol, upper, lower):
                result += (operatorCommands[symbol].map { "\\" + $0 } ?? symbol)
                if !lower.isEmpty { result += "_{" + latex(lower) + "}" }
                if !upper.isEmpty { result += "^{" + latex(upper) + "}" }
            case let .delimited(open, close, body):
                guard !open.isEmpty || !close.isEmpty else {
                    // A group with no brackets of its own — `\text{…}` with more than one
                    // piece in it. `\left.\right.` would be valid and would say nothing.
                    result += latex(body)
                    continue
                }
                result += "\\left" + (open.isEmpty ? "." : latexDelimiter(open))
                result += latex(body)
                result += "\\right" + (close.isEmpty ? "." : latexDelimiter(close))
            case let .stack(open, rows):
                let environment = stackEnvironments[open] ?? "matrix"
                result += "\\begin{" + environment + "}"
                result += rows.map { latex($0) }.joined(separator: " \\\\ ")
                result += "\\end{" + environment + "}"
            }
        }
        return result
    }

    /// One run of set text, written back as source: the glyphs become their commands again,
    /// a raised or lowered character becomes a script, and what LaTeX reserves is escaped.
    private static func latexText(_ value: String) -> String {
        let characters = Array(value)
        var result = ""
        var pendingMark = ""
        var pendingBody = ""
        func flushScript() {
            guard !pendingMark.isEmpty else { return }
            result += pendingMark + "{" + pendingBody + "}"
            pendingMark = ""
            pendingBody = ""
        }
        for (index, character) in characters.enumerated() {
            if let plain = raisedCharacters[character] {
                if pendingMark != "^" { flushScript(); pendingMark = "^" }
                pendingBody.append(plain)
                continue
            }
            if let plain = loweredCharacters[character] {
                if pendingMark != "_" { flushScript(); pendingMark = "_" }
                pendingBody.append(plain)
                continue
            }
            flushScript()
            // What LaTeX reserves comes first: `%` has a command name of its own in the
            // symbol table, and writing `\percent` where `\%` was meant is a comment marker
            // that swallows the rest of the line.
            if reservedCharacters.contains(character) {
                result += "\\" + String(character)
                continue
            }
            if let command = symbolCommands[String(character)] {
                // A command name ends at the first character that is not a letter, so the
                // space is only needed when a letter follows — `\ne 0` would otherwise be
                // written `\ne  0`, with the author's own space after it.
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                result += "\\" + command + (next.isLetter ? " " : "")
                continue
            }
            result.append(character)
        }
        flushScript()
        return result
    }

    private static func latexDelimiter(_ value: String) -> String {
        switch value {
        case "{": return "\\{"
        case "}": return "\\}"
        case "‖": return "\\Vert"
        case "⟨": return "\\langle"
        case "⟩": return "\\rangle"
        case "⌊": return "\\lfloor"
        case "⌋": return "\\rfloor"
        case "⌈": return "\\lceil"
        case "⌉": return "\\rceil"
        default: return value
        }
    }

    private static let reservedCharacters: Set<Character> = ["%", "&", "#", "_", "$"]

    /// Built from the tables the parser reads, so a symbol added in one direction cannot be
    /// missing in the other. The first spelling wins: `≠` comes back as `\ne`, not `\neq`.
    private static let symbolCommands: [String: String] = {
        var table: [String: String] = [:]
        for name in symbols.keys.sorted() {
            guard let glyph = symbols[name], !glyph.isEmpty, glyph != " ", glyph != "  " else { continue }
            if table[glyph] == nil || name.count < (table[glyph] ?? "").count {
                table[glyph] = name
            }
        }
        return table
    }()

    private static let operatorCommands: [String: String] = {
        var table: [String: String] = [:]
        for (name, symbol) in limitOperators where table[symbol] == nil {
            table[symbol] = name
        }
        return table
    }()

    private static let stackEnvironments: [String: String] = [
        "{": "cases", "(": "pmatrix", "[": "bmatrix", "|": "vmatrix", "‖": "Vmatrix", "": "matrix",
    ]

    private static let raisedCharacters: [Character: Character] = {
        var table: [Character: Character] = [:]
        for (plain, raised) in superscripts where table[raised] == nil { table[raised] = plain }
        return table
    }()

    private static let loweredCharacters: [Character: Character] = {
        var table: [Character: Character] = [:]
        for (plain, lowered) in subscripts where table[lowered] == nil { table[lowered] = plain }
        return table
    }()

    // MARK: - What is drawn and what is set

    private static func emit(_ atoms: [Atom], into text: inout String, drawables: inout [Atom]) {
        for atom in atoms {
            if let fallback = textFallback(for: atom) {
                text += fallback
            } else {
                drawables.append(atom)
                text += drawablePlaceholder
            }
        }
    }

    /// The text a construct may be set as instead of drawn, or nil when only a drawing will
    /// do. Text is preferred wherever it is honest: it stays selectable, it keeps the line's
    /// height, and ½ or `x²` set as a character reads better than a picture of one.
    private static func textFallback(for atom: Atom) -> String? {
        switch atom {
        case let .text(value):
            return value
        case let .fraction(numerator, denominator):
            let top = plainText(numerator).trimmingCharacters(in: .whitespaces)
            let bottom = plainText(denominator).trimmingCharacters(in: .whitespaces)
            return vulgar[top + "/" + bottom]
        case .radical, .stack:
            // A root needs its bar over the whole radicand, and a system needs its brace.
            return nil
        case let .script(base, upper, lower):
            guard base.allSatisfy({ $0.isText }) else { return nil }
            let raised = plainText(upper)
            let lowered = plainText(lower)
            if !raised.isEmpty, !canSuperscript(raised) { return nil }
            if !lowered.isEmpty, !canSubscript(lowered) { return nil }
            return plainText(base) + scriptText(upper: raised, lower: lowered)
        case let .bigOperator(symbol, upper, lower):
            // Limits belong above and below, which only a drawing can do. Without them the
            // symbol is just a character.
            guard upper.isEmpty, lower.isEmpty else { return nil }
            return symbol
        case let .delimited(open, close, body):
            var inner = ""
            for piece in body {
                guard let fallback = textFallback(for: piece) else { return nil }
                inner += fallback
            }
            return open + inner + close
        }
    }

    // MARK: - Fragments

    /// `\frac` inside a code span is code, not maths, and has to survive as written.
    private static func forEachFragment(of line: String, body: (String, Bool) -> Void) {
        guard line.contains("`") else {
            body(line, false)
            return
        }
        var fragment = ""
        var inCode = false
        for character in line {
            if character == "`" {
                body(fragment, inCode)
                fragment = ""
                body("`", true)
                inCode.toggle()
            } else {
                fragment.append(character)
            }
        }
        body(fragment, inCode)
    }

    /// The spacing commands are decorative and every one of them leaves a gap behind whether
    /// or not the author already put a space there. A line with no command in it is left
    /// exactly as written, and so is every line's indentation, which is what markdown reads
    /// nesting from.
    private static func tidy(_ value: String, touched: Bool) -> String {
        guard touched else { return value }
        return value.components(separatedBy: "\n").map { line -> String in
            let body = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = line.prefix(line.count - body.count)
            return String(indent) + body.replacingOccurrences(of: #" {2,}"#, with: " ",
                                                              options: .regularExpression)
        }.joined(separator: "\n")
    }

    // MARK: - Scanner

    private struct Scanner {
        let characters: [Character]
        var index: Int = 0

        init(_ source: String) {
            self.characters = Array(source)
        }

        var isAtEnd: Bool { return index >= characters.count }

        func peek(_ offset: Int = 0) -> Character? {
            let position = index + offset
            return position >= 0 && position < characters.count ? characters[position] : nil
        }

        @discardableResult
        mutating func advance() -> Character? {
            guard index < characters.count else { return nil }
            defer { index += 1 }
            return characters[index]
        }

        func matches(_ text: String) -> Bool {
            let target = Array(text)
            guard index + target.count <= characters.count else { return false }
            for (offset, character) in target.enumerated() where characters[index + offset] != character {
                return false
            }
            return true
        }

        @discardableResult
        mutating func consume(_ text: String) -> Bool {
            guard matches(text) else { return false }
            index += text.count
            return true
        }

        /// The letters of a command name, the scanner sitting just after the backslash.
        mutating func readCommandName() -> String {
            var name = ""
            while let character = peek(), character.isASCII, character.isLetter {
                name.append(character)
                index += 1
            }
            return name
        }

        func slice(from start: Int) -> String {
            let end = min(index, characters.count)
            guard start >= 0, start <= end else { return "" }
            return String(characters[start..<end])
        }
    }

    private struct Stop: OptionSet {
        let rawValue: Int
        static let brace = Stop(rawValue: 1 << 0)
        static let right = Stop(rawValue: 1 << 1)
        static let cell = Stop(rawValue: 1 << 2)
    }

    private static let maximumDepth = 10

    // MARK: - Parser

    private static func parseAtoms(_ scanner: inout Scanner, depth: Int, stop: Stop) -> [Atom] {
        var atoms: [Atom] = []
        var run = ""
        func flush() {
            if !run.isEmpty {
                atoms.append(.text(run))
                run = ""
            }
        }
        guard depth < maximumDepth else { return [] }

        while let character = scanner.peek() {
            if stop.contains(.brace), character == "}" { break }
            if stop.contains(.cell) {
                if character == "&" { break }
                if scanner.matches("\\\\") { break }
            }
            if character == "\\" {
                if stop.contains(.right), scanner.matches("\\right") { break }
                if scanner.matches("\\end") { break }
                if scanner.consume("\\\\") {
                    flush()
                    atoms.append(.text("\n"))
                    continue
                }
                let start = scanner.index
                scanner.advance()
                let name = scanner.readCommandName()
                if name.isEmpty {
                    // An escaped character: `\{`, `\%`, `\,` and the rest. It is that
                    // character, and the subscript rule must never see it as a subscript.
                    if let escaped = scanner.advance() {
                        run += escapeText(for: escaped)
                    } else {
                        run += "\\"
                    }
                    continue
                }
                guard let atom = parseCommand(name, from: start, in: &scanner,
                                              depth: depth, stop: stop) else { continue }
                if case let .text(value) = atom {
                    run += value
                } else {
                    flush()
                    atoms.append(atom)
                }
                continue
            }
            if character == "{" {
                scanner.advance()
                let inner = parseAtoms(&scanner, depth: depth + 1, stop: [.brace])
                scanner.consume("}")
                if inner.count == 1, case let .text(value) = inner[0] {
                    run += value
                } else {
                    flush()
                    atoms.append(contentsOf: inner)
                }
                continue
            }
            if character == "^" || character == "_" {
                if attachScript(isUpper: character == "^", to: &atoms, run: &run,
                                scanner: &scanner, depth: depth) {
                    continue
                }
                run.append(character)
                scanner.advance()
                continue
            }
            run.append(character)
            scanner.advance()
        }
        flush()
        return atoms
    }

    /// True when the `^` or `_` really was a script and has been consumed.
    private static func attachScript(isUpper: Bool, to atoms: inout [Atom], run: inout String,
                                     scanner: inout Scanner, depth: Int) -> Bool {
        let save = scanner.index
        scanner.advance()
        guard let argument = parseScriptArgument(&scanner, depth: depth) else {
            scanner.index = save
            return false
        }
        // Something has to sit under or over it. At the start of a line `_` is markdown's own
        // emphasis, not a subscript, and reading it as one cost both the letter and the mark.
        var base: [Atom] = []
        if !run.isEmpty {
            let split = splitBase(run)
            guard !split.base.isEmpty else {
                scanner.index = save
                return false
            }
            run = split.remainder
            if !run.isEmpty {
                atoms.append(.text(run))
                run = ""
            }
            base = [.text(split.base)]
        } else if let last = atoms.popLast() {
            base = [last]
        } else {
            scanner.index = save
            return false
        }
        // `x_1^2` is one base with two scripts, not a script on a script.
        if base.count == 1, case let .script(innerBase, innerUpper, innerLower) = base[0] {
            if isUpper, innerUpper.isEmpty {
                atoms.append(.script(base: innerBase, upper: argument, lower: innerLower))
                return true
            }
            if !isUpper, innerLower.isEmpty {
                atoms.append(.script(base: innerBase, upper: innerUpper, lower: argument))
                return true
            }
        }
        // A limit operator takes its limits above and below, not beside.
        if base.count == 1, case let .bigOperator(symbol, upper, lower) = base[0] {
            atoms.append(.bigOperator(symbol: symbol,
                                      upper: isUpper ? argument : upper,
                                      lower: isUpper ? lower : argument))
            return true
        }
        atoms.append(.script(base: base,
                             upper: isUpper ? argument : [],
                             lower: isUpper ? [] : argument))
        return true
    }

    /// The part of a text run a script belongs to, and what is left of the run.
    ///
    /// `(x-2)^2` raises the whole bracket, not the bracket's last character.
    private static func splitBase(_ run: String) -> (base: String, remainder: String) {
        let characters = Array(run)
        guard let last = characters.last else { return ("", run) }
        if last == " " || last == "\t" || last == "\n" { return ("", run) }
        let closers: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        if let opener = closers[last] {
            var depth = 0
            var index = characters.count - 1
            while index >= 0 {
                if characters[index] == last { depth += 1 }
                if characters[index] == opener {
                    depth -= 1
                    if depth == 0 {
                        return (rounded(String(characters[index...])),
                                String(characters[..<index]))
                    }
                }
                index -= 1
            }
            return (String(last), String(characters.dropLast()))
        }
        // A number is one base: `x10^2` raises ten, not the nought.
        if last.isNumber {
            var index = characters.count - 1
            while index > 0, characters[index - 1].isNumber { index -= 1 }
            return (String(characters[index...]), String(characters[..<index]))
        }
        return (String(last), String(characters.dropLast()))
    }

    /// A group being raised to a power is written with round brackets.
    ///
    /// `[x(x-6)]^2` is correct maths and reads as a squared bracket next to an ordinary one,
    /// which is the "какие-то [" in the report. Square brackets are NOT normalised in general
    /// — `x ∈ [0, 1]` is a closed interval and `(0, 1)` is a different set — only the pair
    /// that a script is sitting on, where the brackets are grouping and nothing else.
    private static func rounded(_ group: String) -> String {
        guard group.count > 2, group.hasPrefix("["), group.hasSuffix("]") else { return group }
        let inner = String(group.dropFirst().dropLast())
        // An interval is a pair, and a pair has a comma in it at the top level.
        var depth = 0
        for character in inner {
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" { depth -= 1 }
            if character == ",", depth == 0 { return group }
        }
        return "(" + inner + ")"
    }

    private static func parseScriptArgument(_ scanner: inout Scanner, depth: Int) -> [Atom]? {
        guard let character = scanner.peek() else { return nil }
        if character == "{" {
            scanner.advance()
            let inner = parseAtoms(&scanner, depth: depth + 1, stop: [.brace])
            scanner.consume("}")
            return inner.isEmpty ? nil : inner
        }
        // A space means the author did not write a script, and neither did markdown: this is
        // what keeps `_italic_ text` out of the subscript rule.
        if character == " " || character == "\t" || character == "\n" { return nil }
        if character == "\\" {
            let start = scanner.index
            scanner.advance()
            let name = scanner.readCommandName()
            guard !name.isEmpty,
                  let atom = parseCommand(name, from: start, in: &scanner,
                                          depth: depth + 1, stop: []) else {
                scanner.index = start
                return nil
            }
            return [atom]
        }
        if character.isNumber {
            var text = ""
            while let digit = scanner.peek(), digit.isNumber {
                text.append(digit)
                scanner.advance()
            }
            return [.text(text)]
        }
        if character == "+" || character == "-" || character == "−" {
            var text = String(character)
            scanner.advance()
            while let digit = scanner.peek(), digit.isNumber {
                text.append(digit)
                scanner.advance()
            }
            return text.count > 1 ? [.text(text)] : nil
        }
        if character.isLetter {
            // A letter followed by a letter is a word, not a script: `file_name` is a name.
            if let next = scanner.peek(1), next.isLetter { return nil }
            scanner.advance()
            return [.text(String(character))]
        }
        return nil
    }

    // MARK: Commands

    private static func parseCommand(_ name: String, from start: Int, in scanner: inout Scanner,
                                     depth: Int, stop: Stop) -> Atom? {
        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            guard let numerator = parseArgument(&scanner, depth: depth),
                  let denominator = parseArgument(&scanner, depth: depth) else {
                // Half a call is not a fraction. It is left exactly as the author wrote it.
                return .text(scanner.slice(from: start))
            }
            return .fraction(numerator: numerator, denominator: denominator)
        case "binom", "dbinom", "tbinom":
            guard let top = parseArgument(&scanner, depth: depth),
                  let bottom = parseArgument(&scanner, depth: depth) else {
                return .text(scanner.slice(from: start))
            }
            return .delimited(open: "(", close: ")",
                              body: [.stack(open: "", rows: [top, bottom])])
        case "sqrt":
            let degree = parseOptionalArgument(&scanner, depth: depth) ?? []
            guard let body = parseArgument(&scanner, depth: depth) else {
                return .text(scanner.slice(from: start))
            }
            return .radical(degree: degree, body: body)
        case "begin":
            return parseEnvironment(&scanner, from: start, depth: depth)
        case "left":
            let open = readDelimiter(&scanner)
            let body = parseAtoms(&scanner, depth: depth + 1, stop: stop.union(.right))
            var close = ""
            if scanner.consume("\\right") {
                close = readDelimiter(&scanner)
            }
            return .delimited(open: open, close: close, body: body)
        case "right":
            // Unpaired: the delimiter is still the character the author meant.
            return .text(readDelimiter(&scanner))
        default:
            break
        }
        if let symbol = limitOperators[name] {
            return .bigOperator(symbol: symbol, upper: [], lower: [])
        }
        if let arity = braceArity[name] {
            var arguments: [[Atom]] = []
            for _ in 0..<arity {
                guard let argument = parseArgument(&scanner, depth: depth) else {
                    return .text(scanner.slice(from: start))
                }
                arguments.append(argument)
            }
            return expand(name: name, arguments: arguments)
        }
        if let symbol = symbols[name] { return .text(symbol) }
        if removed.contains(name) { return .text("") }
        if functions.contains(name) { return .text(name) }
        // Not one of ours. It is left exactly as the author wrote it, braces and all — a
        // Windows path is not a command, and neither is a word someone put a backslash in
        // front of. Unwrapping the group after it would turn `\foo{bar}` into `\foobar`.
        return .text("\\" + name + (readRawGroup(&scanner) ?? ""))
    }

    private static func parseArgument(_ scanner: inout Scanner, depth: Int) -> [Atom]? {
        let save = scanner.index
        while scanner.peek() == " " { scanner.advance() }
        guard scanner.peek() == "{" else {
            scanner.index = save
            return nil
        }
        scanner.advance()
        let inner = parseAtoms(&scanner, depth: depth + 1, stop: [.brace])
        guard scanner.consume("}") else {
            scanner.index = save
            return nil
        }
        return inner
    }

    private static func parseOptionalArgument(_ scanner: inout Scanner, depth: Int) -> [Atom]? {
        guard scanner.peek() == "[" else { return nil }
        let save = scanner.index
        scanner.advance()
        var body = ""
        while let character = scanner.peek(), character != "]" {
            body.append(character)
            scanner.advance()
        }
        guard scanner.consume("]") else {
            scanner.index = save
            return nil
        }
        return depth < maximumDepth ? parse(body) : nil
    }

    private static func parseEnvironment(_ scanner: inout Scanner, from start: Int, depth: Int) -> Atom? {
        guard let name = readBracedWord(&scanner) else {
            return .text(scanner.slice(from: start))
        }
        // `array` carries a column specification nobody needs to see.
        if name.hasPrefix("array") { _ = parseArgument(&scanner, depth: depth) }
        var rows: [[Atom]] = []
        var cells: [Atom] = []
        var guardCounter = 0
        while !scanner.isAtEnd, guardCounter < 400 {
            guardCounter += 1
            if scanner.matches("\\end") { break }
            cells.append(contentsOf: parseAtoms(&scanner, depth: depth + 1, stop: [.cell]))
            if scanner.consume("&") {
                cells.append(.text(" "))
                continue
            }
            if scanner.consume("\\\\") {
                rows.append(trimmed(cells))
                cells = []
                continue
            }
            if scanner.matches("\\end") { break }
            // Nothing was consumed; do not spin.
            guard scanner.advance() != nil else { break }
        }
        let tail = trimmed(cells)
        if !tail.isEmpty { rows.append(tail) }
        scanner.consume("\\end")
        _ = readBracedWord(&scanner)
        let bracket = environmentBrackets[name.replacingOccurrences(of: "*", with: "")] ?? ""
        return .stack(open: bracket, rows: rows.filter { !$0.isEmpty })
    }

    /// A `{…}` group exactly as written, braces included, honouring nesting.
    private static func readRawGroup(_ scanner: inout Scanner) -> String? {
        guard scanner.peek() == "{" else { return nil }
        let start = scanner.index
        var depth = 0
        while let character = scanner.peek() {
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                scanner.advance()
                if depth == 0 { return scanner.slice(from: start) }
                continue
            }
            scanner.advance()
        }
        scanner.index = start
        return nil
    }

    private static func readBracedWord(_ scanner: inout Scanner) -> String? {
        guard scanner.peek() == "{" else { return nil }
        let save = scanner.index
        scanner.advance()
        var name = ""
        while let character = scanner.peek(), character != "}" {
            name.append(character)
            scanner.advance()
        }
        guard scanner.consume("}") else {
            scanner.index = save
            return nil
        }
        return name
    }

    /// The delimiter after `\left` or `\right`. `.` is the invisible one.
    private static func readDelimiter(_ scanner: inout Scanner) -> String {
        while scanner.peek() == " " { scanner.advance() }
        guard let character = scanner.peek() else { return "" }
        if character == "\\" {
            let start = scanner.index
            scanner.advance()
            let name = scanner.readCommandName()
            if name.isEmpty {
                if let escaped = scanner.advance() { return String(escaped) }
                scanner.index = start
                return ""
            }
            return symbols[name] ?? ""
        }
        scanner.advance()
        return character == "." ? "" : String(character)
    }

    private static func trimmed(_ atoms: [Atom]) -> [Atom] {
        var result = atoms
        if case let .text(value) = result.first {
            let head = String(value.drop(while: { $0 == " " || $0 == "\t" }))
            if head.isEmpty { result.removeFirst() } else { result[0] = .text(head) }
        }
        if case let .text(value) = result.last {
            var tail = value
            while tail.hasSuffix(" ") || tail.hasSuffix("\t") { tail.removeLast() }
            if tail.isEmpty {
                result.removeLast()
            } else {
                result[result.count - 1] = .text(tail)
            }
        }
        return result
    }

    private static func expand(name: String, arguments: [[Atom]]) -> Atom {
        let body = arguments[0]
        switch name {
        case "phantom", "hphantom", "vphantom":
            return .text(String(repeating: " ", count: min(max(plainText(body).count, 1), 8)))
        case "hspace", "vspace":
            return .text(" ")
        case "label", "tag":
            return .text("")
        case "mathbb":
            let plain = plainText(body)
            return .text(doubleStruck[plain] ?? plain)
        default:
            if let mark = combining[name] {
                // A mark belongs over ONE letter. Over a whole expression it lands on the
                // first character and reads as a typo.
                let plain = plainText(body)
                return .text(plain.count == 1 ? plain + mark : plain)
            }
            if body.count == 1 { return body[0] }
            return .delimited(open: "", close: "", body: body)
        }
    }

    private static func escapeText(for character: Character) -> String {
        switch character {
        case ",", ";", ":", " ": return " "
        case "!": return ""
        default: return String(character)
        }
    }

    // MARK: - Text rendering

    private static func scriptText(upper: String, lower: String) -> String {
        var result = ""
        if !lower.isEmpty {
            result += canSubscript(lower) ? subscripted(lower) : "_(" + lower + ")"
        }
        if !upper.isEmpty {
            result += canSuperscript(upper) ? superscript(upper) : "^(" + upper + ")"
        }
        return result
    }

    /// The exact single glyphs. Anything outside this set is NOT approximated with one.
    private static let vulgar: [String: String] = [
        "1/2": "½", "1/3": "⅓", "2/3": "⅔", "1/4": "¼", "3/4": "¾",
        "1/5": "⅕", "2/5": "⅖", "3/5": "⅗", "4/5": "⅘", "1/6": "⅙", "5/6": "⅚",
        "1/7": "⅐", "1/8": "⅛", "3/8": "⅜", "5/8": "⅝", "7/8": "⅞",
        "1/9": "⅑", "1/10": "⅒",
    ]

    /// One fraction as text, for where a drawing cannot go.
    ///
    /// Not as superscript-slash-subscript: `\frac{0}{0}` set that way is `⁰⁄₀`, and at body
    /// size that is a percent sign — which is what an answer about an indeterminate form
    /// actually showed a reader. Not with U+2044 either, which the system face draws as a
    /// steep stroke that reads as an accent.
    private static func fractionText(_ numerator: String, _ denominator: String) -> String {
        let top = numerator.trimmingCharacters(in: .whitespaces)
        let bottom = denominator.trimmingCharacters(in: .whitespaces)
        guard !top.isEmpty, !bottom.isEmpty else { return top + "/" + bottom }
        if let glyph = vulgar[top + "/" + bottom] { return glyph }
        return grouped(top) + "/" + grouped(bottom)
    }

    /// Brackets anything that is more than a single term, so a slash cannot silently rebind
    /// it: `x+1` becomes `(x+1)`, because `x+1/2` is a different number.
    private static func grouped(_ value: String) -> String {
        let candidate = value.trimmingCharacters(in: .whitespaces)
        guard candidate.count > 1 else { return candidate }
        if isSingleGroup(candidate) { return candidate }
        let breaking = CharacterSet(charactersIn: "+-−±∓×÷·/, ")
        guard candidate.rangeOfCharacter(from: breaking) != nil else { return candidate }
        return "(" + candidate + ")"
    }

    /// True when the whole string is ONE bracketed group. `hasPrefix("(") && hasSuffix(")")`
    /// is not that test: `(a+b)(c+d)` passes it and is two groups.
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

    private static func canSuperscript(_ source: String) -> Bool {
        return !source.isEmpty && source.allSatisfy { superscripts[$0] != nil }
    }

    private static func canSubscript(_ source: String) -> Bool {
        return !source.isEmpty && source.allSatisfy { subscripts[$0] != nil }
    }

    private static func superscript(_ source: String) -> String {
        return String(source.compactMap { superscripts[$0] })
    }

    private static func subscripted(_ source: String) -> String {
        return String(source.compactMap { subscripts[$0] })
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

    // MARK: - Tables

    private static let doubleStruck: [String: String] = [
        "R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ", "H": "ℍ",
    ]

    private static let combining: [String: String] = [
        "hat": "\u{0302}", "widehat": "\u{0302}", "bar": "\u{0304}", "overline": "\u{0304}",
        "vec": "\u{20D7}", "tilde": "\u{0303}", "widetilde": "\u{0303}",
        "dot": "\u{0307}", "ddot": "\u{0308}",
    ]

    private static let environmentBrackets: [String: String] = [
        "cases": "{", "pmatrix": "(", "bmatrix": "[", "Bmatrix": "{",
        "vmatrix": "|", "Vmatrix": "‖",
    ]

    /// Operators whose limits are set above and below them.
    private static let limitOperators: [String: String] = [
        "sum": "∑", "prod": "∏", "coprod": "∐", "bigcup": "⋃", "bigcap": "⋂",
        "bigoplus": "⨁", "bigotimes": "⨂", "bigvee": "⋁", "bigwedge": "⋀",
        "lim": "lim", "limsup": "lim sup", "liminf": "lim inf",
        "max": "max", "min": "min", "sup": "sup", "inf": "inf",
        "argmax": "argmax", "argmin": "argmin", "gcd": "gcd",
    ]

    private static let braceArity: [String: Int] = [
        "text": 1, "textbf": 1, "textit": 1, "textrm": 1, "textsf": 1, "texttt": 1,
        "mathrm": 1, "mathbf": 1, "mathit": 1, "mathsf": 1, "mathtt": 1, "mathbb": 1,
        "mathcal": 1, "mathfrak": 1, "operatorname": 1, "boxed": 1, "underline": 1,
        "overline": 1, "widehat": 1, "widetilde": 1, "hat": 1, "bar": 1, "vec": 1,
        "tilde": 1, "dot": 1, "ddot": 1, "phantom": 1, "hphantom": 1, "vphantom": 1,
        "hspace": 1, "vspace": 1, "label": 1, "tag": 1, "substack": 1,
    ]

    private static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh", "coth", "log", "ln", "lg", "exp", "det", "dim",
        "ker", "deg", "lcm", "mod", "bmod", "arg", "Pr", "hom",
    ]

    private static let removed: Set<String> = [
        "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle",
        "limits", "nolimits", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
        "biggl", "biggr", "Biggl", "Biggr", "middle", "mathstrut", "strut", "nonumber",
        "notag", "thinspace", "negthinspace", "negmedspace", "negthickspace",
    ]

    private static let symbols: [String: String] = [
        // Spacing wide enough to be worth keeping.
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
        "cup": "∪", "cap": "∩", "setminus": "∖",
        "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃",
        "nexists": "∄", "wedge": "∧", "vee": "∨", "land": "∧", "lor": "∨",
        "therefore": "∴", "because": "∵", "mid": "∣", "nmid": "∤",

        // Operators.
        "times": "×", "cdot": "·", "cdots": "⋯", "ldots": "…", "dots": "…",
        "vdots": "⋮", "ddots": "⋱", "div": "÷", "pm": "±", "mp": "∓",
        "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "∙", "oplus": "⊕",
        "ominus": "⊖", "otimes": "⊗", "odot": "⊙",
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "partial": "∂", "nabla": "∇", "infty": "∞",
        "angle": "∠", "measuredangle": "∡", "perp": "⊥", "parallel": "∥",
        "triangle": "△", "square": "□", "degree": "°", "prime": "′",
        "aleph": "ℵ", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "wp": "℘",
        "checkmark": "✓", "dagger": "†", "ddagger": "‡", "percent": "%",

        // Delimiters with a glyph of their own.
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋",
        "lceil": "⌈", "rceil": "⌉", "vert": "|", "Vert": "‖", "backslash": "\\",
        "lbrace": "{", "rbrace": "}", "lbrack": "[", "rbrack": "]",

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
}
