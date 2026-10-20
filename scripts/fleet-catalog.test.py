#!/usr/bin/env python3
"""Unit tests for scripts/build-fleet-catalog.py.

The catalog is a PUBLIC document, and the gateway that reads it refuses it
WHOLE on one bad row (mcp-host core `public-catalog.ts`). So the two ways this
builder can be wrong are both expensive and both quiet:

  * a private repo reaching a public page — the visibility filter must be
    fail-closed: unreadable, archived or anything-but-"public" is excluded;
  * one row the gateway would refuse — a padded or bidi-carrying string, a
    duplicate pkg or slug, an empty examples array — takes the WHOLE Verified
    list off the page, with nothing in this repo going red.

Plus the non-fatal contract: a repo with no mint.yaml, or one that fails the
mint schema, is REPORTED and left out, never a failed run.

Usage: python3 scripts/fleet-catalog.test.py
(needs jsonschema + PyYAML: scripts/fleet-catalog.requirements.txt)
"""
import importlib.util
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/build-fleet-catalog.py"
spec = importlib.util.spec_from_file_location("build_fleet_catalog", SCRIPT)
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


# A cut-down copy of the mint schema's shape: enough to exercise validation
# (required version const, examples bounds) without coupling the suite to the
# exact generated file in mcp-host.
SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "properties": {
        "version": {"type": "number", "const": 1},
        "name": {"type": "string"},
        "summary": {"type": "string"},
        "examples": {
            "type": "array", "minItems": 1, "maxItems": 5,
            "items": {
                "type": "object",
                "properties": {
                    "prompt": {"type": "string", "minLength": 1, "maxLength": 200},
                    "note": {"type": "string", "minLength": 1, "maxLength": 120},
                },
                "required": ["prompt"],
            },
        },
        "transport": {
            "type": "object",
            "properties": {"bridge": {"type": "boolean"}},
            "required": ["bridge"],
        },
    },
    "required": ["version"],
}


class FakeFetcher:
    """repos: {repo: info-dict | None}; files: {(repo, path): text}.

    The repo's file tree is every path in `files` for that repo, unless
    `trees` overrides it with {repo: (paths, truncated)}. `errors` makes the
    repo's file reads fail; `tree_errors` makes its tree listing fail."""

    def __init__(self, repos, files, errors=(), trees=None, tree_errors=()):
        self.repos, self.files, self.errors = repos, files, set(errors)
        self.trees, self.tree_errors = trees or {}, set(tree_errors)
        self.file_calls = []
        self.file_paths = []
        self.tree_calls = []

    def repo_info(self, repo):
        return self.repos.get(repo)

    def tree(self, repo, ref):
        self.tree_calls.append((repo, ref))
        if repo in self.tree_errors:
            raise mod.FetchError("HTTP 409")
        if repo in self.trees:
            return self.trees[repo]
        return sorted(p for (r, p) in self.files if r == repo), False

    def file(self, repo, path, ref):
        self.file_calls.append(repo)
        self.file_paths.append((repo, path))
        if repo in self.errors:
            raise mod.FetchError("HTTP 502")
        return self.files.get((repo, path))


def pub(branch="main", archived=False):
    return {"visibility": "public", "default_branch": branch, "archived": archived}


def fleet(*entries):
    return {"defaults": {"package_name": ""}, "repos": list(entries)}


KINDS = {"default": "Other", "kinds": {"o/setlist-mcp": "Music", "o/zillow-mcp": "Real estate"}}
NOW = "2026-10-19T05:41:00Z"


def build(fleet_doc, fetcher, kinds=KINDS):
    return mod.build_catalog(fleet_doc, kinds, SCHEMA, fetcher, NOW)


print("── the happy path, field by field ──")
f = FakeFetcher(
    {"o/setlist-mcp": pub()},
    {("o/setlist-mcp", "mint.yaml"): (
        "version: 1\nname: setlist.fm\nslug: setlist\n"
        "summary: >-\n  Concert data for Claude,\n  search setlists\n"
        "examples:\n  - prompt: What did Radiohead open with?\n    note: Public only.\n"
        "  - prompt: Which songs has Wilco played most?\n"
        "transport:\n  bridge: true\n"
    )},
)
cat, rep = build(fleet({"repo": "o/setlist-mcp", "package_name": "setlist-mcp"}), f)
check("generatedAt is the build time", cat["generatedAt"], NOW)
check("one server", len(cat["servers"]), 1)
check("the row, exactly", cat["servers"][0], {
    "name": "setlist.fm",
    "slug": "setlist-mcp",
    "pkg": "setlist-mcp",
    "summary": "Concert data for Claude, search setlists",
    "examples": [
        {"prompt": "What did Radiohead open with?", "note": "Public only."},
        {"prompt": "Which songs has Wilco played most?"},
    ],
    "kind": "Music",
    "bridge": True,
    "repo": "o/setlist-mcp",
})
check("nothing reported", rep.reported, [])
check("the document passes the gateway's rules", mod.validate_catalog(cat), [])

print("\n── visibility is fail-closed ──")
f = FakeFetcher(
    {"o/a-mcp": {"visibility": "private", "default_branch": "main", "archived": False},
     "o/b-mcp": {"visibility": "internal", "default_branch": "main", "archived": False},
     "o/c-mcp": None,  # unreadable with this token
     "o/d-mcp": pub(archived=True),
     "o/e-mcp": {"default_branch": "main", "archived": False}},  # no visibility key
    {(r, "mint.yaml"): "version: 1\n" for r in ("o/a-mcp", "o/b-mcp", "o/c-mcp", "o/d-mcp", "o/e-mcp")},
)
cat, rep = build(fleet(*[{"repo": r, "package_name": r.split("/")[1]}
                         for r in ("o/a-mcp", "o/b-mcp", "o/c-mcp", "o/d-mcp", "o/e-mcp")]), f)
check("no private, internal, unreadable or unlabelled repo is listed", cat["servers"], [])
check("their mint.yaml is never even fetched (except the archived public one)", f.file_calls, [])
check("non-public repos are COUNTED, not named (the summary is public)", rep.non_public, 4)
check("the archived public repo is reported by name", [r["repo"] for r in rep.reported], ["o/d-mcp"])
summary = mod.render_summary(cat, rep)
check("the summary never names a non-public repo",
      any(n in summary for n in ("o/a-mcp", "o/b-mcp", "o/c-mcp", "o/e-mcp")), False)

print("\n── missing / invalid mint.yaml is reported, not fatal ──")
f = FakeFetcher(
    {"o/none-mcp": pub(), "o/bad-mcp": pub(), "o/yaml-mcp": pub(), "o/err-mcp": pub(), "o/list-mcp": pub(),
     "o/zillow-mcp": pub("trunk")},
    {("o/bad-mcp", "mint.yaml"): "version: 2\n",
     ("o/yaml-mcp", "mint.yaml"): "version: 1\nname: [unclosed\n",
     ("o/list-mcp", "mint.yaml"): "- version: 1\n",
     ("o/zillow-mcp", "mint.yaml"): "version: 1\nsummary: Zillow listings\n"},
    errors={"o/err-mcp"},
    trees={"o/err-mcp": (["mint.yaml"], False)},
)
cat, rep = build(fleet(*[{"repo": r, "package_name": r.split("/")[1]} for r in
                         ("o/none-mcp", "o/bad-mcp", "o/yaml-mcp", "o/err-mcp", "o/list-mcp", "o/zillow-mcp")]), f)
check("only the valid repo is listed", [s["repo"] for s in cat["servers"]], ["o/zillow-mcp"])
reasons = {r["repo"]: r["reason"] for r in rep.reported}
check("missing mint.yaml on a repo WITH a package_name is reported (an MCP missing its manifest)",
      reasons.get("o/none-mcp"), "no mint.yaml on the default branch")
check("a schema failure is reported with the path", reasons.get("o/bad-mcp", "").startswith("mint.yaml fails the schema at version"), True)
check("unparseable YAML is reported", reasons.get("o/yaml-mcp", "").startswith("mint.yaml is not valid YAML"), True)
check("a non-mapping document is reported", reasons.get("o/list-mcp", "").startswith("mint.yaml fails the schema"), True)
check("a fetch error is reported", reasons.get("o/err-mcp"), "could not fetch mint.yaml: HTTP 502")
z = cat["servers"][0]
check("no examples => key omitted, never []", "examples" in z, False)
check("no name => repo name", z["name"], "zillow-mcp")
check("no transport => bridge false", z["bridge"], False)
check("summary carried", z["summary"], "Zillow listings")

print("\n── pkg and slug come from fleet.json / the repo name ──")
f = FakeFetcher({"o/nopkg-mcp": pub(), "o/Bad_Slug": pub(), "o/badpkg-mcp": pub()},
                {(r, "mint.yaml"): "version: 1\n" for r in ("o/nopkg-mcp", "o/Bad_Slug", "o/badpkg-mcp")})
cat, rep = build(fleet({"repo": "o/nopkg-mcp"},
                       {"repo": "o/Bad_Slug", "package_name": "bad-slug"},
                       {"repo": "o/badpkg-mcp", "package_name": "Not A Package"}), f)
reasons = {r["repo"]: r["reason"] for r in rep.reported}
check("a root mint.yaml with no package_name is reported, and mint.yaml is never fetched",
      (reasons.get("o/nopkg-mcp"), "o/nopkg-mcp" in f.file_calls), ("no package_name in fleet.json", False))
check("a repo name that is not a slug is reported", reasons.get("o/Bad_Slug", "").startswith("repo name is not a catalog slug"), True)
check("an invalid npm name is reported", reasons.get("o/badpkg-mcp", "").startswith("package_name is not a valid npm name"), True)
check("none listed", cat["servers"], [])

print("\n── a repo with no mint.yaml anywhere is not an MCP ──")
f = FakeFetcher({"o/lib": pub(), "o/tool": pub()},
                {("o/lib", "package.json"): '{"name": "lib"}', ("o/lib", "README.md"): "# lib\n"})
cat, rep = build(fleet({"repo": "o/lib"}, {"repo": "o/tool"}), f)
check("nothing listed", cat["servers"], [])
check("nothing reported", rep.reported, [])
check("both are counted as not an MCP", rep.not_mcp, 2)
check("one tree call per repo, no file reads", (len(f.tree_calls), f.file_calls), (2, []))
summary = mod.render_summary(cat, rep)
check("the summary carries the not-an-MCP count", "2 public repos are not MCPs (no mint.yaml)" in summary, True)
check("and no warning rows for them", ("o/lib" in summary, "o/tool" in summary), (False, False))

print("\n── the file tree is read once per repo, at the default branch ──")
f = FakeFetcher({"o/zillow-mcp": pub("trunk")}, {("o/zillow-mcp", "mint.yaml"): "version: 1\n"})
cat, rep = build(fleet({"repo": "o/zillow-mcp", "package_name": "zillow-mcp"}), f)
check("tree read at the default branch", f.tree_calls, [("o/zillow-mcp", "trunk")])
f = FakeFetcher({"o/t-mcp": pub(), "o/u-mcp": pub()}, {}, tree_errors={"o/t-mcp"},
                trees={"o/u-mcp": (["src/index.ts"], True)})
cat, rep = build(fleet({"repo": "o/t-mcp", "package_name": "t-mcp"}, {"repo": "o/u-mcp"}), f)
reasons = {r["repo"]: r["reason"] for r in rep.reported}
check("a tree fetch error is reported, not fatal", reasons.get("o/t-mcp"), "could not list the repo's files: HTTP 409")
check("a truncated tree with no manifest found is reported, not called 'not an MCP'",
      (reasons.get("o/u-mcp"), rep.not_mcp),
      ("the file tree is truncated and no mint.yaml was found in what was listed", 0))
f = FakeFetcher({"o/v-mcp": pub()}, {("o/v-mcp", "mint.yaml"): "version: 1\n"},
                trees={"o/v-mcp": (["mint.yaml"], True)})
cat, rep = build(fleet({"repo": "o/v-mcp", "package_name": "v-mcp"}), f)
check("a truncated tree that still shows a root mint.yaml lists it", [s["repo"] for s in cat["servers"]], ["o/v-mcp"])

print("\n── a monorepo lists each packages/*/mint.yaml as its own server ──")
MONO = "o/gog-mcp"
mono_files = {
    (MONO, "package.json"): '{"name": "gog-root", "private": true}',
    (MONO, "packages/gog-mcp/package.json"): '{"name": "gog-mcp"}',
    (MONO, "packages/gog-mcp/mint.yaml"): (
        "version: 1\nname: Google (gogcli)\nsummary: All of Google\n"
        "examples:\n  - prompt: Find my unread mail\ntransport:\n  bridge: false\n"),
    (MONO, "packages/gog-mcp-gmail/package.json"): '{"name": "@s/gog-mcp-gmail", "private": false}',
    (MONO, "packages/gog-mcp-gmail/mint.yaml"): "version: 1\nsummary: \"  Gmail\\u202e only \"\n",
    # private: true — never published, never listed
    (MONO, "packages/internal/package.json"): '{"name": "internal", "private": true}',
    (MONO, "packages/internal/mint.yaml"): "version: 1\n",
    # a package.json-less manifest, a broken package.json, a bad npm name,
    # a manifest failing the schema, a dir that is not a slug, a dup pkg
    (MONO, "packages/nopkgjson/mint.yaml"): "version: 1\n",
    (MONO, "packages/brokenjson/package.json"): "{not json",
    (MONO, "packages/brokenjson/mint.yaml"): "version: 1\n",
    (MONO, "packages/badname/package.json"): '{"name": "Bad Name"}',
    (MONO, "packages/badname/mint.yaml"): "version: 1\n",
    (MONO, "packages/badschema/package.json"): '{"name": "badschema"}',
    (MONO, "packages/badschema/mint.yaml"): "version: 2\n",
    (MONO, "packages/Bad_Dir/package.json"): '{"name": "bad-dir"}',
    (MONO, "packages/Bad_Dir/mint.yaml"): "version: 1\n",
    (MONO, "packages/zdup/package.json"): '{"name": "gog-mcp"}',
    (MONO, "packages/zdup/mint.yaml"): "version: 1\n",
    # a package.json with no mint.yaml is just a library package
    (MONO, "packages/core/package.json"): '{"name": "gog-core"}',
    # deeper than packages/<dir>/ is not a package manifest
    (MONO, "packages/gog-mcp/test/fixtures/mint.yaml"): "version: 1\n",
}
f = FakeFetcher({MONO: pub()}, mono_files)
kinds = dict(KINDS, kinds=dict(KINDS["kinds"], **{MONO: "Productivity"}))
cat, rep = build(fleet({"repo": MONO}), f, kinds=kinds)
check("each valid, non-private package is a server, in path order",
      [(s["slug"], s["pkg"]) for s in cat["servers"]],
      [("gog-mcp", "gog-mcp"), ("gog-mcp-gmail", "@s/gog-mcp-gmail")])
check("the package row, exactly", cat["servers"][0], {
    "name": "Google (gogcli)", "slug": "gog-mcp", "pkg": "gog-mcp", "summary": "All of Google",
    "examples": [{"prompt": "Find my unread mail"}],
    "kind": "Productivity", "bridge": False, "repo": MONO,
})
check("a package's display text is cleaned like a root manifest's", cat["servers"][1]["summary"], "Gmail only")
check("a package with no name falls back to its directory", cat["servers"][1]["name"], "gog-mcp-gmail")
check("a monorepo needs no package_name in fleet.json", "no package_name in fleet.json" in
      [r["reason"] for r in rep.reported], False)
reasons = sorted(r["reason"] for r in rep.reported if r["repo"] == MONO)
check("every bad package is reported against the repo, by path", reasons, sorted([
    "packages/Bad_Dir: directory name is not a catalog slug: Bad_Dir",
    "packages/badname: package.json name is not a valid npm name: Bad Name",
    "packages/badschema: mint.yaml fails the schema at version: 1 was expected",
    "packages/brokenjson: package.json is not valid JSON",
    "packages/zdup: package gog-mcp is already listed by o/gog-mcp (packages/gog-mcp)",
    "packages/nopkgjson: no package.json beside mint.yaml",
]))
check("a private package is skipped without a report row",
      any("internal" in r["reason"] for r in rep.reported), False)
check("a private package's mint.yaml is never fetched",
      (MONO, "packages/internal/mint.yaml") in f.file_paths, False)
check("cleaning in a package is noted against that package",
      any(w["repo"] == MONO and w["warning"].startswith("packages/gog-mcp-gmail: summary:") for w in rep.warnings), True)
check("the monorepo document passes the gateway's rules", mod.validate_catalog(cat), [])
check("a monorepo is not 'not an MCP'", rep.not_mcp, 0)

f = FakeFetcher({MONO: pub()}, mono_files)
cat, rep = build(fleet({"repo": MONO}), f)
check("an unmapped monorepo files every package under the default kind, noted per package",
      ([s["kind"] for s in cat["servers"]],
       sorted(w["warning"] for w in rep.warnings if "kind:" in w["warning"])),
      (["Other", "Other"], ["packages/gog-mcp-gmail: kind: not in catalog-kinds.json, filed under Other",
                            "packages/gog-mcp: kind: not in catalog-kinds.json, filed under Other"]))

print("\n── package slugs and pkgs are unique across the WHOLE catalog ──")
f = FakeFetcher(
    {"o/gmail": pub(), MONO: pub(), "o/after-mcp": pub()},
    {("o/gmail", "mint.yaml"): "version: 1\n",
     (MONO, "packages/gmail/package.json"): '{"name": "gog-gmail"}',
     (MONO, "packages/gmail/mint.yaml"): "version: 1\n",
     (MONO, "packages/gog-mcp/package.json"): '{"name": "gog-mcp"}',
     (MONO, "packages/gog-mcp/mint.yaml"): "version: 1\n",
     ("o/after-mcp", "mint.yaml"): "version: 1\n"},
)
cat, rep = build(fleet({"repo": "o/gmail", "package_name": "gmail"}, {"repo": MONO},
                       {"repo": "o/after-mcp", "package_name": "gog-mcp"}), f)
check("first wins across repos and packages", [s["slug"] for s in cat["servers"]], ["gmail", "gog-mcp"])
reasons = {r["reason"] for r in rep.reported}
check("a package slug colliding with an earlier repo is reported",
      "packages/gmail: slug gmail is already listed by o/gmail" in reasons, True)
check("a root pkg colliding with an earlier package is reported",
      "package gog-mcp is already listed by o/gog-mcp (packages/gog-mcp)" in reasons, True)
check("still passes the gateway's rules", mod.validate_catalog(cat), [])

print("\n── a root mint.yaml wins over packages/*/mint.yaml ──")
f = FakeFetcher({"o/both-mcp": pub()},
                {("o/both-mcp", "mint.yaml"): "version: 1\n",
                 ("o/both-mcp", "packages/x/package.json"): '{"name": "x"}',
                 ("o/both-mcp", "packages/x/mint.yaml"): "version: 1\n"})
cat, rep = build(fleet({"repo": "o/both-mcp", "package_name": "both-mcp"}), f)
check("only the root manifest is listed", [(s["slug"], s["pkg"]) for s in cat["servers"]], [("both-mcp", "both-mcp")])
check("the package manifests are never read", [p for (_, p) in f.file_paths], ["mint.yaml"])
f = FakeFetcher({"o/both-mcp": pub()},
                {("o/both-mcp", "mint.yaml"): "version: 1\n",
                 ("o/both-mcp", "packages/x/package.json"): '{"name": "x"}',
                 ("o/both-mcp", "packages/x/mint.yaml"): "version: 1\n"})
cat, rep = build(fleet({"repo": "o/both-mcp"}), f)
check("a root mint.yaml with no package_name is still reported, packages notwithstanding",
      ([r["reason"] for r in rep.reported], cat["servers"]), (["no package_name in fleet.json"], []))

print("\n── display text is cleaned to the gateway's rules ──")
long_summary = "word " * 60
f = FakeFetcher({"o/x-mcp": pub()}, {("o/x-mcp", "mint.yaml"): json.dumps({
    "version": 1,
    "name": "  X\u202e \u0007 Tool  ",
    "summary": long_summary,
    "examples": [{"prompt": " \u200b ", "note": "dropped with its prompt"},
                 {"prompt": "  Ask\tthis\n please ", "note": " \u2066 "}],
})})
cat, rep = build(fleet({"repo": "o/x-mcp", "package_name": "x-mcp"}), f)
x = cat["servers"][0]
check("name: controls/bidi removed, whitespace collapsed and trimmed", x["name"], "X Tool")
check("summary truncated to <= 200 with an ellipsis", (len(x["summary"]) <= 200, x["summary"].endswith("…")), (True, True))
check("an example whose prompt cleans to empty is dropped; an empty note is dropped",
      x["examples"], [{"prompt": "Ask this please"}])
check("unknown kind falls back to the default", x["kind"], "Other")
check("the cleaning is noted in the summary", any(w["repo"] == "o/x-mcp" for w in rep.warnings), True)
check("still passes the gateway's rules", mod.validate_catalog(cat), [])

f = FakeFetcher({"o/y-mcp": pub()}, {("o/y-mcp", "mint.yaml"): json.dumps({
    "version": 1, "name": "\u200b", "summary": " \u200f ", "examples": [{"prompt": "\u200b"}]})})
cat, rep = build(fleet({"repo": "o/y-mcp", "package_name": "y-mcp"}), f)
y = cat["servers"][0]
check("a name that cleans to empty falls back to the repo name", y["name"], "y-mcp")
check("a summary that cleans to empty becomes null", y["summary"], None)
check("all examples dropped => key omitted", "examples" in y, False)

print("\n── caps are UTF-16 code units, as zod counts them ──")
def u16(t):
    return len(t.encode("utf-16-le")) // 2
astral = "\U0001F3B5"  # one code point, two UTF-16 units (a surrogate pair)
t = mod.clean_text(astral * 250, 200)
check("an astral run is truncated to <= 200 UTF-16 units", u16(t) <= 200, True)
check("and ends with the ellipsis, no lone surrogate", (t.endswith("\u2026"), t[:-1] == astral * (len(t) - 1)), (True, True))
t = mod.clean_text("a" + astral * 100, 200)
check("201 units is truncated (100 astral + 1)", u16(t) <= 200 and t.endswith("\u2026"), True)
check("exactly 200 units is kept as is", mod.clean_text(astral * 100, 200), astral * 100)
check("words: cut lands before a word, by units",
      u16(mod.clean_text((astral * 3 + " ") * 60, 200)) <= 200, True)
check("validate_catalog refuses an astral summary over 200 units",
      len(mod.validate_catalog({"generatedAt": NOW, "servers": [dict(
          {"name": "N", "slug": "n", "pkg": "@s/n", "kind": "K", "bridge": False, "repo": "o/n"},
          summary=astral * 101)]})) > 0, True)
check("validate_catalog accepts an astral summary of exactly 200 units",
      mod.validate_catalog({"generatedAt": NOW, "servers": [dict(
          {"name": "N", "slug": "n", "pkg": "@s/n", "kind": "K", "bridge": False, "repo": "o/n"},
          summary=astral * 100)]}), [])
f = FakeFetcher({"o/e-mcp": pub()}, {("o/e-mcp", "mint.yaml"): json.dumps({
    "version": 1, "name": astral * 40, "summary": astral * 150,
    "examples": [{"prompt": astral * 150, "note": astral * 100}]})})
cat, rep = build(fleet({"repo": "o/e-mcp", "package_name": "e-mcp"}), f)
check("a built row of astral text near every cap passes the gateway's rules", mod.validate_catalog(cat), [])

print("\n── uniqueness: one duplicate would refuse the whole document ──")
f = FakeFetcher({"o/a-mcp": pub(), "p/a-mcp": pub(), "o/b-mcp": pub()},
                {(r, "mint.yaml"): "version: 1\n" for r in ("o/a-mcp", "p/a-mcp", "o/b-mcp")})
cat, rep = build(fleet({"repo": "o/a-mcp", "package_name": "a-mcp"},
                       {"repo": "p/a-mcp", "package_name": "other"},
                       {"repo": "o/b-mcp", "package_name": "a-mcp"}), f)
check("first wins, duplicates are reported", [s["repo"] for s in cat["servers"]], ["o/a-mcp"])
reasons = {r["repo"]: r["reason"] for r in rep.reported}
check("duplicate slug reported", reasons.get("p/a-mcp"), "slug a-mcp is already listed by o/a-mcp")
check("duplicate pkg reported", reasons.get("o/b-mcp"), "package a-mcp is already listed by o/a-mcp")

print("\n── validate_catalog mirrors fleetCatalogSchema ──")
good = {"name": "N", "slug": "n", "pkg": "@s/n", "summary": None, "kind": "K", "bridge": False, "repo": "o/n"}
check("a minimal good doc passes", mod.validate_catalog({"generatedAt": NOW, "servers": [good]}), [])
check("an offset datetime passes", mod.validate_catalog({"generatedAt": "2026-10-19T05:41:00.123+01:00", "servers": []}), [])
bads = {
    "bad generatedAt": {"generatedAt": "yesterday", "servers": []},
    "padded name": {"generatedAt": NOW, "servers": [dict(good, name=" N")]},
    "bidi in kind": {"generatedAt": NOW, "servers": [dict(good, kind="K\u202e")]},
    "summary too long": {"generatedAt": NOW, "servers": [dict(good, summary="s" * 201)]},
    "summary key missing": {"generatedAt": NOW, "servers": [{k: v for k, v in good.items() if k != "summary"}]},
    "empty examples": {"generatedAt": NOW, "servers": [dict(good, examples=[])]},
    "six examples": {"generatedAt": NOW, "servers": [dict(good, examples=[{"prompt": "p"}] * 6)]},
    "bridge not bool": {"generatedAt": NOW, "servers": [dict(good, bridge="yes")]},
    "dot-dot repo": {"generatedAt": NOW, "servers": [dict(good, repo="o/..")]},
    "bad slug": {"generatedAt": NOW, "servers": [dict(good, slug="-n")]},
    "dup pkg": {"generatedAt": NOW, "servers": [good, dict(good, slug="m")]},
    "dup slug": {"generatedAt": NOW, "servers": [good, dict(good, pkg="m")]},
    "too many": {"generatedAt": NOW, "servers": [dict(good, slug=f"s{i}", pkg=f"p{i}") for i in range(501)]},
}
for name, doc in bads.items():
    check(f"refuses: {name}", len(mod.validate_catalog(doc)) > 0, True)

print("\n── the CLI end to end, through a stubbed gh ──")
with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    bindir = tmp / "bin"
    bindir.mkdir()
    # gh api repos/<r>            -> repo JSON
    # gh api repos/<r>/contents/mint.yaml?ref=main -H Accept:raw -> body or 404
    (bindir / "gh").write_text(r"""#!/usr/bin/env bash
path="$2"
case "$path" in
  repos/o/pub-mcp) echo '{"visibility":"public","default_branch":"main","archived":false}' ;;
  repos/o/priv-mcp) echo '{"visibility":"private","default_branch":"main","archived":false}' ;;
  repos/o/pub-mcp/git/trees/main\?recursive=1) echo '{"truncated":false,"tree":[{"path":"mint.yaml","type":"blob"},{"path":"src","type":"tree"}]}' ;;
  repos/o/pub-mcp/contents/mint.yaml\?ref=main) printf 'version: 1\nsummary: Public one\n' ;;
  repos/o/mono) echo '{"visibility":"public","default_branch":"dev/x","archived":false}' ;;
  repos/o/mono/git/trees/dev%2Fx\?recursive=1) echo '{"truncated":false,"tree":[{"path":"packages","type":"tree"},{"path":"packages/a","type":"tree"},{"path":"packages/a/mint.yaml","type":"blob"},{"path":"packages/a/package.json","type":"blob"}]}' ;;
  repos/o/mono/contents/packages/a/package.json\?ref=dev%2Fx) echo '{"name":"@o/a"}' ;;
  repos/o/mono/contents/packages/a/mint.yaml\?ref=dev%2Fx) printf 'version: 1\nsummary: Package A\n' ;;
  repos/o/lib) echo '{"visibility":"public","default_branch":"main","archived":false}' ;;
  repos/o/lib/git/trees/main\?recursive=1) echo '{"truncated":false,"tree":[{"path":"package.json","type":"blob"}]}' ;;
  repos/o/gone-mcp) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
""")
    (bindir / "gh").chmod(stat.S_IRWXU)
    (tmp / "fleet.json").write_text(json.dumps(fleet(
        {"repo": "o/pub-mcp", "package_name": "pub-mcp"},
        {"repo": "o/priv-mcp", "package_name": "priv-mcp"},
        {"repo": "o/gone-mcp", "package_name": "gone-mcp"},
        {"repo": "o/mono"},
        {"repo": "o/lib"})))
    (tmp / "kinds.json").write_text(json.dumps(KINDS))
    (tmp / "schema.json").write_text(json.dumps(SCHEMA))
    out = tmp / "site/catalog.json"
    summ = tmp / "summary.md"
    env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}")
    p = subprocess.run([sys.executable, str(SCRIPT), "--fleet", str(tmp / "fleet.json"),
                        "--kinds", str(tmp / "kinds.json"), "--schema", str(tmp / "schema.json"),
                        "--out", str(out), "--summary", str(summ)],
                       env=env, capture_output=True, text=True)
    check("exits 0 with reported repos", p.returncode, 0)
    doc = json.loads(out.read_text()) if out.exists() else {}
    check("emits the public repo and the monorepo's package",
          [(s["repo"], s["slug"], s["pkg"]) for s in doc.get("servers", [])],
          [("o/pub-mcp", "pub-mcp", "pub-mcp"), ("o/mono", "a", "@o/a")])
    s = summ.read_text() if summ.exists() else ""
    check("summary counts the non-public repos", "2 non-public or unreadable" in s, True)
    check("summary counts the not-an-MCP repo", "1 public repos are not MCPs (no mint.yaml)" in s, True)
    check("no gh call went unanswered", "unexpected gh call" in p.stderr, False)
    check("summary names neither the private nor the unreadable repo", ("priv-mcp" in s, "gone-mcp" in s), (False, False))

    # A schema that is not a valid JSON Schema is FATAL: no catalog is better
    # than an unvalidated one under a Verified badge.
    (tmp / "schema.json").write_text(json.dumps({"type": 12}))
    out.unlink()
    p = subprocess.run([sys.executable, str(SCRIPT), "--fleet", str(tmp / "fleet.json"),
                        "--kinds", str(tmp / "kinds.json"), "--schema", str(tmp / "schema.json"),
                        "--out", str(out)], env=env, capture_output=True, text=True)
    check("an invalid schema fails the run", p.returncode != 0, True)
    check("and writes no catalog", out.exists(), False)

print("\n── the real kinds file covers every public candidate it names ──")
kinds = json.loads((ROOT / "catalog-kinds.json").read_text())
fleet_repos = {r["repo"] for r in json.loads((ROOT / "fleet.json").read_text())["repos"]}
check("catalog-kinds.json has a default", isinstance(kinds.get("default"), str) and kinds["default"] != "", True)
check("every repo it names is in fleet.json", sorted(set(kinds["kinds"]) - fleet_repos), [])
check("every kind is valid display text <= 40",
      [k for k in list(kinds["kinds"].values()) + [kinds["default"]] if mod.clean_text(k, 40) != k], [])

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
