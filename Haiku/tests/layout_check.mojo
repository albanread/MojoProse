# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""Layouts through the bridge: a window laid out by a BGroupLayout that
adopted two buttons and a glue item (a factory's), checked once the window
runs, from the main thread under Locked(). Prints PASS or FAIL for each
check, then `SELFTEST PASS n/n` or `SELFTEST FAIL`.

Build on Prose, as Dots is built:
    mojo build -I Haiku/bridge Haiku/tests/layout_check.mojo \\
        -o layout_check -Xlinker -L. -Xlinker -lmojobe -Xlinker -lbe
"""

from haiku import BApplication, BButton, BGroupLayout, BMessage, BMessenger
from haiku import BRect, BSize, BSpaceLayoutItem, BWindow, fourcc
from haiku import B_AUTO_UPDATE_SIZE_LIMITS, B_QUIT_REQUESTED, B_TITLED_WINDOW
from haiku import B_VERTICAL


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
    var app = BApplication("application/x-vnd.Prose-layout-check")

    var window = BWindow(BRect(100, 100, 399, 299), "Layout", B_TITLED_WINDOW,
                         B_AUTO_UPDATE_SIZE_LIMITS)
    # A layout adds views to the view it is set on: before it is set on
    # one, AddView fails (Layout.cpp: no target), and the bridge deletes the
    # view Mojo gave up rather than leak it.
    var loose = BGroupLayout(B_VERTICAL)
    checks.check("AddView to a layout on no view: NULL",
                 not loose.AddView(BButton("lost", "Lost", BMessage(fourcc("lost")))))
    _ = loose^

    window.SetLayout(BGroupLayout(B_VERTICAL, 10))  # the window adopts it
    var layout = window.GetLayout().as_BGroupLayout()
    layout.SetInsets(12, 12, 12, 12)
    var one = BButton("one", "One", BMessage(fourcc("one ")))
    one.SetExplicitSize(BSize(120, 30))  # its minimum, maximum and preferred
    checks.check("AddView(a button)", Bool(layout.AddView(one^)))
    checks.check("AddView(another)", Bool(layout.AddView(
        BButton("two", "Two", BMessage(fourcc("two "))))))
    checks.check("AddItem(a factory's glue)",
                 layout.AddItem(BSpaceLayoutItem.CreateGlue()))
    checks.check("the layout has its three items", layout.CountItems() == 3)
    var messenger = BMessenger(window)
    window^.Show()

    # Once the window has answered a message, it has been laid out.
    var reply = BMessage()
    messenger.SendMessage(BMessage(fourcc("ping")), reply)
    with messenger.Locked() as looper:
        var shown = looper.as_BWindow()
        checks.check("the window's layout is the BGroupLayout",
                     Bool(shown.GetLayout().as_BGroupLayout()))
        var first = shown.FindView("one").Frame()
        var second = shown.FindView("two").Frame()
        checks.check("the insets place the first button",
                     first.top == 12 and first.left >= 12, String(first))
        checks.check("its explicit size",
                     first.Width() == 120 and first.Height() == 30, String(first))
        checks.check("the spacing separates the second",
                     second.top == first.bottom + 1 + 10, String(second))
        checks.check("the glue takes the rest: the second is not stretched",
                     second.bottom < shown.Bounds().bottom - 12, String(second))
    messenger.SendMessage(B_QUIT_REQUESTED)
    _ = app^

    var total = checks.passed + checks.failed
    if checks.failed:
        print("SELFTEST FAIL", checks.passed, "/", total)
    else:
        print("SELFTEST PASS", String(checks.passed) + "/" + String(total))
