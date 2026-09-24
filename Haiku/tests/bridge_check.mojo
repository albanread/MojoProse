# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""The generated bridge, used where no window is needed: each of the ways a
C++ signature is carried into Mojo (Haiku/docs/bridge-design.md, section
10), checked on Prose against libbe itself. Prints PASS or FAIL for each
check, then `SELFTEST PASS n/n` or `SELFTEST FAIL`.

Build on Prose, as Dots is built:
    mojo build -I Haiku/bridge Haiku/tests/bridge_check.mojo -o bridge_check \\
        -Xlinker -L. -Xlinker -lmojobe -Xlinker -lbe
"""

from haiku import BMessage, BMessageRef, BPoint, BRect, BView, fourcc, rgb
from haiku import B_ANY_TYPE, B_DOCUMENT_WINDOW, B_INT32_TYPE
from haiku import B_TITLED_WINDOW, B_WILL_DRAW
from haiku import window_type


struct Checks:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def check(mut self, what: String, ok: Bool, detail: String = ""):
        if ok:
            self.passed += 1
            print("PASS:", what)
        else:
            self.failed += 1
            print("FAIL:", what, detail)


def main() raises:
    var checks = Checks()

    # Constants: evaluated by clang; named enums are types of their own.
    checks.check("B_WILL_DRAW is 0x20000000", B_WILL_DRAW == 0x20000000)
    checks.check(
        "B_TITLED_WINDOW is a window_type, 1",
        B_TITLED_WINDOW == window_type(1) and B_TITLED_WINDOW.value == 1,
    )
    checks.check(
        "enum constants compare by value",
        B_TITLED_WINDOW != B_DOCUMENT_WINDOW,
    )
    checks.check("B_INT32_TYPE is 'LONG'", B_INT32_TYPE == fourcc("LONG"))

    # Value types: laid out as C++ lays them out, passed and returned.
    var frame = BRect(10, 20, 110, 70)
    checks.check("BRect.Width()", frame.Width() == 100)

    var message = BMessage(fourcc("test"))
    checks.check("BMessage(what): what", message.get_what() == fourcc("test"))
    checks.check("a new message is empty", message.IsEmpty())

    # status_t results raise; parameters of every kind.
    message.AddInt32("int", 42)
    message.AddInt32("int", -7)
    message.AddString("string", "Prose")
    message.AddRect("rect", frame)
    message.AddPoint("point", BPoint(1.5, -2.5))
    message.AddBool("bool", True)
    message.AddFloat("float", 0.25)
    message.AddColor("color", rgb(255, 200, 0))
    checks.check("CountNames(B_ANY_TYPE)", message.CountNames(B_ANY_TYPE) == 7)

    # Out-parameters are results: one, or a tuple.
    checks.check("FindInt32(name)", message.FindInt32("int") == 42)
    checks.check("FindInt32(name, index)", message.FindInt32("int", 1) == -7)
    checks.check("FindString: a copy", message.FindString("string") == "Prose")
    var rect = message.FindRect("rect")
    checks.check(
        "FindRect: a BRect through a mirror struct",
        rect.left == 10 and rect.top == 20 and rect.right == 110
        and rect.bottom == 70,
    )
    var point = message.FindPoint("point")
    checks.check("FindPoint", point.x == 1.5 and point.y == -2.5)
    checks.check("FindBool", message.FindBool("bool"))
    checks.check("FindFloat", message.FindFloat("float") == 0.25)
    var color = message.FindColor("color")
    checks.check(
        "FindColor: an rgb_color",
        color.red == 255 and color.green == 200 and color.blue == 0
        and color.alpha == 255,
    )
    var info = message.GetInfo("int")
    checks.check(
        "GetInfo: two out-parameters, a tuple",
        info[0] == B_INT32_TYPE and info[1] == 2,
    )

    # A failing status_t raises, with the method and strerror()'s text.
    try:
        _ = message.FindInt32("missing")
        checks.check("FindInt32 of a missing name raises", False)
    except e:
        print("  raised:", e)
        checks.check(
            "FindInt32 of a missing name raises",
            String(e).startswith("BMessage::FindInt32: "),
            String(e),
        )

    message.MakeEmpty()
    checks.check("MakeEmpty", message.IsEmpty())

    # References: NULL is a value, tested with `if`.
    var nothing = BMessageRef()
    checks.check("a NULL reference is False", not nothing)

    # An object Mojo owns, and a reference the kit returns.
    var view = BView(BRect(0, 0, 99, 49), "view", 0, B_WILL_DRAW)
    checks.check("BView.Name(): a string result", view.Name() == "view")
    checks.check("BView.Bounds(): a BRect result", view.Bounds().Width() == 99)
    checks.check("BView.Parent() of a lone view is NULL", not view.Parent())
    checks.check("BView.Window() of a lone view is NULL", not view.Window())

    var total = checks.passed + checks.failed
    if checks.failed:
        print("SELFTEST FAIL", checks.passed, "/", total)
    else:
        print("SELFTEST PASS", String(checks.passed) + "/" + String(total))
