# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""Threads and messages through the bridge (Haiku/docs/bridge-design.md,
sections 8.5 and 12): a Mojo type behind a running BLooper gets its hooks on
the looper's thread; other threads reach it with a BMessenger -- messages,
a synchronous reply, and the looper's lock -- and everything fails cleanly
once it has quit. No window is needed. Prints PASS or FAIL for each check,
then `SELFTEST PASS n/n` or `SELFTEST FAIL`.

Build on Prose, as Dots is built:
    mojo build -I Haiku/bridge Haiku/tests/threads_check.mojo -o threads_check \\
        -Xlinker -L. -Xlinker -lmojobe -Xlinker -lbe
"""

from std.ffi import external_call
from std.time import sleep

from haiku import BLooper, BLooperRef, BMessage, BMessageRef, BMessenger
from haiku import B_BAD_PORT_ID, B_BAD_VALUE, B_INFINITE_TIMEOUT
from haiku import B_QUIT_REQUESTED
from haiku import fourcc, status_of
from haiku.hooks import LooperMessageReceived

comptime MSG_TICK = fourcc("tick")
comptime MSG_ASK = fourcc("ask ")


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


struct Counter(LooperMessageReceived, Movable):
    """Counts ticks on the looper's thread, and answers how many."""

    var ticks: Int

    def __init__(out self):
        self.ticks = 0

    def MessageReceived(
        mut self, looper: BLooperRef[_], message: BMessageRef[_]
    ):
        if message.what == MSG_TICK:
            self.ticks += 1
        elif message.what == MSG_ASK:
            try:
                var reply = BMessage(MSG_ASK)
                reply.AddInt32("ticks", Int32(self.ticks))
                reply.AddInt32("thread", looper.Thread())
                reply.AddBool("locked", looper.IsLocked())
                message.SendReply(reply)
            except e:
                print("Counter:", e)
        else:
            looper.base_MessageReceived(message)


def main() raises:
    var checks = Checks()

    var looper = BLooper(Counter(), "counter")
    var messenger = BMessenger(looper)
    checks.check("a messenger to a looper not yet running is valid",
                 messenger.IsValid())
    var thread = looper^.Run()  # the looper runs, and owns itself
    checks.check("Run() starts the looper's thread", thread > 0)

    for _ in range(5):
        messenger.SendMessage(MSG_TICK)
    var reply = BMessage()
    messenger.SendMessage(BMessage(MSG_ASK), reply)
    checks.check(
        "the hook ran once per message, in order",
        reply.FindInt32("ticks") == 5,
        String(reply.FindInt32("ticks")),
    )
    checks.check(
        "hooks run on the looper's thread",
        reply.FindInt32("thread") == thread,
        String(reply.FindInt32("thread"), " / ", thread),
    )
    checks.check("hooks run with the looper locked", reply.FindBool("locked"))
    checks.check("the reply's what", reply.get_what() == MSG_ASK)

    var copy = messenger  # copied as bytes
    checks.check("a copied messenger compares equal", copy == messenger)
    checks.check("a messenger to nothing differs", BMessenger() != messenger)

    # From this thread, under the looper's lock: its state, and its lock.
    with messenger.Locked() as locked:
        var this_thread = external_call["find_thread", Int32](0)
        checks.check(
            "Locked(): this thread holds the looper's lock",
            locked.IsLocked() and locked.LockingThread() == this_thread,
        )
        checks.check(
            "Locked(): the Mojo state, read under the lock",
            locked.state[Counter]().ticks == 5,
        )
        checks.check("as_BWindow() of a plain looper is NULL",
                     not locked.as_BWindow())
    # The block unlocked it: the looper answers again, which it could not
    # do while this thread held its lock (the reply would time out).
    var again = BMessage()
    messenger.SendMessage(BMessage(MSG_ASK), again, B_INFINITE_TIMEOUT, 2000000)
    checks.check("the block's end unlocks the looper",
                 again.FindInt32("ticks") == 5)

    # Quitting deletes the looper and, with it, the Counter.
    messenger.SendMessage(B_QUIT_REQUESTED)
    var gone = False
    for _ in range(100):
        if not messenger.IsValid():
            gone = True
            break
        sleep(0.01)
    checks.check("B_QUIT_REQUESTED ends the looper", gone)
    checks.check("LockTarget() of a looper that has gone fails",
                 not messenger.LockTarget())
    try:
        messenger.SendMessage(MSG_TICK)
        checks.check("SendMessage to a looper that has gone raises", False)
    except e:
        print("  raised:", e)
        checks.check("SendMessage to a looper that has gone raises",
                     status_of(e) == B_BAD_PORT_ID, String(status_of(e)))

    try:
        with messenger.Locked() as locked:
            _ = locked.Thread()
        checks.check("Locked() of a looper that has gone raises", False)
    except e:
        print("  raised:", e)
        checks.check("Locked() of a looper that has gone raises B_BAD_VALUE",
                     status_of(e) == B_BAD_VALUE, String(status_of(e)))

    var total = checks.passed + checks.failed
    if checks.failed:
        print("SELFTEST FAIL", checks.passed, "/", total)
    else:
        print("SELFTEST PASS", String(checks.passed) + "/" + String(total))
