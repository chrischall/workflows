#!/usr/bin/env python3
"""Append `(thanks @user)` to one changelog entry.

Lives in its own file rather than a heredoc inside `action.yml`: a heredoc body
must sit at column 0 to be valid Python, and a line at column 0 terminates the
YAML block scalar it is embedded in — which silently produced an unparseable
action. Being a file also makes it directly testable.

Usage: amend_changelog.py <path> <pr-number> <login> [--all-blocks]

`--all-blocks` amends every `## ` section rather than only the first. Use it
for a release PR's BODY, where every section belongs to the release being
proposed; never for CHANGELOG.md, whose later blocks are published history.

Exits 0 whether or not it changed anything; prints "changed" when it did.
"""
import re
import sys


def amend(text: str, pr: str, author: str, all_blocks: bool = False) -> tuple[str, bool]:
    """Return (new_text, changed).

    By default only the FIRST `## ` block is considered — everything below it
    is already published and must not churn. `all_blocks=True` lifts that for a
    release PR body, which is entirely the release being proposed. A line
    already carrying a credit is left alone, so repeated runs (release-please
    regenerates and force-pushes its branch on every push to main) do not stack
    duplicates.
    """
    lines = text.split("\n")
    seen = 0
    for i, line in enumerate(lines):
        if line.startswith("## "):
            seen += 1
            if seen > 1 and not all_blocks:
                break
        if seen < 1:
            continue
        if not re.search(rf"/(issues|pull)/{re.escape(pr)}\b", line):
            continue
        if "thanks @" in line:
            continue
        # Insert before the trailing link group, so the credit reads as part of
        # the description rather than trailing after the commit hash.
        m = re.search(r"\s*\(\[#", line)
        if m:
            lines[i] = line[: m.start()] + f" (thanks @{author})" + line[m.start() :]
        else:
            lines[i] = line.rstrip() + f" (thanks @{author})"
        return "\n".join(lines), True
    return text, False


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--all-blocks"]
    all_blocks = "--all-blocks" in sys.argv[1:]
    path, pr, author = args[0], args[1], args[2]
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    updated, changed = amend(original, pr, author, all_blocks=all_blocks)
    if changed:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(updated)
        print("changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
