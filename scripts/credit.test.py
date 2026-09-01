#!/usr/bin/env python3
"""Unit tests for credit-contributors' amend_changelog.py.

The action had no tests at all, and its failure modes are quiet: a credit that
silently does not land reads exactly like "no external contributors this
release". skylight-mcp#135 (a `closes #136` line turning a 404 body into the
contributor name) is the kind of thing that reached a published changelog.

Covers the `--all-blocks` split too: CHANGELOG.md must only ever touch its
unreleased top block, because everything below it is published history, while a
release PR's BODY is entirely this release and has to be amended throughout.

Usage: python3 scripts/credit.test.py
"""
import importlib.util
import pathlib
import sys

ACTION = pathlib.Path(__file__).resolve().parent.parent / ".github/actions/credit-contributors/amend_changelog.py"
spec = importlib.util.spec_from_file_location("amend_changelog", ACTION)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

PASS = FAIL = 0


def check(name, got, want):
    global PASS, FAIL
    if got == want:
        PASS += 1
        print(f"ok   {name}")
    else:
        FAIL += 1
        print(f"FAIL {name}\n     got:  {got!r}\n     want: {want!r}")


ENTRY = "* **chores:** inline category_id ([#148](https://github.com/o/r/issues/148)) ([abc](https://github.com/o/r/commit/abc))"
ONE = f"# Changelog\n\n## [0.10.0](x) (2026-09-01)\n\n### Bug Fixes\n\n{ENTRY}\n"

print("── inserting the credit ──")
out, changed = mod.amend(ONE, "148", "Weetermachine")
check("reports that it changed", changed, True)
check(
    "credit lands before the link group",
    "* **chores:** inline category_id (thanks @Weetermachine) ([#148]" in out,
    True,
)
check("original link group survives", "([#148](https://github.com/o/r/issues/148))" in out, True)

print("\n── idempotence ──")
twice, changed2 = mod.amend(out, "148", "Weetermachine")
check("a credited line is left alone", changed2, False)
check("and its text is untouched", twice, out)

print("\n── a line with no link group ──")
bare = "# Changelog\n\n## [0.1.0](x) (2026-01-01)\n\n* fix a thing /pull/7\n"
out3, changed3 = mod.amend(bare, "7", "someone")
check("appends at end of line", changed3 and out3.rstrip().endswith("(thanks @someone)"), True)

print("\n── no match ──")
_, changed4 = mod.amend(ONE, "999", "nobody")
check("an unreferenced PR changes nothing", changed4, False)

print("\n── published history must not churn (CHANGELOG default) ──")
TWO = ONE + f"\n## [0.9.0](x) (2026-08-01)\n\n### Bug Fixes\n\n{ENTRY.replace('148', '99')}\n"
out5, changed5 = mod.amend(TWO, "99", "Weetermachine")
check("a match in a LATER block is ignored", changed5, False)
check("and the text is unchanged", out5, TWO)

print("\n── a release PR body is all one release (--all-blocks) ──")
out6, changed6 = mod.amend(TWO, "99", "Weetermachine", all_blocks=True)
check("a match in a later block IS credited", changed6, True)
check("credit lands there too", "(thanks @Weetermachine) ([#99]" in out6, True)
check("the first block is untouched by it", out6.split("## [0.9.0]")[0], TWO.split("## [0.9.0]")[0])

print()
print(f"{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
