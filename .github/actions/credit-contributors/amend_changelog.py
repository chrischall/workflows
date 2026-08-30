#!/usr/bin/env python3
"""Append `(thanks @user)` to one CHANGELOG entry, in the unreleased block only.

Lives in its own file rather than a heredoc inside `action.yml`: a heredoc body
must sit at column 0 to be valid Python, and a line at column 0 terminates the
YAML block scalar it is embedded in — which silently produced an unparseable
action. Being a file also makes it directly testable.

Usage: amend_changelog.py <changelog-path> <pr-number> <login>
Exits 0 whether or not it changed anything; prints "changed" when it did.
"""
import re
import sys


def amend(text: str, pr: str, author: str) -> tuple[str, bool]:
    """Return (new_text, changed).

    Only the FIRST `## ` block is considered — everything below it is already
    published and must not churn. A line already carrying a credit is left
    alone, so repeated runs (release-please regenerates and force-pushes its
    branch on every push to main) do not stack duplicates.
    """
    lines = text.split("\n")
    seen = 0
    for i, line in enumerate(lines):
        if line.startswith("## "):
            seen += 1
            if seen > 1:
                break
        if seen != 1:
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
    path, pr, author = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    updated, changed = amend(original, pr, author)
    if changed:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(updated)
        print("changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
