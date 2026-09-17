import Foundation

// The maths in an assistant answer. Every expectation below is either a line taken from a
// real answer the app rendered wrongly, or a rule that failure showed was missing.
//
// The two failures this suite exists for, from a screenshot of a solved fraction equation:
//
//   * `x \ne 0` — printed with the backslash, because the table had `\neq` and not `\ne`,
//     and `\quad` and `\boxed{...}` printed likewise. The final answer of the solution read
//     "\boxed{x = 2}".
//   * `\frac{0}{0}` — set as superscript zero, fraction slash, subscript zero, which at body
//     size is a percent sign. The answer said the limit was "= %".

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

private func inline(_ source: String) -> String {
    return AorusAIMath.inlineText(source)
}

// MARK: - The commands that printed as themselves

private func setsEveryCommandTheAnswerUsed() {
    expect(inline(#"Знаменатель: x - 6 \ne 0 \Rightarrow x \ne 6"#),
           "Знаменатель: x - 6 ≠ 0 ⇒ x ≠ 6",
           "`\\ne` is a command, not text")
    expect(inline(#"x = 2 \Rightarrow x - 6 = -4 \ne 0 \quad ✓"#),
           "x = 2 ⇒ x - 6 = -4 ≠ 0 ✓",
           "`\\quad` is a space, not text")
    expect(inline(#"\boxed{x = 2}"#), "x = 2", "a boxed answer is its content")
    expect(inline(#"Только один корень: x = 2, при x \ne 0, 6"#),
           "Только один корень: x = 2, при x ≠ 0, 6",
           "the closing sentence of the same answer")

    // Whole-name matching. A table applied by prefix would reach `\le` inside `\leftarrow`
    // and leave `≤ftarrow`, and `\ne` inside `\neq` leaving `≠q`.
    expect(inline(#"\le \leq \leqslant"#), "≤ ≤ ≤", "every spelling of at-most")
    expect(inline(#"\ge \geq \neq \ne"#), "≥ ≥ ≠ ≠", "and of at-least and not-equal")
    expect(inline(#"a \leftarrow b \Leftarrow c"#), "a ← b ⇐ c", "an arrow is not a relation")
    expect(inline(#"\left( a + b \right)"#), "( a + b )", "sizing commands leave no trace")
    expect(inline(#"\left. \frac{1}{2} \right|"#), " ½ |", "and neither do the invisible ones")

    expect(inline(#"\alpha + \beta = \gamma, \Delta x, \Omega"#),
           "α + β = γ, Δ x, Ω", "Greek, both cases")
    expect(inline(#"2 \cdot 3 \times 4 \div 5 \pm 6"#), "2 · 3 × 4 ÷ 5 ± 6", "the operators")
    expect(inline(#"x \in \mathbb{R}, y \notin \varnothing, A \cup B \cap C"#),
           "x ∈ ℝ, y ∉ ∅, A ∪ B ∩ C", "sets")
    expect(inline(#"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}"#),
           "∑ᵢ₌₁ⁿ i = (n(n+1))/2", "a sum with its limits")
    expect(inline(#"\lim_{x \to 0} \frac{\sin x}{x} = 1"#),
           "lim_(x → 0) (sin x)/x = 1", "a limit reads as one")
    expect(inline(#"\int_0^1 x^2 dx"#), "∫₀¹ x² dx", "an integral with simple limits")
    expect(inline(#"\infty \approx \equiv \propto \therefore"#), "∞ ≈ ≡ ∝ ∴", "the rest of the relations")
    expect(inline(#"\vec{v} \bar{x} \hat{y}"#), "v\u{20D7} x\u{0304} y\u{0302}", "marks over one letter")
    expect(inline(#"\overline{AB}"#), "AB", "and not over a whole expression, where they land wrong")
}

// MARK: - Fractions

private func setsFractionsSoTheyReadAsValues() {
    // The percent sign. This is the one that reached a reader.
    expect(inline(#"\frac{0}{0}"#), "0/0", "the indeterminate form is not a percent sign")
    expect(inline(#"(0 \cdot (0 - 2)^2) / (0 \cdot (0 - 6)) = \frac{0}{0}"#),
           "(0 · (0 - 2)²) / (0 · (0 - 6)) = 0/0",
           "the line the screenshot showed as `= %`")

    expect(inline(#"\frac{x(x-2)^2}{x(x-6)} = 0"#), "(x(x-2)²)/(x(x-6)) = 0",
           "the equation the answer opens with")
    expect(inline(#"\frac{(x-2)^2}{x-6} = 0"#), "((x-2)²)/(x-6) = 0",
           "and the one it reduces to")

    // A half is bracketed unless it is one term, because `x+1/2` is a different number.
    expect(inline(#"\frac{x+1}{2}"#), "(x+1)/2", "a compound numerator is bracketed")
    expect(inline(#"\frac{2}{x+1}"#), "2/(x+1)", "so is a compound denominator")
    expect(inline(#"\frac{2x}{3y}"#), "2x/3y", "a single term is not")
    expect(inline(#"\frac{(a+b)(c+d)}{2}"#), "((a+b)(c+d))/2",
           "two bracketed groups are still bracketed together — they are not one group")
    expect(inline(#"\frac{(a+b)}{2}"#), "(a+b)/2", "one group is left as it is")

    // An exact glyph where one exists, and never an approximation where one does not.
    expect(inline(#"\frac{1}{2} + \frac{3}{4} + \frac{5}{8}"#), "½ + ¾ + ⅝", "the vulgar fractions")
    expect(inline(#"\frac{1}{2}x"#), "½x", "one reads correctly against what follows")
    expect(inline(#"\frac{7}{9}"#), "7/9", "and a pair with no glyph is not approximated by one")
    expect(inline(#"\dfrac{a}{b} \tfrac{c}{d} \cfrac{e}{f}"#), "a/b c/d e/f", "every spelling of frac")
    expect(inline(#"\frac{\frac{a}{b}}{c}"#), "(a/b)/c", "a fraction inside a fraction")

    // U+2044 FRACTION SLASH is drawn by the system face as a steep stroke that reads as an
    // accent. Nothing here may emit one, at any size, in any half.
    for source in [#"\frac{0}{0}"#, #"\frac{1}{3}"#, #"\frac{x+1}{y-1}"#, #"\frac{ab}{cd}"#] {
        expect(!inline(source).contains("\u{2044}"), "no fraction slash in \(source)")
    }
}

// MARK: - Scripts

private func setsScriptsWithoutSwallowingWhatFollows() {
    expect(inline("x^2"), "x²", "a squared term")
    expect(inline("x^2+1"), "x²+1", "an exponent is one term — this was x to the three")
    expect(inline("(x^2+1)"), "(x²+1)", "and the bracket does not go up with it")
    expect(inline("x^{10}"), "x¹⁰", "a grouped exponent")
    expect(inline("x^{n+1}"), "xⁿ⁺¹", "a grouped one whose parts all have glyphs")
    expect(inline("x^{2n+1}"), "x²ⁿ⁺¹", "and a longer one")
    expect(inline("e^{i\\pi}"), "e^(iπ)", "one whose parts do not all have glyphs")
    expect(inline("x_1 + x_2"), "x₁ + x₂", "subscripts")
    expect(inline("a_{ij}"), "aᵢⱼ", "a two-letter subscript")
    expect(inline("a_{max}"), "aₘₐₓ", "a three-letter one")
    expect(inline("a_{fig}"), "a_(fig)", "and one with a letter that has no subscript form")

    // This pass runs before the markdown pass, so it must not eat markdown's own underscore.
    expect(inline("_italic_ text"), "_italic_ text", "markdown emphasis is not a subscript")
    expect(inline("file_name.txt"), "file_name.txt", "and neither is an identifier")
    expect(inline(#"a \_ b"#), "a _ b", "an escaped underscore is an underscore")
}

// MARK: - Prose

private func leavesProseAlone() {
    expect(inline("Обычный текст без формул."), "Обычный текст без формул.", "plain prose")
    expect(inline("R&D spends 40% of $5 on C:\\net"), "R&D spends 40% of $5 on C:\\net",
           "an ampersand, a percent, a dollar and a path are not maths")
    expect(inline(#"\foo{bar}"#), #"\foo{bar}"#, "a command we do not know is left as written")
    expect(inline(#"\frac{a}"#), #"\frac{a}"#, "and so is a call with a half missing")
    // Two hashes: in a `#"…"#` literal the escape character is `\#`, so `\#1` is read as one.
    expect(inline(##"100\% \$5 \{x\} \#1"##), "100% $5 {x} #1", "escapes are the characters")
}

private func setsEnvironments() {
    let cases = #"\begin{cases} x, & x > 0 \\ -x, & x < 0 \end{cases}"#
    expect(inline(cases), "x, x > 0\n-x, x < 0", "cases become lines")
    expect(inline(#"\begin{aligned} a &= b \\ c &= d \end{aligned}"#), "a = b\nc = d",
           "so does an alignment")
}

// MARK: - Which fractions are drawn

private func liftsEveryFractionWhereverItStands() {
    // THE bug this section exists for. A model writes `\frac` on a line of its own far more
    // often than it wraps it in `$$…$$`, and when it did, nothing was drawn: a whole solved
    // equation came back as `([x(x - 6)]²)/(x(x - 2))`, which is what a fraction looks like
    // when the renderer cannot draw one.
    let bare = AorusAIMath.render(#"\frac{[x(x-6)]^2}{x(x-2)}"#)
    expect(bare.drawables.count, 1, "a fraction with no delimiters around it is still a fraction")
    expect(bare.text, "\u{FFFC}", "and leaves a placeholder for the drawing")
    expect(AorusAIMath.plainText(bare.drawables), "([x(x-6)]²)/(x(x-2))",
           "whose text fallback is still correct")

    let inSentence = AorusAIMath.render(#"Теперь дробь: \frac{x^2(x-6)^2}{x(x-2)} и дальше"#)
    expect(inSentence.drawables.count, 1, "one in the middle of a sentence is drawn too")
    expect(inSentence.text, "Теперь дробь: \u{FFFC} и дальше", "with the prose either side kept")

    let display = AorusAIMath.render("Решим:\n$$\\frac{x(x-2)^2}{x(x-6)} = 0$$\nДальше.")
    expect(display.drawables.count, 1, "a display equation still works")
    expect(display.text, "Решим:\n\u{FFFC} = 0\nДальше.", "with only the fraction lifted")

    let bracket = AorusAIMath.render("\\[\\frac{a}{b}\\]")
    expect(bracket.drawables.count, 1, "`\\[…\\]` is unwrapped, not printed")
    expect(bracket.text, "\u{FFFC}", "and leaves nothing behind")

    let fenced = AorusAIMath.render("До\n$$\n\\frac{a+1}{b}\n$$\nПосле")
    expect(fenced.drawables.count, 1, "a fence on its own line is a delimiter")
    expect(fenced.text, "До\n\u{FFFC}\nПосле", "and is consumed, not shown")

    // A glyph of its own beats a drawing: ½ keeps the line's height and reads perfectly.
    let half = AorusAIMath.render(#"Возьмём \frac{1}{2} от числа"#)
    expect(half.drawables.count, 0, "a vulgar fraction is not drawn")
    expect(half.text, "Возьмём ½ от числа", "it is set")

    let noFraction = AorusAIMath.render("$$x = 2$$")
    expect(noFraction.drawables.count, 0, "an equation with no fraction has nothing to draw")
    expect(noFraction.text, "x = 2", "and is just text")

    let nested = AorusAIMath.render(#"\frac{\frac{a}{b}}{c}"#)
    expect(nested.drawables.count, 1, "a fraction inside a fraction is one drawing")
    if case let .fraction(numerator, _)? = nested.drawables.first {
        var isNested = false
        for atom in numerator {
            if case .fraction = atom { isNested = true }
        }
        expect(isNested, "whose numerator is itself a fraction")
    } else {
        failures.append("a nested fraction parses as a fraction")
    }

    // A code span is code. `\frac` in one is what the reader asked to see.
    let code = AorusAIMath.render("Пиши `\\frac{a}{b}` в LaTeX")
    expect(code.drawables.count, 0, "nothing is lifted out of a code span")
    expect(code.text, "Пиши `\\frac{a}{b}` в LaTeX", "and it survives exactly")

    let two = AorusAIMath.render(#"\frac{a}{b} = \frac{c}{d}"#)
    expect(two.drawables.count, 2, "two fractions on a line are two drawings")
    expect(two.text, "\u{FFFC} = \u{FFFC}", "in the order they appear")

    expect(AorusAIMath.plainText(AorusAIMath.atoms("x = 2")), "x = 2", "atoms of plain text")
}

private func drawsEveryConstructThatOnlyADrawingCanShow() {
    // A root needs its bar carried over the whole radicand.
    let root = AorusAIMath.render(#"\sqrt{x+1}"#)
    expect(root.drawables.count, 1, "a root is drawn")
    expect(root.text, "\u{FFFC}", "and leaves a placeholder")
    expect(AorusAIMath.plainText(root.drawables), "√(x+1)", "its text fallback is still right")

    let cube = AorusAIMath.render(#"\sqrt[3]{8} = 2"#)
    expect(cube.drawables.count, 1, "so is one with a degree")
    expect(cube.text, "\u{FFFC} = 2", "with the rest of the line kept")

    // A script whose parts have characters of their own stays text — it reads better and it
    // stays selectable. One whose parts do not is drawn rather than written `e^(iπ)`.
    let squared = AorusAIMath.render("x^2 + 1")
    expect(squared.drawables.count, 0, "a squared term is a character")
    expect(squared.text, "x² + 1", "so it is set, not drawn")

    let exponential = AorusAIMath.render(#"e^{i\pi} + 1 = 0"#)
    expect(exponential.drawables.count, 1, "an exponent with no characters for it is drawn")
    expect(exponential.text, "\u{FFFC} + 1 = 0", "and the rest of the identity is text")

    let indexed = AorusAIMath.render("a_{fig}")
    expect(indexed.drawables.count, 1, "and so is a subscript with no characters for it")

    // Limits belong above and below, which only a drawing can do.
    let sum = AorusAIMath.render(#"\sum_{i=1}^{n} i"#)
    expect(sum.drawables.count, 1, "a sum with limits is drawn")
    expect(sum.text, "\u{FFFC} i", "with what follows it kept as text")
    expect(AorusAIMath.plainText(sum.drawables), "∑ᵢ₌₁ⁿ", "its fallback is the flattened form")

    let limit = AorusAIMath.render(#"\lim_{x \to 0} f(x)"#)
    expect(limit.drawables.count, 1, "a limit is drawn")

    let integral = AorusAIMath.render(#"\int_0^1 x^2 dx"#)
    expect(integral.drawables.count, 0, "an integral's limits are characters, so it is set")
    expect(integral.text, "∫₀¹ x² dx", "exactly as before")

    let bareSum = AorusAIMath.render(#"\sum a_i"#)
    expect(bareSum.drawables.count, 0, "a sum with no limits is just a symbol")
    expect(bareSum.text, "∑ aᵢ", "and is set")

    // Brackets grow to what they hold — but only when there is something to grow to.
    let tall = AorusAIMath.render(#"\left(\frac{a}{b}\right)^2"#)
    expect(tall.drawables.count, 1, "brackets round a fraction are drawn with it")

    let flat = AorusAIMath.render(#"\left(a+b\right)"#)
    expect(flat.drawables.count, 0, "brackets round plain text are plain text")
    expect(flat.text, "(a+b)", "written as they were")

    // A system needs its brace.
    let system = AorusAIMath.render(#"\begin{cases} x, & x > 0 \\ -x, & x < 0 \end{cases}"#)
    expect(system.drawables.count, 1, "a system is drawn")
    expect(system.text, "\u{FFFC}", "as one thing")
    if case let .stack(open, rows)? = system.drawables.first {
        expect(open, "{", "with the brace a system has")
        expect(rows.count, 2, "and both its rows")
    } else {
        failures.append("a system parses as a stack")
    }

    let matrix = AorusAIMath.render(#"\begin{pmatrix} 1 & 0 \\ 0 & 1 \end{pmatrix}"#)
    expect(matrix.drawables.count, 1, "and so is a matrix")
    if case let .stack(open, rows)? = matrix.drawables.first {
        expect(open, "(", "with the bracket its environment names")
        expect(rows.count, 2, "and both its rows")
    } else {
        failures.append("a matrix parses as a stack")
    }
}

private func survivesWhatAModelActuallySends() {
    // The whole answer from the first screenshot, start to finish.
    let answer = """
    Решим дробное уравнение:

    $$\\frac{x(x-2)^2}{x(x-6)} = 0$$

    Сократим x в числителе и знаменателе (при x \\ne 0):

    $$= \\frac{(x-2)^2}{x-6}, \\quad x \\ne 0$$

    - Числитель: (x-2)^2 = 0 \\Rightarrow x = 2
    - Знаменатель: x - 6 \\ne 0 \\Rightarrow x \\ne 6

    $$x = 2 \\Rightarrow x - 6 = -4 \\ne 0 \\quad ✓$$

    Ответ: $\\boxed{x = 2}$
    """
    let rendered = AorusAIMath.render(answer)
    expect(!rendered.text.contains("\\"), "no backslash survives into what the reader sees")
    expect(!rendered.text.contains("\u{2044}"), "and no fraction slash either")
    expect(rendered.text.contains("x ≠ 0"), "the condition reads as a condition")
    expect(rendered.text.contains("Ответ: x = 2"), "the answer reads as the answer")
    expect(rendered.drawables.count, 2, "both fractions in it are drawn")

    // And the whole answer from the second screenshot, which used no display delimiters at all.
    let undelimited = """
    Упростим дробь:

    \\frac{[x(x-6)]^2}{x(x-2)}

    Шаг 1: Раскроем числитель.

    [x(x-6)]^2 = x^2(x-6)^2

    Теперь дробь:

    \\frac{x^2(x-6)^2}{x(x-2)}

    Шаг 2: Упростим дробь, сократив x^2 и x:

    \\frac{x^2}{x} = x

    Получаем:

    x \\cdot \\frac{(x-6)^2}{x-2}
    """
    let second = AorusAIMath.render(undelimited)
    expect(second.drawables.count, 4, "every one of the four fractions is drawn")
    expect(second.text.contains("x²(x-6)²"), "and a line that is not a fraction is still set")
    expect(second.text.contains("x · \u{FFFC}"), "a fraction after an operator keeps the operator")
}

@main
private enum AorusAIMathTests {
    static func main() {
        setsEveryCommandTheAnswerUsed()
        setsFractionsSoTheyReadAsValues()
        setsScriptsWithoutSwallowingWhatFollows()
        leavesProseAlone()
        setsEnvironments()
        liftsEveryFractionWhereverItStands()
        drawsEveryConstructThatOnlyADrawingCanShow()
        survivesWhatAModelActuallySends()
        guard failures.isEmpty else {
            for failure in failures {
                fputs("AorusAIMath test failed: \(failure)\n", stderr)
            }
            exit(1)
        }
        print("AorusAIMath tests: OK")
    }
}
