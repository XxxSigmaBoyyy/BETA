#!/usr/bin/env python3
"""Checks that the patched AorusGramUI sources import the modules they name.

The release preflight can only `swiftc -frontend -parse` the AorusGramUI files: they
reference Display, ContextUI and the rest of Telegram, so there is nothing to typecheck
against until Bazel runs. `-parse` resolves no names at all, so a type used without its
module imported compiles locally and fails fifty minutes into CI. That has happened
twice, and it is a purely mechanical mistake, so it is caught mechanically here.

The rule: a name that only the AorusGram core module declares may only appear in an
AorusGramUI file that imports AorusGram. Names the UI module declares itself are ignored,
so moving a type between the two never turns into a false alarm.
"""

import re
import sys
from pathlib import Path

CORE_SOURCES = Path("AorusGram/Sources")
UI_SOURCES = Path("patches/submodules/AorusGramUI/Sources")

# `public struct Foo`, `public final class Foo`, `public enum Foo`, `public func foo(`,
# `public typealias Foo`. Anchored at column 0 on purpose: a public member of a public
# type is also written `public let messages`, and a member name is not something another
# module ever spells on its own. `extension` is excluded for the same reason — it names a
# type that is declared elsewhere.
PUBLIC_DECL = re.compile(
    r"^public\s+(?:final\s+|indirect\s+)?"
    r"(?:struct|class|enum|protocol|typealias|func)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)
ANY_DECL = re.compile(
    r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+)?"
    r"(?:final\s+|indirect\s+)?"
    r"(?:struct|class|enum|protocol|typealias|func|let|var)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)
# A name that appears only in prose is not a use of the type.
COMMENT = re.compile(r"//[^\n]*|/\*.*?\*/", re.DOTALL)


def declared_names(root: Path, pattern: re.Pattern) -> set:
    names = set()
    if not root.is_dir():
        return names
    for source in sorted(root.rglob("*.swift")):
        names.update(pattern.findall(source.read_text(encoding="utf-8")))
    return names


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    core = root / CORE_SOURCES
    ui = root / UI_SOURCES
    if not core.is_dir() or not ui.is_dir():
        print(f"AorusAI scope check: missing {CORE_SOURCES} or {UI_SOURCES}", file=sys.stderr)
        return 1

    exported = declared_names(core, PUBLIC_DECL)
    # A name the UI module also declares resolves locally, whatever the imports are.
    exported -= declared_names(ui, ANY_DECL)
    if not exported:
        print("AorusAI scope check: no exported AorusGram names found", file=sys.stderr)
        return 1

    errors = []
    for source in sorted(ui.rglob("*.swift")):
        text = source.read_text(encoding="utf-8")
        if re.search(r"^\s*import\s+AorusGram\s*$", text, re.MULTILINE):
            continue
        code = COMMENT.sub(" ", text)
        used = sorted(name for name in exported if re.search(rf"\b{re.escape(name)}\b", code))
        if used:
            relative = source.relative_to(root)
            errors.append(f"{relative} uses {', '.join(used)} without `import AorusGram`")

    for error in errors:
        print(f"AorusAI scope check: {error}", file=sys.stderr)
    if errors:
        return 1
    print("AorusAI scope check: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
