#!/usr/bin/env python3
"""Tests for serializable_scan.classify.

Two bugs are pinned here.

1. The original shell guard grepped for any @Serializable declaration and
   demanded a matching $$serializer in the DEX. Enums, objects and
   @Serializable(with = ...) types never generate one, so the first such type
   added to shared/ would have failed the release for no reason.

2. The first Python rewrite only matched @Serializable when it sat alone on its
   line, so `@Serializable data class Foo(...)` was skipped silently — neither
   required nor exempt. A silently unchecked type is the worse bug of the two:
   it makes the guard report success while guarding nothing.

Hence `classify` returns a third bucket, `unrecognized`. Anything the scanner
cannot confidently place is surfaced as an error rather than dropped: this
guard's whole value is that it never quietly stops checking.

Run: python3 android/scripts/test_serializable_scan.py   (no dependencies)
"""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from serializable_scan import classify

FIXTURE = '''
package com.example

import kotlinx.serialization.Serializable

@Serializable
data class PlainData(val a: String)

@Serializable
class PlainClass(val a: String)

@Serializable
enum class Kind { ONE, TWO }

@Serializable
object Singleton

@Serializable
sealed class Base

@Serializable
interface BareInterface

@Serializable
sealed interface SealedInterface

@Serializable
abstract class AbstractBase

@Serializable(with = CustomSerializer::class)
class Custom(val a: String)

@Serializable
@JvmInline
value class Wrapped(val a: String)

@Serializable
@SerialName("renamed")
data class Annotated(val a: String)

// Same-line forms: the regression that made the scanner skip types silently.
@Serializable data class SameLineData(val a: String)

@Serializable enum class SameLineEnum { A, B }

@Serializable(with = CustomSerializer::class) class SameLineCustom(val a: String)

@Serializable @JvmInline value class SameLineValue(val a: String)

@Serializable data class SpacedOut  (  val a: String )

class NotSerializable(val a: String)
'''

# @Serializable on a property is a use-site annotation, not a type declaration.
USE_SITE_FIXTURE = '''
package com.example

class Holder {
    @Serializable(with = CustomSerializer::class)
    val prop: Foo = Foo()
}
'''

failures = []


def check(label, actual, expected):
    if actual == expected:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}\n        expected: {expected}\n        actual:   {actual}")
        failures.append(label)


def scan(text):
    with tempfile.TemporaryDirectory() as d:
        (Path(d) / "Fixture.kt").write_text(text)
        return classify(d)


def main():
    required, exempt, unrecognized = scan(FIXTURE)
    exempt_names = [n for n, _ in exempt]

    print("Types REQUIRING a generated $$serializer:")
    for n in ("PlainData", "PlainClass", "Annotated"):
        check(f"{n} is required", n in required, True)

    print("Types generating NO $$serializer (bug 1):")
    for n in ("Kind", "Singleton", "Custom", "Base", "AbstractBase", "Wrapped",
              "BareInterface", "SealedInterface"):
        check(f"{n} is NOT required", n in required, False)
        check(f"{n} is reported exempt", n in exempt_names, True)

    print("Same-line annotations are seen at all (bug 2 — the silent skip):")
    check("SameLineData is required", "SameLineData" in required, True)
    check("SpacedOut is required", "SpacedOut" in required, True)
    check("SameLineEnum is exempt", "SameLineEnum" in exempt_names, True)
    check("SameLineCustom is exempt", "SameLineCustom" in exempt_names, True)
    check("SameLineValue is exempt", "SameLineValue" in exempt_names, True)
    for n in ("SameLineData", "SameLineEnum", "SameLineCustom", "SameLineValue", "SpacedOut"):
        check(f"{n} is never silently dropped",
              n in required or n in exempt_names, True)

    print("Nothing is left unrecognized:")
    check("no unrecognized declarations in the fixture", unrecognized, [])

    print("Non-types and unannotated types are ignored:")
    check("NotSerializable is ignored",
          "NotSerializable" in required or "NotSerializable" in exempt_names, False)
    _, use_exempt, use_unrec = scan(USE_SITE_FIXTURE)
    check("a @Serializable property is not treated as a type", use_unrec, [])
    check("a @Serializable property is not reported exempt",
          "prop" in [n for n, _ in use_exempt], False)

    print("The exact required set:")
    check("required set", sorted(required),
          ["Annotated", "PlainClass", "PlainData", "SameLineData", "SpacedOut"])

    print()
    if failures:
        print(f"{len(failures)} FAILED")
        return 1
    print("all passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
