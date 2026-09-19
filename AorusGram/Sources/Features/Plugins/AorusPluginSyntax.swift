import Foundation

// A JavaScript tokenizer for the editor's colouring. It works in UTF-16 offsets because
// that is what NSTextStorage and the layout manager speak, and it is a single forward pass
// with no backtracking so a keystroke in a large file re-colours in well under a frame.
//
// It is a lexer, not a parser: it knows strings, templates, comments, numbers, regular
// expression literals, keywords and punctuation, and it tells a member access from a call.
// That is what colouring needs. It never fails — anything it does not recognise is a
// one-character punctuation token — and the tokens it returns cover the text end to end
// without gaps or overlaps, which the tests check.

public struct AorusJSToken: Equatable {
    public enum Kind: Equatable {
        case keyword
        case literal
        case number
        case string
        case template
        case comment
        case regex
        case identifier
        /// `aorus`, `console` and every member reached through them: the plugin API.
        case api
        /// An identifier directly followed by `(`.
        case function
        /// An identifier directly after `.` that is not part of the API.
        case property
        case punctuation
        case `operator`
        case whitespace
    }

    public var kind: Kind
    public var range: NSRange

    public init(kind: Kind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

public enum AorusJavaScriptTokenizer {
    private static let keywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "finally", "for", "function",
        "if", "import", "in", "instanceof", "let", "new", "of", "return", "static", "super",
        "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield",
    ]
    private static let literals: Set<String> = ["true", "false", "null", "undefined", "NaN", "Infinity"]
    private static let apiRoots: Set<String> = ["aorus", "console"]
    private static let punctuation: Set<UInt16> = Set("(){}[];,".utf16)
    private static let operators: Set<UInt16> = Set("+-*/%=<>!&|^~?:.".utf16)

    public static func tokenize(_ text: String) -> [AorusJSToken] {
        let units = Array(text.utf16)
        let count = units.count
        var tokens: [AorusJSToken] = []
        tokens.reserveCapacity(count / 4)
        var index = 0
        // The kind of the last token that was not whitespace or a comment: it decides
        // whether a `/` opens a regular expression or divides.
        var previousSignificant: AorusJSToken.Kind?
        var previousText: String = ""
        // True while the identifiers being read hang off `aorus.` or `console.`.
        var apiChain = false

        func append(_ kind: AorusJSToken.Kind, _ start: Int, _ end: Int) {
            tokens.append(AorusJSToken(kind: kind, range: NSRange(location: start, length: end - start)))
            if kind != .whitespace && kind != .comment {
                previousSignificant = kind
            }
        }

        func isIdentifierStart(_ unit: UInt16) -> Bool {
            return (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x24 || unit >= 0x80
        }

        func isIdentifierPart(_ unit: UInt16) -> Bool {
            return isIdentifierStart(unit) || (unit >= 0x30 && unit <= 0x39)
        }

        func isDigit(_ unit: UInt16) -> Bool {
            return unit >= 0x30 && unit <= 0x39
        }

        func regexAllowed() -> Bool {
            guard let previous = previousSignificant else { return true }
            switch previous {
            case .number, .string, .template, .regex, .identifier, .property, .api, .function, .literal:
                return false
            case .keyword:
                // `return /x/` and `typeof /x/` are regular expressions; `this / 2` is not.
                return !["this", "super"].contains(previousText)
            case .punctuation:
                // After `)` or `]` a slash divides; after `(`, `[`, `{`, `}`, `;`, `,` it opens.
                return previousText != ")" && previousText != "]"
            case .operator:
                return true
            case .whitespace, .comment:
                return true
            }
        }

        while index < count {
            let unit = units[index]
            let start = index

            // Whitespace
            if unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C {
                while index < count, [0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C].contains(units[index]) { index += 1 }
                append(.whitespace, start, index)
                continue
            }

            // Comments
            if unit == 0x2F, index + 1 < count {
                let next = units[index + 1]
                if next == 0x2F {
                    index += 2
                    while index < count, units[index] != 0x0A { index += 1 }
                    append(.comment, start, index)
                    continue
                }
                if next == 0x2A {
                    index += 2
                    while index < count {
                        if units[index] == 0x2A, index + 1 < count, units[index + 1] == 0x2F {
                            index += 2
                            break
                        }
                        index += 1
                    }
                    append(.comment, start, index)
                    continue
                }
            }

            // Strings
            if unit == 0x22 || unit == 0x27 {
                index += 1
                while index < count {
                    let current = units[index]
                    if current == 0x5C {
                        index += min(2, count - index)
                        continue
                    }
                    if current == unit {
                        index += 1
                        break
                    }
                    if current == 0x0A {
                        // An unterminated string ends at the line, so a missing quote does
                        // not repaint the rest of the file.
                        break
                    }
                    index += 1
                }
                append(.string, start, index)
                previousText = ""
                apiChain = false
                continue
            }

            // Template literals, `${…}` included: the whole template is one token, which is
            // how most editors colour it.
            if unit == 0x60 {
                index += 1
                var depth = 0
                while index < count {
                    let current = units[index]
                    if current == 0x5C {
                        index += min(2, count - index)
                        continue
                    }
                    if depth == 0, current == 0x60 {
                        index += 1
                        break
                    }
                    if current == 0x24, index + 1 < count, units[index + 1] == 0x7B {
                        depth += 1
                        index += 2
                        continue
                    }
                    if depth > 0, current == 0x7D {
                        depth -= 1
                    }
                    index += 1
                }
                append(.template, start, index)
                previousText = ""
                apiChain = false
                continue
            }

            // Numbers: decimal, float, exponent, hex/octal/binary, numeric separators, bigint.
            if isDigit(unit) || (unit == 0x2E && index + 1 < count && isDigit(units[index + 1])) {
                index += 1
                if unit == 0x30, index < count, [0x78, 0x58, 0x6F, 0x4F, 0x62, 0x42].contains(units[index]) {
                    index += 1
                    while index < count, isIdentifierPart(units[index]) { index += 1 }
                } else {
                    while index < count, isDigit(units[index]) || units[index] == 0x5F { index += 1 }
                    if index < count, units[index] == 0x2E {
                        index += 1
                        while index < count, isDigit(units[index]) || units[index] == 0x5F { index += 1 }
                    }
                    if index < count, units[index] == 0x65 || units[index] == 0x45 {
                        var probe = index + 1
                        if probe < count, units[probe] == 0x2B || units[probe] == 0x2D { probe += 1 }
                        if probe < count, isDigit(units[probe]) {
                            index = probe
                            while index < count, isDigit(units[index]) { index += 1 }
                        }
                    }
                    if index < count, units[index] == 0x6E { index += 1 }
                }
                append(.number, start, index)
                previousText = ""
                apiChain = false
                continue
            }

            // Identifiers, keywords, literals, API members.
            if isIdentifierStart(unit) {
                index += 1
                while index < count, isIdentifierPart(units[index]) { index += 1 }
                let word = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
                let afterDot = previousSignificant == .operator && previousText == "."
                var lookahead = index
                while lookahead < count, units[lookahead] == 0x20 || units[lookahead] == 0x09 { lookahead += 1 }
                let callFollows = lookahead < count && units[lookahead] == 0x28

                let kind: AorusJSToken.Kind
                if afterDot {
                    if apiChain {
                        kind = .api
                    } else {
                        kind = callFollows ? .function : .property
                    }
                } else if keywords.contains(word) {
                    kind = .keyword
                    apiChain = false
                } else if literals.contains(word) {
                    kind = .literal
                    apiChain = false
                } else if apiRoots.contains(word) {
                    kind = .api
                    apiChain = true
                } else {
                    kind = callFollows ? .function : .identifier
                    apiChain = false
                }
                append(kind, start, index)
                previousText = word
                continue
            }

            // Regular expression literal
            if unit == 0x2F, regexAllowed() {
                index += 1
                var inClass = false
                var terminated = false
                while index < count {
                    let current = units[index]
                    if current == 0x5C {
                        index += min(2, count - index)
                        continue
                    }
                    if current == 0x0A { break }
                    if inClass {
                        if current == 0x5D { inClass = false }
                    } else if current == 0x5B {
                        inClass = true
                    } else if current == 0x2F {
                        index += 1
                        terminated = true
                        break
                    }
                    index += 1
                }
                if terminated {
                    while index < count, isIdentifierPart(units[index]) { index += 1 }
                    append(.regex, start, index)
                    previousText = ""
                    apiChain = false
                    continue
                }
                // Not a regular expression after all: a lone slash.
                index = start + 1
                append(.operator, start, index)
                previousText = "/"
                apiChain = false
                continue
            }

            // Punctuation and operators
            if punctuation.contains(unit) {
                index += 1
                append(.punctuation, start, index)
                previousText = String(utf16CodeUnits: [unit], count: 1)
                if unit != 0x29 && unit != 0x5D {
                    apiChain = false
                }
                continue
            }
            if operators.contains(unit) {
                index += 1
                // Multi-character operators are still one token each; only the dot matters
                // for classification, and it is always alone.
                if unit != 0x2E {
                    while index < count, operators.contains(units[index]), units[index] != 0x2E { index += 1 }
                }
                append(.operator, start, index)
                previousText = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
                if unit != 0x2E {
                    apiChain = false
                }
                continue
            }

            // Anything else: one unit of punctuation.
            index += 1
            append(.punctuation, start, index)
            previousText = ""
            apiChain = false
        }
        return tokens
    }

    /// The offset of the bracket that pairs with the one at `index`, or nil when there is no
    /// bracket there or it is unbalanced. Strings and comments are not excluded: this is for
    /// the editor's highlight of the pair under the caret, where a rare false match costs
    /// nothing.
    public static func matchingBracket(in text: String, at index: Int) -> Int? {
        let units = Array(text.utf16)
        guard index >= 0, index < units.count else { return nil }
        let opens: [UInt16: UInt16] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]
        let closes: [UInt16: UInt16] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]
        let unit = units[index]
        if let close = opens[unit] {
            var depth = 0
            var cursor = index
            while cursor < units.count {
                if units[cursor] == unit { depth += 1 }
                if units[cursor] == close {
                    depth -= 1
                    if depth == 0 { return cursor }
                }
                cursor += 1
            }
            return nil
        }
        if let open = closes[unit] {
            var depth = 0
            var cursor = index
            while cursor >= 0 {
                if units[cursor] == unit { depth += 1 }
                if units[cursor] == open {
                    depth -= 1
                    if depth == 0 { return cursor }
                }
                cursor -= 1
            }
            return nil
        }
        return nil
    }

    /// The leading spaces and tabs of the line that contains `index`.
    public static func indentation(ofLineContaining index: Int, in text: String) -> String {
        let nsText = text as NSString
        guard nsText.length > 0 else { return "" }
        let location = max(0, min(index, nsText.length))
        let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        let line = nsText.substring(with: lineRange)
        var result = ""
        for character in line {
            if character == " " || character == "\t" {
                result.append(character)
            } else {
                break
            }
        }
        return result
    }

    /// 1-based line number of a UTF-16 offset.
    public static func lineNumber(of index: Int, in text: String) -> Int {
        let units = text.utf16
        var line = 1
        var count = 0
        for unit in units {
            if count >= index { break }
            if unit == 0x0A { line += 1 }
            count += 1
        }
        return line
    }

    /// UTF-16 range of a 1-based line, without its newline.
    public static func range(ofLine line: Int, in text: String) -> NSRange? {
        guard line >= 1 else { return nil }
        let nsText = text as NSString
        var current = 1
        var location = 0
        while location <= nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            if current == line {
                var contentRange = lineRange
                var end = lineRange.location + lineRange.length
                while end > lineRange.location {
                    let unit = nsText.character(at: end - 1)
                    if unit == 0x0A || unit == 0x0D { end -= 1 } else { break }
                }
                contentRange.length = end - lineRange.location
                return contentRange
            }
            if lineRange.length == 0 { break }
            location = lineRange.location + lineRange.length
            current += 1
            if location == nsText.length {
                // A trailing newline means one more, empty, line.
                if current == line { return NSRange(location: location, length: 0) }
                break
            }
        }
        return nil
    }
}
