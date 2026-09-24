# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""List views through the bridge: a BListView does not delete its items, so
the bridge's does -- AddItem adopts, RemoveItem(index) gives the item back,
and the items left are deleted with the list (the guarded-heap run catches
a double delete). A Mojo type behind a list hears its selection change.
Prints PASS or FAIL for each check, then `SELFTEST PASS n/n` or `SELFTEST
FAIL`.

Build on Prose, as Dots is built:
    mojo build -I Haiku/bridge Haiku/tests/list_check.mojo \\
        -o list_check -Xlinker -L. -Xlinker -lmojobe -Xlinker -lbe
"""

from haiku import BApplication, BListView, BListViewRef, BRect, BScrollView
from haiku import BStringItem
from haiku.hooks import ListViewSelectionChanged


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


struct Picker(ListViewSelectionChanged, Movable):
    """What a list's selection was, each time it changed."""

    var changes: Int
    var selected: Int32

    def __init__(out self):
        self.changes = 0
        self.selected = -1

    def SelectionChanged(mut self, listView: BListViewRef[_]):
        self.changes += 1
        self.selected = listView.CurrentSelection()


def main() raises:
    var checks = Checks()
    var app = BApplication("application/x-vnd.Prose-list-check")

    var list = BListView(BRect(0, 0, 99, 99), "list")
    checks.check("AddItem adopts",
                 list.AddItem(BStringItem("one")) and list.AddItem(BStringItem("two")))
    checks.check("AddItem at an index", list.AddItem(BStringItem("between"), 1))
    checks.check("CountItems", list.CountItems() == 3)
    checks.check("ItemAt, as a BStringItem",
                 list.ItemAt(1).as_BStringItem().Text() == "between")
    var removed = list.RemoveItem(0)
    checks.check("RemoveItem(index) gives the item back, owned",
                 removed.as_BStringItem().Text() == "one" and list.CountItems() == 2)
    checks.check("AddItem out of range: false (and the item deleted)",
                 not list.AddItem(BStringItem("lost"), 9))
    _ = removed^  # Mojo deletes the item it was given back
    _ = list^     # the list deletes the two items left

    var scroll = BScrollView("scroll", BListView("inner"), 0, False, True)
    checks.check("a BScrollView adopts its target",
                 scroll.Target().Name() == "inner")
    _ = scroll^

    var picker = BListView(BRect(0, 0, 99, 99), "picker", Picker())
    for label in ["red", "green", "blue"]:
        _ = picker.AddItem(BStringItem(label))
    picker.Select(2)
    checks.check("SelectionChanged ran in Mojo, with the new selection",
                 picker.state[Picker]().changes == 1
                 and picker.state[Picker]().selected == 2)
    picker.Select(0)
    checks.check("and again", picker.state[Picker]().selected == 0)
    _ = picker^
    _ = app^

    var total = checks.passed + checks.failed
    if checks.failed:
        print("SELFTEST FAIL", checks.passed, "/", total)
    else:
        print("SELFTEST PASS", String(checks.passed) + "/" + String(total))
