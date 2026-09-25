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

from haiku import BHandler, BLooper, BLooperRef, BMessage, BMessageRef
from haiku import BPoint, BRect
from haiku import BApplication, BMenu, BMenuItem, BView, fourcc, rgb
from haiku import B_ANY_TYPE, B_DOCUMENT_WINDOW, B_INT32_TYPE
from haiku import B_TITLED_WINDOW, B_WILL_DRAW
from haiku import B_ERROR, B_NAME_NOT_FOUND, status_of, window_type
from haiku.hooks import LooperMessageReceived, ViewMessageReceived
from haiku import BViewRef


struct Reentrant(Movable, ViewMessageReceived):
    """A hook that calls its own object's virtual method, which would enter
    it again (design section 9)."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def MessageReceived(mut self, view: BViewRef[_], message: BMessageRef[_]):
        self.calls += 1
        # BView::MessageReceived is virtual: this comes back through the
        # shadow, which must hand it to BView's own instead of to this hook
        # while it runs.
        view.MessageReceived(message)


struct Worker(LooperMessageReceived, Movable):
    """A Mojo type standing behind a looper."""

    var seen: Int

    def __init__(out self, seen: Int):
        self.seen = seen

    def MessageReceived(
        mut self, looper: BLooperRef[_], message: BMessageRef[_]
    ):
        self.seen += 1


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

    # Value types' methods: C++'s inline ones, compiled into libmojobe.
    var inset = BRect(10, 20, 110, 70)
    inset.InsetBy(5, 5)
    checks.check("BRect.InsetBy changes the value", inset == BRect(15, 25, 105, 65),
                 String(inset))
    checks.check("BRect.Contains", inset.Contains(BPoint(20, 30))
                 and not inset.Contains(BPoint(0, 0)))
    checks.check("BRect & and |: intersection and union",
                 (BRect(0, 0, 9, 9) & BRect(5, 5, 19, 19)) == BRect(5, 5, 9, 9)
                 and (BRect(0, 0, 9, 9) | BRect(5, 5, 19, 19)) == BRect(0, 0, 19, 19))
    checks.check("BRect from two points",
                 BRect(BPoint(1, 2), BPoint(3, 4)) == BRect(1, 2, 3, 4))
    checks.check("BRect() is not valid", not BRect().IsValid())
    checks.check("BRect.OffsetByCopy leaves the value",
                 inset.OffsetByCopy(1, 1) == BRect(16, 26, 106, 66)
                 and inset == BRect(15, 25, 105, 65))
    checks.check("BPoint + and unary -",
                 BPoint(1, 2) + BPoint(3, 4) == BPoint(4, 6)
                 and -BPoint(1, 2) == BPoint(-1, -2))
    var constrained = BPoint(50, -50)
    constrained.ConstrainTo(BRect(0, 0, 9, 9))
    checks.check("BPoint.ConstrainTo", constrained == BPoint(9, 0), String(constrained))

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
        checks.check(
            "the error names its status, and status_of() reads it",
            String(e).endswith("(B_NAME_NOT_FOUND)")
            and status_of(e) == B_NAME_NOT_FOUND,
            String(status_of(e)),
        )
    checks.check("status_of() an error that names none: B_ERROR",
                 status_of(Error("plain")) == B_ERROR)

    # The stdlib's errors and the bridge's in one program: both call
    # strerror, which once had two signatures here and did not compile.
    try:
        with open("/boot/home/no such file", "r") as f:
            _ = f.read()
        checks.check("the stdlib's file error, beside the bridge's", False)
    except e:
        checks.check("the stdlib's file error, beside the bridge's", True)

    message.MakeEmpty()
    checks.check("MakeEmpty", message.IsEmpty())

    # References: NULL is a value, tested with `if`.
    var nothing = BMessageRef[ImmUntrackedOrigin]()
    checks.check("a NULL reference is False", not nothing)

    # An object Mojo owns, and a reference the kit returns.
    var view = BView(BRect(0, 0, 99, 49), "view", 0, B_WILL_DRAW)
    checks.check("BView.Name(): a string result", view.Name() == "view")
    checks.check("BView.Bounds(): a BRect result", view.Bounds().Width() == 99)
    checks.check("BView.Parent() of a lone view is NULL", not view.Parent())
    checks.check("BView.Window() of a lone view is NULL", not view.Window())

    # Adoption into a view; a by-value overload whose pointer twin changes
    # its argument in place (bridge.toml [inout]) -- once left out with it.
    # `child` is borrowed from `parent` and keeps it alive: `parent` is not
    # used after FindView, and once Mojo ended it there, deleting the view
    # `child` points into (design section 17.6).
    var parent = BView(BRect(0, 0, 199, 199), "parent", 0, 0)
    parent.AddChild(BView(BRect(10, 20, 59, 69), "child", 0, 0))
    var child = parent.FindView("child")
    checks.check("FindView finds the adopted child", Bool(child))
    checks.check(
        "the child's Parent() is the parent",
        child.Parent().Name() == "parent",
    )
    var converted = child.ConvertToParent(BPoint(1, 2))
    checks.check(
        "ConvertToParent(BPoint): by value",
        converted.x == 11 and converted.y == 22,
        String(converted),
    )
    var frame_in_parent = child.ConvertToParent(child.Bounds())
    checks.check(
        "ConvertToParent(BRect): by value",
        frame_in_parent.left == 10 and frame_in_parent.bottom == 69,
        String(frame_in_parent),
    )

    # A looper borrows its handlers (~BHandler leaves the looper). A new
    # looper is locked, as AddHandler requires.
    var looper = BLooper("worker")
    var handler = BHandler("handler")
    # A string is a name, not a Mojo state: the shadow constructors' state
    # must implement a hook, so BLooper("worker") is the plain constructor.
    checks.check("BLooper(name): its name", looper.Name() == "worker")
    checks.check("BHandler(name): its name", handler.Name() == "handler")
    looper.AddHandler(handler)
    checks.check("AddHandler: CountHandlers", looper.CountHandlers() == 2)
    checks.check(
        "BHandler.Looper() is the looper",
        handler.Looper().Name() == "worker",
    )
    checks.check("IndexOf(handler)", looper.IndexOf(handler) == 1)

    # A looper with a Mojo type behind it, and its state before it runs.
    var shadowed = BLooper(Worker(41), "shadowed")
    shadowed.state[Worker]().seen += 1
    checks.check(
        "BLooper(state, name): the name, and the state through the value",
        shadowed.Name() == "shadowed" and shadowed.state[Worker]().seen == 42,
    )
    try:
        _ = shadowed.state[Checks]()
        checks.check("state of the wrong type raises", False)
    except e:
        checks.check("state of the wrong type raises", True)

    # An adopting method that fails: BMenu::AddItem at an index out of
    # range returns false and does not take the item; the bridge deletes
    # it, as Mojo gave it up (a leak before; the guarded-heap run catches a
    # double delete).
    # (Menus need the app_server, so a BApplication; Mojo ends it at its
    # last use, so that comes after them.)
    var app = BApplication("application/x-vnd.Prose-bridge-check")
    var menu = BMenu("menu")
    var added = menu.AddItem(BMenuItem("one", BMessage(fourcc("one "))))
    var refused = menu.AddItem(BMenuItem("two", BMessage(fourcc("two "))), 5)
    checks.check(
        "AddItem out of range: false, and the menu unchanged",
        added and not refused and menu.CountItems() == 1,
    )
    _ = menu^
    _ = app^

    # Re-entrancy: the nested call goes to the base class, once.
    var reentrant = BView(BRect(0, 0, 9, 9), "reentrant", 0, 0, Reentrant())
    reentrant.MessageReceived(BMessage(fourcc("reen")))
    checks.check("a hook entered again on its own object reaches the base",
                 reentrant.state[Reentrant]().calls == 1,
                 String(reentrant.state[Reentrant]().calls))
    reentrant.MessageReceived(BMessage(fourcc("agin")))
    checks.check("and the next call enters the hook again",
                 reentrant.state[Reentrant]().calls == 2)

    var total = checks.passed + checks.failed
    if checks.failed:
        print("SELFTEST FAIL", checks.passed, "/", total)
    else:
        print("SELFTEST PASS", String(checks.passed) + "/" + String(total))
