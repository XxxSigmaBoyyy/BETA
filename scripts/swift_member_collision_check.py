#!/usr/bin/env python3
"""Reject a property in an AorusGram class that collides with one its base class declares.

Swift reads a stored property whose name a superclass already uses as an attempt to
override that superclass property. Across a module boundary — and every Telegram base
class we subclass is across one — that is two errors at once:

    error: overriding non-open property outside of its defining module
    error: property 'toolbar' with type 'UIStackView' cannot override a property with
           type 'Toolbar?'

which is what `private let toolbar = UIStackView()` inside a `Display.ViewController`
subclass produced, forty minutes into a Bazel build. Nothing in the preflight could see
it: the file parses, and the collision only exists relative to a class in Telegram's own
sources.

So this reads those sources. Given the patched tree it indexes every class in it —
Telegram's and ours — with its superclass and the properties it declares, then walks the
ancestors of each of our classes and reports a name used twice. It runs after the sources
are injected, which is where the tree first holds both sides, and it costs a second.

Usage: swift_member_collision_check.py <telegram-ios tree>
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# Our own code, wherever it sits in the patched tree.
OURS = ("AorusGram", "AorusGramUI", "AorusBadge", "AorusMaskPicker")

CLASS_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+|final\s+)*"
    r"class\s+(\w+)\s*(?:<[^>]*>)?\s*(?::\s*([^{]+?))?\s*\{"
)
PROPERTY_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?P<modifiers>(?:public|internal|private|fileprivate|open|final|static|class|weak|unowned|lazy|override|nonisolated|dynamic)"
    r"(?:\s*\([^)]*\))?\s+)*"
    r"(?:var|let)\s+(?P<name>\w+)\b"
)


def index_tree(root: Path) -> dict[str, list[dict]]:
    """Every class the app is built from: name -> [{superclasses, properties, file, ours}].

    Only what Bazel actually compiles. `third-party` carries test fixtures with names like
    `ViewController` in them, and letting one of those stand in for `Display.ViewController`
    is how this check silently passes everything.
    """
    classes: dict[str, list[dict]] = {}
    sources: list[Path] = []
    for area in ("submodules", "Telegram"):
        directory = root / area
        if directory.is_dir():
            sources.extend(directory.rglob("*.swift"))
    for path in sorted(sources):
        parts = path.parts
        if any(part in ("Tests", "Fixtures", ".build") for part in parts):
            continue
        ours = any(part in OURS for part in parts)
        text = path.read_text(encoding="utf-8", errors="replace")
        depth = 0
        stack: list[tuple[str, int]] = []  # (class name, brace depth of its body)
        in_block_comment = False
        for line in text.split("\n"):
            code = line
            if in_block_comment:
                end = code.find("*/")
                if end == -1:
                    continue
                code = code[end + 2:]
                in_block_comment = False
            start = code.find("/*")
            if start != -1:
                if "*/" in code[start:]:
                    code = code[:start] + code[code.index("*/", start) + 2:]
                else:
                    code = code[:start]
                    in_block_comment = True
            code = code.split("//")[0]
            # Strings can carry braces; drop their contents before counting.
            code_no_strings = re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)

            match = CLASS_RE.match(code_no_strings)
            if match:
                name = match.group(1)
                inherits = [
                    part.strip().split("<")[0].strip()
                    for part in (match.group(2) or "").split(",")
                    if part.strip()
                ]
                entry = {
                    "supers": inherits,
                    "properties": {},
                    "file": str(path),
                    "ours": ours,
                }
                classes.setdefault(name, []).append(entry)
                stack.append((entry, depth))
            elif stack and depth == stack[-1][1] + 1:
                prop = PROPERTY_RE.match(code_no_strings)
                if prop:
                    modifiers = prop.group("modifiers") or ""
                    stack[-1][0]["properties"][prop.group("name")] = modifiers

            depth += code_no_strings.count("{") - code_no_strings.count("}")
            while stack and depth <= stack[-1][1]:
                stack.pop()
    return classes


def ancestors(entry: dict, classes: dict[str, list[dict]]) -> list[str]:
    """The names of the classes `entry` inherits from, nearest first."""
    chain: list[str] = []
    seen: set[str] = set()
    current = entry
    while current is not None:
        following = None
        for candidate in current["supers"]:
            # The first inherited name that is a class we know is the superclass;
            # everything else on that line is a protocol.
            if candidate in classes and candidate not in seen:
                following = candidate
                break
        if following is None:
            break
        chain.append(following)
        seen.add(following)
        # An ambiguous name stops the walk: which one it is decides what comes next.
        current = classes[following][0] if len(classes[following]) == 1 else None
    return chain


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: swift_member_collision_check.py <telegram-ios tree>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    if not root.is_dir():
        print(f"not a directory: {root}", file=sys.stderr)
        return 2

    classes = index_tree(root)
    errors: list[str] = []
    checked = 0

    def collides(base: dict, prop: str) -> bool:
        if prop not in base["properties"]:
            return False
        modifiers = base["properties"][prop]
        # A private member of another file is invisible here, so it cannot be what the
        # compiler tries to override. `private(set)` is not that: it is a publicly
        # readable property with a private setter, and it does collide — Display's
        # `public private(set) var toolbar` is exactly the one that did.
        visibility = re.sub(r"(private|fileprivate)\s*\(\s*set\s*\)", "", modifiers)
        if "private" in visibility or "fileprivate" in visibility:
            return False
        return "static" not in modifiers and "class " not in modifiers

    for name, entries in sorted(classes.items()):
        for entry in entries:
            if not entry["ours"]:
                continue
            checked += 1
            chain = ancestors(entry, classes)
            for prop, modifiers in sorted(entry["properties"].items()):
                if "override" in modifiers or "static" in modifiers or "class " in modifiers:
                    continue
                for ancestor in chain:
                    bases = classes[ancestor]
                    # With several classes of that name, only report when every one of
                    # them declares the property: whichever it resolves to, it collides.
                    if not all(collides(base, prop) for base in bases):
                        continue
                    errors.append(
                        f"{Path(entry['file']).name}: {name}.{prop} collides with "
                        f"{ancestor}.{prop} ({Path(bases[0]['file']).name}) — Swift reads "
                        f"it as an override of that property"
                    )
                    break

    if errors:
        print("Swift member collision check FAILED:")
        for error in errors:
            print(f"  {error}")
        return 1
    print(f"Swift member collision check: OK ({checked} AorusGram classes, {len(classes)} names indexed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
