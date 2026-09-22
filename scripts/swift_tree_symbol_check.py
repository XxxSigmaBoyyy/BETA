#!/usr/bin/env python3
"""Names our Swift uses from Telegram's tree, checked against the tree.

Our code compiles inside Telegram's modules, which are not on this machine and cannot be
compiled here. Three builds have been lost to a name that does not exist — a type renamed
upstream, a property that belongs to a different type, a module that was never imported —
each found by Bazel forty minutes in.

This does the part of that the tree can answer on its own: collect every type Telegram
declares, then read our own Swift and the code the branding patches inject, and report a
Telegram-shaped name that nothing in the tree declares. It does not check signatures, so a
call with the wrong arguments still reaches Bazel; it checks that the name exists at all,
which is the failure that keeps happening.

Only Telegram-shaped names are checked. A prefix list rather than an allowlist of the SDK,
because the SDK has thousands of names and guessing at that list is how a check starts
reporting things that are fine.

Usage: swift_tree_symbol_check.py <patched telegram-ios root> <repo root>
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# Prefixes that only Telegram's own modules and ours declare. `UI`, `NS` and `CG` are left
# out on purpose: those are the SDK's, and the SDK is not on this machine.
TELEGRAM_SHAPED = re.compile(
    r"^(Telegram|Presentation|Chat|Peer|Engine|Star|Message|Account|Navigation|Undo|Context|"
    r"Media|Profile|Attachment|Enqueue|Rendered|Cached|Postbox|Signal|Atomic|Aorus)"
    r"[A-Za-z0-9_]*$"
)

DECLARATION = re.compile(
    r"^\s*(?:@\w+\s+)*(?:public\s+|private\s+|fileprivate\s+|internal\s+|open\s+|final\s+|indirect\s+)*"
    r"(?:class|struct|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)",
    re.M,
)
TOP_LEVEL_VALUE = re.compile(
    r"^(?:public\s+|internal\s+|open\s+)?(?:func|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)",
    re.M,
)
# Not preceded by a dot: `strings.PeerInfo_DeleteGroupTitle` is a member of something, not a
# type, and a member is not a name this check can answer for. Members that do not exist still
# reach Bazel; the type they hang off is what is checked here.
REFERENCE = re.compile(r"(?<![.\w])([A-Z][A-Za-z0-9_]*)\b")

# Names that match the prefixes but belong to the SDK.
SDK_NAMES = {
    "NavigationView", "NavigationLink", "NavigationStack", "NavigationSplitView",
    "NavigationBarItem", "NavigationPath", "NavigationTitleDisplayMode",
    "MediaType", "ContextMenu", "MessageUI", "AttachmentMarker",
}

SKIP_DIRECTORIES = {".git", "build-system", "Tests", "Fixtures", ".build", "third-party"}


IMPORT = re.compile(r"^\s*(?:@\w+\s+)?import\s+.*$", re.M)


def strip_comments_and_strings(text: str) -> str:
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


def sources(root: Path):
    for path in root.rglob("*.swift"):
        if any(part in SKIP_DIRECTORIES for part in path.parts):
            continue
        yield path


def declared(root: Path) -> set[str]:
    names: set[str] = set()
    for path in sources(root):
        text = path.read_text(encoding="utf-8", errors="replace")
        names.update(DECLARATION.findall(text))
        names.update(TOP_LEVEL_VALUE.findall(text))
        # An extension of a type declares nothing new, but `extension Foo` proves Foo exists
        # somewhere the compiler can see, which is all this check asks.
        names.update(re.findall(r"^\s*extension\s+([A-Za-z_][A-Za-z0-9_]*)", text, re.M))
    return names


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: swift_tree_symbol_check.py <telegram-ios root> <repo root>", file=sys.stderr)
        return 2
    tree = Path(sys.argv[1])
    repo = Path(sys.argv[2])
    if not tree.is_dir():
        print(f"{tree} is not a directory", file=sys.stderr)
        return 2

    known = declared(tree)
    # The tree at this point already holds everything we inject, so our own types are in
    # `known` too. Reading the repository as well covers a file that has not been copied in
    # yet, which is a mistake worth catching rather than a reason to stay quiet.
    known |= declared(repo / "AorusGram" / "Sources")
    known |= declared(repo / "patches")
    known |= SDK_NAMES
    # Module names read like type names when they qualify one, and Bazel decides whether a
    # module is visible, not this.
    known |= {path.name for path in (repo / "patches" / "submodules").iterdir() if path.is_dir()}
    known |= {path.name for path in (tree / "submodules").iterdir() if path.is_dir()}

    ours = sorted(sources(repo / "patches")) + sorted(sources(repo / "AorusGram" / "Sources"))
    errors: list[str] = []
    for path in ours:
        # An `import` names a module, not a type, and modules are Bazel's business.
        text = IMPORT.sub("", strip_comments_and_strings(path.read_text(encoding="utf-8", errors="replace")))
        for name in sorted(set(REFERENCE.findall(text))):
            if not TELEGRAM_SHAPED.match(name) or name in known:
                continue
            errors.append(f"{path.relative_to(repo)}: names {name}, which nothing declares")

    if errors:
        print("Swift tree symbol check FAILED:")
        for error in errors:
            print(f"  {error}")
        return 1
    print(f"Swift tree symbol check: OK ({len(known)} names indexed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
