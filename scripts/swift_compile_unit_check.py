#!/usr/bin/env python3
"""Every `swiftc` invocation in the workflow must list the files its sources need.

Run 489 died here. `AorusAIClient.swift` was added to a type-check that listed the AI models
it decodes into — and nothing else. The file also signs every request, so it names the key
provider, the fingerprint, the pinned session delegate and the environment guard, none of
which were on the list. Twenty-three `cannot find X in scope` errors, two minutes in, on a
step whose whole purpose is to find errors early.

There is no Swift compiler on this machine, so the only way to catch that before CI is to do
the bookkeeping the compiler would have done: for every `swiftc` command in the workflow,
take the files it lists, find the AorusGram types they mention, and check each one is
declared in a file the same command lists.

Only our own types are checked. Anything from the SDK or from Telegram's modules is out of
scope: those come from `-sdk` and from Bazel, and guessing at that list is how a check starts
reporting things that are fine. Our types are the ones that have to be passed in by hand, and
they are exactly the ones that were missing.

Usage: swift_compile_unit_check.py <repo root>
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

WORKFLOW = ".github/workflows/build-aorusgram.yml"

# What counts as ours. These are the prefixes that only ever come from this repository, so a
# name that matches one and is not declared in the command's own file list is a name the
# compiler will not find either.
OURS = re.compile(
    r"^(Aorus|License|Subscription|DeviceFingerprint|ClientOutdated|ClientSpoof|BadgeSnapshot)"
    r"[A-Za-z0-9_]*$"
)

DECLARATION = re.compile(
    r"^\s*(?:@\w+\s+)*(?:public\s+|private\s+|fileprivate\s+|internal\s+|open\s+|final\s+|indirect\s+)*"
    r"(?:class|struct|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)",
    re.M,
)

# A global function or value is referenced the same way a type is, and is just as capable of
# being missing from a compile unit.
TOP_LEVEL_VALUE = re.compile(
    r"^(?:public\s+|internal\s+)?(?:func|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)",
    re.M,
)

REFERENCE = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\b")


def strip_comments_and_strings(text: str) -> str:
    """Comments name types in prose all the time; strings name them in error messages."""
    out: list[str] = []
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        if char == "/" and index + 1 < length and text[index + 1] == "/":
            end = text.find("\n", index)
            index = length if end == -1 else end
            continue
        if char == "/" and index + 1 < length and text[index + 1] == "*":
            end = text.find("*/", index + 2)
            index = length if end == -1 else end + 2
            continue
        if char == '"':
            if text.startswith('"""', index):
                end = text.find('"""', index + 3)
                index = length if end == -1 else end + 3
                continue
            index += 1
            while index < length and text[index] != '"':
                if text[index] == "\\":
                    index += 1
                index += 1
            index += 1
            continue
        out.append(char)
        index += 1
    return "".join(out)


def declarations(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    names = set(DECLARATION.findall(text))
    names.update(TOP_LEVEL_VALUE.findall(text))
    # A `case foo` inside an enum is not a declaration anyone references by bare name, and
    # an extension adds nothing new, so neither is collected.
    return {name for name in names if OURS.match(name)}


def references(path: Path) -> set[str]:
    text = strip_comments_and_strings(path.read_text(encoding="utf-8", errors="replace"))
    return {name for name in REFERENCE.findall(text) if OURS.match(name)}


def commands(workflow: str) -> list[tuple[int, list[str]]]:
    """Every `swiftc` invocation and the repository files it lists, with its line number."""
    lines = workflow.split("\n")
    result: list[tuple[int, list[str]]] = []
    index = 0
    while index < len(lines):
        if "swiftc" not in lines[index]:
            index += 1
            continue
        start = index
        parts: list[str] = []
        while index < len(lines):
            stripped = lines[index].strip()
            parts.append(stripped)
            if not stripped.endswith("\\"):
                break
            index += 1
        joined = " ".join(part.rstrip("\\").strip() for part in parts)
        # Only the commands that resolve names. `-frontend -parse` reads the grammar and
        # nothing else, which is the whole reason files are parsed one at a time there — a
        # file that names something from another module parses perfectly and must.
        if "-frontend -parse" in joined:
            index += 1
            continue
        files = re.findall(r"aorusgram/(\S+\.swift)", joined)
        if files:
            result.append((start + 1, files))
        index += 1
    return result


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    workflow = (root / WORKFLOW).read_text(encoding="utf-8")
    errors: list[str] = []
    checked = 0
    for line, files in commands(workflow):
        paths = [root / name for name in files]
        missing_files = [name for name, path in zip(files, paths) if not path.is_file()]
        if missing_files:
            for name in missing_files:
                errors.append(f"{WORKFLOW}:{line}: lists a file that does not exist: {name}")
            continue
        provided: set[str] = set()
        for path in paths:
            provided |= declarations(path)
        for name, path in zip(files, paths):
            for reference in sorted(references(path) - provided):
                errors.append(
                    f"{WORKFLOW}:{line}: {name} names {reference}, which no file in this "
                    f"swiftc command declares"
                )
        checked += 1

    if errors:
        print("Swift compile unit check FAILED:")
        for error in errors:
            print(f"  {error}")
        return 1
    print(f"Swift compile unit check: OK ({checked} swiftc commands)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
