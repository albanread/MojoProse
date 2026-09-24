# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""Controls: a window of Be controls whose messages a Mojo type handles --
a button, a check box, a text field and a slider, and a line of text that
says what they last did. The design's "menu and controls" example (section
12).

`controls --selftest` drives each control through the bridge from the
application's thread (ReadyToRun), as a click or a keystroke would, and
checks what the window's Mojo state saw; it prints PASS or FAIL for each
check, then `SELFTEST PASS n/n` or `SELFTEST FAIL`, and exits 1 on failure.
"""

from std.sys import argv, exit
from std.time import sleep

from haiku import BAlert, BApplication, BApplicationRef, BButton, BCheckBox
from haiku import BInvoker, BMessage, BRadioButton
from haiku import BMessageRef, BMessenger, BRect, BSlider, BStringView
from haiku import BTextControl, BView, BWindow, BWindowRef, fourcc
from haiku import B_FOLLOW_ALL, B_PANEL_BACKGROUND_COLOR, B_QUIT_ON_WINDOW_CLOSE
from haiku import B_QUIT_REQUESTED, B_TITLED_WINDOW, B_WILL_DRAW
from haiku.hooks import ApplicationReadyToRun, WindowMessageReceived

comptime MSG_CLICK = fourcc("clik")
comptime MSG_LOUD = fourcc("loud")
comptime MSG_NAME = fourcc("name")
comptime MSG_LEVEL = fourcc("levl")
comptime MSG_PING = fourcc("ping")
comptime MSG_SLOW = fourcc("slow")
comptime MSG_FAST = fourcc("fast")
comptime MSG_ANSWER = fourcc("answ")


struct Panel(Movable, WindowMessageReceived):
    """The window's Mojo state: what its controls last said."""

    var clicks: Int
    var loud: Bool
    var name: String
    var level: Int32
    var fast: Bool
    var answer: Int32

    def __init__(out self):
        self.clicks = 0
        self.loud = False
        self.name = ""
        self.level = 0
        self.fast = False
        self.answer = -1

    def MessageReceived(
        mut self, window: BWindowRef[_], message: BMessageRef[_]
    ):
        try:
            if message.what == MSG_CLICK:
                self.clicks += 1
            elif message.what == MSG_LOUD:
                self.loud = message.FindInt32("be:value") != 0
            elif message.what == MSG_NAME:
                self.name = window.FindView("name").as_BTextControl().Text()
            elif message.what == MSG_LEVEL:
                self.level = message.FindInt32("be:value")
            elif message.what == MSG_SLOW or message.what == MSG_FAST:
                self.fast = message.what == MSG_FAST
            elif message.what == MSG_ANSWER:
                self.answer = message.FindInt32("which")  # the button pressed
            elif message.what == MSG_PING:
                message.SendReply(MSG_PING)  # everything before is done
                return
            else:
                window.base_MessageReceived(message)
                return
            window.FindView("status").as_BStringView().SetText(
                String(
                    self.clicks, " clicks, ", "loud" if self.loud else "quiet",
                    ", ", self.name, ", level ", self.level,
                )
            )
        except e:
            print("Controls:", e)


struct Checks(Movable):
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


struct SelfTest(ApplicationReadyToRun, Movable):
    """The application's Mojo state: with --selftest, it drives the window's
    controls once the application runs, and then quits."""

    var window: BMessenger
    var enabled: Bool
    var checks: Checks

    def __init__(out self, window: BMessenger, enabled: Bool):
        self.window = window
        self.enabled = enabled
        self.checks = Checks()

    def ReadyToRun(mut self, application: BApplicationRef[_]):
        if not self.enabled:
            return
        try:
            self.drive()
        except e:
            self.checks.check("the self-test ran", False, String(e))
        try:
            application.PostMessage(B_QUIT_REQUESTED)
        except e:
            print("Controls:", e)

    def drive(mut self) raises:
        # As a person would: a click, a tick, a name typed, the slider moved.
        with self.window.Locked() as looper:
            var window = looper.as_BWindow()
            var button = window.FindView("button").as_BButton()
            self.checks.check("the button's label", button.Label() == "Click")
            button.Invoke()
            var loud = window.FindView("loud").as_BCheckBox()
            loud.SetValue(1)
            loud.Invoke()
            var name = window.FindView("name").as_BTextControl()
            name.SetText("Prose")
            name.Invoke()
            var level = window.FindView("level").as_BSlider()
            level.SetValue(7)
            level.Invoke()
            var fast = window.FindView("fast").as_BRadioButton()
            fast.SetValue(1)
            fast.Invoke()
        # An alert, answered by its second button, as a click would.
        var alert = BAlert("Controls", "Go faster?", "No", "Yes")
        var alert_messenger = BMessenger(alert)
        alert^.Go(BInvoker(BMessage(MSG_ANSWER), self.window))
        with alert_messenger.Locked() as looper:
            looper.as_BAlert().ButtonAt(1).Invoke()
        # The alert answers on its own thread, then quits: once it has gone,
        # its answer is in the window's queue, ahead of the ping below.
        for _ in range(200):
            if not alert_messenger.IsValid():
                break
            sleep(0.01)
        # The window handles its messages in order: once it answers this,
        # it has handled the four before.
        var reply = BMessage()
        self.window.SendMessage(BMessage(MSG_PING), reply)
        with self.window.Locked() as looper:
            var window = looper.as_BWindow()
            ref panel = window.state[Panel]()
            self.checks.check("the button's message reached the window's Mojo"
                              " state", panel.clicks == 1)
            self.checks.check("the check box's value came with its message",
                              panel.loud)
            self.checks.check("the text field's text", panel.name == "Prose",
                              panel.name)
            self.checks.check("the slider's value came with its message",
                              panel.level == 7, String(panel.level))
            self.checks.check("the radio button's message", panel.fast)
            self.checks.check("the alert's answer, through its invoker",
                              panel.answer == 1, String(panel.answer))
            var status = window.FindView("status").as_BStringView().Text()
            self.checks.check(
                "the string view says so",
                status == "1 clicks, loud, Prose, level 7",
                status,
            )


def main() raises:
    var selftest = len(argv()) > 1 and argv()[1] == "--selftest"
    var app = BApplication(
        "application/x-vnd.Prose-controls", SelfTest(BMessenger(), selftest)
    )
    var window = BWindow(
        BRect(120, 120, 480, 340),
        "Controls",
        B_TITLED_WINDOW,
        B_QUIT_ON_WINDOW_CLOSE,
        Panel(),
    )
    # The controls sit on a view in the panel colour, as Haiku's do.
    var panel = BView(window.Bounds(), "panel", B_FOLLOW_ALL, B_WILL_DRAW)
    panel.SetViewUIColor(B_PANEL_BACKGROUND_COLOR)
    panel.AddChild(
        BButton(BRect(20, 20, 120, 45), "button", "Click", BMessage(MSG_CLICK))
    )
    panel.AddChild(
        BCheckBox(BRect(140, 22, 300, 42), "loud", "Loud", BMessage(MSG_LOUD))
    )
    panel.AddChild(
        BTextControl(
            BRect(20, 60, 340, 80), "name", "Name:", "", BMessage(MSG_NAME)
        )
    )
    panel.AddChild(
        BSlider(
            BRect(20, 95, 340, 140),
            "level",
            "Level",
            BMessage(MSG_LEVEL),
            0,
            10,
        )
    )
    panel.AddChild(
        BRadioButton(BRect(20, 185, 120, 205), "slow", "Slow", BMessage(MSG_SLOW))
    )
    panel.AddChild(
        BRadioButton(BRect(130, 185, 240, 205), "fast", "Fast", BMessage(MSG_FAST))
    )
    panel.AddChild(
        BStringView(BRect(20, 160, 340, 180), "status", "Nothing yet")
    )
    window.AddChild(panel^)
    app.state[SelfTest]().window = BMessenger(window)
    window^.Show()
    _ = app.Run()
    if selftest:
        ref checks = app.state[SelfTest]().checks
        var total = checks.passed + checks.failed
        if checks.failed:
            print("SELFTEST FAIL", checks.passed, "/", total)
            exit(1)
        print("SELFTEST PASS", String(checks.passed) + "/" + String(total))
