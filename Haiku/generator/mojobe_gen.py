#!/usr/bin/env python3
# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""mojobe_gen: the Haiku bridge's generator (Haiku/docs/bridge-design.md,
section 10).

Reads the Haiku headers of the Prose sysroot through clang -- the build's
own, for aarch64-unknown-haiku -- and the annotations in bridge.toml, and
writes both halves of the bridge from that one model:

  Haiku/bridge/libmojobe/mojobe.h, mojobe.cpp   the C entry points and the
                                                shadow classes (C++)
  Haiku/bridge/haiku/_api.mojo, _values.mojo,   the `haiku` package's
  _constants.mojo, hooks.mojo, __init__.mojo    generated modules
  Haiku/bridge/MANIFEST.md                      every method, included or
                                                skipped, and why

Constants and layouts are not computed here: a probe file of `extern "C"`
globals is compiled to LLVM IR by the same clang, and the values read back.

Usage: mojobe_gen.py [--clang PATH] [--sysroot DIR] [--keep DIR]
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import struct
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
HAIKU_DIR = HERE.parent
ROOT = HAIKU_DIR.parent
BRIDGE = HAIKU_DIR / "bridge"
SNIPPETS = HERE / "snippets"

DEFAULT_SYSROOT = "/Volumes/HaikuSrc/mojoprose-sysroot-arm64"
DEFAULT_CLANG = ROOT / "bazel-MojoProse/external/+http_archive+clang-macos/bin/clang"

# C++ primitive types (desugared, aarch64 Haiku, LP64) and their Mojo types.
PRIMITIVES = {
    "bool": "Bool",
    "signed char": "Int8",
    "unsigned char": "UInt8",
    "short": "Int16",
    "unsigned short": "UInt16",
    "int": "Int32",
    "unsigned int": "UInt32",
    "long": "Int64",
    "unsigned long": "UInt64",
    "long long": "Int64",
    "unsigned long long": "UInt64",
    "float": "Float32",
    "double": "Float64",
}

MOJO_KEYWORDS = {
    "and", "as", "break", "comptime", "continue", "def", "deinit", "elif",
    "else", "except", "False", "finally", "fn", "for", "from", "global",
    "if", "import", "in", "is", "lambda", "mut", "None", "not", "or", "out",
    "owned", "pass", "raise", "raises", "read", "ref", "return", "self",
    "struct", "trait", "True", "try", "var", "while", "with", "alias",
    "assert", "async", "await", "borrowed", "class", "del", "import",
    "inout", "match", "nonlocal", "yield",
}


# ===----------------------------------------------------------------------=== #
# The AST, with the files of its locations
# ===----------------------------------------------------------------------=== #


class Locations:
    """Follows clang's JSON AST in document order. The dumper writes a
    location's file only when it changes, so the file of any location is
    the last one seen before it."""

    def __init__(self):
        self.file = None

    def _bare(self, loc):
        if not loc:
            return None
        if "file" in loc:
            self.file = loc["file"]
        if "offset" not in loc:
            return None
        return (self.file, loc["offset"], loc.get("tokLen", 0))

    def see(self, loc):
        """The (file, offset, token length) of a location, as written: the
        expansion's, for one inside a macro."""
        if not loc:
            return None
        if "spellingLoc" in loc or "expansionLoc" in loc:
            self._bare(loc.get("spellingLoc"))
            return self._bare(loc.get("expansionLoc"))
        return self._bare(loc)

    def walk(self, node):
        for key, value in list(node.items()):
            if key == "loc":
                where = self.see(value)
                if where:
                    node["_file"] = where[0]
            elif key == "range":
                begin = self.see(value.get("begin"))
                end = self.see(value.get("end"))
                if begin and end and begin[0] == end[0] and begin[0]:
                    node["_range"] = (begin[0], begin[1], end[1] + end[2])
            elif isinstance(value, dict):
                self.walk(value)
            elif isinstance(value, list):
                for item in value:
                    if isinstance(item, dict):
                        self.walk(item)


_sources = {}


def source_text(where):
    """The text of a (file, begin, end) range of a header."""
    if not where:
        return None
    path, begin, end = where
    if path not in _sources:
        try:
            _sources[path] = Path(path).read_bytes()
        except OSError:
            return None
    return _sources[path][begin:end].decode("utf-8", "replace")


# ===----------------------------------------------------------------------=== #
# Types
# ===----------------------------------------------------------------------=== #


# typedef name -> the type it names, as spelled; filled as the AST is read
TYPEDEFS = {}


class CType:
    """A C++ type as the AST spells it (`qual`), parsed into a base name,
    const-ness and indirection; `dbase` is the base with typedefs resolved
    (`int32 *` -> `int`), which clang's dump does not do below the top
    level."""

    def __init__(self, type_node):
        self.qual = type_node.get("qualType", "")
        self.base, self.const, self.pointers, self.reference = _parse(self.qual)

    @property
    def dbase(self):
        base = self.base
        for _ in range(16):
            if base not in TYPEDEFS:
                break
            resolved = _parse(TYPEDEFS[base])
            if resolved[2] or resolved[3]:
                break  # a typedef of a pointer: kept by its name
            base = resolved[0]
        return base

    def __repr__(self):
        return self.qual


def _parse(spelling):
    s = spelling.strip()
    reference = None
    if s.endswith("&&"):
        reference = "&&"
        s = s[:-2].strip()
    elif s.endswith("&"):
        reference = "&"
        s = s[:-1].strip()
    pointers = []  # const-ness of each pointer level, outermost last
    while True:
        if s.endswith("*const"):
            s = s[: -len("*const")].strip()
            pointers.append(True)
        elif s.endswith("*"):
            s = s[:-1].strip()
            pointers.append(False)
        else:
            break
    const = False
    words = s.split()
    if "const" in words:
        const = True
        words = [w for w in words if w != "const"]
    if "volatile" in words:
        words = [w for w in words if w != "volatile"]
    for tag in ("struct", "class", "enum", "union"):
        if words and words[0] == tag:
            words = words[1:]
    base = " ".join(words)
    if base.startswith("::"):
        base = base[2:]
    return base, const, pointers, reference


# ===----------------------------------------------------------------------=== #
# The model
# ===----------------------------------------------------------------------=== #


class Param:
    def __init__(self, node, index):
        self.name = node.get("name") or "arg%d" % index
        self.type = CType(node["type"])
        self.default = None
        if node.get("init") and node.get("inner"):
            text = source_text(node["inner"][0].get("_range"))
            # a copy-initialising default's range starts at its `=`
            self.default = (re.sub(r"^=\s*", "", " ".join(text.split()))
                            if text else None)


class Method:
    """A method, constructor or destructor of a class, as declared."""

    def __init__(self, node, owner, access):
        self.node = node
        self.kind = node["kind"]
        self.name = node.get("name", "")
        self.owner = owner  # the class that declares it
        self.access = access
        self.virtual = bool(node.get("virtual"))
        self.pure = bool(node.get("pure"))
        self.static = node.get("storageClass") == "static"
        self.implicit = bool(node.get("isImplicit"))
        self.deleted = bool(node.get("explicitlyDeleted"))
        signature = node.get("type", {}).get("qualType", "")
        self.variadic = "..." in signature
        self.const = bool(re.search(r"\)\s*const\b", signature))
        self.params = [
            Param(p, i)
            for i, p in enumerate(
                c for c in node.get("inner", []) if c["kind"] == "ParmVarDecl"
            )
        ]
        result = re.match(r"^(.*?)\s*\(", signature)
        self.result = (
            CType({"qualType": result.group(1)})
            if result and self.kind in ("CXXMethodDecl", "FunctionDecl")
            else None
        )
        self.result_node = None

    def cxx(self):
        """The declaration, for comments and the manifest."""
        args = ", ".join("%s %s" % (spelled(p.type), p.name) for p in self.params)
        head = ("%s::%s(%s)" % (self.owner, self.name, args) if self.owner
                else "%s(%s)" % (self.name, args))
        if self.result is not None:
            head = "%s %s" % (spelled(self.result), head)
        return head + (" const" if self.const else "")


def spelled(ctype):
    """A type as Haiku's sources write it: `BMessage*`, not `BMessage *`."""
    return re.sub(r"\s+([*&])", r"\1", ctype.qual).lstrip(":")


class Record:
    def __init__(self, node):
        self.node = node
        self.name = node["name"]
        self.kind = node.get("tagUsed", "class")
        self.file = node.get("_file")
        self.bases = [
            _parse(b["type"]["qualType"])[0]
            for b in node.get("bases", [])
            if b.get("access", "public") == "public"
        ]
        definition = node.get("definitionData", {})
        self.in_registers = bool(definition.get("canPassInRegisters"))
        self.abstract = bool(definition.get("isAbstract"))
        self.members = []  # Method
        self.fields = []  # (name, CType, access)
        access = "public" if self.kind == "struct" else "private"
        for child in node.get("inner", []):
            kind = child["kind"]
            if kind == "AccessSpecDecl":
                access = child["access"]
            elif kind in (
                "CXXMethodDecl",
                "CXXConstructorDecl",
                "CXXDestructorDecl",
            ):
                self.members.append(Method(child, self.name, access))
            elif kind == "FieldDecl":
                self.fields.append(
                    (child.get("name", ""), CType(child["type"]), access))


class Model:
    def __init__(self, ast):
        self.records = {}
        self.enums = {}  # enum type name -> [constant names]
        self.enum_of = {}  # constant name -> enum type name (or None)
        self.constant_files = {}  # constant name -> header
        self.integral_vars = {}  # const integral variable -> CType
        self.typedef_enums = {}  # typedef name -> enum name
        self.anonymous = {}  # id -> an anonymous record's node, or enum's constants
        self.header_defined = set()  # mangled names of methods defined after their class
        self.functions = {}  # name -> [Method], free functions
        for node in ast.get("inner", []):
            self._top(node)

    def _anonymous_in(self, node):
        """The anonymous record or enum a typedef names, if it names one:
        followed through elaborations only, never into a function's or a
        pointer's parts (a typedef of a function taking a color_space is not
        color_space)."""
        inner = node.get("inner", [])
        while inner:
            child = inner[0]
            for key in ("ownedTagDecl", "decl"):
                target = child.get(key)
                if isinstance(target, dict) and target.get("id") in self.anonymous:
                    return self.anonymous[target["id"]]
            if child.get("kind") not in ("ElaboratedType", "EnumType", "RecordType",
                                         "ParenType"):
                return None
            inner = child.get("inner", [])
        return None

    def _top(self, node):
        kind = node.get("kind")
        if kind in ("CXXMethodDecl", "CXXConstructorDecl") and (
                node.get("inline") or any(c.get("kind") == "CompoundStmt"
                                          for c in node.get("inner", []))):
            # defined in the header, after its class (`inline void
            # BView::ScrollTo(float x, float y) { ... }`)
            if node.get("mangledName"):
                self.header_defined.add(node["mangledName"])
        if kind == "LinkageSpecDecl":
            for child in node.get("inner", []):
                self._top(child)
        elif kind == "FunctionDecl" and node.get("name"):
            self.functions.setdefault(node["name"], []).append(
                Method(node, "", "public"))
        elif kind == "CXXRecordDecl" and node.get("completeDefinition"):
            if node.get("name"):
                self.records[node["name"]] = Record(node)
            else:
                # `typedef struct { ... } clipping_rect;`: named by its typedef
                self.anonymous[node["id"]] = node
        elif kind == "EnumDecl":
            name = node.get("name")
            constants = []
            for child in node.get("inner", []):
                if child["kind"] == "EnumConstantDecl":
                    constants.append(child["name"])
                    self.enum_of[child["name"]] = name
                    self.constant_files[child["name"]] = child.get(
                        "_file", node.get("_file")
                    )
            if name:
                self.enums[name] = constants
            else:
                # `typedef enum { ... } color_space;`: named by its typedef
                self.anonymous[node["id"]] = constants
        elif kind == "TypedefDecl":
            inner = node.get("inner", [])
            spelled = node.get("type", {}).get("qualType", "")
            TYPEDEFS[node["name"]] = spelled
            found = self._anonymous_in(node)
            if isinstance(found, list) and node["name"] not in self.enums:
                self.enums[node["name"]] = found
                for constant in found:
                    self.enum_of[constant] = node["name"]
            elif isinstance(found, dict) and node["name"] not in self.records:
                self.records[node["name"]] = Record(dict(found, name=node["name"]))
            match = re.match(r"^enum\s+(\w+)$", spelled)
            if match:
                self.typedef_enums[node["name"]] = match.group(1)
            elif inner and "decl" in inner[0] and inner[0]["decl"].get(
                "kind"
            ) == "EnumDecl":
                self.typedef_enums[node["name"]] = inner[0]["decl"].get("name")
        elif kind == "VarDecl":
            ctype = CType(node.get("type", {}))
            if (
                ctype.const
                and not ctype.pointers
                and not ctype.reference
                and (ctype.dbase in PRIMITIVES or ctype.dbase in self.enums)
                and ctype.dbase != "bool"
                and node.get("init")
            ):
                self.integral_vars[node["name"]] = ctype
                self.constant_files[node["name"]] = node.get("_file")

    def ancestors(self, name):
        """The public bases of a class, nearest first."""
        seen = []
        queue = list(self.records[name].bases) if name in self.records else []
        while queue:
            base = queue.pop(0)
            if base in seen or base not in self.records:
                continue
            seen.append(base)
            queue.extend(self.records[base].bases)
        return seen


# ===----------------------------------------------------------------------=== #
# Clang
# ===----------------------------------------------------------------------=== #


class Clang:
    def __init__(self, clang, sysroot):
        self.clang = clang
        self.sysroot = sysroot
        headers = Path(sysroot) / "boot/system/develop/headers"
        self.flags = [
            "-target",
            "aarch64-unknown-haiku",
            "--sysroot=%s" % sysroot,
            "-x",
            "c++",
            "-std=c++17",
            "-nostdinc++",
            "-isystem",
            str(headers / "c++"),
            "-isystem",
            str(headers / "c++/aarch64-unknown-haiku"),
            "-isystem",
            str(headers / "c++/backward"),
        ]

    def run(self, args, source):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / "tu.cpp"
            path.write_text(source)
            result = subprocess.run(
                [self.clang] + self.flags + args + [str(path)],
                capture_output=True,
                text=True,
            )
            return result

    def ast(self, includes):
        source = "".join("#include <%s>\n" % h for h in includes)
        result = self.run(["-fsyntax-only", "-Xclang", "-ast-dump=json"], source)
        if result.returncode != 0:
            sys.exit("mojobe_gen: clang could not parse the headers:\n"
                     + result.stderr[-4000:])
        return json.loads(result.stdout)

    def symbols(self, libraries):
        """The symbols the sysroot's libraries define."""
        nm = Path(os.path.realpath(self.clang)).parent / "llvm-nm"
        found = set()
        for library in libraries:
            path = Path(self.sysroot) / "boot/system/lib" / library
            result = subprocess.run([str(nm), "-D", "--defined-only", str(path)],
                                    capture_output=True, text=True)
            # versioned: _ZNK10BMessenger7IsValidEv@@LIBBE_BASE
            found.update(line.split()[-1].split("@")[0]
                         for line in result.stdout.splitlines() if line.strip())
        return found

    def macros(self, includes):
        source = "".join("#include <%s>\n" % h for h in includes)
        result = self.run(["-E", "-dM"], source)
        return result.stdout

    def ir(self, source):
        result = self.run(["-S", "-emit-llvm", "-o", "-"], source)
        if result.returncode != 0:
            sys.exit("mojobe_gen: the probe did not compile:\n"
                     + result.stderr[-6000:])
        return result.stdout


# ===----------------------------------------------------------------------=== #
# The probe: constants and layouts, evaluated by clang
# ===----------------------------------------------------------------------=== #

PROBE_HEAD = """
#include <stddef.h>
#include <type_traits>
template<typename T> constexpr int mojobe_kind()
{
	static_assert(std::is_arithmetic_v<T> || std::is_enum_v<T>,
		"not a number");
	if constexpr (std::is_floating_point_v<T>)
		return 100 + (int)sizeof(T);
	else if constexpr (std::is_enum_v<T>)
		return (std::is_signed_v<std::underlying_type_t<T>> ? -1 : 1)
			* (int)sizeof(T);
	else
		return (std::is_signed_v<T> ? -1 : 1) * (int)sizeof(T);
}
"""


def _constant_lines(i, name):
    return [
        'extern "C" const long long mojobe_v%d = (long long)(%s);' % (i, name),
        'extern "C" const int mojobe_k%d = mojobe_kind<std::decay_t<decltype(%s)>>();'
        % (i, name),
        'extern "C" const double mojobe_d%d = (double)(%s);' % (i, name),
    ]


def probe(clang, includes, names, values):
    """Evaluates constants and value type layouts with clang: returns
    ({name: (value, kind)}, {type: (size, align, [field offsets])}).
    `kind` is the byte size, negative when signed, or 100 + the size for
    floating point."""
    lines = ["#include <%s>" % h for h in includes] + [PROBE_HEAD]
    for i, name in enumerate(names):
        lines.extend(_constant_lines(i, name))
    for i, (name, fields) in enumerate(values):
        lines.append('extern "C" const long long mojobe_s%d = sizeof(%s);' % (i, name))
        lines.append('extern "C" const long long mojobe_a%d = alignof(%s);' % (i, name))
        for j, field in enumerate(fields):
            lines.append(
                'extern "C" const long long mojobe_o%d_%d = offsetof(%s, %s);'
                % (i, j, name, field))
    ir = clang.ir("\n".join(lines) + "\n")
    found = {}
    for match in re.finditer(
            r"^@mojobe_(\w+) = (?:dso_local )?constant i\d+ (-?\d+)", ir, re.M):
        found[match.group(1)] = int(match.group(2))
    for match in re.finditer(
            r"^@mojobe_(d\d+) = (?:dso_local )?constant double ([0-9A-Fa-fx.e+-]+)", ir, re.M):
        text = match.group(2)
        if text.startswith("0x"):
            value = struct.unpack(">d", bytes.fromhex(text[2:].rjust(16, "0")))[0]
        else:
            value = float(text)
        found[match.group(1)] = value
    constants = {}
    for i, name in enumerate(names):
        if "v%d" % i in found:
            kind = found.get("k%d" % i, -4)
            value = found["d%d" % i] if kind > 100 else found["v%d" % i]
            constants[name] = (value, kind)
    layouts = {}
    for i, (name, fields) in enumerate(values):
        layouts[name] = (
            found["s%d" % i],
            found["a%d" % i],
            [found["o%d_%d" % (i, j)] for j in range(len(fields))],
        )
    return constants, layouts


def probe_each(clang, includes, names):
    """The names that are numbers clang can evaluate: probed in halves,
    until the ones that fail are found and left out."""
    if not names:
        return []
    lines = ["#include <%s>" % h for h in includes] + [PROBE_HEAD]
    for i, name in enumerate(names):
        lines.extend(_constant_lines(i, name))
    result = clang.run(["-S", "-emit-llvm", "-o", "/dev/null"], "\n".join(lines))
    if result.returncode == 0:
        return list(names)
    if len(names) == 1:
        return []
    half = len(names) // 2
    return (probe_each(clang, includes, names[:half])
            + probe_each(clang, includes, names[half:]))


# ===----------------------------------------------------------------------=== #
# Mapping C++ to C and Mojo
# ===----------------------------------------------------------------------=== #


class Unbridged(Exception):
    """A declaration the bridge cannot carry (yet); the message says why."""


class Bridge:
    def __init__(self, model, config, constants, layouts):
        self.model = model
        self.config = config
        self.constants = constants
        self.layouts = layouts
        self.values = config.get("values", {})
        self.classes = config.get("classes", {})
        self.adopts = config.get("adopts", {})
        self.skips = config.get("skip", {})
        for name in list(self.values) + list(self.classes):
            if name not in model.records:
                sys.exit("mojobe_gen: %s is not in the headers" % name)
        self.typed_enums = {
            name for name, members in model.enums.items()
            if name and members and all(c in constants for c in members)
        }
        self.known_names = set(constants) | set(hand_written("_values.mojo", "comptime"))
        self.used_names = set()

    # ---- classification ----------------------------------------------------

    def enum_name(self, ctype):
        """The named enum a type is, if the bridge types it."""
        for base in (ctype.base, ctype.dbase):
            enum = self.model.typedef_enums.get(base, base)
            if enum in self.typed_enums:
                return enum
        return None

    def enum_mojo(self, enum):
        """A named enum's Mojo type: a struct of its own, so that overloads
        taking different enums stay apart (BWindow's two constructors)."""
        return enum

    def enum_int(self, enum):
        """The integer type under a named enum."""
        return mojo_int(0, self.constants[self.model.enums[enum][0]][1])[0]

    def mirrored(self, value):
        """Every value type crosses the C interface as a plain C struct of
        its fields: C++ passes BRect and BPoint (user-declared copy
        constructors) by hidden reference, and clang warns of rgb_color
        (member functions) in a C function's result."""
        return True

    def c_value(self, value):
        """A value type as the C interface carries it."""
        return "mojobe_%s" % value if self.mirrored(value) else value

    def classify(self, ctype):
        """(kind, detail) for a type: prim, char, enum, value, cstring,
        object, void, status."""
        if ctype.base == "status_t" and not ctype.pointers and not ctype.reference:
            return "status", None
        base = ctype.dbase
        if base == "void" and not ctype.pointers:
            return "void", None
        held = self.value_class(ctype)
        if held:
            # a class held in a Mojo value: crosses by address
            if not ctype.pointers and (not ctype.reference or ctype.const):
                return "valueobj", held
            if len(ctype.pointers) == 1:
                return ("valueobjptr" if ctype.const else "outvalueobj"), held
            return "unknown", None
        if not ctype.pointers:
            if base == "char":
                return "char", None
            if base in PRIMITIVES:
                return "prim", PRIMITIVES[base]
            enum = self.enum_name(ctype)
            if enum:
                return "enum", enum
            if ctype.base in self.values or base in self.values:
                return "value", ctype.base if ctype.base in self.values else base
            if ctype.base in self.classes or base in self.classes:
                return "object", ctype.base if ctype.base in self.classes else base
            return "unknown", None
        if len(ctype.pointers) == 1:
            if base == "char" and ctype.const:
                return "cstring", None
            if ctype.base in self.classes or base in self.classes:
                return "objectptr", ctype.base if ctype.base in self.classes else base
            if not ctype.const:
                if base == "char":
                    return "unknown", None  # a buffer, not one character
                if base in PRIMITIVES:
                    return "outprim", PRIMITIVES[base]
                enum = self.enum_name(ctype)
                if enum:
                    return "outenum", enum
                if ctype.base in self.values:
                    return "outvalue", ctype.base
        if len(ctype.pointers) == 2 and base == "char" and ctype.const:
            return "outcstring", None
        return "unknown", None

    def defined(self, method):
        """Whether a call can link: a virtual method is called through the
        vtable, an inline one is in the header; anything else must be in the
        libraries (Haiku declares a few methods it never wrote)."""
        node = method.node
        name = node.get("mangledName")
        if not name or method.virtual or node.get("inline") or any(
                c.get("kind") == "CompoundStmt" for c in node.get("inner", [])) \
                or name in self.model.header_defined:
            return True
        if method.kind == "CXXConstructorDecl":
            return name in self.symbols or name.replace("C1E", "C2E", 1) in self.symbols
        return name in self.symbols

    def span_element(self, ctype):
        """The Mojo element type of a `const T*` that can be a Span: bytes
        for void, a number, or a value type laid out as C's."""
        if not ctype.const or len(ctype.pointers) != 1 or ctype.reference:
            return None
        if ctype.dbase == "void":
            return "UInt8"
        if ctype.dbase in PRIMITIVES and ctype.dbase not in ("bool",):
            return PRIMITIVES[ctype.dbase]
        if ctype.base in self.values:
            return ctype.base
        return None

    def value_class(self, ctype):
        """The class a type names, if it is held in a Mojo value (kind
        "value": its copy and destructor do nothing more than copy bytes)."""
        for name in (ctype.base, ctype.dbase):
            if self.classes.get(name, {}).get("kind") == "value":
                return name
        return None

    def constant_type(self, name):
        if name not in self.constants:
            return None
        value, kind = self.constants[name]
        return mojo_int(value, kind)[0]

    def mojo_scalar(self, kind, detail):
        if kind == "prim":
            return detail
        if kind == "enum":
            return self.enum_mojo(detail)
        if kind == "value":
            return detail
        raise AssertionError(kind)

    # ---- defaults ----------------------------------------------------------

    def default(self, text, kind, detail):
        """A C++ default argument as Mojo, or None if it cannot be said."""
        if text is None:
            return None
        text = text.strip()
        if kind in ("objectptr",):
            if text in ("NULL", "nullptr", "0"):
                return "%sRef[ImmUntrackedOrigin]()" % detail
            return None
        if kind in ("valueobjptr", "valueobjmutptr"):
            return "None" if text in ("NULL", "nullptr", "0") else None
        if kind == "cstring":
            if text in ("NULL", "nullptr", "0"):
                return "None"
            if re.fullmatch(r'"[^"\\]*"', text):
                return text
            return None
        if kind == "char":
            if text in ("0", "'\\0'"):
                return '""'
            match = re.fullmatch(r"'(.)'", text)
            return '"%s"' % match.group(1) if match else None
        if kind in ("prim", "enum", "status"):
            if text in ("true", "false"):
                return "True" if text == "true" else "False"
            number = re.fullmatch(r"(-?(?:0x[0-9a-fA-F]+|\d+(?:\.\d*)?))[uUlLfF]*", text)
            if number:
                if kind == "enum":
                    return "%s(%s)" % (detail, number.group(1))
                return number.group(1)
            arithmetic = literal_arithmetic(text)
            if arithmetic is not None:
                return ("%s(%d)" % (detail, arithmetic) if kind == "enum"
                        else str(arithmetic))
            names = re.findall(r"[A-Za-z_]\w*", text)
            if not names or not all(n in self.known_names for n in names) \
                    or not re.fullmatch(r"[\w\s|()+<>-]+", text):
                return None
            enums = {self.model.enum_of.get(n) for n in names} & self.typed_enums
            wanted = {detail} if kind == "enum" else set()
            self.used_names.update(names)
            if enums == wanted and kind == "enum":
                return text
            if kind == "enum" or enums:
                if kind != "enum" and len(names) == 1:
                    # a typed enum's constant for an integer parameter
                    return "%s(%s.value)" % (detail, text)
                return None
            # integer constants: each converted to the parameter's type
            if all(self.constant_type(n) == detail for n in names):
                return text
            return re.sub(r"[A-Za-z_]\w*",
                          lambda m: "%s(%s)" % (detail, m.group(0)), text)
        if kind == "value":
            if text in self.known_names:
                self.used_names.add(text)
                return text
            return None
        return None

    # ---- methods ---------------------------------------------------------------

    def map_method(self, method, cls, is_ctor=False):
        """Maps a method (or constructor) for class `cls`: returns a dict
        describing its C and Mojo sides, or raises Unbridged."""
        key = "%s::%s" % (method.owner, method.name) if method.owner else method.name
        if key in self.skips:
            raise Unbridged(self.skips[key])
        overload = "%s(%s)" % (key, ", ".join(spelled(p.type) for p in method.params))
        if overload in self.skips:  # one overload: "BListView::RemoveItem(BListItem*)"
            raise Unbridged(self.skips[overload])
        if method.variadic:
            raise Unbridged("variadic")
        if not self.defined(method):
            raise Unbridged("declared in the header, but not defined in %s"
                            % ", ".join(self.libraries))
        adopted = set(self.adopts.get(key, []))
        inout = set(self.config.get("inout", {}).get(key, []))
        init_check = self.classes.get(cls, {}).get("init_check") if is_ctor else None
        params = []
        spans = {}    # a buffer's index -> its element's Mojo type
        lengths = {}  # a length parameter's index -> its buffer's name
        checked = self.config.get("checked_spans", {}).get(key, {})
        for index, param in enumerate(method.params):
            element = self.span_element(param.type)
            if element is None:
                continue
            if param.name in checked:
                spans[index] = element
                continue
            # its length: the next parameter, or the one before (a count)
            for other in (index + 1, index - 1):
                if 0 <= other < len(method.params) and other not in lengths \
                        and self.classify(method.params[other].type)[0] == "prim" \
                        and method.params[other].name in (
                            "length", "numBytes", "size", "bytes", "count"):
                    spans[index] = element
                    lengths[other] = param.name
                    break
        for index, param in enumerate(method.params):
            if index in spans:
                params.append({"role": "span", "p": param, "detail": spans[index],
                               "check": checked.get(param.name)})
                continue
            if index in lengths:
                params.append({"role": "spanlen", "p": param, "span": lengths[index],
                               "detail": self.classify(param.type)[1]})
                continue
            kind, detail = self.classify(param.type)
            if init_check and param.name == init_check and kind == "outprim":
                params.append({"role": "initcheck", "p": param})
                continue
            if kind == "unknown":
                if param.type.pointers and param.default in ("NULL", "nullptr", "0") \
                        and all(p.default for p in method.params[index:]):
                    params.append({"role": "null", "p": param})
                    continue
                raise Unbridged("parameter %s: %s is not bridged"
                                % (param.name, param.type.qual))
            if kind in ("void", "status"):
                if kind == "status":
                    kind, detail = "prim", "Int32"
                else:
                    raise Unbridged("parameter %s: void" % param.name)
            if kind == "object":
                if param.type.reference:
                    kind = "objectptr"
                else:
                    raise Unbridged("parameter %s: %s by value"
                                    % (param.name, param.type.qual))
            if kind == "outvalueobj" and param.name in self.config.get("in", {}).get(key, []):
                kind = "valueobjmutptr"  # a pointer the method reads
            if param.name in inout and param.type.pointers:
                raise Unbridged("changes %s in place; the overload that returns"
                                " the result is bridged" % param.name)
            role = "in"
            if kind.startswith("out"):
                role = "out"
            elif kind == "objectptr" and param.name in adopted:
                role = "adopt"
            if kind == "value" and param.type.pointers:
                raise Unbridged("parameter %s: pointer to a value" % param.name)
            params.append({"role": role, "kind": kind, "detail": detail, "p": param})
        # defaults: a suffix of in-parameters, all sayable
        last_bad = -1
        for index, entry in enumerate(params):
            if entry["role"] != "in":
                entry["mojo_default"] = None
                if entry["role"] in ("adopt", "span"):
                    last_bad = index
                continue
            entry["mojo_default"] = self.default(
                entry["p"].default, entry["kind"], entry["detail"])
            if entry["mojo_default"] is None:
                last_bad = index
        for index, entry in enumerate(params):
            if index <= last_bad and entry["role"] == "in":
                entry["mojo_default"] = None
        result = None
        if not is_ctor:
            rkind, rdetail = self.classify(method.result)
            if rkind == "object" and method.result.reference:
                rkind = "objectptr"
            if rkind == "objectptr" and key in self.config.get("factories", []):
                rkind = "owned"  # a new object, the caller's to delete
            if len(method.result.pointers) == 1 and not method.result.const \
                    and key in self.config.get("spans", {}):
                rkind, rdetail = "span", self.config["spans"][key]
            if rkind in ("unknown", "object", "valueobjptr") or rkind.startswith("out"):
                raise Unbridged("result: %s is not bridged" % method.result.qual)
            if rkind == "value" and method.result.pointers:
                raise Unbridged("result: pointer to a value")
            result = (rkind, rdetail, method.result.const)
        return {"method": method, "cls": cls, "params": params, "result": result,
                "ctor": is_ctor}


# ===----------------------------------------------------------------------=== #
# Emitting
# ===----------------------------------------------------------------------=== #


def hook_marker(cls):
    """The trait every hook trait of a class inherits (`ViewHooks`): what a
    Mojo type standing behind the class implements."""
    return "%sHooks" % (cls[1:] if cls.startswith("B") else cls)


def literal_arithmetic(text):
    """The value of integer arithmetic on literals (`256 * 1024`, `1 << 3`),
    or None."""
    if not re.fullmatch(r"[\d\s*+\-()<>|&xXa-fA-FuUlL]+", text) \
            or not re.search(r"[*+\-<>|&]", text):
        return None
    try:
        value = eval(re.sub(r"(?<=[\da-fA-F])[uUlL]+", "", text),
                     {"__builtins__": {}}, {})
    except Exception:
        return None
    return value if isinstance(value, int) else None


def hand_written(snippet, kind):
    """The public names a snippet defines at its top level: `comptime` constants,
    or `def`s and `struct`s."""
    path = SNIPPETS / snippet
    if not path.exists():
        return []
    words = ("comptime",) if kind == "comptime" else ("def", "struct")
    return [m.group(2) for m in re.finditer(r"^(%s) ([A-Za-z]\w*)" % "|".join(words),
                                             path.read_text(), re.M)]


def mojo_name(name):
    return name + "_" if name in MOJO_KEYWORDS else name


def type_tag(entries):
    """An overload's suffix, from its C parameter types."""
    parts = []
    for entry in entries:
        p = entry["p"]
        word = re.sub(r"\W", "", p.type.base) or "void"
        if p.type.pointers:
            word += "P" * len(p.type.pointers)
        parts.append(word)
    return "_".join(parts) or "void"


class Emitter:
    def __init__(self, bridge):
        self.b = bridge
        self.model = bridge.model
        self.manifest = {}  # class -> [(what, status, why)]
        self.h = []  # mojobe.h prototypes
        self.cpp = []  # mojobe.cpp entry points
        self.mojo = []  # _api.mojo
        self.hook_traits = []  # names for hooks.mojo
        self.entries = set()

    # ---- C side helpers -------------------------------------------------------

    def c_param(self, entry):
        """(C declaration, C++ argument expression) for a parameter."""
        p, kind, detail = entry["p"], entry.get("kind"), entry.get("detail")
        name = "a_" + p.name
        role = entry["role"]
        if role == "null":
            return None, "static_cast<%s>(NULL)" % p.type.qual
        if role == "span":
            return "%s %s" % (p.type.qual, name), name
        if role == "spanlen":
            spelled = p.type.qual.replace("const ", "").strip()
            return "%s %s" % (spelled, name), name
        if role == "initcheck":
            return "status_t* %s" % name, name
        if kind == "value":
            ctype = self.b.c_value(detail)
            if self.b.mirrored(detail):
                return "%s %s" % (ctype, name), "mojobe_from_c(%s)" % name
            return "%s %s" % (ctype, name), name
        if kind == "cstring":
            return "const char* %s" % name, name
        if kind == "char":
            return "char %s" % name, name
        if kind in ("prim", "enum"):
            spelled = p.type.qual.replace("const ", "").replace(" &", "").strip()
            if spelled.startswith("::"):
                spelled = spelled[2:]
            return "%s %s" % (spelled, name), name
        if kind == "objectptr":
            cls = detail
            if p.type.reference:
                return "%s* %s" % (cls, name), "*" + name
            return "%s* %s" % (cls, name), name
        if kind == "outprim" or kind == "outenum":
            spelled = p.type.qual.strip()
            return "%s %s" % (spelled, name), name
        if kind == "outvalue":
            if self.b.mirrored(detail):
                return "mojobe_%s* %s" % (detail, name), "&t_" + p.name
            return "%s* %s" % (detail, name), name
        if kind == "outcstring":
            return "const char** %s" % name, name
        if kind == "valueobj":
            return "const %s* %s" % (detail, name), "*" + name
        if kind == "valueobjptr":
            return "const %s* %s" % (detail, name), name
        if kind == "valueobjmutptr":
            return "%s* %s" % (detail, name), name
        if kind == "outvalueobj":
            return "%s* %s" % (detail, name), name
        raise AssertionError(kind)

    def c_result(self, result):
        kind, detail = result[0], result[1]
        if kind in ("void",):
            return "void"
        if kind == "status":
            return "status_t"
        if kind == "value":
            return self.b.c_value(detail)
        if kind == "cstring":
            return "const char*"
        if kind == "char":
            return "char"
        if kind in ("prim", "enum"):
            return {"Bool": "bool"}.get(PRIMITIVES.get(detail, ""), None) or (
                detail if kind == "enum" else _c_prim(detail))
        if kind == "objectptr":
            return ("const %s*" if result[2] else "%s*") % detail
        if kind == "valueobj":
            return "void"
        if kind == "span":
            return "void*"
        if kind == "owned":
            return "%s*" % detail
        raise AssertionError(kind)

    # ---- Mojo side helpers ----------------------------------------------------

    def mojo_param(self, entry):
        """(Mojo parameter declaration, argument expression, pre-call lines,
        post-call lines) for a parameter."""
        p, kind, detail, role = entry["p"], entry.get("kind"), entry.get("detail"), entry["role"]
        name = mojo_name(p.name)
        default = entry.get("mojo_default")
        suffix = " = " + default if default is not None else ""
        if role == "null":
            return None, None, [], []
        if role == "span":
            pre = []
            if entry.get("check"):
                # C++ reads as far as the other arguments say: never past
                # the end of what Mojo gives it
                pre = ["if len(%s) < %s:" % (name, entry["check"]),
                       '    raise Error("%s: %s is shorter than %s")'
                       % (self.current_method, name, entry["check"].replace('"', "'"))]
            return ("%s: Span[%s, _]" % (name, entry["detail"]),
                    "Int(%s.unsafe_ptr())" % name, pre, [])
        if role == "spanlen":
            return None, "%s(len(%s))" % (entry["detail"], mojo_name(entry["span"])), [], []
        if role == "initcheck":
            return None, "Pointer(to=_status)", ["var _status = Int32(-1)"], []
        if role == "adopt":
            return "var %s: %s" % (name, detail), "%s^._adopt()" % name, [], []
        if role == "out":
            if kind == "outprim":
                zero = "False" if detail == "Bool" else "%s(0)" % detail
                return None, "Pointer(to=%s)" % name, ["var %s = %s" % (name, zero)], []
            if kind == "outenum":
                mt = self.b.enum_mojo(detail)
                return None, "Pointer(to=%s)" % name, ["var %s = %s(0)" % (name, mt)], []
            if kind == "outvalue":
                return (None, "Pointer(to=%s)" % name,
                        ["var %s = %s" % (name, self.value_zero(detail))], [])
            if kind == "outcstring":
                return (None, "Pointer(to=%s_address)" % name,
                        ["var %s_address = 0" % name], [])
            if kind == "outvalueobj":
                return (None, "_address_of(%s)" % name,
                        ["var %s = %s._zeroed()" % (name, detail)], [])
        if kind in ("prim", "enum", "value"):
            return "%s: %s%s" % (name, self.b.mojo_scalar(kind, detail), suffix), name, [], []
        if kind in ("valueobjptr", "valueobjmutptr") and p.default in ("NULL", "nullptr", "0"):
            # a pointer C++ lets be NULL: an Optional value
            return ("var %s: Optional[%s] = None" % (name, detail), "%s_address" % name,
                    ["var %s_address = 0" % name,
                     "if %s:" % name,
                     "    %s_address = _address_of(%s.value())" % (name, name)],
                    ["_ = %s^" % name])
        if kind in ("valueobj", "valueobjptr", "valueobjmutptr"):
            return "%s: %s" % (name, detail), "_address_of(%s)" % name, [], []
        if kind == "char":
            return "%s: String%s" % (name, suffix), "_char(%s)" % name, [], []
        if kind == "cstring":
            if default == "None":
                return ("var %s: Optional[String] = None" % name, "%s_address" % name,
                        ["var %s_address = 0" % name,
                         "if %s:" % name,
                         "    %s_address = Int(%s.value().as_c_string_span().ptr())"
                         % (name, name)],
                        ["_ = %s^" % name])
            return ("var %s: String%s" % (name, suffix),
                    "%s.as_c_string_span()" % name, [], ["_ = %s^" % name])
        if kind == "objectptr":
            if default is not None:
                return ("%s: %sRef[_]%s" % (name, detail, suffix),
                        "_addr(%s._as_%s())" % (name, detail), [], [])
            return ("%s: Some[_As%s]" % (name, detail),
                    "_addr(%s._as_%s())" % (name, detail), [], [])
        raise AssertionError((kind, role))

    def value_zero(self, value):
        fields = self.value_fields(value)
        return "%s(%s)" % (value, ", ".join("%s(0)" % t for _, t in fields))

    def value_fields(self, value):
        override = self.b.values.get(value, {}).get("mojo_fields")
        if override:
            return [tuple(f) for f in override]
        record = self.model.records[value]
        fields = []
        for name, ctype, access in record.fields:
            kind, detail = self.b.classify(ctype)
            fields.append((name, self.b.mojo_scalar(kind, detail)))
        return fields

    def mojo_result(self, result):
        """(Mojo result type or None, external_call type, conversion)."""
        kind, detail = result[0], result[1]
        if kind == "void":
            return None, "NoneType", None
        if kind == "status":
            return None, "Int32", "status"
        if kind in ("prim", "enum", "value"):
            t = self.b.mojo_scalar(kind, detail)
            return t, t, None
        if kind == "cstring":
            return "String", "Int", "_string_from(%s)"
        if kind == "char":
            return "String", "c_char", "_string_from_char(%s)"
        if kind == "valueobj":
            # constructed by C++ in a value Mojo provides
            return detail, "NoneType", "valueobj"
        if kind == "owned":
            return detail, "Int", "owned"
        if kind == "span":
            # the bytes, as long as the method `detail` says, borrowed from
            # (and so no longer than) the object
            return ("Span[UInt8, origin_of(self).unsafe_mut_cast[True]()]", "Int",
                    "span:" + detail)
        if kind == "objectptr":
            # borrowed from what it was got from, which it keeps alive
            return ("%sRef[origin_of(self)]" % detail, "Int",
                    "%sRef[origin_of(self)](_ptr_from(%%s))" % detail)
        raise AssertionError(kind)

    # ---- one method -------------------------------------------------------------

    def emit_method(self, info, cls, entry_name, self_expr, indent, trait=True,
                    held=False, static=False, mirror=False, mojo_def=None):
        """C prototype, C++ entry point, and the Mojo method body. `held`:
        `cls` is held in a Mojo value, whose non-const methods take `mut
        self`."""
        method = info["method"]
        params = info["params"]
        self.current_method = ("%s::%s" % (method.owner, method.name) if method.owner
                               else method.name)
        c_params = ["%s* self" % cls] if cls and not static else []
        if mirror:
            # a value type: its methods run on a C++ copy of the mirror,
            # written back when they change it. A const one takes the value:
            # a register-passable `self` is a copy, and its address would
            # be a temporary's.
            c_params = ["mojobe_%s%s self" % (cls, "" if method.const else "*")]
        c_args = []
        pre_c = []
        post_c = []
        for entry in params:
            decl, arg = self.c_param(entry)
            if decl:
                c_params.append(decl)
            c_args.append(arg)
            if entry["role"] == "out" and entry["kind"] == "outvalue" \
                    and self.b.mirrored(entry["detail"]):
                pre_c.append("%s t_%s;" % (entry["detail"], entry["p"].name))
                post_c.append("if (a_%s != NULL)\n\t\t*a_%s = mojobe_to_c(t_%s);"
                              % (entry["p"].name, entry["p"].name, entry["p"].name))
        result = info["result"]
        c_ret = self.c_result(result)
        if mirror and method.const:
            call = "mojobe_from_c(self).%s(%s)" % (method.name, ", ".join(c_args))
        elif mirror:
            pre_c.insert(0, "%s value = mojobe_from_c(*self);" % cls)
            post_c.append("*self = mojobe_to_c(value);")
            call = "value.%s(%s)" % (method.name, ", ".join(c_args))
        elif cls is None:
            call = "::%s(%s)" % (method.name, ", ".join(c_args))
        elif static:
            call = "%s::%s(%s)" % (method.owner, method.name, ", ".join(c_args))
        elif method.owner == cls:
            call = "self->%s(%s)" % (method.name, ", ".join(c_args))
        else:
            # inherited from a class the bridge does not carry
            call = "static_cast<%s*>(self)->%s(%s)" % (
                method.owner, method.name, ", ".join(c_args))
        body = []
        body.extend(pre_c)
        kind = result[0]
        adopted = ["a_" + e["p"].name for e in params if e["role"] == "adopt"]
        if adopted and c_ret.endswith("*") and not post_c:
            # NULL: not taken (BLayout::AddView), and Mojo gave it up
            body.append("%s result = %s;" % (c_ret, call))
            body.append("if (result == NULL) {")
            body.extend("\tdelete %s;" % a for a in adopted)
            body.append("}")
            body.append("return result;")
        elif adopted and c_ret == "bool" and not post_c:
            # false: not taken, and the caller keeps it -- but Mojo already
            # gave it up (BMenu::AddItem of an index out of range)
            body.append("bool result = %s;" % call)
            body.append("if (!result) {")
            body.extend("\tdelete %s;" % a for a in adopted)
            body.append("}")
            body.append("return result;")
        elif kind == "valueobj":
            c_params.append("%s* a_result" % result[1])
            body.append("new(a_result) %s(%s);" % (result[1], call))
            body.extend(post_c)
        elif kind == "void":
            body.append(call + ";")
            body.extend(post_c)
        else:
            expr = call
            if kind == "value" and self.b.mirrored(result[1]):
                expr = "mojobe_to_c(%s)" % call
            if post_c:
                body.append("%s result = %s;" % (c_ret, expr))
                body.extend(post_c)
                body.append("return result;")
            else:
                body.append("return %s;" % expr)
        self.add_entry(c_ret, entry_name, c_params, body, method.cxx())
        # Mojo
        m_params = []
        m_args = [self_expr] if cls and not static else []
        if mirror and method.const:
            m_args = ["self"]
        pre = []
        post = []
        outs = []
        for entry in params:
            decl, arg, before, after = self.mojo_param(entry)
            if decl:
                m_params.append(decl)
            if arg is not None:
                m_args.append(arg)
            pre.extend(before)
            post.extend(after)
            if entry["role"] == "out":
                name = mojo_name(entry["p"].name)
                if entry["kind"] == "outcstring":
                    outs.append(("String", "_string_from(%s_address)" % name))
                elif entry["kind"] == "outenum":
                    outs.append((self.b.enum_mojo(entry["detail"]), name))
                else:
                    outs.append((entry["detail"], name))
        rtype, call_type, convert = self.mojo_result(result)
        raises = convert in ("status", "owned") or any(
            e.get("check") for e in params if e["role"] == "span")
        if static and rtype and "origin_of(self)" in rtype:
            # a static has no self to borrow from: what it returns lives
            # where the kit keeps it
            rtype = rtype.replace("origin_of(self)", "ImmUntrackedOrigin")
            convert = convert.replace("origin_of(self)", "ImmUntrackedOrigin")
        if convert == "valueobj":
            pre.insert(0, "var _result = %s._zeroed()" % rtype)
            m_args.append("_address_of(_result)")
            convert = None
        returned = []
        if rtype is not None:
            returned.append((rtype, None))
        returned.extend(outs)
        if not returned:
            signature_ret = ""
        elif len(returned) == 1:
            signature_ret = " -> " + returned[0][0]
        else:
            signature_ret = " -> Tuple[%s]" % ", ".join(t for t, _ in returned)
        # a reference result borrows from `self`, so `self` must be a
        # reference too, even for a register-passable Self
        self_decl = "ref self" if result[0] in ("objectptr", "span") else "self"
        if held and not method.const:
            self_decl = "mut self"
        head = "def %s(%s)%s%s:" % (
            mojo_def or mojo_name(method.name),
            ", ".join(([self_decl] if cls and not static else []) + m_params),
            " raises" if raises else "",
            signature_ret,
        )
        lines = [head, '    """`%s`."""' % method.cxx().replace("`", "'")]
        lines.extend("    " + l for l in pre)
        call_text = 'external_call["%s", %s](%s)' % (
            entry_name, call_type, ", ".join(m_args))
        if (rtype is None and not raises) or call_type == "NoneType":
            lines.append("    " + call_text)
        else:
            lines.append("    var _result = " + call_text)
        lines.extend("    " + l for l in post)
        if convert == "status":
            lines.append('    _check(_result, "%s")' % (
                "%s::%s" % (method.owner, method.name) if method.owner else method.name))
        values = []
        if convert == "owned":
            lines.append("    if _result == 0:")
            lines.append('        raise Error("%s::%s made nothing")' % (method.owner, method.name))
            lines.append("    return %s(_adopting=_result)" % rtype)
            return lines, [p for p in m_params]
        if convert and convert.startswith("span:"):
            lines.append("    if _result == 0:")
            lines.append("        return %s()" % rtype)
            lines.append("    return %s(" % rtype)
            lines.append("        unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](")
            lines.append("            unsafe_from_address=_result")
            lines.append("        ).unsafe_origin_cast[origin_of(self).unsafe_mut_cast[True]()](),")
            length = convert[len("span:"):]
            if "(" not in length:
                length = "self.%s()" % length  # a method's name
            lines.append("        length=Int(%s)," % length)
            lines.append("    )")
            return lines, [p for p in m_params]
        if rtype is not None:
            values.append(convert % "_result" if convert else "_result")
        values.extend(v for _, v in outs)
        if values:
            if len(values) == 1:
                lines.append("    return " + values[0])
            else:
                lines.append("    return (%s)" % ", ".join(values))
        return lines, [p for p in m_params]

    def add_entry(self, ret, name, params, body, comment, guard=True):
        """An entry point. `guard`: its body may throw, and no C++ exception
        may unwind into Mojo: bad_alloc becomes B_NO_MEMORY or a zero
        result, anything else a bridge bug for debugger() (design 7.1)."""
        if name in self.entries:
            raise Unbridged("entry point %s exists" % name)
        self.entries.add(name)
        if guard:
            body = ["try {"] + ["\t" + l for l in body] + [
                "} catch (const std::bad_alloc&) {",
                "\treturn%s;" % ("" if ret == "void" else
                                 " B_NO_MEMORY" if ret == "status_t" else " {}"),
                "} catch (...) {",
                '\tmojobe_unexpected("%s");' % name,
                "}"]
            if ret != "void":
                body.append("return %s;" % ("B_ERROR" if ret == "status_t" else "{}"))
        self.h.append("")
        self.h.append("// %s" % comment)
        one_line = "%s %s(%s);" % (ret, name, ", ".join(params))
        if len(one_line) <= 80:
            self.h.append(one_line)
        else:
            self.h.append("%s %s(%s,\n\t%s);" % (ret, name, params[0],
                                                ",\n\t".join(params[1:])))
        signature = "%s(%s)" % (name, ", ".join(params))
        if len(signature) > 80:
            signature = "%s(%s,\n\t%s)" % (name, params[0], ",\n\t".join(params[1:]))
        self.cpp.append("")
        self.cpp.append("// %s" % comment)
        self.cpp.append("%s\n%s\n{\n%s\n}\n"
                        % (ret, signature, "\n".join("\t" + l for l in body)))

    def mark(self, title):
        """A `#pragma mark` in both files, as Haiku's sources divide them."""
        for lines in (self.h, self.cpp):
            lines.extend(["", "", "// #pragma mark - %s" % title, ""])

    # ---- classes ----------------------------------------------------------------

    def bridged_bases(self, cls):
        """The nearest bridged class along each base path: BGroupLayout's is
        BLayout, through BTwoDimensionalLayout and BAbstractLayout, which the
        bridge does not carry (their methods come with BGroupLayout)."""
        found = []
        for base in self.model.records[cls].bases:
            if base in self.b.classes:
                if base not in found:
                    found.append(base)
            elif base in self.model.records:
                for above in self.bridged_bases(base):
                    if above not in found:
                        found.append(above)
        return found

    def bridged_ancestors(self, cls):
        return [a for a in self.model.ancestors(cls) if a in self.b.classes]

    def own_members(self, cls):
        """The methods a class's trait carries: its own, and those of its
        unbridged ancestors up to the bridged ones (whose traits it
        inherits)."""
        members = list(self.model.records[cls].members)
        queue = list(self.model.records[cls].bases)
        seen = set()
        while queue:
            base = queue.pop(0)
            if base in seen or base in self.b.classes or base not in self.model.records:
                continue
            seen.add(base)
            members.extend(self.model.records[base].members)
            queue.extend(self.model.records[base].bases)
        return members

    def inherited_signatures(self, cls):
        """The Mojo signatures a class's bridged ancestors' traits give it:
        name -> [(parameter types, required count, class)]."""
        found = {}
        for ancestor in self.bridged_ancestors(cls):
            for name, overloads in self.signatures.get(ancestor, {}).items():
                found.setdefault(name, []).extend(overloads)
        return found

    def signature(self, info):
        """(parameter types, required count) of a method's Mojo side."""
        types = []
        required = 0
        for entry in info["params"]:
            decl = self.mojo_param(entry)[0]
            if decl is None:
                continue
            types.append(re.sub(r"\s*=.*$", "", decl.split(":", 1)[1]).strip())
            if " = " not in decl:
                required = len(types)
        return tuple(types), required

    @staticmethod
    def ambiguous(one, other):
        """Whether a call could match both overloads: some argument count
        both take, with the same types that far."""
        (types, required), (other_types, other_required) = one, other
        for count in range(max(required, other_required),
                           min(len(types), len(other_types)) + 1):
            if types[:count] == other_types[:count]:
                return True
        return False

    OPERATORS = {
        ("operator+", 1): ("__add__", "add"),
        ("operator-", 1): ("__sub__", "sub"),
        ("operator-", 0): ("__neg__", "neg"),
        ("operator&", 1): ("__and__", "and"),
        ("operator|", 1): ("__or__", "or"),
    }

    def emit_value_methods(self, value):
        """A value type's methods (bridge.toml `methods = true`): the C++
        inline ones, compiled into libmojobe, so they are C++'s own."""
        self.mark(value)
        record = self.model.records[value]
        manifest = self.manifest.setdefault(value, [])
        fields = [f[1] for f in self.value_fields(value)]
        lines_all = []
        groups = {}
        for m in record.members:
            if m.access != "public" or m.implicit or m.deleted or m.static:
                continue
            if m.kind == "CXXConstructorDecl":
                try:
                    info = self.b.map_method(m, value, is_ctor=True)
                except Unbridged as why:
                    manifest.append((m.cxx(), "skipped", str(why)))
                    continue
                kinds = [(e.get("kind"), e.get("detail")) for e in info["params"]]
                if any(k == "value" and d == value for k, d in kinds):
                    manifest.append((m.cxx(), "skipped", "copy constructor: Mojo copies"))
                    continue
                if [self.b.mojo_scalar(k, d) if k in ("prim", "enum", "value") else None
                        for k, d in kinds] == fields:
                    manifest.append((m.cxx(), "skipped", "the fields' own constructor"))
                    continue
                groups.setdefault("__init__", []).append(info)
                continue
            if m.kind != "CXXMethodDecl":
                continue
            if m.name.startswith("operator"):
                if (m.name, len(m.params)) not in self.OPERATORS:
                    manifest.append((m.cxx(), "skipped", "operator (== is Equatable's)"
                                     if m.name in ("operator==", "operator!=") else "operator"))
                    continue
            try:
                info = self.b.map_method(m, value)
            except Unbridged as why:
                manifest.append((m.cxx(), "skipped", str(why)))
                continue
            groups.setdefault(m.name, []).append(info)
        for name, infos in groups.items():
            kept = []
            for info in infos:
                m = info["method"]
                signature = self.signature(info)
                if any(self.ambiguous(signature, other) for other in kept):
                    manifest.append((m.cxx(), "skipped", "a call would match another overload too"))
                    continue
                kept.append(signature)
                tag = ""
                if len(infos) > 1:
                    tag = "__" + type_tag([e for e in info["params"] if e["role"] != "null"])
                if name == "__init__":
                    lines_all.append(self.value_type_ctor(value, info, tag))
                    continue
                mojo_def, c_word = self.OPERATORS.get((name, len(m.params)), (None, name))
                entry = "mojobe_%s_%s%s" % (value, c_word, tag)
                try:
                    lines, _ = self.emit_method(info, value, entry, "_address_of(self)", "",
                                                held=True, mirror=True, mojo_def=mojo_def)
                except Unbridged as why:
                    manifest.append((m.cxx(), "skipped", str(why)))
                    continue
                lines_all.append(lines)
                manifest.append((m.cxx(), "included", entry))
        self.value_methods[value] = lines_all

    def value_type_ctor(self, value, info, tag):
        m = info["method"]
        entry = "mojobe_%s_new%s" % (value, tag)
        c_params, c_args = [], []
        for e in info["params"]:
            decl, arg = self.c_param(e)
            if decl:
                c_params.append(decl)
            c_args.append(arg)
        self.add_entry("mojobe_%s" % value, entry, c_params,
                       ["return mojobe_to_c(%s(%s));" % (value, ", ".join(
                           a for a in c_args if a is not None))], m.cxx())
        self.manifest[value].append((m.cxx(), "included", entry))
        params, args, pre, post = [], [], [], []
        for e in info["params"]:
            decl, arg, before, after = self.mojo_param(e)
            if decl:
                params.append(decl)
            if arg is not None:
                args.append(arg)
            pre.extend(before)
            post.extend(after)
        lines = ["def __init__(%s):" % ", ".join(["out self"] + params),
                 '    """`%s`."""' % m.cxx().replace("`", "'")]
        lines.extend("    " + l for l in pre)
        lines.append('    self = external_call["%s", Self](%s)' % (entry, ", ".join(args)))
        lines.extend("    " + l for l in post)
        return lines

    def emit_functions(self):
        """The free functions bridge.toml names (find_directory)."""
        names = self.b.config.get("functions", [])
        if not names:
            return
        self.mark("Functions")
        manifest = self.manifest.setdefault("Functions", [])
        for name in names:
            infos = []
            for f in self.model.functions.get(name, []):
                try:
                    infos.append(self.b.map_method(f, None))
                except Unbridged as why:
                    manifest.append((f.cxx(), "skipped", str(why)))
            kept = []
            for info in infos:
                signature = self.signature(info)
                if any(self.ambiguous(signature, other) for other in kept):
                    manifest.append((info["method"].cxx(), "skipped",
                                     "a call would match another overload too"))
                    continue
                kept.append(signature)
                tag = ""
                if len(infos) > 1:
                    tag = "__" + type_tag([e for e in info["params"]
                                           if e["role"] not in ("null",)])
                entry = "mojobe_%s%s" % (name, tag)
                lines, _ = self.emit_method(info, None, entry, None, "")
                self.functions.append(lines)
                manifest.append((info["method"].cxx(), "included", entry))

    def emit_value_class(self, cls):
        """A class held in a Mojo value (kind "value"): C++ constructs it in
        the value's bytes and its methods take the value's address."""
        self.mark(cls)
        conf = self.b.classes[cls]
        record = self.model.records[cls]
        manifest = self.manifest.setdefault(cls, [])
        size, align, _ = self.b.layouts[cls]
        field_type = {1: "UInt8", 2: "UInt16", 4: "Int32", 8: "Int64"}[align]
        fields = ["_%d" % i for i in range(size // align)]
        method_lines = []
        equals = False
        groups = {}
        for m in record.members:
            if m.kind != "CXXMethodDecl" or m.access != "public" \
                    or m.implicit or m.deleted:
                continue
            if m.name == "operator==" and len(m.params) == 1 \
                    and self.b.value_class(m.params[0].type) == cls:
                entry = "mojobe_%s_equals" % cls
                self.add_entry("bool", entry, ["const %s* self" % cls,
                                               "const %s* other" % cls],
                               ["return *self == *other;"], m.cxx())
                equals = True
                manifest.append((m.cxx(), "included", entry + ", as __eq__"))
                continue
            if m.name.startswith("operator"):
                manifest.append((m.cxx(), "skipped", "operator"))
                continue
            if m.static:
                manifest.append((m.cxx(), "skipped", "static"))
                continue
            try:
                info = self.b.map_method(m, cls)
            except Unbridged as why:
                manifest.append((m.cxx(), "skipped", str(why)))
                continue
            groups.setdefault(m.name, []).append(info)
        mine = {}
        for name, infos in groups.items():
            for info in infos:
                m = info["method"]
                signature = self.signature(info)
                if any(self.ambiguous(signature, other)
                       for other in mine.get(name, [])):
                    manifest.append((m.cxx(), "skipped",
                                     "a call would match another overload too"))
                    continue
                tag = ""
                if len(infos) > 1:
                    tag = "__" + type_tag([e for e in info["params"]
                                           if e["role"] not in ("null",)])
                entry_name = "mojobe_%s_%s%s" % (cls, name, tag)
                try:
                    lines, _ = self.emit_method(info, cls, entry_name,
                                                "_address_of(self)", "    ",
                                                held=True)
                except Unbridged as why:
                    manifest.append((m.cxx(), "skipped", str(why)))
                    continue
                mine.setdefault(name, []).append(signature)
                method_lines.append(lines)
                manifest.append((m.cxx(), "included", entry_name))
        # constructors
        ctor_infos = []
        for m in record.members:
            if m.kind != "CXXConstructorDecl" or m.access != "public" \
                    or m.implicit or m.deleted:
                continue
            if any(self.b.value_class(p.type) == cls for p in m.params):
                manifest.append((m.cxx(), "skipped", "copy constructor: Mojo copies"))
                continue
            try:
                ctor_infos.append(self.b.map_method(m, cls, is_ctor=True))
            except Unbridged as why:
                manifest.append((m.cxx(), "skipped", str(why)))
        ctor_infos.sort(key=lambda info: not any(
            e["role"] == "initcheck" for e in info["params"]))
        kept, ctor_lines = [], []
        for info in ctor_infos:
            m = info["method"]
            signature = self.signature(info)
            if any(self.ambiguous(signature, other) for other in kept):
                manifest.append((m.cxx(), "skipped",
                                 "a call would match another constructor too"))
                continue
            kept.append(signature)
            ctor_lines.append(self.value_ctor(cls, info, size, align,
                                              len(ctor_infos) > 1))
        self.write_value_class(cls, conf, size, align, field_type, fields,
                               ctor_lines, method_lines, equals)

    def value_ctor(self, cls, info, size, align, overloaded):
        m = info["method"]
        check = self.b.classes[cls].get("init_check")
        checks = any(e["role"] == "initcheck" for e in info["params"])
        tag = ""
        if overloaded:
            tag = "__" + type_tag([e for e in info["params"] if e["role"] != "null"])
        entry = "mojobe_%s_new%s" % (cls, tag)
        c_params, c_args = ["%s* self" % cls], []
        for e in info["params"]:
            decl, arg = self.c_param(e)
            if decl:
                c_params.append(decl)
            c_args.append("&status" if checks and arg == "a_" + str(check) else arg)
        if checks:
            body = ["status_t status = B_NO_MEMORY;",
                    "new(self) %s(%s);" % (cls, ", ".join(c_args)),
                    "if (a_%s != NULL)" % check,
                    "\t*a_%s = status;" % check]
        else:
            body = ["new(self) %s(%s);" % (cls, ", ".join(c_args))]
        self.add_entry("void", entry, c_params, body, m.cxx())
        self.manifest[cls].append((m.cxx(), "included", entry))
        params, args, pre, post = [], ["_address_of(self)"], [], []
        for e in info["params"]:
            decl, arg, before, after = self.mojo_param(e)
            if decl:
                params.append(decl)
            if arg is not None:
                args.append(arg)
            pre.extend(before)
            post.extend(after)
        lines = ["def __init__(%s)%s:" % (", ".join(["out self"] + params),
                                         " raises" if checks else ""),
                 '    """`%s`."""' % m.cxx().replace("`", "'"),
                 "    comptime assert size_of[Self]() == %d" % size,
                 "    comptime assert align_of[Self]() == %d" % align,
                 "    self = Self(_zeroed=True)"]
        lines.extend("    " + l for l in pre)
        lines.append('    external_call["%s", NoneType](%s)' % (entry, ", ".join(args)))
        lines.extend("    " + l for l in post)
        if checks:
            lines.append('    _check(_status, "%s")' % cls)
        return lines

    def write_value_class(self, cls, conf, size, align, field_type, fields,
                          ctor_lines, method_lines, equals):
        out = self.mojo
        out.append("")
        out.append("# " + "=" * 74 + " #")
        out.append("# %s" % cls)
        out.append("# " + "=" * 74 + " #")
        out.append("")
        out.append("")
        traits = ["ImplicitlyCopyable", "Movable"]
        if equals:
            traits.insert(0, "Equatable")
        out.append("struct %s(%s):" % (cls, ", ".join(traits)))
        out.append('    """A `%s`, held in this value: C++ constructs it in these %d bytes,'
                   % (cls, size))
        out.append("    and it is copied as bytes and needs no destructor, as its own copy")
        out.append('    constructor and destructor do."""')
        out.append("")
        for field in fields:
            out.append("    var %s: %s" % (field, field_type))
        out.append("")
        out.append("    def __init__(out self, *, _zeroed: Bool):")
        out.append('        """The bytes, all zero, for C++ to construct into."""')
        for field in fields:
            out.append("        self.%s = 0" % field)
        out.append("")
        out.append("    @staticmethod")
        out.append("    def _zeroed() -> Self:")
        out.append("        return Self(_zeroed=True)")
        for lines in ctor_lines + method_lines:
            out.append("")
            out.extend("    " + l for l in lines)
        if equals:
            out.append("")
            out.append("    def __eq__(self, other: Self) -> Bool:")
            out.append('        """`%s::operator==`."""' % cls)
            out.append('        return external_call["mojobe_%s_equals", Bool]('
                       "_address_of(self), _address_of(other))" % cls)
        snippet = SNIPPETS / ("%s.mojo" % cls)
        if snippet.exists():
            out.append("")
            out.extend(("    " + l if l.strip() else "")
                       for l in snippet.read_text().rstrip("\n").split("\n"))

    def emit_class(self, cls):
        if self.b.classes[cls].get("kind") == "value":
            return self.emit_value_class(cls)
        self.mark(cls)
        conf = self.b.classes[cls]
        record = self.model.records[cls]
        manifest = self.manifest.setdefault(cls, [])
        hands_over = set(conf.get("hands_over", []))
        hooks = conf.get("hooks", []) if conf.get("shadow") else []
        trait_lines = []
        ref_extra = []
        owned_extra = []
        inherited = self.inherited_signatures(cls)
        mine = {}
        groups = {}
        members = [m for m in self.own_members(cls)
                   if m.kind == "CXXMethodDecl" and m.access == "public"]
        # a hand-over method a bridged base declares (BGamePane's Show, a
        # BWindow's): its owned struct needs it too
        for name in hands_over:
            if not any(m.name == name for m in members):
                for owner in self.model.ancestors(cls):
                    found = [m for m in self.model.records[owner].members
                             if m.name == name and m.kind == "CXXMethodDecl"
                             and m.access == "public" and not m.static]
                    if found:
                        members.extend(found)
                        break
        # most-derived first: a redeclaration hides the base's
        seen_c = set()
        for m in members:
            if m.name.startswith("operator"):
                manifest.append((m.cxx(), "skipped", "operator"))
                continue
            if m.implicit or m.deleted:
                continue
            if m.static:
                if m.owner != cls or m.name == "Instantiate":
                    manifest.append((m.cxx(), "skipped", "static" if m.owner == cls
                                     else "a static of %s" % m.owner))
                    continue
                try:
                    info = self.b.map_method(m, cls)
                    entry_name = "mojobe_%s_%s" % (cls, m.name)
                    lines, _ = self.emit_method(info, cls, entry_name, None, "",
                                                static=True)
                except Unbridged as why:
                    manifest.append((m.cxx(), "skipped", str(why)))
                    continue
                owned_extra.append(["@staticmethod"] + lines)
                manifest.append((m.cxx(), "included", entry_name + ", static"))
                continue
            ckey = (m.name, tuple(p.type.qual for p in m.params), m.const)
            if ckey in seen_c:
                continue
            seen_c.add(ckey)
            try:
                info = self.b.map_method(m, cls)
            except Unbridged as why:
                manifest.append((m.cxx(), "skipped", str(why)))
                continue
            groups.setdefault(m.name, []).append(info)
        for name, infos in groups.items():
            for info in infos:
                m = info["method"]
                signature = self.signature(info)
                clash = None
                for types, required, owner in inherited.get(mojo_name(name), []):
                    if self.ambiguous(signature, (types, required)):
                        clash = "reached through %s's %s" % (owner, name)
                        break
                for types, required, owner in mine.get(mojo_name(name), []):
                    if clash is None and self.ambiguous(signature, (types, required)):
                        clash = "a call would match another overload too"
                if clash:
                    manifest.append((m.cxx(), "skipped", clash))
                    continue
                tag = ""
                if len(infos) > 1:
                    tag = "__" + type_tag([e for e in info["params"]
                                           if e["role"] not in ("null",)])
                entry_name = "mojobe_%s_%s%s" % (cls, name, tag)
                try:
                    lines, mparams = self.emit_method(
                        info, cls, entry_name,
                        '_nonnull(self._as_%s(), "%s::%s")' % (cls, cls, name), "    ")
                except Unbridged as why:
                    manifest.append((m.cxx(), "skipped", str(why)))
                    continue
                if name in hands_over:
                    # not in the trait, so not inherited: a subclass's own
                    # (BApplication::Run over BLooper::Run) is no override
                    ref_extra.append(lines)
                    owned_extra.append(self.handover(lines, cls))
                else:
                    mine.setdefault(mojo_name(name), []).append(
                        signature + (cls,))
                    trait_lines.append(lines)
                manifest.append((m.cxx(), "included", entry_name))
        combined = {}
        for table in (inherited, mine):
            for key, overloads in table.items():
                combined.setdefault(key, []).extend(overloads)
        self.signatures[cls] = combined
        # public fields
        field_lines = []
        for fname, ftype, access in record.fields:
            if access != "public":
                continue
            kind, detail = self.b.classify(ftype)
            if kind not in ("prim", "enum", "value"):
                manifest.append(("%s::%s (field)" % (cls, fname), "skipped",
                                 "field type %s" % ftype.qual))
                continue
            ctype = self.b.c_value(detail) if kind == "value" else ftype.qual
            getter = "mojobe_%s_get_%s" % (cls, fname)
            setter = "mojobe_%s_set_%s" % (cls, fname)
            conv = "mojobe_to_c(self->%s)" % fname if kind == "value" and self.b.mirrored(detail) else "self->%s" % fname
            self.add_entry(ctype, getter, ["%s* self" % cls], ["return %s;" % conv],
                           "%s::%s (read)" % (cls, fname), guard=False)
            setv = "mojobe_from_c(value)" if kind == "value" and self.b.mirrored(detail) else "value"
            self.add_entry("void", setter, ["%s* self" % cls, "%s value" % ctype],
                           ["self->%s = %s;" % (fname, setv)], "%s::%s (write)" % (cls, fname),
                           guard=False)
            mt = self.b.mojo_scalar(kind, detail)
            field_lines.append([
                "def get_%s(self) -> %s:" % (fname, mt),
                '    """`%s::%s`."""' % (cls, fname),
                '    return external_call["%s", %s](_nonnull(self._as_%s(), "%s::%s"))'
                % (getter, mt, cls, cls, fname),
            ])
            field_lines.append([
                "def set_%s(self, value: %s):" % (fname, mt),
                '    """`%s::%s`."""' % (cls, fname),
                '    external_call["%s", NoneType](_nonnull(self._as_%s(), "%s::%s"), value)'
                % (setter, cls, cls, fname),
            ])
            manifest.append(("%s::%s (field)" % (cls, fname), "included",
                             "get_%s, set_%s" % (fname, fname)))
        trait_lines.extend(field_lines)
        self.emit_casts(cls)
        ctor_lines, shadow_ctor_lines = self.emit_constructors(cls)
        hook_parts = self.emit_hooks(cls, hooks) if hooks else None
        self.write_mojo_class(cls, trait_lines, ref_extra, owned_extra, ctor_lines,
                              shadow_ctor_lines, hook_parts)

    def handover(self, lines, cls):
        """A method that hands the object to the system, for the owned
        struct: it consumes the value."""
        head = lines[0].replace("(self", "(deinit self", 1)
        body = [l.replace("_nonnull(self._as_%s(), " % cls, "_nonnull(self._ptr, ") for l in lines[1:]]
        return [head] + body

    # ---- casts ------------------------------------------------------------------

    def descendants(self, cls):
        return [c for c in self.b.classes if cls in self.bridged_ancestors(c)]

    def emit_casts(self, cls):
        for ancestor in self.bridged_ancestors(cls):
            self.add_entry("%s*" % ancestor, "mojobe_%s_as_%s" % (cls, ancestor),
                           ["%s* self" % cls], ["return self;"],
                           "%s* as %s*" % (cls, ancestor), guard=False)
        for descendant in self.descendants(cls):
            self.add_entry("%s*" % descendant, "mojobe_%s_to_%s" % (cls, descendant),
                           ["%s* self" % cls],
                           ["return dynamic_cast<%s*>(self);" % descendant],
                           "%s* as %s*, or NULL" % (cls, descendant), guard=False)

    # ---- constructors -------------------------------------------------------------

    def emit_constructors(self, cls):
        conf = self.b.classes[cls]
        record = self.model.records[cls]
        manifest = self.manifest[cls]
        plain = []
        shadow = []
        ctors = [m for m in record.members if m.kind == "CXXConstructorDecl"
                 and m.access == "public" and not m.implicit and not m.deleted]
        infos = []
        for m in ctors:
            if record.abstract:
                manifest.append((m.cxx(), "skipped", "abstract: pure virtual methods"))
                continue
            if len(m.params) == 1 and m.params[0].type.base == "BMessage" \
                    and m.params[0].type.pointers:
                manifest.append((m.cxx(), "skipped", "archive constructor"))
                continue
            if any(p.type.base == cls and not p.type.pointers for p in m.params):
                manifest.append((m.cxx(), "skipped", "copy constructor"))
                continue
            try:
                info = self.b.map_method(m, cls, is_ctor=True)
            except Unbridged as why:
                manifest.append((m.cxx(), "skipped", str(why)))
                continue
            infos.append(info)
        # a constructor that reports its status comes before one that
        # cannot, and then any that a call could not tell from one before
        infos.sort(key=lambda info: not any(
            e["role"] == "initcheck" for e in info["params"]))
        kept = []
        for info in infos:
            signature = self.signature(info)
            if any(self.ambiguous(signature, other) for other in kept):
                manifest.append((info["method"].cxx(), "skipped",
                                 "a call would match another constructor too"))
                continue
            kept.append(signature)
            info["keep"] = True
        infos = [info for info in infos if info.get("keep")]
        for info in infos:
            m = info["method"]
            tag = ""
            if len(infos) > 1:
                tag = "__" + type_tag([e for e in info["params"] if e["role"] not in ("null",)])
            c_params, c_args = [], []
            for entry in info["params"]:
                decl, arg = self.c_param(entry)
                if decl:
                    c_params.append(decl)
                c_args.append(arg)
            check = conf.get("init_check") if any(
                e["role"] == "initcheck" for e in info["params"]) else None
            if str(conf.get("init_check", "")).endswith("()"):
                # the class reports through a method (InitCheck()), and the
                # entry through a status parameter of its own
                check = conf["init_check"]
            status = ["status_t* _status"] if check and check.endswith("()") else []
            # plain
            name = "mojobe_%s_new%s" % (cls, tag)
            if conf.get("owns_items"):
                # always the bridge's subclass, whose destructor deletes the
                # items: with no hooks when there is no Mojo state
                body = self.ctor_body(cls, "Mojo" + cls, c_args, check,
                                      ["&kNoHooks", "NULL"])
                body.insert(0, "static const mojobe_%s_hooks kNoHooks = {};" % cls)
            else:
                body = self.ctor_body(cls, cls, c_args, check, [])
            self.add_entry("%s*" % cls, name, c_params + status, body, m.cxx())
            plain.append(self.mojo_ctor(cls, info, name, False))
            manifest.append((m.cxx(), "included", name))
            if conf.get("shadow"):
                sname = "mojobe_Mojo%s_new%s" % (cls, tag)
                extra = ["const mojobe_%s_hooks* hooks" % cls, "void* context"]
                body = self.ctor_body(cls, "Mojo" + cls, c_args, check, ["hooks", "context"])
                self.add_entry("%s*" % cls, sname, c_params + extra + status, body,
                               m.cxx() + ", as a Mojo" + cls)
                shadow.append((info, self.mojo_ctor(cls, info, sname, True), c_params, c_args))
        # destructor
        destroy = conf.get("destroy")
        if destroy == "quit":
            self.add_entry("void", "mojobe_%s_destroy" % cls, ["%s* self" % cls],
                           ["if (self->Lock())", "\tself->Quit();"],
                           "deletes a %s that was never handed over: locked, then Quit()" % cls)
        else:
            self.add_entry("void", "mojobe_%s_delete" % cls, ["%s* self" % cls],
                           ["delete self;"], "~%s()" % cls, guard=False)
        self.shadow_ctors[cls] = shadow
        return plain, shadow

    def ctor_body(self, cls, make, c_args, check, extra):
        """A constructor's entry point. With `check`, the constructor reports
        its status there -- a parameter, or a method such as InitCheck() --
        and an object that failed is deleted."""
        if check and check.endswith("()"):
            args = [a for a in c_args if a is not None] + extra
            return ["status_t status = B_NO_MEMORY;",
                    "%s* object = new(std::nothrow) %s(%s);" % (cls, make, ", ".join(args)),
                    "if (object != NULL) {",
                    "\tstatus = object->%s;" % check,
                    "\tif (status != B_OK) {",
                    "\t\tdelete object;",
                    "\t\tobject = NULL;",
                    "\t}",
                    "}",
                    "*_status = status;",
                    "return object;"]
        if not check:
            args = [a for a in c_args if a is not None] + extra
            return ["return new(std::nothrow) %s(%s);" % (make, ", ".join(args))]
        args = ["&status" if a == "a_" + check else a
                for a in c_args if a is not None] + extra
        return ["status_t status = B_NO_MEMORY;",
                "%s* object = new(std::nothrow) %s(%s);" % (cls, make, ", ".join(args)),
                "if (object != NULL && status != B_OK) {",
                "\tdelete object;",
                "\tobject = NULL;",
                "}",
                "if (a_%s != NULL)" % check,
                "\t*a_%s = status;" % check,
                "return object;"]

    def mojo_ctor(self, cls, info, entry_name, shadow):
        params, args, pre, post = [], [], [], []
        for entry in info["params"]:
            decl, arg, before, after = self.mojo_param(entry)
            if decl:
                params.append(decl)
            if arg is not None:
                args.append(arg)
            pre.extend(before)
            post.extend(after)
        lines = []
        conf = self.b.classes[cls]
        if shadow:
            # the state goes after the parameters without defaults
            split = len(params)
            for index, decl in enumerate(params):
                if " = " in decl:
                    split = index
                    break
            params = params[:split] + ["var state: T"] + params[split:]
            # T must stand behind the class (implement one of its hooks):
            # an unconstrained T would take any argument, and BLooper("x")
            # would make a looper whose Mojo state is "x"
            head = "def __init__[T: %s & Movable & Deinitable](%s) raises:" % (
                hook_marker(cls), ", ".join(["out self"] + params))
        else:
            head = "def __init__(%s) raises:" % ", ".join(["out self"] + params)
        lines.append(head)
        lines.append('    """`%s`%s."""' % (info["method"].cxx().replace("`", "'"),
                                            ", its hooks those of `state`" if shadow else ""))
        if cls in self.b.config.get("layout_check", ["BApplication"]):
            lines.append("    _check_layouts()")
        if shadow:
            lines.append("    var hooks = _%s_hooks[T]()" % cls)
            lines.append("    var context = _to_heap(state^)")
            args = args + ["Pointer(to=hooks)", "context"]
        method_check = str(conf.get("init_check", "")).endswith("()")
        if method_check:
            pre = ["var _status = Int32(-1)"] + pre
            args = args + ["Pointer(to=_status)"]
        lines.extend("    " + l for l in pre)
        lines.append('    var address = external_call["%s", Int](%s)' % (entry_name, ", ".join(args)))
        lines.extend("    " + l for l in post)
        lines.append("    if address == 0:")
        if shadow:
            lines.append("        _destroy[T](context)")
        if method_check or any(e["role"] == "initcheck" for e in info["params"]):
            lines.append('        _check(_status, "%s")' % cls)
        lines.append('        raise Error("%s could not be made")' % cls)
        lines.append("    self._ptr = _ptr_from(address)")
        return lines

    # ---- hooks --------------------------------------------------------------------

    def find_hook(self, cls, name):
        for owner in [cls] + self.model.ancestors(cls):
            record = self.model.records.get(owner)
            if not record:
                continue
            for m in record.members:
                if m.kind == "CXXMethodDecl" and m.name == name and m.virtual:
                    return m
        return None

    def hook_param(self, p):
        """(Mojo trait type, trampoline type, conversion, C hook type,
        C++ -> C expression) for a hook parameter."""
        kind, detail = self.b.classify(p.type)
        if kind == "object" and p.type.reference:
            kind = "objectptr"
        if kind in ("prim", "enum"):
            mt = self.b.mojo_scalar(kind, detail)
            spelled = p.type.qual.replace("const ", "").strip()
            return mt, mt, "%s", spelled, p.name
        if kind == "value":
            ctype = self.b.c_value(detail)
            conv = "mojobe_to_c(%s)" % p.name if self.b.mirrored(detail) else p.name
            return detail, detail, "%s", ctype, conv
        if kind == "cstring":
            return "String", "Int", "_string_from(%s)", "const char*", p.name
        if kind == "objectptr":
            expr = "&%s" % p.name if p.type.reference else p.name
            if p.type.const:
                expr = "const_cast<%s*>(%s)" % (detail, expr)
            return ("%sRef[_]" % detail, "Int",
                    "%sRef[origin_of(call)](_ptr_from(%%s))" % detail, "%s*" % detail, expr)
        raise Unbridged("hook parameter %s: %s" % (p.name, p.type.qual))

    def emit_hooks(self, cls, hooks):
        prefix = cls[1:] if cls.startswith("B") else cls
        subject = prefix[0].lower() + prefix[1:]
        table_c = ["struct mojobe_%s_hooks {" % cls, "\tuint64\ttype;",
                   "\tvoid\t(*destroy)(void* context);"]
        shadow_methods = []
        base_entries = []
        mojo_traits = []
        mojo_table_fields = []
        trampolines = []
        builder = []
        ref_base = []
        manifest = self.manifest[cls]
        for hook in hooks:
            m = self.find_hook(cls, hook)
            if m is None:
                sys.exit("mojobe_gen: %s has no virtual %s" % (cls, hook))
            try:
                parts = [self.hook_param(p) for p in m.params]
                rkind, rdetail = self.b.classify(m.result)
                if rkind not in ("void", "prim"):
                    raise Unbridged("hook result %s" % m.result.qual)
            except Unbridged as why:
                manifest.append(("hook " + m.cxx(), "skipped", str(why)))
                continue
            ret_c = "void" if rkind == "void" else m.result.qual
            ret_m = None if rkind == "void" else PRIMITIVES[m.result.dbase]
            self.hook_signatures.setdefault(cls, []).append(
                (hook, m, [self.b.classify(p.type) for p in m.params], ret_m))
            c_types = ", ".join(["void* context", "%s* self" % cls] + [
                "%s %s" % (t[3], p.name) for p, t in zip(m.params, parts)])
            line = "\t%s\t(*%s)(%s);" % (ret_c, hook, c_types)
            if len(line.expandtabs(4)) > 80:
                types = c_types.split(", ")
                line = "\t%s\t(*%s)(%s,\n\t\t\t%s);" % (
                    ret_c, hook, types[0], ",\n\t\t\t".join(types[1:]))
            table_c.append(line)
            # the shadow's override
            decl_params = ", ".join("%s %s" % (p.type.qual, p.name) for p in m.params)
            names = ", ".join(p.name for p in m.params)
            call_args = ", ".join(["fContext", "this"] + [t[4] for t in parts])
            const = " const" if m.const else ""
            if rkind == "void":
                body = ["if (fHooks.%s == NULL || !fDepth.Enter(\"%s\")) {" % (hook, hook),
                        "\t%s::%s(%s);" % (cls, hook, names),
                        "\treturn;", "}",
                        "fHooks.%s(%s);" % (hook, call_args),
                        "fDepth.Leave();"]
            else:
                body = ["if (fHooks.%s == NULL || !fDepth.Enter(\"%s\"))" % (hook, hook),
                        "\treturn %s::%s(%s);" % (cls, hook, names),
                        "%s result = fHooks.%s(%s);" % (ret_c, hook, call_args),
                        "fDepth.Leave();",
                        "return result;"]
            shadow_methods.append("\tvirtual %s %s(%s)%s\n\t{\n%s\n\t}\n"
                                  % (ret_c, hook, decl_params, const,
                                     "\n".join("\t\t" + l for l in body)))
            # base entry
            base_params = ["%s* self" % cls]
            base_args = []
            for p, part in zip(m.params, parts):
                ctype = part[3]
                base_params.append("%s %s" % (ctype, p.name))
                kind, detail = self.b.classify(p.type)
                if kind == "value" and self.b.mirrored(detail):
                    base_args.append("mojobe_from_c(%s)" % p.name)
                elif kind == "object" or (kind == "objectptr" and p.type.reference):
                    base_args.append("*" + p.name)
                else:
                    base_args.append(p.name)
            entry = "mojobe_%s_base_%s" % (cls, hook)
            self.add_entry(ret_c, entry, base_params,
                           ["%sself->%s::%s(%s);" % ("" if rkind == "void" else "return ",
                                                     cls, hook, ", ".join(base_args))],
                           "%s's own %s" % (cls, hook))
            # Mojo: trait
            trait = "%s%s" % (prefix, hook)
            self.hook_traits.append(trait)
            arg_decls = ["mut self", "%s: %sRef[_]" % (subject, cls)] + [
                "%s: %s" % (mojo_name(p.name), part[0]) for p, part in zip(m.params, parts)]
            mojo_traits.append([
                "trait %s(%s):" % (trait, hook_marker(cls)),
                '    """`%s`: a hook of %s."""' % (m.cxx(), cls),
                "",
                "    def %s(%s)%s:" % (hook, ", ".join(arg_decls),
                                       " -> %s" % ret_m if ret_m else ""),
                "        ...",
            ])
            mojo_table_fields.append(hook)
            tramp_params = ["context: _Ptr", "%s: Int" % subject] + [
                "%s: %s" % (mojo_name(p.name), part[1]) for p, part in zip(m.params, parts)]
            conv_args = ["%sRef[origin_of(call)](_ptr_from(%s))" % (cls, subject)] + [
                part[2] % mojo_name(p.name) for p, part in zip(m.params, parts)]
            call = "context.unsafe_bitcast[T]()[].%s(%s)" % (hook, ", ".join(conv_args))
            # the references borrow from `call`, which ends with the hook
            trampolines.append([
                "def _%s_%s[T: %s](%s) abi(\"C\")%s:" % (
                    cls, hook, trait, ", ".join(tramp_params),
                    " -> %s" % ret_m if ret_m else ""),
                "    var call = _HookCall()",
                "    %s%s" % ("var result = " if ret_m else "", call),
                "    _ = call^",
            ] + (["    return result"] if ret_m else []))
            builder.append("    comptime if conforms_to(T, %s):" % trait)
            builder.append("        hooks.%s = _fn_ptr(_%s_%s[downcast[T, %s]])"
                           % (hook, cls, hook, trait))
            # Ref: base_ call
            base_decl = ["self"] + ["%s: %s" % (mojo_name(p.name), part[0])
                                    for p, part in zip(m.params, parts)]
            base_args_m = ['_nonnull(self._ptr, "%s::%s")' % (cls, hook)]
            for p, part in zip(m.params, parts):
                if part[1] == "Int" and part[0].endswith("Ref[_]"):
                    base_args_m.append("_addr(%s._ptr)" % mojo_name(p.name))
                elif part[0] == "String":
                    base_args_m.append("%s.as_c_string_span()" % mojo_name(p.name))
                else:
                    base_args_m.append(mojo_name(p.name))
            ref_base.append([
                "def base_%s(%s)%s:" % (hook, ", ".join(base_decl),
                                        " -> %s" % ret_m if ret_m else ""),
                '    """`%s::%s`, the class\'s own."""' % (cls, hook),
                '    %sexternal_call["%s", %s](%s)' % (
                    "return " if ret_m else "", entry, ret_m or "NoneType",
                    ", ".join(base_args_m)),
            ])
            manifest.append(("hook " + m.cxx(), "included", trait))
        table_c.append("};")
        return {"table_c": table_c, "shadow_methods": shadow_methods,
                "traits": mojo_traits, "fields": mojo_table_fields,
                "trampolines": trampolines, "builder": builder, "ref_base": ref_base}

    # ---- Mojo class text ------------------------------------------------------------

    def write_mojo_class(self, cls, trait_lines, ref_extra, owned_extra, ctor_lines,
                         shadow_ctors, hooks):
        conf = self.b.classes[cls]
        out = self.mojo
        bases = self.bridged_bases(cls)
        ancestors = self.bridged_ancestors(cls)
        descendants = [c for c in self.b.classes if cls in self.bridged_ancestors(c)]
        out.append("")
        out.append("# " + "=" * 74 + " #")
        out.append("# %s" % cls)
        out.append("# " + "=" * 74 + " #")
        out.append("")
        out.append("")
        if bases:
            out.append("trait _As%s(%s):" % (cls, ", ".join("_As%s" % b for b in bases)))
        else:
            out.append("trait _As%s:" % cls)
        out.append('    """Has a `%s*` for libmojobe."""' % cls)
        out.append("")
        out.append("    def _as_%s(self) -> _NPtr:" % cls)
        out.append("        ...")
        out.append("")
        out.append("")
        out.append("trait _%sMethods(%s):" % (cls, ", ".join(
            ["_As%s" % cls] + ["_%sMethods" % b for b in bases])))
        out.append('    """`%s`\'s methods, for its references and the values Mojo'
                   ' owns."""' % cls)
        for lines in trait_lines:
            out.append("")
            out.extend("    " + l for l in lines)
        if not trait_lines:
            out.append("")
            out.append("    pass")
        out.append("")
        out.append("")
        # casts, shared by the Ref and the owned struct
        casts = []
        casts.append("def _as_%s(self) -> _NPtr:" % cls)
        casts.append("    return self._ptr")
        for ancestor in ancestors:
            casts.append("")
            casts.append("def _as_%s(self) -> _NPtr:" % ancestor)
            casts.append('    return _ptr_from(external_call["mojobe_%s_as_%s", Int](_addr(self._ptr)))'
                         % (cls, ancestor))
        # the reference
        ref_fields = conf.get("ref_fields", [])
        out.append("struct %sRef[origin: ImmOrigin]("
                   "Boolable, ImplicitlyCopyable, RegisterPassable, _%sMethods):"
                   % (cls, cls))
        out.append('    """A `%s` the kit owns, borrowed from `origin`: a hook\'s call, or'
                   % cls)
        out.append("    the value or reference it was got from, which it keeps alive. It")
        out.append('    may be NULL: test it with `if`."""')
        out.append("")
        out.append("    var _ptr: _NPtr")
        for field in ref_fields:
            ftype = [f for f in self.model.records[cls].fields if f[0] == field][0][1]
            kind, detail = self.b.classify(ftype)
            out.append("    var %s: %s" % (field, self.b.mojo_scalar(kind, detail)))
            out.append('    """`%s::%s`, read when the reference was made."""' % (cls, field))
        out.append("")
        out.append("    def __init__(out self):")
        out.append('        """A NULL reference: `%sRef[ImmUntrackedOrigin]()`."""' % cls)
        out.append("        self._ptr = None")
        for field in ref_fields:
            ftype = [f for f in self.model.records[cls].fields if f[0] == field][0][1]
            kind, detail = self.b.classify(ftype)
            out.append("        self.%s = 0" % field)
        out.append("")
        out.append("    def __init__(out self, ptr: _NPtr):")
        out.append("        self._ptr = ptr")
        for field in ref_fields:
            ftype = [f for f in self.model.records[cls].fields if f[0] == field][0][1]
            kind, detail = self.b.classify(ftype)
            mt = self.b.mojo_scalar(kind, detail)
            out.append('        self.%s = external_call["mojobe_%s_get_%s", %s](_addr(ptr)) if ptr else 0'
                       % (field, cls, field, mt))
        for d in descendants:
            out.append("")
            out.append("    @implicit")
            out.append("    def __init__(out self, other: %sRef[Self.origin]):" % d)
            out.append('        """A `%s` is a `%s`."""' % (d, cls))
            out.append("        self = %sRef[Self.origin](other._as_%s())" % (cls, cls))
        out.append("")
        out.append("    def __bool__(self) -> Bool:")
        out.append("        return Bool(self._ptr)")
        out.append("")
        out.append("    def unsafe_untracked(self) -> %sRef[ImmUntrackedOrigin]:" % cls)
        out.append('        """The same reference, borrowed from nothing: the compiler no')
        out.append("        longer keeps what it was got from alive, and it may be kept")
        out.append("        anywhere. Use it only while the object exists, and in its")
        out.append('        looper\'s hooks or with the looper locked."""')
        out.append("        return %sRef[ImmUntrackedOrigin](self._ptr)" % cls)
        out.append("")
        for d in descendants:
            out.append("    def as_%s(ref self) -> %sRef[origin_of(self)]:" % (d, d))
            out.append('        """This `%s` as a `%s`: NULL if it is not one."""' % (cls, d))
            out.append("        return %sRef[origin_of(self)](_ptr_from(external_call["
                       '"mojobe_%s_to_%s", Int](_addr(self._ptr))))' % (d, cls, d))
            out.append("")
        out.extend("    " + l for l in casts)
        for lines in ref_extra:
            out.append("")
            out.extend("    " + l for l in lines)
        if hooks:
            out.append("")
            out.append("    def state[T: Movable & Deinitable](self) raises -> ref["
                       "Self.origin.unsafe_mut_cast[True]()] T:")
            out.append('        """The Mojo value the %s was made from, borrowed as this' % cls)
            out.append("        reference is (the C++ object owns it; nothing else in Mojo")
            out.append("        does).")
            out.append("")
            out.append("        Raises:")
            out.append("            When it was not made from a `T`.")
            out.append('        """')
            out.append('        return _state_at[T, Self.origin.unsafe_mut_cast[True]()]('
                       'external_call["mojobe_Mojo%s_context", Int]('
                       '_addr(self._ptr), _type_tag[T]()), "%s")' % (cls, cls))
            for lines in hooks["ref_base"]:
                out.append("")
                out.extend("    " + l for l in lines)
        out.append("")
        out.append("")
        # the owned struct
        kind = conf.get("kind", "owned")
        out.append("struct %s(Movable, _%sMethods):" % (cls, cls))
        if kind == "self-owning":
            out.append('    """A `%s` Mojo made. It owns itself once handed over (%s);'
                       ' until then, Mojo deletes it."""' % (cls, ", ".join(conf.get("hands_over", []))))
        else:
            out.append('    """A `%s` Mojo owns, until something adopts it."""' % cls)
        out.append("")
        out.append("    var _ptr: _NPtr")
        for lines in ctor_lines:
            out.append("")
            out.extend("    " + l for l in lines)
        for info, lines, _, _ in shadow_ctors:
            out.append("")
            out.extend("    " + l for l in lines)
        # an owned value becomes its base's only if both end the same way:
        # a BWindow must not become a BHandler that Mojo deletes
        def ending(c):
            return (self.b.classes[c].get("kind", "owned"),
                    self.b.classes[c].get("destroy", "delete"))
        for d in [d for d in descendants if ending(d) == ending(cls)]:
            out.append("")
            out.append("    @implicit")
            out.append("    def __init__(out self, var other: %s):" % d)
            out.append('        """A `%s` is a `%s`: this one takes it over."""' % (d, cls))
            out.append('        self._ptr = _ptr_from(external_call["mojobe_%s_as_%s", Int](other^._adopt()))'
                       % (d, cls))
        out.append("")
        out.append("    def __deinit__(deinit self):")
        if conf.get("destroy") == "quit":
            out.append('        external_call["mojobe_%s_destroy", NoneType](_addr(self._ptr))' % cls)
        else:
            out.append('        external_call["mojobe_%s_delete", NoneType](_addr(self._ptr))' % cls)
        out.append("")
        out.append("    def __init__(out self, *, _adopting: Int):")
        out.append('        """Takes over an object C++ made for the caller (a factory\'s)."""')
        out.append("        self._ptr = _ptr_from(_adopting)")
        out.append("")
        out.append("    def _adopt(deinit self) -> Int:")
        out.append('        """Hands the object over without deleting it."""')
        out.append("        return _addr(self._ptr)")
        out.append("")
        out.extend("    " + l for l in casts)
        for lines in owned_extra:
            out.append("")
            out.extend("    " + l for l in lines)
        for d in descendants:
            out.append("")
            out.append("    def as_%s(ref self) -> %sRef[origin_of(self)]:" % (d, d))
            out.append('        """This `%s` as a `%s`, borrowed: NULL if it is not one."""'
                       % (cls, d))
            out.append("        return %sRef[origin_of(self)](_ptr_from(external_call["
                       '"mojobe_%s_to_%s", Int](_addr(self._ptr))))' % (d, cls, d))
        if hooks:
            out.append("")
            out.append("    def state[T: Movable & Deinitable](ref self) raises -> ref["
                       "origin_of(self).unsafe_mut_cast[True]()] T:")
            out.append('        """The Mojo value the %s was made from, borrowed from this' % cls)
            out.append("        value.")
            out.append("")
            out.append("        Raises:")
            out.append("            When it was not made from a `T`.")
            out.append('        """')
            out.append('        return _state_at[T, origin_of(self).unsafe_mut_cast[True]()]('
                       'external_call["mojobe_Mojo%s_context", Int]('
                       '_addr(self._ptr), _type_tag[T]()), "%s")' % (cls, cls))
            self.write_hook_tables(cls, hooks)

    def write_hook_tables(self, cls, hooks):
        out = self.mojo
        out.append("")
        out.append("")
        out.append("trait %s:" % hook_marker(cls))
        out.append('    """A Mojo type that stands behind a `%s`: it implements one or'
                   % cls)
        out.append("    more of the hook traits, each of which inherits this one. Making a")
        out.append("    `%s` with such a value as its state builds its hook table." % cls)
        out.append('    """')
        out.append("")
        out.append("    pass")
        self.hook_traits.append(hook_marker(cls))
        for lines in hooks["traits"]:
            out.append("")
            out.append("")
            out.extend(lines)
        out.append("")
        out.append("")
        out.append("struct _%sHooks(ImplicitlyCopyable, RegisterPassable):" % cls)
        out.append('    """`mojobe_%s_hooks`, laid out as C\'s."""' % cls)
        out.append("")
        out.append("    var type: UInt64")
        out.append("    var destroy: _FnPtr")
        for f in hooks["fields"]:
            out.append("    var %s: _FnPtr" % f)
        out.append("")
        out.append("    def __init__(out self):")
        out.append("        self.type = 0")
        out.append("        self.destroy = {}")
        for f in hooks["fields"]:
            out.append("        self.%s = {}" % f)
        for lines in hooks["trampolines"]:
            out.append("")
            out.append("")
            out.extend(lines)
        out.append("")
        out.append("")
        out.append("def _%s_hooks[T: Movable & Deinitable]() -> _%sHooks:" % (cls, cls))
        out.append('    """`T`\'s hooks for a `%s`: a slot for each hook it implements,'
                   ' NULL for the rest, decided at compile time."""' % cls)
        out.append("    var hooks = _%sHooks()" % cls)
        out.append("    hooks.type = _type_tag[T]()")
        out.append("    hooks.destroy = _fn_ptr(_destroy[T])")
        out.extend(hooks["builder"])
        out.append("    return hooks")
        self.shadow_parts[cls] = hooks


def _groups(line):
    """The top-level (start, end) parenthesis pairs of a line, outside
    strings."""
    groups, depth, start, quote = [], 0, 0, None
    for index, char in enumerate(line):
        if quote:
            if char == quote and line[index - 1] != "\\":
                quote = None
        elif char in "\"'":
            quote = char
        elif char in "([":
            if depth == 0:
                start = index
            depth += 1
        elif char in ")]":
            depth -= 1
            if depth == 0:
                groups.append((start, index))
    return groups


def _split_args(text):
    args, depth, current, quote = [], 0, "", None
    for index, char in enumerate(text):
        if quote:
            if char == quote and text[index - 1] != "\\":
                quote = None
        elif char in "\"'":
            quote = char
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            args.append(current.strip())
            current = ""
            continue
        current += char
    if current.strip():
        args.append(current.strip())
    return args


def wrap(line, width=80):
    """A Mojo line too long, as `mojo format` would break it: the last
    call or signature's arguments one to a line."""
    if len(line) <= width or line.lstrip().startswith(('"""', "#")):
        return [line]
    indent = line[: len(line) - len(line.lstrip())]
    groups = [(start, end) for start, end in _groups(line)
              if line[start] == "(" and end - start >= 3
              and not line[:start].endswith("abi")]
    if line.lstrip().startswith("def "):
        groups = groups[:1]  # the parameters
    for start, end in reversed(groups):
        args = _split_args(line[start + 1:end])
        if not args:
            continue
        head = line[: start + 1]
        tail = line[end:]
        inner = indent + "    "
        lines = [head]
        for arg in args:
            lines.extend(wrap(inner + arg + ",", width))
        lines.append(indent + tail)
        if len(head) > width:
            head_lines = wrap(head[:-1] + ")", width)
            if len(head_lines) > 1:
                continue
        return lines
    return [line]


def wrap_all(lines, width=80):
    out = []
    for line in lines:
        out.extend(wrap(line, width))
    return out


def _c_prim(mojo):
    return {"Bool": "bool", "Int8": "int8", "UInt8": "uint8", "Int16": "int16",
            "UInt16": "uint16", "Int32": "int32", "UInt32": "uint32", "Int64": "int64",
            "UInt64": "uint64", "Float32": "float", "Float64": "double"}[mojo]


# ===----------------------------------------------------------------------=== #
# Files
# ===----------------------------------------------------------------------=== #

LICENSE_C = """/*
 * Copyright 2026, MojoProse. All rights reserved.
 * Distributed under the terms of the Apache License v2.0 with LLVM Exceptions.
 *
 * Generated by Haiku/generator/mojobe_gen.py from the Haiku headers and
 * bridge.toml. Do not edit: change the generator or its annotations.
 */
"""

LICENSE_MOJO = """# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Generated by Haiku/generator/mojobe_gen.py from the Haiku headers and
# bridge.toml. Do not edit: change the generator or its annotations.
# ===----------------------------------------------------------------------=== #
"""

UNEXPECTED = """
/*!	A C++ exception other than bad_alloc reached an entry point: a bridge
	bug. It must not unwind into Mojo's frames, so it stops here.
*/
void
mojobe_unexpected(const char* entry)
{
	char text[256];
	snprintf(text, sizeof(text),
		"mojobe: %s: a C++ exception reached the bridge", entry);
	debugger(text);
}

"""

HOOK_DEPTH = """
/*!	Counts the hooks of one object that are running, so that a hook entered
	again on the same object -- AddChild() calling AttachedToWindow(), say --
	goes to the base class instead of into Mojo a second time: two live
	`mut self` borrows of one Mojo value are not allowed (design section 9).
*/
class HookDepth {
public:
	HookDepth()
		:
		fDepth(0),
		fWarned(false)
	{
	}

	bool Enter(const char* hook)
	{
		if (fDepth > 0) {
			if (!fWarned) {
				fprintf(stderr, "mojobe: %s re-entered while another hook of "
					"the same object ran; the base class handled it\\n", hook);
				fWarned = true;
			}
			return false;
		}
		fDepth++;
		return true;
	}

	void Leave()
	{
		fDepth--;
	}

private:
	int32	fDepth;
	bool	fWarned;
};
"""


def write_c(emitter, bridge, includes):
    h = [LICENSE_C, "#ifndef MOJOBE_H", "#define MOJOBE_H", "", ""]
    h.append("/*!\tThe C interface of the Haiku bridge: an entry point per method,")
    h.append("\tand the hook tables of the shadow classes. See")
    h.append("\tHaiku/docs/bridge-design.md, sections 7 and 8.")
    h.append("*/")
    h.append("")
    h.append("")
    for include in includes:
        h.append("#include <%s>" % include)
    h.append("")
    h.append("")
    h.append('extern "C" {')
    h.append("")
    h.append("")
    for value in bridge.values:
        if not bridge.mirrored(value):
            continue
        record = bridge.model.records[value]
        if record.in_registers:
            h.append("/*!\t`%s` as C passes it: laid out the same, a plain C struct" % value)
            h.append("\t(its member functions make `%s` a C++ type to C). */" % value)
        else:
            h.append("/*!\t`%s` as C passes it: laid out the same, but without the" % value)
            h.append("\tuser-declared copy constructor that makes C++ pass a `%s` by"
                     % value)
            h.append("\thidden reference. */")
        h.append("struct mojobe_%s {" % value)
        for name, ctype, access in record.fields:
            array = re.fullmatch(r"(.*?)\s*(\[\d+\])", ctype.qual)
            if array:
                h.append("\t%s\t%s%s;" % (array.group(1), name, array.group(2)))
            else:
                h.append("\t%s\t%s;" % (ctype.qual, name))
        h.append("};")
        h.append("")
        h.append("")
    for cls, parts in emitter.shadow_parts.items():
        h.append("/*!\tA Mojo type's hooks for a `%s`: a NULL slot is a hook the type" % cls)
        h.append("\tdoes not implement. The type tag names the Mojo type. */")
        h.extend(parts["table_c"])
        h.append("")
        h.append("")
    h.extend(emitter.h)
    extra = SNIPPETS / "mojobe.h"
    if extra.exists():
        h.append("")
        h.append("")
        h.append(extra.read_text().rstrip("\n"))
    h.append("")
    h.append("")
    h.append('}\t// extern "C"')
    h.append("")
    h.append("")
    h.append("#endif\t// MOJOBE_H")
    (BRIDGE / "libmojobe" / "mojobe.h").write_text("\n".join(h) + "\n")

    c = [LICENSE_C, "", '#include "mojobe.h"', "", "#include <new>", "#include <stdio.h>", "#include <string.h>",
         "", "", "namespace {", ""]
    for value in bridge.values:
        if not bridge.mirrored(value):
            continue
        record = bridge.model.records[value]
        fields = [f[0] for f in record.fields]
        arrays = {f[0] for f in record.fields if f[1].qual.endswith("]")}
        c.append("")
        c.append("[[maybe_unused]] mojobe_%s" % value)
        c.append("mojobe_to_c(const %s& value)" % value)
        c.append("{")
        c.append("\tmojobe_%s result;" % value)
        for f in fields:
            if f in arrays:
                c.append("\tmemcpy(result.%s, value.%s, sizeof(result.%s));" % (f, f, f))
            else:
                c.append("\tresult.%s = value.%s;" % (f, f))
        c.append("\treturn result;")
        c.append("}")
        c.append("")
        c.append("")
        c.append("[[maybe_unused]] %s" % value)
        c.append("mojobe_from_c(const mojobe_%s& value)" % value)
        c.append("{")
        c.append("\t%s result;" % value)
        for f in fields:
            if f in arrays:
                c.append("\tmemcpy(result.%s, value.%s, sizeof(result.%s));" % (f, f, f))
            else:
                c.append("\tresult.%s = value.%s;" % (f, f))
        c.append("\treturn result;")
        c.append("}")
        c.append("")
    c.append(UNEXPECTED)
    c.append(HOOK_DEPTH)
    for cls, parts in emitter.shadow_parts.items():
        c.append("")
        c.append("class Mojo%s : public %s {" % (cls, cls))
        c.append("public:")
        for info, _, c_params, c_args in emitter.shadow_ctors.get(cls, []):
            method = info["method"]
            params = ["%s %s" % (p.type.qual, p.name) for p in method.params] + [
                "const mojobe_%s_hooks* hooks" % cls, "void* context"]
            c.append("\tMojo%s(%s)" % (cls, ", ".join(params)))
            c.append("\t\t:")
            c.append("\t\t%s(%s)," % (cls, ", ".join(p.name for p in method.params)))
            c.append("\t\tfHooks(*hooks),")
            c.append("\t\tfContext(context)")
            c.append("\t{")
            c.append("\t}")
            c.append("")
        c.append("\tvirtual ~Mojo%s()" % cls)
        c.append("\t{")
        c.append("\t\t// From here on no hook reaches Mojo: what the destruction")
        c.append("\t\t// does may call hooks (removing a selected item calls")
        c.append("\t\t// SelectionChanged), and the Mojo state is about to go. While")
        c.append("\t\t// ~%s runs this is a %s anyway." % (cls, cls))
        c.append("\t\tmojobe_%s_hooks hooks = fHooks;" % cls)
        c.append("\t\tfHooks = mojobe_%s_hooks();" % cls)
        owned = bridge.classes[cls].get("owns_items")
        if owned:
            c.append("\t\t// %s does not delete its items; Mojo gave them to this one." % cls)
            c.append("\t\tfor (int32 i = CountItems() - 1; i >= 0; i--)")
            c.append("\t\t\tdelete RemoveItem(i);")
        c.append("\t\tif (hooks.destroy != NULL)")
        c.append("\t\t\thooks.destroy(fContext);")
        c.append("\t}")
        c.append("")
        c.extend(parts["shadow_methods"])
        c.append("\t//! The Mojo state, if it is of the type tagged.")
        c.append("\tvoid* Context(uint64 type) const")
        c.append("\t{")
        c.append("\t\treturn fHooks.type == type ? fContext : NULL;")
        c.append("\t}")
        c.append("")
        c.append("private:")
        c.append("\tmojobe_%s_hooks\tfHooks;" % cls)
        c.append("\tvoid*\t\t\tfContext;")
        c.append("\tHookDepth\t\tfDepth;")
        c.append("};")
        c.append("")
    c.append("")
    c.append("}\t// namespace")
    c.append("")
    c.append("")
    c.append('extern "C" {')
    c.append("")
    c.append("")
    for cls in emitter.shadow_parts:
        c.append("void*")
        c.append("mojobe_Mojo%s_context(%s* self, uint64 type)" % (cls, cls))
        c.append("{")
        c.append("\tMojo%s* object = dynamic_cast<Mojo%s*>(self);" % (cls, cls))
        c.append("\treturn object != NULL ? object->Context(type) : NULL;")
        c.append("}")
        c.append("")
        c.append("")
    c.extend(emitter.cpp)
    extra = SNIPPETS / "mojobe.cpp"
    if extra.exists():
        c.append("")
        c.append(extra.read_text().rstrip("\n"))
        c.append("")
        c.append("")
    c.append('}\t// extern "C"')
    (BRIDGE / "libmojobe" / "mojobe.cpp").write_text("\n".join(c) + "\n")
    # the context lookups' prototypes
    header = (BRIDGE / "libmojobe" / "mojobe.h").read_text()
    protos = "".join("void* mojobe_Mojo%s_context(%s* self, uint64 type);\n" % (cls, cls)
                     for cls in emitter.shadow_parts)
    header = header.replace('\n\n}\t// extern "C"', "\n\n" + protos + '\n\n}\t// extern "C"', 1)
    (BRIDGE / "libmojobe" / "mojobe.h").write_text(header)


def write_values(emitter, bridge):
    out = [LICENSE_MOJO.rstrip("\n"),
           '"""The Be API\'s value types, laid out as the Haiku headers lay them out',
           "(checked at compile time against clang's layout for the Haiku target),",
           'and the constant values of those types."""', "",
           "from std.ffi import external_call",
           "from std.sys import size_of, align_of", "",
           "from ._core import _address_of", ""]
    enums = sorted({t for v in bridge.values for _, t in emitter.value_fields(v)
                    if t in bridge.typed_enums})
    if enums:
        out.append("from ._constants import %s" % ", ".join(enums))
        out.append("")
    for value in bridge.values:
        fields = emitter.value_fields(value)
        snippet = SNIPPETS / ("%s.mojo" % value)
        traits = ["Equatable", "TrivialRegisterPassable"]
        extra = snippet.read_text() if snippet.exists() else ""
        if "def write_to" in extra:
            traits.append("Writable")
        out.append("")
        out.append("@fieldwise_init")
        out.append("struct %s(%s):" % (value, ", ".join(traits)))
        out.append('    """`%s`, %d bytes."""' % (value, bridge.layouts[value][0]))
        out.append("")
        for name, t in fields:
            out.append("    var %s: %s" % (name, t))
        for lines in emitter.value_methods.get(value, []):
            out.append("")
            out.extend("    " + l for l in lines)
        if extra:
            out.append("")
            out.extend(("    " + l if l.strip() else "") for l in extra.rstrip("\n").split("\n"))
        out.append("")
    out.append("")
    out.append("def _check_layouts():")
    out.append('    """Fails the compile when a value type is not laid out as clang lays'
               ' it out for Haiku."""')
    for value in bridge.values:
        size, align, offsets = bridge.layouts[value]
        out.append("    comptime assert size_of[%s]() == %d" % (value, size))
        if bridge.values[value].get("mojo_fields"):
            # passed whole, in a register: its Mojo alignment may differ
            continue
        out.append("    comptime assert align_of[%s]() == %d" % (value, align))
    extra = SNIPPETS / "_values.mojo"
    if extra.exists():
        out.append("")
        out.append("")
        out.append(extra.read_text().rstrip("\n"))
    (BRIDGE / "haiku" / "_values.mojo").write_text("\n".join(wrap_all(out)) + "\n")


def mojo_int(value, kind):
    """(Mojo type, value) of a probed constant."""
    if kind > 100:
        return ("Float32" if kind == 104 else "Float64"), value
    size = abs(kind)
    signed = kind < 0
    names = {1: "Int8", 2: "Int16", 4: "Int32", 8: "Int64"}
    t = names.get(size, "Int64")
    if not signed:
        t = "U" + t
        value &= (1 << (8 * size)) - 1
    return t, value


def status_names(bridge):
    """`_status_name()` and `status_of()`: between a status_t and its name in
    Errors.h. A value with several names gets the shortest."""
    statuses = {}
    for name, (value, kind) in bridge.constants.items():
        if name in bridge.error_names and kind == -4 and value <= 0:
            statuses[name] = value
    by_value = {}
    for name in sorted(statuses, key=lambda n: (len(n), n)):
        by_value.setdefault(statuses[name], name)
    out = ["", "",
           "def _status_name(status: Int32) -> StaticString:",
           '    """The name Errors.h gives a `status_t`; "" when it gives none."""']
    for value, name in sorted(by_value.items()):
        out.append("    if status == %d:" % value)
        out.append('        return "%s"' % name)
    out.append('    return ""')
    out += ["", "",
            "def status_of(error: Error) -> Int32:",
            '    """The `status_t` an error the bridge raised stands for, as its',
            "    message ends by naming it: `BMessage::FindInt32: Name not found",
            "    (B_NAME_NOT_FOUND)`. B_ERROR for an error that names none.",
            "",
            "    The bridge raises plain `Error`s rather than a typed error, so that",
            "    one `try` block can call it and anything else (design section",
            '    18.4)."""',
            "    var text = String(error)",
            '    var start = text.rfind(" (")',
            '    if start < 0 or not text.endswith(")"):',
            "        return B_ERROR",
            "    var name = String(text[byte = start + 2 : text.byte_length() - 1])",
            '    if name.startswith("status "):',
            "        try:",
            "            return Int32(atol(name[byte=7:]))",
            "        except:",
            "            return B_ERROR"]
    for name, value in sorted(statuses.items()):
        out.append('    if name == "%s":' % name)
        out.append("        return %d" % value)
    out.append("    return B_ERROR")
    return out


def write_constants(bridge, names):
    out = [LICENSE_MOJO.rstrip("\n"),
           '"""The Haiku headers\' constants, as clang evaluates them for the Haiku',
           "target. A named enum is a type of its own, so that a `window_type` is",
           'not taken for a `window_look`; the rest are integers."""', ""]
    for enum in sorted(bridge.typed_enums):
        out.append("")
        out.append("@fieldwise_init")
        out.append("struct %s(Equatable, TrivialRegisterPassable):" % enum)
        out.append('    """`enum %s`."""' % enum)
        out.append("")
        out.append("    var value: %s" % bridge.enum_int(enum))
        out.append("")
        out.append("    def __or__(self, other: Self) -> Self:")
        out.append("        return Self(self.value | other.value)")
        out.append("")
    out.append("")
    for name in names:
        value, kind = bridge.constants[name]
        t, v = mojo_int(value, kind)
        if isinstance(v, float):
            literal = repr(v)
        else:
            literal = hex(v) if v > 9 else str(v)
        enum = bridge.model.enum_of.get(name)
        if enum in bridge.typed_enums:
            out.append("comptime %s = %s(%s)" % (name, enum, literal))
        else:
            out.append("comptime %s: %s = %s" % (name, t, literal))
    out.extend(status_names(bridge))
    (BRIDGE / "haiku" / "_constants.mojo").write_text("\n".join(out) + "\n")
    return sorted(bridge.typed_enums)


def write_api(emitter, bridge):
    out = [LICENSE_MOJO.rstrip("\n"),
           '"""The Haiku API\'s classes, generated from the headers: for each, a',
           "trait with its methods (inheriting its bases'), a reference to one the",
           "kit owns (`BViewRef`), a struct for one Mojo owns (`BView`), and, for",
           "the classes Mojo types may stand behind, the hook traits and tables.",
           '"""', "",
           "from std.builtin.rebind import downcast",
           "from std.ffi import c_char, external_call",
           "from std.sys import align_of, size_of", "",
           "from ._core import (",
           "    _FnPtr,", "    _HookCall,", "    _NPtr,", "    _Ptr,", "    _addr,",
           "    _address_of,", "    _char,", "    _check,",
           "    _destroy,", "    _fn_ptr,", "    _nonnull,", "    _ptr_from,", "    _state_at,",
           "    _string_from,", "    _string_from_char,", "    _to_heap,", "    _type_tag,", ")",
           "from ._values import _check_layouts"]
    value_names = list(bridge.values) + sorted(
        n for n in bridge.used_names if n in hand_written("_values.mojo", "comptime"))
    out.append("from ._values import %s" % ", ".join(value_names))
    consts = sorted(bridge.typed_enums) + sorted(
        n for n in bridge.used_names if n in bridge.constants)
    if consts:
        out.append("from ._constants import (")
        out.extend("    %s," % n for n in consts)
        out.append(")")
    out.extend(emitter.mojo)
    if emitter.functions:
        out += ["", "# " + "=" * 74 + " #", "# Functions", "# " + "=" * 74 + " #"]
        for lines in emitter.functions:
            out += ["", ""] + lines
    extra = SNIPPETS / "_api.mojo"
    if extra.exists():
        out.append("")
        out.append("")
        out.extend(extra.read_text().rstrip("\n").split("\n"))
    (BRIDGE / "haiku" / "_api.mojo").write_text("\n".join(wrap_all(out)) + "\n")


def write_hooks(emitter):
    out = [LICENSE_MOJO.rstrip("\n"),
           '"""The Be API\'s hook functions, one trait each (design section 8.3). A',
           "type implements the hooks it wants; making a `BView` or a `BWindow` from",
           "it builds that type's hook table at compile time, and a hook it does not",
           'implement never enters Mojo."""', "",
           "from ._api import ("]
    out.extend("    %s," % t for t in emitter.hook_traits)
    out.append(")")
    (BRIDGE / "haiku" / "hooks.mojo").write_text("\n".join(out) + "\n")


def write_init(emitter, bridge, constants):
    out = [LICENSE_MOJO.rstrip("\n"),
           '"""The Haiku API for Mojo programs on Prose, through libmojobe',
           "(Haiku/docs/bridge-design.md). Link programs with `-lmojobe -lbe`.",
           "",
           "Generated from the Haiku headers for: %s." % ", ".join(bridge.classes),
           'Haiku/bridge/MANIFEST.md lists every method, and what is left out and why."""',
           "",
           "from ._core import fourcc",
           "from ._values import %s" % ", ".join(
               list(bridge.values) + hand_written("_values.mojo", "def")
               + hand_written("_values.mojo", "comptime")),
           "from ._api import ("]
    for cls in bridge.classes:
        out.append("    %s," % cls)
        if bridge.classes[cls].get("kind") != "value":
            out.append("    %sRef," % cls)
    out.extend("    %s," % n for n in hand_written("_api.mojo", "def"))
    out.extend("    %s," % n for n in bridge.config.get("functions", []))
    out.append(")")
    out.append("from ._constants import status_of")
    out.append("from ._constants import (")
    out.extend("    %s," % n for n in constants)
    out.append(")")
    (BRIDGE / "haiku" / "__init__.mojo").write_text("\n".join(out) + "\n")


def write_manifest(emitter, bridge):
    out = ["# The bridge's manifest", "",
           "Generated by `Haiku/generator/mojobe_gen.py`: every public method of the",
           "bridged classes (and of their unbridged bases, which they carry), and",
           "whether the bridge has it; what is left out says why. An override that a",
           "base class's method already reaches (virtual dispatch) is not left out.",
           ""]
    totals = [0, 0, 0]
    sections = []
    for cls, rows in emitter.manifest.items():
        included = [r for r in rows if r[1] == "included"]
        reached = [r for r in rows if r[1] == "skipped" and r[2].startswith("reached through")]
        skipped = [r for r in rows if r[1] == "skipped" and r not in reached]
        totals[0] += len(included)
        totals[1] += len(reached)
        totals[2] += len(skipped)
        sections.append("## %s: %d included, %d overrides reached through a base, "
                        "%d left out" % (cls, len(included), len(reached), len(skipped)))
        sections.append("")
        sections.append("| C++ | | |")
        sections.append("|---|---|---|")
        for what, status, why in rows:
            sections.append("| `%s` | %s | %s |" % (what.replace("|", "\\|"), status,
                                                   why.replace("|", "\\|")))
        sections.append("")
    out.append("In all: %d included, %d overrides reached through a base, %d left out."
               % tuple(totals))
    out.append("")
    out.extend(sections)
    (BRIDGE / "MANIFEST.md").write_text("\n".join(out) + "\n")
    return totals[0], totals[2]



# ===----------------------------------------------------------------------=== #
# The ABI oracle (design section 12)
# ===----------------------------------------------------------------------=== #


class OracleValue:
    """An argument's known value, spelled for C++ and for Mojo."""

    def __init__(self, cxx, mojo, check):
        self.cxx = cxx        # the C++ expression passed
        self.mojo = mojo      # the Mojo value expected (for value types)
        self.check = check    # a Mojo condition on `%s`, the received name


def _float(x):
    return repr(float(x))


def oracle_argument(bridge, emitter, kind, detail, k, i, setup):
    """The value hook k's argument i is called with. `setup` collects C++
    statements that make real objects (messages) before the call."""
    if kind == "objectptr" and detail == "BMessage":
        what = 0x6F720000 + k * 16 + i
        setup.append("BMessage message%d_%d(0x%X);" % (k, i, what))
        return OracleValue("&message%d_%d" % (k, i), None,
                           "%%s.what == 0x%X" % what)
    if kind == "objectptr":
        address = 0x10000 + 0x100 * k + 0x10 * i
        return OracleValue("reinterpret_cast<%s*>(0x%X)" % (detail, address), None,
                           "_addr(%%s._ptr) == 0x%X" % address)
    if kind == "cstring":
        text = "oracle-%d-%d-é" % (k, i)
        return OracleValue('"%s"' % text, None, '%%s == "%s"' % text)
    if kind == "value":
        fields = emitter.value_fields(detail)
        record = bridge.model.records[detail]
        cvals, mvals = [], []
        for j, (name, mtype) in enumerate(fields):
            if mtype.startswith("Float"):
                v = k * 10 + i + 0.25 * (j + 1)
                cvals.append(_float(v))
                mvals.append(_float(v))
            else:
                v = (k * 16 + i * 4 + j + 1) & 0x7F
                cvals.append(str(v))
                mvals.append(str(v))
        mojo = "%s(%s)" % (detail, ", ".join(mvals))
        return OracleValue("mojobe_%s{%s}" % (detail, ", ".join(cvals)), mojo,
                           "%%s == %s" % mojo)
    if kind == "prim":
        if detail == "Bool":
            v = (k + i) % 2 == 0
            return OracleValue("true" if v else "false", None,
                               "%%s == %s" % ("True" if v else "False"))
        if detail.startswith("Float"):
            v = k + i * 0.25 + 0.5
            return OracleValue(_float(v), None, "%%s == %s" % _float(v))
        signed = not detail.startswith("U")
        v = -(k * 100 + i * 10 + 7) if signed else k * 100 + i * 10 + 3
        return OracleValue(str(v), None, "%%s == %d" % v)
    if kind == "enum":
        return OracleValue("(%s)%d" % (detail, i + 1), None,
                           "%%s == %s(%d)" % (detail, i + 1))
    raise AssertionError((kind, detail))


ORACLE_CPP_HEAD = """/*
 * Copyright 2026, MojoProse. All rights reserved.
 * Distributed under the terms of the Apache License v2.0 with LLVM Exceptions.
 *
 * Generated by Haiku/generator/mojobe_gen.py. Do not edit.
 */


/*!	The ABI oracle (Haiku/docs/bridge-design.md, section 12): what the C++
	compiler passes and returns, for Haiku/tests/abi_oracle.mojo to compare
	with what Mojo sees. Hook tables are called slot by slot with known
	arguments; value types and enums are passed and returned around other
	arguments; and a call spills onto the stack.
*/


#include "mojobe.h"

#include <stdint.h>


extern "C" {
"""


def write_oracle(emitter, bridge):
    cpp = [ORACLE_CPP_HEAD]
    mojo = [LICENSE_MOJO.rstrip("\n"),
            '"""The ABI oracle (Haiku/docs/bridge-design.md, section 12), generated',
            "with the bridge: C++ calls every slot of each hook table through the",
            "bridge's own trampolines with known arguments, and a Mojo type that",
            "implements every hook checks what arrives; value types and enums go",
            "both ways by value around other arguments; and a call spills onto the",
            "stack. Prints PASS or FAIL for each, then `SELFTEST PASS n/n`.",
            "",
            "Build on Prose with liboracle.so (Haiku/bridge/oracle/oracle.cpp):",
            "    mojo build -I Haiku/bridge abi_oracle.mojo -o abi_oracle \\",
            "        -Xlinker -L. -Xlinker -loracle -Xlinker -lmojobe -Xlinker -lbe",
            '"""',
            "",
            "from std.ffi import external_call",
            "",
            "from haiku import *",
            "from haiku._api import %s" % ", ".join(
                "_%s_hooks" % c for c in emitter.hook_signatures),
            "from haiku._core import _addr, _destroy, _to_heap",
            "from haiku.hooks import *",
            "",
            "",
            "struct Checks:",
            "    var passed: Int",
            "    var failed: Int",
            "",
            "    def __init__(out self):",
            "        self.passed = 0",
            "        self.failed = 0",
            "",
            "    def check(mut self, what: String, ok: Bool):",
            "        if ok:",
            "            self.passed += 1",
            '            print("PASS:", what)',
            "        else:",
            "            self.failed += 1",
            '            print("FAIL:", what)']
    main = ["", "", "def main() raises:", "    var checks = Checks()"]
    # hooks, class by class
    for cls, hooks in emitter.hook_signatures.items():
        oracle = "Oracle%s" % cls
        traits = [hook_marker(cls)[:-len("Hooks")] + h for h, _, _, _ in hooks]
        cpp.append("")
        cpp.append("int32")
        cpp.append("mojobe_oracle_%s(const mojobe_%s_hooks* hooks, void* context)" % (cls, cls))
        cpp.append("{")
        cpp.append("\tint32 failures = 0;")
        mojo += ["", "", "struct %s(%s, Movable):" % (oracle, ", ".join(traits)),
                 '    """Every hook of `%s`, checking its arguments."""' % cls, "",
                 "    var calls: Int", "    var wrong: Int", "",
                 "    def __init__(out self):", "        self.calls = 0",
                 "        self.wrong = 0", "",
                 "    def expect(mut self, what: String, ok: Bool):",
                 "        if not ok:", "            self.wrong += 1",
                 '            print("  wrong:", what)']
        subject = hook_marker(cls)[:-len("Hooks")]
        subject = subject[0].lower() + subject[1:]
        for k, (hook, m, kinds, ret_m) in enumerate(hooks):
            setup = []
            args = [oracle_argument(bridge, emitter, "objectptr", cls, k, 0, setup)]
            names = [subject]
            for i, ((kind, detail), p) in enumerate(zip(kinds, m.params)):
                if kind == "object" and p.type.reference:
                    kind = "objectptr"
                args.append(oracle_argument(bridge, emitter, kind, detail, k, i + 1, setup))
                names.append(mojo_name(p.name))
            cpp.append("\t{")
            cpp.extend("\t\t" + line for line in setup)
            call = "hooks->%s(%s)" % (hook, ", ".join(["context"] + [a.cxx for a in args]))
            cpp.append("\t\tif (hooks->%s == NULL)" % hook)
            cpp.append("\t\t\tfailures++;")
            if ret_m:
                expected = "true" if k % 2 == 1 else "false"
                cpp.append("\t\telse if (%s != %s)" % (call, expected))
                cpp.append("\t\t\tfailures++;")
            else:
                cpp.append("\t\telse")
                cpp.append("\t\t\t%s;" % call)
            cpp.append("\t}")
            # the Mojo hook
            decls = ["mut self", "%s: %sRef[_]" % (subject, cls)]
            for (kind, detail), p in zip(kinds, m.params):
                decls.append("%s: %s" % (mojo_name(p.name),
                                          emitter.hook_param(p)[0]))
            mojo += ["", "    def %s(%s)%s:" % (hook, ", ".join(decls),
                                                  " -> %s" % ret_m if ret_m else ""),
                     "        self.calls += 1"]
            for name, arg in zip(names, args):
                mojo.append('        self.expect("%s %s", %s)' % (hook, name, arg.check % name))
            if ret_m:
                mojo.append("        return %s" % ("True" if k % 2 == 1 else "False"))
        cpp.append("\treturn failures;")
        cpp.append("}")
        main += ["", "    # %s's hooks, through its generated table and trampolines" % cls,
                 "    var hooks%s = _%s_hooks[%s]()" % (cls, cls, oracle),
                 "    var context%s = _to_heap(%s())" % (cls, oracle),
                 '    var failures%s = external_call["mojobe_oracle_%s", Int32]('
                 "Pointer(to=hooks%s), context%s)" % (cls, cls, cls, cls),
                 "    ref seen%s = context%s.unsafe_bitcast[%s]()[]" % (cls, cls, oracle),
                 '    checks.check("%s: all %d hooks called, their results seen by C++",'
                 % (cls, len(hooks)),
                 "        seen%s.calls == %d and failures%s == 0)" % (cls, len(hooks), cls),
                 '    checks.check("%s: every argument as C++ passed it", seen%s.wrong == 0)'
                 % (cls, cls),
                 "    _destroy[%s](context%s)" % (oracle, cls)]
    # value types and enums, both ways
    echoes = []
    for value in bridge.values:
        fields = emitter.value_fields(value)
        record = bridge.model.records[value]
        cfields = [(n, c) for n, c, a in record.fields]
        ins, outs, cin = [], [], []
        if bridge.values[value].get("mojo_fields"):
            # laid out otherwise in Mojo (pattern's bytes as a UInt64,
            # key_info's as UInt32s): C++ bumps every byte, and the Mojo
            # fields are what those bytes are
            sizes = {"UInt8": 1, "UInt16": 2, "UInt32": 4, "UInt64": 8,
                     "Int8": 1, "Int16": 2, "Int32": 4, "Int64": 8}
            at = 0
            for name, mtype in fields:
                size = sizes[mtype]
                raw = [(3 + 5 * (at + j)) & 0x7F for j in range(size)]
                ins.append("%s(%d)" % (mtype, sum(b << (8 * j) for j, b in enumerate(raw))))
                outs.append("%s(%d)" % (mtype, sum((b + 1) << (8 * j)
                                                   for j, b in enumerate(raw))))
                at += size
            bump = ("\tunsigned char* bytes = reinterpret_cast<unsigned char*>(&result);\n"
                    "\tfor (size_t j = 0; j < sizeof(result); j++)\n"
                    "\t\tbytes[j] += 1;")
        else:
            bump = ""
            for j, (name, mtype) in enumerate(fields):
                if mtype.startswith("Float"):
                    ins.append(_float(j + 0.25))
                    outs.append(_float(j + 1.25))
                    bump += "\tresult.%s += 1;\n" % name
                elif mtype in bridge.typed_enums:
                    ins.append("%s(%d)" % (mtype, j + 2))
                    outs.append("%s(%d)" % (mtype, j + 3))
                    bump += "\tresult.%s = (%s)(result.%s + 1);\n" % (name, mtype, name)
                else:
                    ins.append(str(j * 7 + 2))
                    outs.append(str(j * 7 + 3))
                    bump += "\tresult.%s += 1;\n" % name
            bump = bump.rstrip("\n")
        echoes.append((value, "mojobe_%s" % value, bump,
                       "%s(%s)" % (value, ", ".join(ins)),
                       "%s(%s)" % (value, ", ".join(outs))))
    for enum in sorted(bridge.typed_enums):
        signed = bridge.enum_int(enum).startswith("Int")
        v = -3 if signed else 3
        echoes.append((enum, enum, "\tresult = (%s)(result + 1);" % enum,
                       "%s(%d)" % (enum, v), "%s(%d)" % (enum, v + 1)))
    for name, ctype, bump, given, expected in echoes:
        cpp += ["", "%s" % ctype,
                "mojobe_oracle_echo_%s(int8 before, %s value, double after," % (name, ctype),
                "\t%s* seen, int8* seenBefore, double* seenAfter)" % ctype,
                "{",
                "\t*seen = value;",
                "\t*seenBefore = before;",
                "\t*seenAfter = after;",
                "\t%s result = value;" % ctype,
                bump,
                "\treturn result;",
                "}"]
        main += ["",
                 "    var given%s = %s" % (name, given),
                 "    var seen%s = given%s" % (name, name),
                 "    var before%s = Int8(0)" % name,
                 "    var after%s = Float64(0)" % name,
                 '    var result%s = external_call["mojobe_oracle_echo_%s", %s](' % (name, name, name),
                 "        Int8(-5), given%s, Float64(2.75), Pointer(to=seen%s)," % (name, name),
                 "        Pointer(to=before%s), Pointer(to=after%s))" % (name, name),
                 '    checks.check("%s by value, between an int8 and a double",' % name,
                 "        seen%s == given%s and before%s == -5 and after%s == 2.75)"
                 % (name, name, name, name),
                 '    checks.check("%s returned", result%s == %s)' % (name, name, expected)]
    # the stack: more arguments than registers
    ints = list(range(1, 13))
    floats = [i + 0.25 for i in range(10)]
    total = (sum(a * (n + 1) for n, a in enumerate(ints))
             + sum(f * (n + 1) * 0.5 for n, f in enumerate(floats))
             + 1000 - 7 * 3 + 65000 * 5 - 123456789 * 7 + 987654321 * 11 + 0.125 * 13)
    cpp += ["",
            "double",
            "mojobe_oracle_stack(%s," % ", ".join("int32 a%d" % n for n in range(12)),
            "\t%s," % ", ".join("float f%d" % n for n in range(10)),
            "\tbool b, int8 i8, uint16 u16, int64 i64, uint64 u64, double d)",
            "{",
            "\treturn %s" % " + ".join("a%d * %d.0" % (n, n + 1) for n in range(12)),
            "\t\t+ %s" % " + ".join("f%d * %s" % (n, _float((n + 1) * 0.5)) for n in range(10)),
            "\t\t+ (b ? 1000.0 : 0.0) + i8 * 3.0 + u16 * 5.0 + i64 * 7.0 + u64 * 11.0",
            "\t\t+ d * 13.0;",
            "}",
            "",
            "",
            '}\t// extern "C"']
    main += ["",
             '    var stack = external_call["mojobe_oracle_stack", Float64](',
             "        %s," % ", ".join("Int32(%d)" % a for a in ints),
             "        %s," % ", ".join("Float32(%s)" % _float(f) for f in floats),
             "        True, Int8(-7), UInt16(65000), Int64(-123456789),",
             "        UInt64(987654321), Float64(0.125))",
             '    checks.check("30 arguments, most of them on the stack", stack == %s)'
             % _float(total),
             "",
             "    var total = checks.passed + checks.failed",
             "    if checks.failed:",
             '        print("SELFTEST FAIL", checks.passed, "/", total)',
             "    else:",
             '        print("SELFTEST PASS", String(checks.passed) + "/" + String(total))']
    (BRIDGE / "oracle").mkdir(exist_ok=True)
    (BRIDGE / "oracle" / "oracle.cpp").write_text("\n".join(cpp) + "\n")
    (HAIKU_DIR / "tests" / "abi_oracle.mojo").write_text("\n".join(wrap_all(mojo + main)) + "\n")


# ===----------------------------------------------------------------------=== #
# Main
# ===----------------------------------------------------------------------=== #


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--clang", default=os.environ.get("CLANG"))
    parser.add_argument("--sysroot", default=os.environ.get("HAIKU_SYSROOT", DEFAULT_SYSROOT))
    arguments = parser.parse_args()
    clang_path = arguments.clang or os.path.realpath(DEFAULT_CLANG)
    if not Path(clang_path).exists():
        sys.exit("mojobe_gen: no clang at %s (build MojoProse, or --clang)" % clang_path)
    config = tomllib.loads((HERE / "bridge.toml").read_text())
    includes = config["headers"]
    clang = Clang(clang_path, arguments.sysroot)

    ast = clang.ast(includes)
    Locations().walk(ast)
    model = Model(ast)

    # constants: enum constants and const integral variables of the kits'
    # headers, and the macros among them that evaluate to integers
    dirs = ["/headers/%s/" % d for d in config.get("constant_dirs", [])]
    names = sorted(n for n, f in model.constant_files.items()
                   if f and any(d in f for d in dirs) and n.startswith("B_"))
    macro_names = []
    for line in clang.macros(includes).splitlines():
        match = re.match(r"#define (B_\w+) (.+)$", line)
        if match and match.group(1) not in model.constant_files and re.fullmatch(
                r"[\w\s|()+<>'-]+", match.group(2)) and not re.search(r'"', match.group(2)):
            macro_names.append(match.group(1))
    found = probe_each(clang, includes, names + sorted(macro_names))
    values = [(v, [f[0] for f in model.records[v].fields]) for v in config.get("values", {})]
    values += [(c, []) for c, conf in config.get("classes", {}).items()
               if conf.get("kind") == "value"]
    constants, layouts = probe(clang, includes, sorted(found), values)

    bridge = Bridge(model, config, constants, layouts)
    bridge.libraries = config.get("libraries", ["libbe.so", "libroot.so"])
    bridge.symbols = clang.symbols(bridge.libraries)
    # Errors.h defines its statuses as macros, which carry no file
    errors_h = Path(arguments.sysroot) / "boot/system/develop/headers/os/support/Errors.h"
    bridge.error_names = set(re.findall(r"#\s*define\s+(B_\w+)", errors_h.read_text()))
    emitter = Emitter(bridge)
    emitter.signatures = {}
    emitter.shadow_parts = {}
    emitter.shadow_ctors = {}
    emitter.hook_signatures = {}
    # classes in an order where bases come first
    order = []
    def visit(cls):
        if cls in order:
            return
        for base in emitter.bridged_bases(cls):
            visit(base)
        order.append(cls)
    for cls in bridge.classes:
        visit(cls)
    emitter.functions = []
    emitter.value_methods = {}
    for value, conf in config.get("values", {}).items():
        if conf.get("methods"):
            emitter.emit_value_methods(value)
    for cls in order:
        emitter.emit_class(cls)
    emitter.emit_functions()
        # remember the shadow constructors for the C++ class
    write_c(emitter, bridge, includes)
    write_values(emitter, bridge)
    enums = write_constants(bridge, sorted(constants))
    write_api(emitter, bridge)
    write_hooks(emitter)
    write_init(emitter, bridge, enums + sorted(constants))
    write_oracle(emitter, bridge)
    included, skipped = write_manifest(emitter, bridge)
    print("mojobe_gen: %d classes, %d methods included, %d left out (overrides"
          " aside), %d constants"
          % (len(bridge.classes), included, skipped, len(constants)))


if __name__ == "__main__":
    main()
