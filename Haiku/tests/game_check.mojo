# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""Prose's game kit through the bridge: a game pane's world, a Span of its
bytes, drawn into by the pane and by Mojo; palettes from spans of colours;
a blit checked against its source's length; and the chip player. Prints
PASS or FAIL for each check, then `SELFTEST PASS n/n` or `SELFTEST FAIL`.

Build on Prose, as Dots is built:
    mojo build -I Haiku/bridge Haiku/tests/game_check.mojo \\
        -o game_check -Xlinker -L. -Xlinker -lmojobe -Xlinker -lbe
"""

from haiku import BApplication, BChipPlayer, BGamePane, BMessenger, BRect
from haiku import B_GAME_COPY, B_QUIT_REQUESTED, get_key_info, key_info, rgb
from haiku import rgb_color


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
    var app = BApplication("application/x-vnd.Prose-game-check")

    var pane = BGamePane(BRect(100, 100, 419, 339), "Game", 320, 240)
    var bpr = Int(pane.BytesPerRow())
    var world = pane.World()
    checks.check("World(): a span of BytesPerRow() * WorldHeight() bytes",
                 len(world) == bpr * 240 and bpr >= 320, String(len(world)))
    pane.Clear(3)
    checks.check("Clear(3), read from the world",
                 world[0] == 3 and world[len(world) - 1] == 3)
    pane.Plot(10, 20, 7)
    pane.FillRect(0, 0, 4, 4, 9)
    checks.check("Plot, read back through RowAt()", pane.RowAt(20)[10] == 7)
    checks.check("FillRect's edges",
                 pane.RowAt(3)[3] == 9 and pane.RowAt(4)[4] == 3)
    world[bpr * 30 + 30] = 12  # Mojo draws straight into the world
    checks.check("a byte Mojo wrote, as the pane sees it",
                 pane.RowAt(30)[30] == 12)

    var source = List[UInt8]()
    for value in [1, 2, 3, 4, 5, 6, 7, 8]:
        source.append(UInt8(value))
    pane.Blit(Span(source), 4, 50, 50, 4, 2, B_GAME_COPY)
    checks.check("Blit from a Span",
                 pane.RowAt(50)[50] == 1 and pane.RowAt(51)[53] == 8)
    try:
        pane.Blit(Span(source), 4, 50, 50, 4, 3, B_GAME_COPY)
        checks.check("a Blit longer than its source raises", False)
    except e:
        print("  raised:", e)
        checks.check("a Blit longer than its source raises", True)

    pane.SetColor(7, rgb(255, 0, 0))
    checks.check("SetColor, Color", pane.Color(7) == rgb(255, 0, 0))
    var colours = List[rgb_color]()
    colours.append(rgb(0, 255, 0))
    colours.append(rgb(0, 0, 255))
    pane.SetColors(20, Span(colours))
    checks.check("SetColors from a Span of rgb_color",
                 pane.Color(20) == rgb(0, 255, 0) and pane.Color(21) == rgb(0, 0, 255))

    var messenger = BMessenger(pane)
    pane^.Show()
    messenger.SendMessage(B_QUIT_REQUESTED)

    try:
        var chip = BChipPlayer()
        checks.check("BChipPlayer: voices and tracks",
                     chip.CountVoices() > 0 and chip.CountTracks() > 0)
        chip.Play("X:1\nK:C\nL:1/8\nCDEF GABc|\n", 0, True)
        checks.check("Play(ABC): the track sounds", chip.IsPlaying(0))
        chip.StopAll()
        checks.check("StopAll(): nothing sounds", chip.Playing() == 0)
    except e:
        checks.check("BChipPlayer", False, String(e))
    # The keyboard, polled: nobody is at the keys here, so the bit logic is
    # checked on a key_info made by hand -- space (0x5E) is bit 1 of byte 11.
    _ = get_key_info()
    var space = key_info(0, 0, 0, UInt32(2) << 24, 0)
    checks.check("key_info.is_down: space, and not its neighbours",
                 space.is_down(0x5E) and not space.is_down(0x5D)
                 and not space.is_down(0x5F))
    _ = app^

    var total = checks.passed + checks.failed
    if checks.failed:
        print("SELFTEST FAIL", checks.passed, "/", total)
    else:
        print("SELFTEST PASS", String(checks.passed) + "/" + String(total))
