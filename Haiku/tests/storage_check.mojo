# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""The storage kit through the bridge: find_directory (a free function),
paths, entries, entry_refs carried in a BMessage, and Tracker's file panel.
Prints PASS or FAIL for each check, then `SELFTEST PASS n/n` or `SELFTEST
FAIL`.

Build on Prose, as Dots is built:
    mojo build -I Haiku/bridge Haiku/tests/storage_check.mojo \\
        -o storage_check -Xlinker -L. -Xlinker -lmojobe -Xlinker -lbe
"""

from haiku import BApplication, BEntry, BFilePanel, BMessage, BPath, entry_ref
from haiku import B_OPEN_PANEL, B_SAVE_PANEL, B_USER_SETTINGS_DIRECTORY
from haiku import find_directory, fourcc, status_of, B_ENTRY_NOT_FOUND


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

    var settings = BPath()
    find_directory(B_USER_SETTINGS_DIRECTORY, settings)
    checks.check("find_directory(B_USER_SETTINGS_DIRECTORY)",
                 settings.Path() == "/boot/home/config/settings", settings.Path())

    var desktop = BPath("/boot/home", "Desktop")
    checks.check("BPath(dir, leaf)", desktop.Path() == "/boot/home/Desktop"
                 and desktop.Leaf() == "Desktop", desktop.Path())
    var parent = BPath()
    desktop.GetParent(parent)
    checks.check("BPath.GetParent()", parent.Path() == "/boot/home", parent.Path())
    parent.Append("config/settings")
    checks.check("BPath.Append()", parent.Path() == settings.Path(), parent.Path())

    var home = BEntry("/boot/home")
    checks.check("BEntry: exists, a directory", home.Exists() and home.IsDirectory())
    checks.check("BEntry of nothing does not exist",
                 not BEntry("/boot/home/no such file").Exists())

    # An entry_ref, through a message and back to a path.
    var ref_ = entry_ref()
    home.GetRef(ref_)
    var message = BMessage(fourcc("refs"))
    message.AddRef("refs", ref_)
    var found = entry_ref()
    message.FindRef("refs", found)
    checks.check("an entry_ref, through a BMessage, to a BPath",
                 BPath(found).Path() == "/boot/home", BPath(found).Path())
    try:
        message.FindRef("nothing", found)
        checks.check("FindRef of a missing name raises", False)
    except e:
        checks.check("FindRef of a missing name raises B_NAME_NOT_FOUND",
                     String(e).endswith("(B_NAME_NOT_FOUND)"), String(e))
    try:
        BEntry("/no such directory/file").InitCheck()
        checks.check("an entry in no directory fails InitCheck()", False)
    except e:
        checks.check("an entry in no directory fails InitCheck() with"
                     " B_ENTRY_NOT_FOUND", status_of(e) == B_ENTRY_NOT_FOUND,
                     String(e))

    # Tracker's file panel: made, pointed at a directory, asked back.
    var app = BApplication("application/x-vnd.Prose-storage-check")
    var panel = BFilePanel(B_SAVE_PANEL)
    checks.check("BFilePanel: its mode", panel.PanelMode() == B_SAVE_PANEL)
    panel.SetPanelDirectory("/boot/home/config")
    var directory = entry_ref()
    panel.GetPanelDirectory(directory)
    checks.check("BFilePanel: the directory it was given",
                 BPath(directory).Path() == "/boot/home/config",
                 BPath(directory).Path())
    checks.check("BFilePanel: not shown", not panel.IsShowing())
    _ = panel^
    _ = app^

    var total = checks.passed + checks.failed
    if checks.failed:
        print("SELFTEST FAIL", checks.passed, "/", total)
    else:
        print("SELFTEST PASS", String(checks.passed) + "/" + String(total))
