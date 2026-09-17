#!/usr/bin/env python3
"""Every UIKit subclass that overrides a designated initializer must declare `init(coder:)`.

Why this exists
---------------
The preflight can only PARSE the AorusGramUI sources — type-checking one needs the whole
module graph behind it, which is the hour-long Bazel build. So a file that is syntactically
perfect and semantically broken gets through, and the first thing that notices is the build.

This is the shape that keeps happening, and it has now cost an hour twice:

    override init(frame: CGRect) { ... }        // and no init(coder:)

Swift gives two errors for it, and neither is obvious from reading the diff:

    'required' initializer 'init(coder:)' must be provided by subclass of 'UIView'
    missing argument for parameter 'frame' in call      // at every `Thing()` call site

The second one is the surprising half. A subclass inherits its superclass's convenience
initializers — `UIView()` among them — ONLY once it has overridden every designated
initializer above it. `UIView` has two, `init(frame:)` and `init(coder:)`, so dropping the
`init(coder:)` silently takes `Thing()` away from every call site as well.

It is easy to delete by accident: it is a one-line stub, usually `fatalError()`, and it sits
wherever it was first written rather than next to the initializer it belongs with.

Run it by hand, or let the preflight run it:

    python3 scripts/uikit_required_init_check.py [root]
"""
import pathlib
import re
import sys

# Overriding any of these means the subclass has declared a designated initializer of its own.
# `public override init(...)` and `override public init(...)` are both written in this
# codebase, so anything between the keyword and `init` is skipped over.
MODIFIERS = r"(?:\w+\s+)*"
DESIGNATED = (
    re.compile(r"\boverride\s+" + MODIFIERS + r"init\s*\(\s*frame\s*:"),
    re.compile(r"\boverride\s+" + MODIFIERS + r"init\s*\(\s*style\s*:"),
    re.compile(r"\boverride\s+" + MODIFIERS + r"init\s*\(\s*nibName\s*:"),
)
CODER = re.compile(r"\brequired\s+" + MODIFIERS + r"init\??\s*\(\s*coder\s*:")
# `class Name: Super` — the inheritance clause is what says this is a UIKit subclass, and a
# subclass of a subclass is caught by the same rule applying to the one it inherits from.
CLASS = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::([^{]*))?\{")
UIKIT_ROOTS = ("UIView", "UIControl", "UILabel", "UITextView", "UITextField", "UIButton",
               "UIImageView", "UIScrollView", "UIStackView", "UITableViewCell",
               "UICollectionViewCell", "UICollectionReusableView", "UIViewController",
               "UITableViewController", "UICollectionViewController", "UIVisualEffectView")


def strip(source, string_token=" "):
    """Comments and string literals removed, so a brace inside prose is not counted.

    `string_token` is what a literal collapses to. A single space is right for counting
    braces; a caller that needs to see that an argument was there at all — the call-label
    check does — passes a non-blank token instead.
    """
    out = []
    index = 0
    length = len(source)
    block = 0
    while index < length:
        if block:
            if source.startswith("/*", index):
                block += 1
                index += 2
            elif source.startswith("*/", index):
                block -= 1
                index += 2
            else:
                # Newlines are kept even inside what is removed, so an offset in the result
                # still counts to the same line of the original. Without this every line
                # number reported after a block comment was wrong.
                if source[index] == "\n":
                    out.append("\n")
                index += 1
            continue
        if source.startswith("//", index):
            newline = source.find("\n", index)
            index = length if newline < 0 else newline
            continue
        if source.startswith("/*", index):
            block = 1
            index += 2
            continue
        if source.startswith('"""', index):
            closing = source.find('"""', index + 3)
            end = length if closing < 0 else closing + 3
            out.append(string_token)
            out.append("\n" * source.count("\n", index, end))
            index = end
            continue
        if source[index] == '"':
            index += 1
            while index < length:
                if source[index] == "\\":
                    index += 2
                    continue
                if source[index] == '"':
                    index += 1
                    break
                index += 1
            out.append(string_token)
            continue
        out.append(source[index])
        index += 1
    return "".join(out)


def bodies(code):
    """Every class body in `code`, as (name, inheritance, text), innermost included."""
    for match in CLASS.finditer(code):
        depth = 0
        start = match.end() - 1
        for position in range(start, len(code)):
            if code[position] == "{":
                depth += 1
            elif code[position] == "}":
                depth -= 1
                if depth == 0:
                    yield match.group(1), (match.group(2) or ""), code[start + 1:position]
                    break


def offenders(path):
    code = strip(path.read_text(encoding="utf-8"))
    found = []
    for name, inherits, body in bodies(code):
        if not any(root in inherits for root in UIKIT_ROOTS):
            continue
        # A nested class's own body is scanned in its own turn, so it must not count as part
        # of the class around it.
        outer = body
        for _, _, nested in bodies(body):
            outer = outer.replace(nested, " ")
        if not any(pattern.search(outer) for pattern in DESIGNATED):
            continue
        if CODER.search(outer):
            continue
        found.append(name)
    return found


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    searched = 0
    failures = []
    for directory in ("patches/submodules", "AorusGram/Sources"):
        base = root / directory
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.swift")):
            searched += 1
            for name in offenders(path):
                failures.append(f"{path.relative_to(root)}: class {name} overrides a designated "
                                f"initializer without declaring init(coder:)")
    if failures:
        print("UIKit init check: FAILED")
        for failure in failures:
            print("  " + failure)
        return 1
    print(f"UIKit init check: OK ({searched} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
