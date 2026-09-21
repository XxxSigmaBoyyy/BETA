#!/usr/bin/env python3
"""Reject a second `let`/`var` with a name already bound in the same scope.

Swift calls it `invalid redeclaration of 'x'`, and it costs a CI round. The test files are
where it happens: they are one long `static func main()` with every binding at the same
level, so a name chosen for a new block is very likely to already be taken by one written
months earlier, hundreds of lines up, where nobody looks.

The check is deliberately narrow. It tracks brace depth, treats every `{` as a new scope
and every `}` as leaving one, and reports a binding whose name is already live in the *same*
scope. Shadowing an outer scope is legal Swift and is not reported; a `guard let x = x`
rebinding is legal too and is not reported. What is left is exactly the error the compiler
gives.

Usage: swift_local_shadow_check.py <repo root>
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# `let (a, b) = …` and `case let .x(a, b)` bind several names at once and are not worth
# modelling; a single simple binding is where the mistake actually happens.
BINDING = re.compile(
    r"^\s*(?:private\s+|fileprivate\s+|public\s+|internal\s+|static\s+|final\s+|weak\s+|lazy\s+)*"
    r"(let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]+)?=",
)
# Anything that opens a scope of its own on the same line, where a repeated name is fine.
SCOPED = re.compile(r"\b(?:if|guard|while|for|switch|catch|closure)\b")


def strip_comments_and_strings(line: str, in_block: bool) -> tuple[str, bool]:
    out: list[str] = []
    index = 0
    length = len(line)
    while index < length:
        if in_block:
            end = line.find("*/", index)
            if end == -1:
                return "".join(out), True
            index = end + 2
            in_block = False
            continue
        if line.startswith("//", index):
            break
        if line.startswith("/*", index):
            in_block = True
            index += 2
            continue
        if line[index] == '"':
            if line.startswith('"""', index):
                # A multi-line string opener; the caller handles the rest by depth, and
                # its contents cannot contain a binding this check should see.
                return "".join(out), in_block
            index += 1
            while index < length and line[index] != '"':
                if line[index] == "\\":
                    index += 1
                index += 1
            index += 1
            out.append('""')
            continue
        out.append(line[index])
        index += 1
    return "".join(out), in_block


def check(path: Path) -> list[str]:
    errors: list[str] = []
    scopes: list[dict[str, int]] = [{}]
    in_block = False
    in_multiline_string = False
    for number, raw in enumerate(path.read_text(encoding="utf-8", errors="replace").split("\n"), start=1):
        if in_multiline_string:
            if '"""' in raw:
                in_multiline_string = False
            continue
        if raw.count('"""') == 1:
            in_multiline_string = True
            continue
        line, in_block = strip_comments_and_strings(raw, in_block)
        if not line.strip():
            continue

        match = BINDING.match(line)
        if match and not SCOPED.search(line[: match.start(1)]):
            name = match.group(2)
            if name != "_" and name in scopes[-1]:
                errors.append(
                    f"{path.name}:{number}: '{name}' is already bound at line "
                    f"{scopes[-1][name]} in the same scope"
                )
            else:
                scopes[-1][name] = number

        opened = line.count("{")
        closed = line.count("}")
        for _ in range(opened):
            scopes.append({})
        for _ in range(closed):
            if len(scopes) > 1:
                scopes.pop()
    return errors


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    targets = sorted((root / "scripts" / "tests").glob("*.swift"))
    if not targets:
        print("no test sources to check", file=sys.stderr)
        return 2
    errors: list[str] = []
    for path in targets:
        errors.extend(check(path))
    if errors:
        print("Swift local shadow check FAILED:")
        for error in errors:
            print(f"  {error}")
        return 1
    print(f"Swift local shadow check: OK ({len(targets)} test sources)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
