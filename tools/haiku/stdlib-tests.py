#!/usr/bin/env python3
"""Write the manifest run-stdlib-tests.sh runs on Prose.

    tools/haiku/stdlib-tests.py > tests.tsv

Asks Bazel for the standard library's mojo_test targets and writes one line
a test, tab separated: the target's name, its source (relative to
Mojo/stdlib/test), the compiler flags, whether assertions are on, the
environment (K=V;K=V), the test's arguments, the dependencies beyond std and
test_utils, and "incompatible" when Bazel would not run it or "generated"
when its source is a build output. Each select() is taken at its default, which is what a Haiku
build without a GPU or sanitizers gets.
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


# The config_settings that hold for a Haiku build: the platform, and the
# compiler built from source (--config=build-mojo), not a prebuilt one.
TRUE_SETTINGS = (
    "@platforms//os:haiku",
    "//:haiku_aarch64",
    "//:use_prebuilt_mojo_toolchain_disabled",
)


def take_defaults(expr):
    """Replace each select({...}) with the branch of a setting that holds
    for a Haiku build, or else its //conditions:default value."""

    def default(match):
        for key in TRUE_SETTINGS + ("//conditions:default",):
            found = re.search('"' + re.escape(key) +
                              r'": (\[[^\]]*\]|\{[^}]*\})', match.group(1))
            if found:
                return found.group(1)
        return "[]"

    previous = None
    while previous != expr:
        previous = expr
        expr = re.sub(r"select\((\{(?:[^{}]|\{[^{}]*\})*\})\)", default, expr)
    return expr


def main():
    query = subprocess.run(
        ["./bazelw", "query", 'kind("mojo_test rule", //Mojo/stdlib/test/...)',
         "--output=build"],
        cwd=ROOT, check=True, capture_output=True, text=True).stdout

    rows = []
    for block in re.findall(r"^mojo_test\((.*?)^\)", query, re.S | re.M):
        def attr(name, empty):
            found = re.search(r"^\s+" + name + r" = (.*),$", block, re.M)
            if not found:
                return empty
            expr = take_defaults(found.group(1))
            if expr.startswith("{"):
                # Dictionaries joined with "+", which Python cannot add.
                merged = {}
                for part in re.findall(r"\{[^{}]*\}", expr):
                    merged.update(eval(part))
                return merged
            return eval(expr)

        name = attr("name", "")
        srcs = attr("srcs", [])
        # With several sources, the main file is the one the target is named
        # for, as in rules_mojo; the others are its modules, found from its
        # directory.
        if len(srcs) > 1:
            srcs = [s for s in srcs if s.endswith(":" + name.removesuffix(".test"))]
        (src,) = srcs
        package, _, file = src.partition(":")
        # A generated source (a genrule's output) is not in the tree.
        generated = not file.endswith(".mojo")
        src = (package.removeprefix("//Mojo/stdlib/test") + "/" + file).lstrip("/")
        copts = attr("copts", [])
        # enable_assertions defaults to True and is printed only when set.
        asserts = "no" if "enable_assertions = False" in block else "yes"
        env = attr("env", {})
        env = {k: v for k, v in env.items()
               if k != "GPU_ENV_DO_NOT_USE" and "$(" not in v}
        deps = [d for d in attr("deps", [])
                if d not in ("@mojo//:std", "@mojo//:test_utils")]
        # Incompatible with Haiku: marked so, or needing another OS.
        constraints = attr("target_compatible_with", [])
        incompatible = "@platforms//:incompatible" in constraints or any(
            c.startswith("@platforms//os:") and c != "@platforms//os:haiku"
            for c in constraints)
        args = attr("args", [])
        assert all(" " not in a for a in args), (name, args)
        rows.append("\t".join([
            name, src, " ".join(copts), asserts,
            ";".join(f"{k}={v}" for k, v in env.items()), " ".join(args),
            ",".join(deps),
            "incompatible" if incompatible else
            "generated" if generated else ""]))

    sys.stdout.write("".join(row + "\n" for row in sorted(rows)))


if __name__ == "__main__":
    main()
