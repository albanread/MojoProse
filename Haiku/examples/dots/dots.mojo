# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""Dots: the bridge design's example program (section 2). Click to put a dot
down; Dots ▸ Clear (Alt+C) clears them; Quit (Alt+Q) quits."""

from haiku import BApplication, BMenu, BMenuBar, BMenuItem, BMessage, BPoint
from haiku import BRect, BView, BViewRef, BWindow, BWindowRef, fourcc, rgb
from haiku import BMessageRef
from haiku import B_FOLLOW_ALL, B_QUIT_ON_WINDOW_CLOSE, B_QUIT_REQUESTED
from haiku import B_TITLED_WINDOW, B_WILL_DRAW
from haiku.hooks import ViewDraw, ViewMouseDown, WindowMessageReceived

comptime MSG_CLEAR = fourcc("clr ")


struct Canvas(Movable, ViewDraw, ViewMouseDown):
    var dots: List[BPoint]

    def __init__(out self, var dots: List[BPoint]):
        self.dots = dots^

    def Draw(mut self, view: BViewRef[_], updateRect: BRect):
        view.SetHighColor(rgb(30, 30, 46))
        view.FillRect(view.Bounds())
        view.SetHighColor(rgb(255, 200, 0))
        for p in self.dots:
            view.FillEllipse(p, 4, 4)

    def MouseDown(mut self, view: BViewRef[_], where: BPoint):
        self.dots.append(where)
        view.Invalidate()


struct Main(Movable, WindowMessageReceived):
    def __init__(out self):
        pass

    def MessageReceived(
        mut self, window: BWindowRef[_], message: BMessageRef[_]
    ):
        if message.what == MSG_CLEAR:
            try:
                var canvas = window.FindView("canvas")
                canvas.state[Canvas]().dots.clear()  # the window is locked
                canvas.Invalidate()
            except e:
                print("Dots:", e)
        else:
            window.base_MessageReceived(message)  # BWindow's own handling


def main() raises:
    var app = BApplication("application/x-vnd.Prose-dots")
    var window = BWindow(
        BRect(100, 100, 500, 400),
        "Dots",
        B_TITLED_WINDOW,
        B_QUIT_ON_WINDOW_CLOSE,
        Main(),
    )

    var menu = BMenu("Dots")
    _ = menu.AddItem(BMenuItem("Clear", BMessage(MSG_CLEAR), "C"))
    _ = menu.AddItem(BMenuItem("Quit", BMessage(B_QUIT_REQUESTED), "Q"))
    var bar = BMenuBar(BRect(0, 0, 400, 19), "menubar")
    _ = bar.AddItem(menu^)  # the bar adopts the menu
    window.AddChild(bar^)  # and the window the bar

    # A few dots to start with, so a drawn window shows the bridge working.
    var dots = List[BPoint]()
    dots.append(BPoint(60, 60))
    dots.append(BPoint(200, 150))
    dots.append(BPoint(340, 240))

    var frame = window.Bounds()
    frame.top = 20
    window.AddChild(
        BView(frame, "canvas", B_FOLLOW_ALL, B_WILL_DRAW, Canvas(dots^))
    )
    window^.Show()  # the window runs, and owns itself
    _ = app.Run()
