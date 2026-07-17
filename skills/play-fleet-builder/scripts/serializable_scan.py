#!/usr/bin/env python3
"""Classify the @Serializable declarations in a Kotlin source tree.

Only some @Serializable shapes make the compiler plugin generate a
`Foo$$serializer` class. The rest are served by a serializer that already
exists, so looking for `Foo$$serializer` in a minified DEX would report them
missing and fail a release for no reason:

  @Serializable data class Foo(...)          -> Foo$$serializer       REQUIRED
  @Serializable class Foo(...)               -> Foo$$serializer       REQUIRED
  @Serializable enum class Foo               -> EnumSerializer        exempt
  @Serializable object Foo                   -> ObjectSerializer      exempt
  @Serializable sealed class Foo             -> SealedClassSerializer exempt
  @Serializable abstract class Foo           -> PolymorphicSerializer exempt
  @Serializable(with = X::class) class Foo   -> X                     exempt
  @Serializable @JvmInline value class Foo   -> (not asserted)        exempt

Two rules govern this file, both learned the hard way:

  * Nothing is dropped silently. A type the scanner cannot place lands in
    `unrecognized`, which the caller must treat as an error. A guard that
    quietly stops checking reports success while guarding nothing — strictly
    worse than never having guarded at all.
  * The annotation is matched wherever it sits. `@Serializable data class Foo`
    on one line is as valid as the two-line form, and an earlier version of
    this scanner skipped it silently by anchoring the annotation to end-of-line.

Usage:
  serializable_scan.py <source-root>            # print REQUIRED type names
  serializable_scan.py <source-root> --report   # + exemptions on stderr
"""

import re
import sys
from pathlib import Path

# `@Serializable`, optionally `(with = Foo::class)`, at the start of a line.
SERIALIZABLE = re.compile(r"^\s*@Serializable\b(\s*\((?P<args>[^)]*)\))?")
# Any other annotation, so `@Serializable @JvmInline value class F` parses.
OTHER_ANNOTATION = re.compile(r"^\s*@[A-Za-z_][A-Za-z0-9_.]*(\s*\([^)]*\))?")
# A class-like declaration. `enum`/`data`/`sealed`/... are captured as modifiers
# so `enum class Foo` and `data class Foo` share one pattern.
DECLARATION = re.compile(
    r"^\s*(?P<mods>(?:(?:public|internal|private|protected|abstract|sealed|open|final"
    r"|data|value|inline|annotation|enum|companion|expect|actual)\s+)*)"
    r"(?P<kind>class|object|interface)\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
)
# Things @Serializable can legally precede that are not type declarations:
# use-site annotations on properties, parameters, functions, typealiases.
NON_TYPE = re.compile(r"^\s*(?:val|var|fun|typealias|constructor|init|get|set)\b")
COMMENT_OR_BLANK = re.compile(r"^\s*(?://|/\*|\*|$)")


def _strip_annotations(text):
    """Drop any leading annotations, returning what they decorate."""
    while True:
        m = OTHER_ANNOTATION.match(text)
        if not m:
            return text
        text = text[m.end():]


def classify(source_root):
    """-> (required, exempt: [(name, reason)], unrecognized: [(file, line, text)])"""
    required, exempt, unrecognized = [], [], []

    for path in sorted(Path(source_root).rglob("*.kt")):
        lines = path.read_text(encoding="utf-8").splitlines()
        for i, line in enumerate(lines):
            m = SERIALIZABLE.match(line)
            if not m:
                continue

            custom = bool(m.group("args") and "with" in m.group("args"))

            # The declaration may share this line with the annotation, or follow
            # it after further annotations/comments.
            decl = _strip_annotations(line[m.end():]).strip()
            if not decl:
                for nxt in lines[i + 1: i + 8]:
                    if COMMENT_OR_BLANK.match(nxt):
                        continue
                    decl = _strip_annotations(nxt).strip()
                    if decl:
                        break

            if not decl:
                unrecognized.append((str(path), i + 1, line.strip()))
                continue

            if NON_TYPE.match(decl):
                # A use-site annotation, e.g. on a property. Not a type.
                continue

            d = DECLARATION.match(decl)
            if not d:
                unrecognized.append((str(path), i + 1, decl[:60]))
                continue

            name, kind, mods = d.group("name"), d.group("kind"), d.group("mods") or ""

            if custom:
                exempt.append((name, "@Serializable(with = ...) -> custom serializer"))
            elif "enum" in mods:
                exempt.append((name, "enum class -> EnumSerializer"))
            elif kind == "object":
                exempt.append((name, "object -> ObjectSerializer"))
            elif kind == "interface" or "sealed" in mods:
                exempt.append((name, "sealed/interface -> SealedClassSerializer"))
            elif "abstract" in mods:
                exempt.append((name, "abstract -> PolymorphicSerializer"))
            elif "value" in mods or "inline" in mods:
                exempt.append((name, "value class -> not asserted"))
            else:
                required.append(name)

    return sorted(set(required)), sorted(set(exempt)), unrecognized


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    required, exempt, unrecognized = classify(sys.argv[1])

    if unrecognized:
        print("error: could not classify these @Serializable declarations, so they", file=sys.stderr)
        print("       are not being guarded. Teach serializable_scan.py their shape:", file=sys.stderr)
        for f, ln, text in unrecognized:
            print(f"         {f}:{ln}: {text}", file=sys.stderr)
        return 1

    for name in required:
        print(name)
    if "--report" in sys.argv:
        for name, reason in exempt:
            print(f"  exempt: {name} ({reason})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
