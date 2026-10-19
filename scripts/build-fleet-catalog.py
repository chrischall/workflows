#!/usr/bin/env python3
"""Build the fleet catalog manifest (catalog.json) the mcp-host gateway's
public /catalog page reads from FLEET_CATALOG_URL.

For every repo in fleet.json that is PUBLIC (checked against the GitHub API,
fail-closed: anything unreadable or not exactly "public" is left out), fetch
its mint.yaml at the default branch, validate it against the mint manifest
JSON Schema that mcp-host publishes, and emit one row per valid repo in
exactly the shape mcp-host core's `fleetCatalogSchema` accepts
(packages/core/src/public-catalog.ts):

    {"generatedAt": ISO datetime,
     "servers": [{name, slug, pkg, summary|null, examples?, kind, bridge, repo}]}

The gateway refuses that document WHOLE on a single bad row, and refuses
display text rather than stripping it, so this producer cleans every string
(no control or bidi characters, collapsed and trimmed whitespace, within its
cap) and then re-checks the finished document against the same rules
(`validate_catalog`). Those rules are re-implemented here because
`@mcp-host/core` is a private, unpublished package; the trim, bidi and
uniqueness checks could not be expressed in JSON Schema anyway.

A repo with no mint.yaml, a mint.yaml that fails the schema, or no npm package
in fleet.json is REPORTED in the job summary and left out — never fatal. What
IS fatal is anything that would publish an unvalidated document: an invalid
schema, or a finished catalog that fails `validate_catalog`.

The job summary is public (this repo is public), so non-public repos are
counted, never named.

Usage:
  build-fleet-catalog.py --fleet fleet.json --kinds catalog-kinds.json \\
      --schema mint-manifest.schema.json --out site/catalog.json \\
      [--summary "$GITHUB_STEP_SUMMARY"]

Reads the GitHub API through `gh api`, authenticated by GH_TOKEN.
Needs jsonschema + PyYAML (scripts/fleet-catalog.requirements.txt).
"""
import argparse
import datetime
import json
import pathlib
import re
import subprocess
import sys
import urllib.parse

import jsonschema
import yaml

# ── the gateway's rules (mcp-host core public-catalog.ts / source.ts) ──

MAX_SERVERS = 500
MAX_BYTES = 1024 * 1024
MAX_NAME = 80
MAX_SUMMARY = 200  # MAX_CATALOG_BLURB
MAX_KIND = 40
MAX_EXAMPLES = 5
MAX_PROMPT = 200
MAX_NOTE = 120

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
NPM_RE = re.compile(r"^(@[a-z0-9-~][a-z0-9-._~]*/)?[a-z0-9-~][a-z0-9-._~]*$")
REPO_RE = re.compile(r"^[\w.-]+/[\w.-]+$", re.ASCII)
# zod `z.string().datetime({ offset: true })`
DATETIME_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$")
# core catalog-listing.ts REWRITES_THE_LINE: C0/C1 controls (bar \t-\r), ALM,
# zero-width space, LRM/RLM, the embedding/override and isolate controls.
REWRITES_THE_LINE = re.compile(
    "[\u0000-\u0008\u000e-\u001f\u007f-\u009f\u061c\u200b\u200e\u200f\u202a-\u202e\u2066-\u2069]"
)
# JS String.prototype.trim() also trims U+FEFF, which Python's \s does not match.
EXTRA_TRIM = re.compile("\ufeff")


def utf16_len(text):
    """Length in UTF-16 code units: what JS `.length` and zod `.min()/.max()` count.
    An astral character (most emoji) is ONE Python code point but TWO units."""
    return len(text.encode("utf-16-le")) // 2


def _is_display_text(value, max_len):
    return (
        isinstance(value, str)
        and 1 <= utf16_len(value) <= max_len
        and value.strip() == value
        and EXTRA_TRIM.search(value) is None
        and value.strip() != ""
        and REWRITES_THE_LINE.search(value) is None
    )


def validate_catalog(doc):
    """Every reason the gateway's fleetCatalogSchema would refuse `doc`; [] when it would accept it."""
    errors = []
    if not isinstance(doc, dict):
        return ["document is not an object"]
    if not (isinstance(doc.get("generatedAt"), str) and DATETIME_RE.match(doc["generatedAt"])):
        errors.append("generatedAt is not an ISO datetime")
    servers = doc.get("servers")
    if not isinstance(servers, list):
        return errors + ["servers is not an array"]
    if len(servers) > MAX_SERVERS:
        errors.append(f"servers has {len(servers)} entries (max {MAX_SERVERS})")
    pkgs, slugs = set(), set()
    for i, s in enumerate(servers):
        at = f"servers[{i}]"
        if not isinstance(s, dict):
            errors.append(f"{at} is not an object")
            continue
        if not _is_display_text(s.get("name"), MAX_NAME):
            errors.append(f"{at}.name is not display text <= {MAX_NAME}")
        if not (isinstance(s.get("slug"), str) and SLUG_RE.match(s["slug"])):
            errors.append(f"{at}.slug is not a catalog slug")
        if not (isinstance(s.get("pkg"), str) and len(s["pkg"]) <= 214 and NPM_RE.match(s["pkg"])):
            errors.append(f"{at}.pkg is not an npm package name")
        if "summary" not in s:
            errors.append(f"{at}.summary is missing (use null)")
        elif s["summary"] is not None and not _is_display_text(s["summary"], MAX_SUMMARY):
            errors.append(f"{at}.summary is not display text <= {MAX_SUMMARY}")
        if "examples" in s:
            ex = s["examples"]
            if not (isinstance(ex, list) and 1 <= len(ex) <= MAX_EXAMPLES):
                errors.append(f"{at}.examples must hold 1..{MAX_EXAMPLES} items (omit the key when none)")
            else:
                for j, e in enumerate(ex):
                    if not (isinstance(e, dict) and _is_display_text(e.get("prompt"), MAX_PROMPT)):
                        errors.append(f"{at}.examples[{j}].prompt is not display text <= {MAX_PROMPT}")
                    elif "note" in e and not _is_display_text(e["note"], MAX_NOTE):
                        errors.append(f"{at}.examples[{j}].note is not display text <= {MAX_NOTE}")
        if not _is_display_text(s.get("kind"), MAX_KIND):
            errors.append(f"{at}.kind is not display text <= {MAX_KIND}")
        if not isinstance(s.get("bridge"), bool):
            errors.append(f"{at}.bridge is not a boolean")
        repo = s.get("repo")
        if not (isinstance(repo, str) and REPO_RE.match(repo) and all(seg not in (".", "..") for seg in repo.split("/"))):
            errors.append(f"{at}.repo is not owner/repo")
        if s.get("pkg") in pkgs:
            errors.append(f"{at}.pkg {s.get('pkg')} is listed twice")
        if s.get("slug") in slugs:
            errors.append(f"{at}.slug {s.get('slug')} is listed twice")
        pkgs.add(s.get("pkg"))
        slugs.add(s.get("slug"))
    return errors


# ── cleaning display text to those rules ──


def clean_text(value, max_len):
    """(text or None) cleaned to display text <= max_len. None when nothing is left."""
    text, _ = _clean(value, max_len)
    return text


def _clean(value, max_len):
    """Returns (cleaned-or-None, what changed beyond whitespace: list of strings)."""
    if not isinstance(value, str):
        return None, []
    changes = []
    stripped = REWRITES_THE_LINE.sub("", value)
    stripped = EXTRA_TRIM.sub("", stripped)
    if stripped != value:
        changes.append("removed control/bidi characters")
    text = re.sub(r"\s+", " ", stripped).strip()
    if text == "":
        return None, changes
    if utf16_len(text) > max_len:
        # Keep whole code points (never half a surrogate pair) within
        # max_len - 1 units, leaving one unit for the ellipsis.
        cut, units = [], 0
        for ch in text:
            units += 2 if ord(ch) > 0xFFFF else 1
            if units > max_len - 1:
                break
            cut.append(ch)
        cut = "".join(cut)
        if " " in cut:
            cut = cut[: cut.rindex(" ")]
        text = cut.rstrip() + "…"
        changes.append(f"truncated to {max_len} UTF-16 units")
    return text, changes


# ── fetching ──


class FetchError(Exception):
    pass


class GhFetcher:
    """Reads GitHub through the `gh` CLI (GH_TOKEN)."""

    def _api(self, path, raw=False):
        cmd = ["gh", "api", path]
        if raw:
            cmd += ["-H", "Accept: application/vnd.github.raw"]
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode == 0:
            return p.stdout
        err = (p.stderr or p.stdout).strip()
        if "HTTP 404" in err or "Not Found" in err:
            return None
        raise FetchError(err.splitlines()[-1] if err else f"gh exited {p.returncode}")

    def repo_info(self, repo):
        try:
            body = self._api(f"repos/{repo}")
            return json.loads(body) if body is not None else None
        except (FetchError, ValueError):
            return None  # unreadable is treated exactly like private: left out

    def file(self, repo, path, ref):
        return self._api(f"repos/{repo}/contents/{path}?ref={urllib.parse.quote(ref, safe='')}", raw=True)


# ── the build ──


class Report:
    def __init__(self):
        self.reported = []  # [{repo, reason}] — public repos left out
        self.warnings = []  # [{repo, warning}] — listed, but something was changed or defaulted
        self.non_public = 0

    def skip(self, repo, reason):
        self.reported.append({"repo": repo, "reason": reason})

    def warn(self, repo, warning):
        self.warnings.append({"repo": repo, "warning": warning})


def _schema_error(validator, doc):
    err = jsonschema.exceptions.best_match(validator.iter_errors(doc))
    where = ".".join(str(p) for p in err.absolute_path) or "(root)"
    return f"mint.yaml fails the schema at {where}: {err.message}"


def build_catalog(fleet, kinds, schema, fetcher, generated_at):
    jsonschema.Draft202012Validator.check_schema(schema)
    validator = jsonschema.Draft202012Validator(schema)
    defaults = fleet.get("defaults", {})
    kind_map = kinds.get("kinds", {})
    default_kind = kinds["default"]
    report = Report()
    servers = []
    by_slug, by_pkg = {}, {}

    for entry in fleet.get("repos", []):
        repo = entry["repo"]
        info = fetcher.repo_info(repo)
        # Fail-closed: only an explicit "public" passes.
        if not isinstance(info, dict) or info.get("visibility") != "public":
            report.non_public += 1
            continue
        if info.get("archived"):
            report.skip(repo, "archived")
            continue
        name_part = repo.split("/", 1)[1]
        slug = name_part
        if not SLUG_RE.match(slug):
            report.skip(repo, f"repo name is not a catalog slug: {name_part}")
            continue
        pkg = entry.get("package_name", defaults.get("package_name", "")) or ""
        if not pkg:
            report.skip(repo, "no package_name in fleet.json")
            continue
        if len(pkg) > 214 or not NPM_RE.match(pkg):
            report.skip(repo, f"package_name is not a valid npm name: {pkg}")
            continue
        if slug in by_slug:
            report.skip(repo, f"slug {slug} is already listed by {by_slug[slug]}")
            continue
        if pkg in by_pkg:
            report.skip(repo, f"package {pkg} is already listed by {by_pkg[pkg]}")
            continue

        try:
            text = fetcher.file(repo, "mint.yaml", info.get("default_branch") or "main")
        except FetchError as e:
            report.skip(repo, f"could not fetch mint.yaml: {e}")
            continue
        if text is None:
            report.skip(repo, "no mint.yaml on the default branch")
            continue
        try:
            doc = yaml.safe_load(text)
        except yaml.YAMLError as e:
            report.skip(repo, f"mint.yaml is not valid YAML: {str(e).splitlines()[0]}")
            continue
        errors = list(validator.iter_errors(doc))
        if errors:
            report.skip(repo, _schema_error(validator, doc))
            continue

        changes = []

        def take(value, max_len, field):
            cleaned, what = _clean(value, max_len)
            changes.extend(f"{field}: {w}" for w in what)
            return cleaned

        name = take(doc.get("name"), MAX_NAME, "name") or name_part
        summary = take(doc.get("summary"), MAX_SUMMARY, "summary")
        examples = []
        for i, ex in enumerate(doc.get("examples") or []):
            prompt = take(ex.get("prompt"), MAX_PROMPT, f"examples[{i}].prompt")
            if prompt is None:
                changes.append(f"examples[{i}]: dropped (empty prompt)")
                continue
            row = {"prompt": prompt}
            note = take(ex.get("note"), MAX_NOTE, f"examples[{i}].note")
            if note is not None:
                row["note"] = note
            examples.append(row)
        if repo in kind_map:
            kind = kind_map[repo]
        else:
            kind = default_kind
            changes.append(f"kind: not in catalog-kinds.json, filed under {default_kind}")
        transport = doc.get("transport")
        bridge = isinstance(transport, dict) and transport.get("bridge") is True

        server = {"name": name, "slug": slug, "pkg": pkg, "summary": summary}
        if examples:
            server["examples"] = examples
        server.update({"kind": kind, "bridge": bridge, "repo": repo})
        servers.append(server)
        by_slug[slug] = repo
        by_pkg[pkg] = repo
        for c in changes:
            report.warn(repo, c)

    return {"generatedAt": generated_at, "servers": servers}, report


def render_summary(catalog, report):
    n = len(catalog["servers"])
    with_examples = sum(1 for s in catalog["servers"] if "examples" in s)
    lines = [
        "## Fleet catalog",
        "",
        f"- {n} servers listed ({with_examples} with examples, {n - with_examples} summary only)",
        f"- {report.non_public} non-public or unreadable fleet repos left out "
        "(counted, not named: this summary is public)",
        f"- {len(report.reported)} public repos reported and left out",
        "",
    ]
    if report.reported:
        lines += ["### Reported (not listed)", "", "| repo | reason |", "|---|---|"]
        lines += [f"| `{r['repo']}` | {r['reason'].replace('|', '/')} |" for r in report.reported]
        lines.append("")
    if report.warnings:
        lines += ["### Listed with changes", "", "| repo | change |", "|---|---|"]
        lines += [f"| `{w['repo']}` | {w['warning'].replace('|', '/')} |" for w in report.warnings]
        lines.append("")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--fleet", required=True)
    ap.add_argument("--kinds", required=True)
    ap.add_argument("--schema", required=True, help="the mint manifest JSON Schema, as a local file")
    ap.add_argument("--out", required=True)
    ap.add_argument("--summary", help="append a markdown report here (e.g. $GITHUB_STEP_SUMMARY)")
    args = ap.parse_args(argv)

    fleet = json.loads(pathlib.Path(args.fleet).read_text())
    kinds = json.loads(pathlib.Path(args.kinds).read_text())
    schema = json.loads(pathlib.Path(args.schema).read_text())
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    try:
        catalog, report = build_catalog(fleet, kinds, schema, GhFetcher(), now)
    except jsonschema.exceptions.SchemaError as e:
        print(f"::error::the mint manifest schema is not a valid JSON Schema: {e.message}", file=sys.stderr)
        return 2

    errors = validate_catalog(catalog)
    body = json.dumps(catalog, indent=2, ensure_ascii=False) + "\n"
    if len(body.encode("utf-8")) > MAX_BYTES:
        errors.append(f"catalog is {len(body.encode('utf-8'))} bytes (max {MAX_BYTES})")
    if errors:
        for e in errors:
            print(f"::error::catalog would be refused by the gateway: {e}", file=sys.stderr)
        return 1

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(body, encoding="utf-8")

    summary = render_summary(catalog, report)
    print(summary)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write(summary + "\n")
    for r in report.reported:
        print(f"::warning::{r['repo']}: {r['reason']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
