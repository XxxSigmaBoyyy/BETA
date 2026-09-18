#!/usr/bin/env python3
"""Calls to our own methods must use argument labels those methods actually have.

Why this exists
---------------
The preflight can only PARSE the AorusGramUI sources — type-checking one needs the whole
module graph behind it, which is the hour-long Bazel build. A file that is syntactically
perfect and semantically broken goes straight through, and the build is what notices.

Changing a method's signature and missing one caller is the commonest way to land in that
hole. It happened here: `deletedMessages(peerId:)` became `deletedMessages(accountKey:peerId:)`
and a caller three functions further down the same file still said `deletedMessages(for:)`.
Nothing short of a type-checker sees that — except this, which only has to compare labels.

What it checks, and what it deliberately does not
-------------------------------------------------
Only calls whose target is unambiguous:

  * an unqualified `name(...)` inside a type that declares `name`, or in a file that declares
    it at top level;
  * `TypeName.shared.name(...)` and `TypeName.name(...)`, where `TypeName` is one of ours.

A call is reported only when the name IS declared on that target and NO overload of it accepts
the labels written. A name we never declare is somebody else's and is not our business; a
label set that matches any overload is fine. Parameters with defaults may be omitted, so every
subset that keeps the required ones is accepted.

Run it by hand, or let the preflight run it:

    python3 scripts/swift_call_label_check.py [root]
"""
import itertools
import pathlib
import re
import sys

from uikit_required_init_check import strip

OPEN = "([{<"
CLOSE = ")]}>"
KEYWORDS = {
    "if", "while", "for", "switch", "guard", "return", "catch", "throw", "defer", "repeat",
    "init", "super", "self", "Self", "in", "where", "case", "else", "do", "try", "await",
    "func", "var", "let", "as", "is", "not", "and", "or",
}

# Members every type gets from the language or the frameworks, which our sources never
# declare and which are not ours to check.
KNOWN_FOREIGN = {
    "init", "shared", "self", "type", "some", "none", "allCases", "default", "standard",
    "main", "current", "zero", "max", "min", "first", "last", "count", "append", "insert",
    "remove", "removeAll", "contains", "map", "flatMap", "compactMap", "filter", "reduce",
    "sorted", "joined", "split", "hasPrefix", "hasSuffix", "prefix", "suffix", "dropFirst",
    "dropLast", "trimmingCharacters", "replacingOccurrences", "components", "description",
}

TYPE_DECL = re.compile(r"\b(?:class|struct|enum|extension|actor|protocol)\s+([A-Za-z_]\w*)")
# `class Cell: UITableViewCell, UITextViewDelegate {` — the first name after the colon is the
# superclass when it is one of ours, and an inherited method is not a mistake.
TYPE_PARENTS = re.compile(r"\b(?:class|extension)\s+([A-Za-z_]\w*)\s*:\s*([^{]+)\{")
FUNC_DECL = re.compile(r"\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>(]*>)?\s*\(")
CALL = re.compile(r"(?<![\w.$])([A-Za-z_]\w*)\s*\(")
QUALIFIED = re.compile(r"\b([A-Z]\w*)\.(?:shared\.)?([A-Za-z_]\w*)\s*\(")
LABELLED = re.compile(r"^\s*([A-Za-z_]\w*)\s*:(?!:)")
TWO_NAMES = re.compile(r"^\s*(?:@\w+\s+)*(_|[A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*:")
ONE_NAME = re.compile(r"^\s*(?:@\w+\s+)*([A-Za-z_]\w*)\s*:")
# `let finish = { ... }` gives the name of a closure, not of the method it happens to share a
# name with, and `case object(...)` declares an enum case rather than calling anything.
BINDING = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*[:=]")
# `{ body in` and `{ (body, next) in` — a closure's own parameters. Calling one of those is
# calling a closure, not a method, and the name it happens to share with somebody's method is
# a coincidence.
CLOSURE_PARAMS = re.compile(r"\{\s*\(?\s*([A-Za-z_][\w,\s]*?)\s*\)?\s+in\b")
PRECEDING_WORD = re.compile(r"([A-Za-z_]\w*)\s*$")


def match_paren(code, start):
    """Index of the `)` closing the `(` at `start`, or -1."""
    depth = 0
    index = start
    while index < len(code):
        char = code[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return -1


def split_arguments(text):
    """Top-level comma-separated pieces of an argument or parameter list."""
    pieces = []
    depth = 0
    current = []
    for char in text:
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        if char == "," and depth == 0:
            pieces.append("".join(current))
            current = []
            continue
        current.append(char)
    tail = "".join(current)
    if tail.strip():
        pieces.append(tail)
    return pieces


def parameter_labels(text):
    """(labels, required) for a parameter list — `_` for an unlabelled parameter."""
    labels = []
    required = []
    for piece in split_arguments(text):
        if not piece.strip():
            continue
        two = TWO_NAMES.match(piece)
        if two:
            labels.append(two.group(1))
        else:
            one = ONE_NAME.match(piece)
            if not one:
                return None, None
            labels.append(one.group(1))
        # A parameter with a default may be left out at the call site. `==` inside a default
        # expression is not an assignment, and neither is `=>`; nothing here writes either.
        required.append("=" not in piece.split(":", 1)[-1].split("//")[0])
    return tuple(labels), tuple(required)


def accepted_label_sets(labels, required):
    """Every label tuple a call may legally write, given which parameters are required."""
    optional = [index for index, needed in enumerate(required) if not needed]
    if len(optional) > 8:
        return None  # too many combinations to enumerate; not worth guessing
    accepted = set()
    for drop_count in range(len(optional) + 1):
        for dropped in itertools.combinations(optional, drop_count):
            keep = set(range(len(labels))) - set(dropped)
            accepted.add(tuple(labels[index] for index in sorted(keep)))
    return accepted


def call_labels(text):
    """The labels a call writes, with `_` for an unlabelled argument."""
    labels = []
    for piece in split_arguments(text):
        labelled = LABELLED.match(piece)
        labels.append(labelled.group(1) if labelled else "_")
    return tuple(labels)


def matches(labels, accepted, trailing_closure):
    """Whether a call writing `labels` fits any of `accepted`.

    A trailing closure is written outside the parentheses, so the labels inside them are a
    prefix of the declaration's: `load(accountId: x) { ... }` calls `load(accountId:completion:)`.
    Swift also allows several trailing closures, hence more than one missing label.
    """
    if labels in accepted:
        return True
    if not trailing_closure:
        return False
    return any(option[:len(labels)] == labels and len(option) > len(labels) for option in accepted)


def enclosing_types(code):
    """(start, end, name) for every type body, so a declaration can be attributed to one."""
    spans = []
    for match in TYPE_DECL.finditer(code):
        brace = code.find("{", match.end())
        if brace < 0:
            continue
        depth = 0
        for index in range(brace, len(code)):
            if code[index] == "{":
                depth += 1
            elif code[index] == "}":
                depth -= 1
                if depth == 0:
                    spans.append((brace, index, match.group(1)))
                    break
    return spans


def ancestors(name, parents, seen=None):
    """Every one of our own types `name` inherits from, however deep."""
    seen = seen if seen is not None else set()
    for parent in parents.get(name, ()):  # noqa: B007
        if parent in seen:
            continue
        seen.add(parent)
        ancestors(parent, parents, seen)
    return seen


def collect(paths):
    """Declarations, grouped by owning type and (for free functions) by file."""
    by_type = {}
    free = {}
    sources = {}
    layout = {}
    # `Owner.Nested(...)` is a type being made, not a method being called. Without this every
    # `AorusBackupArchive.Limits(...)` reads as a missing member.
    nested = {}
    parents = {}
    for path in paths:
        # A literal collapses to `S`, not to nothing: `t("a", "b")` has to keep two
        # arguments, or every call that passes only literals looks like `t()`.
        code = strip(path.read_text(encoding="utf-8"), string_token="S")
        sources[path] = code
        spans = enclosing_types(code)
        layout[path] = spans
        for match in TYPE_DECL.finditer(code):
            owner = innermost(spans, match.start())
            if owner is not None and match.group(1) != owner:
                nested.setdefault(owner, set()).add(match.group(1))
        for match in TYPE_PARENTS.finditer(code):
            inherited = [piece.strip().split("<")[0].strip()
                         for piece in match.group(2).split(",")]
            parents.setdefault(match.group(1), set()).update(name for name in inherited if name)
        for match in FUNC_DECL.finditer(code):
            close = match_paren(code, match.end() - 1)
            if close < 0:
                continue
            labels, required = parameter_labels(code[match.end():close])
            if labels is None:
                continue
            accepted = accepted_label_sets(labels, required)
            if accepted is None:
                continue
            owner = None
            for start, end, name in spans:
                if start < match.start() < end:
                    # Innermost wins: a nested type's method is not the outer type's.
                    if owner is None or start > owner[0]:
                        owner = (start, name)
            if owner:
                by_type.setdefault(owner[1], {}).setdefault(match.group(1), set()).update(accepted)
            else:
                free.setdefault(path, {}).setdefault(match.group(1), set()).update(accepted)
    return sources, layout, by_type, free, nested, parents


def line_of(code, index):
    return code.count("\n", 0, index) + 1


def innermost(spans, position):
    """The name of the tightest type body containing `position`, or None."""
    best = None
    for start, end, name in spans:
        if start < position < end and (best is None or start > best[0]):
            best = (start, name)
    return best[1] if best else None


def locals_in(code):
    """Names that are something other than a method in this file: bindings, parameters, the
    arguments of a closure. A call to one of them is not a call to anybody's method."""
    names = {binding.group(1) for binding in BINDING.finditer(code)}
    for match in CLOSURE_PARAMS.finditer(code):
        for piece in match.group(1).split(","):
            piece = piece.strip()
            if piece and piece.isidentifier():
                names.add(piece)
    for match in FUNC_DECL.finditer(code):
        close = match_paren(code, match.end() - 1)
        if close < 0:
            continue
        for piece in split_arguments(code[match.end():close]):
            two = TWO_NAMES.match(piece)
            if two:
                names.add(two.group(1))
                names.add(two.group(2))
                continue
            one = ONE_NAME.match(piece)
            if one:
                names.add(one.group(1))
    return names


def check(sources, layout, by_type, free, nested, parents):
    failures = []
    for path, code in sources.items():
        spans = layout.get(path, [])
        bound = locals_in(code)
        for match in CALL.finditer(code):
            name = match.group(1)
            if name in KEYWORDS:
                continue
            # Scope matters: a bare `name(` means this type's method, or a free function in
            # this file. A same-named method on ANOTHER type in the same file is a different
            # method, and `present(_:animated:)` inherited from UIKit is not ours at all.
            preceding = PRECEDING_WORD.search(code, max(0, match.start() - 32), match.start())
            if preceding and preceding.group(1) in ("case", "func", "indirect"):
                continue
            if name in bound:
                continue
            owner = innermost(spans, match.start())
            declared_here = by_type.get(owner, {}) if owner else {}
            if name not in declared_here:
                declared_here = free.get(path, {})
            if name not in declared_here:
                # Not this type's, and not this file's. If exactly ONE of our own types
                # declares it, and this type does not inherit from that one, the call cannot
                # resolve: it is a method of something else, reached from a place that has no
                # way to reach it. That is what a delegate method written into the wrong type
                # looks like, and nothing short of the hour-long build sees it otherwise.
                if owner is None or name in KNOWN_FOREIGN:
                    continue
                holders = [holder for holder, table in by_type.items() if name in table]
                if len(holders) != 1 or holders[0] == owner:
                    continue
                if holders[0] in ancestors(owner, parents):
                    continue
                before = code[:match.start()].rstrip()
                if before.endswith(".") or before.endswith("func"):
                    continue
                failures.append(
                    f"{path}:{line_of(code, match.start())}: {name}(...) is called inside "
                    f"{owner}, which has no such method — only {holders[0]} declares it"
                )
                continue
            # `Type.name(` and `x.name(` are handled by the qualified pass, which knows what
            # the receiver is. Here only a bare `name(` is attributed to this file.
            before = code[:match.start()].rstrip()
            if before.endswith(".") or before.endswith("func"):
                continue
            close = match_paren(code, match.end() - 1)
            if close < 0:
                continue
            labels = call_labels(code[match.end():close])
            trailing = code[close + 1:close + 65].lstrip().startswith("{")
            if not matches(labels, declared_here[name], trailing):
                failures.append(
                    f"{path}:{line_of(code, match.start())}: {name}({', '.join(labels)}) "
                    f"does not match any declaration in scope "
                    f"({'; '.join(sorted(name + '(' + ', '.join(option) + ')' for option in declared_here[name]))})"
                )
        for match in QUALIFIED.finditer(code):
            owner, name = match.group(1), match.group(2)
            methods = by_type.get(owner)
            if methods is None:
                continue
            if name not in methods:
                # A member of OUR type that our sources do not declare anywhere. This is the
                # shape a careless span replacement leaves behind: the declaration goes and
                # the call stays, and nothing short of the hour-long build notices.
                #
                # Only for a type we own, and only when the member is declared nowhere at all
                # — inherited and framework members are somebody else's to check.
                if name in KNOWN_FOREIGN or name in nested.get(owner, set()):
                    continue
                if any(name in table for table in by_type.values()):
                    continue
                failures.append(
                    f"{path}:{line_of(code, match.start())}: {owner}.{name} is called, and "
                    f"{owner} has no such member anywhere in these sources"
                )
                continue
            close = match_paren(code, match.end() - 1)
            if close < 0:
                continue
            labels = call_labels(code[match.end():close])
            trailing = code[close + 1:close + 65].lstrip().startswith("{")
            if not matches(labels, methods[name], trailing):
                failures.append(
                    f"{path}:{line_of(code, match.start())}: {owner}.{name}({', '.join(labels)}) "
                    f"does not match any declaration of {owner}.{name} "
                    f"({'; '.join(sorted(name + '(' + ', '.join(option) + ')' for option in methods[name]))})"
                )
    return failures


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    paths = []
    for directory in ("patches/submodules", "AorusGram/Sources"):
        base = root / directory
        if base.is_dir():
            paths.extend(sorted(base.rglob("*.swift")))
    sources, layout, by_type, free, nested, parents = collect(paths)
    failures = check(sources, layout, by_type, free, nested, parents)
    if failures:
        print("Swift call label check: FAILED")
        for failure in failures:
            print("  " + str(failure))
        return 1
    print(f"Swift call label check: OK ({len(paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
