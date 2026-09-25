# Writing a Mojo application for Prose

A Mojo program on Prose is a real Haiku program: its windows are `BWindow`s,
its views draw on the app_server's thread schedule, its messages are
`BMessage`s. The `haiku` package is the Be API, generated from the headers,
with the Be Book's names; this guide is how to use it well. Every example
here is taken from a program in `Haiku/examples/` that runs on Prose.

The design behind it is `bridge-design.md`; what is and is not bridged, and
why, is `Haiku/bridge/MANIFEST.md`.

## Building

On Prose, with the compiler staged (`. /HostFS/mojo-haiku/env.sh`):

```
c++ -O2 -shared -fPIC -o libmojobe.so Haiku/bridge/libmojobe/mojobe.cpp \
    -lbe -ltracker -lgame
mojo build -I Haiku/bridge myapp.mojo -o myapp \
    -Xlinker -L. -Xlinker -lmojobe -Xlinker -lbe -Xlinker -rpath -Xlinker $PWD
```

`libmojobe` is the bridge's C++ half: build it once. `Haiku/tests/run.sh`
builds it, the tests and the examples, and is the quickest way to see that
everything works on your machine.

## The shape of a program

```mojo
def main() raises:
    var app = BApplication("application/x-vnd.Me-Dots")
    var window = BWindow(BRect(100, 100, 500, 400), "Dots",
                         B_TITLED_WINDOW, B_QUIT_ON_WINDOW_CLOSE, Main())
    window.AddChild(BView(frame, "canvas", B_FOLLOW_ALL, B_WILL_DRAW,
                          Canvas(dots^)))
    window^.Show()      # the window runs, and owns itself
    _ = app.Run()
```

Three kinds of thing appear here, and the types say which is which:

- **Owned values** (`BView`, `BMessage`, `BBitmap`, `BPath`): Mojo deletes
  them when they go, unless something *adopts* them. Adoption is a consuming
  argument: `window.AddChild(view^)`, `menu.AddItem(item^)`,
  `bar.AddItem(menu^)`. After it, the Mojo value is gone and the kit owns the
  object; using it again is a compile error, not a double free.
- **Self-owning objects** (`BWindow`, `BLooper`, `BAlert`, `BGamePane`) are
  handed to the system: `window^.Show()`, `looper^.Run()`, `alert^.Go()`.
  From then on the object lives on its own thread and deletes itself when it
  quits, so Mojo holds nothing that could dangle. To reach it later, keep a
  `BMessenger` made before you hand it over.
- **References** (`BViewRef[origin]`, `BWindowRef[origin]`) to objects the
  kit owns: what hooks receive and what methods return. More on these below.

**Mojo ends a value at its last use.** That is usually what you want, and
occasionally a surprise: a `BApplication` whose last use is its constructor
is gone by the next line, and menus and windows need it. Make `app.Run()`,
or `_ = app^`, the last thing `main` does with it.

Value types are plain structs laid out as C's: `BRect`, `BPoint`,
`rgb_color` (`rgb(255, 200, 0)`), `BSize`, `font_height`. `BRect` and
`BPoint` carry the C++ methods themselves (`InsetBy`, `Contains`, `&` and
`|` for intersection and union, `+` and `-`), compiled into the bridge.
`BMessenger` and `BFont` are values too, copied as bytes.

## Hooks: a Mojo type behind an object

A class the Be Book subclasses — `BView`, `BWindow`, `BApplication`,
`BLooper`, `BHandler`, `BListView`, `BGamePane` — can have a Mojo value
behind it. The value implements the hooks it wants, one trait each, and is
passed where C++ would take a subclass:

```mojo
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
```

- A hook the type does not implement never enters Mojo: the table is built
  at compile time.
- Hooks run on their looper's thread with the looper locked, as in C++.
- **Hooks do not raise.** A call that can fail goes in a `try`, and the hook
  decides what failing means; Mojo will not let an error reach C++.
- The class's own behaviour is `base_<Hook>`: a `WindowMessageReceived` that
  does not recognise a message passes it on with
  `window.base_MessageReceived(message)`.
- The Mojo value behind any such object is `ref.state[T]()`, which raises if
  it is not a `T`: `window.FindView("canvas").state[Canvas]().dots.clear()`.
- A hook that calls its own object's virtual method would enter the hook
  again; the bridge sends that call to the base class instead, and says so
  once on stderr.

## References, and why they cannot be kept

A reference carries an *origin*: what it was got from. The compiler keeps
that alive while the reference is used, and refuses to let the reference
outlive it:

- A hook's references are borrowed from the hook's call. `self.saved = view`
  does not compile — the view might be gone by the next hook.
- A reference a method returns is borrowed from what it was called on:
  `var child = parent.FindView("child")` keeps `parent` alive as long as
  `child` is used.
- A reference got from a window cannot be used after `window^.Show()`: the
  window runs on its own thread then.

Where a program really does keep a pointer, as Be programs keep their views,
`ref.unsafe_untracked()` says so: the compiler stops tracking it, and it is
yours to use only while the object exists and its looper is locked.

References may be NULL (`FindView` of a name that is not there): test them
with `if`. Calling through a NULL reference stops the program with the
method's name rather than crashing in C++.

## Messages

```mojo
comptime MSG_CLEAR = fourcc("clr ")

var message = BMessage(MSG_CLEAR)
message.AddInt32("count", 3)
message.AddString("name", "Prose")
var count = message.FindInt32("count")      # raises if it is not there
var info = message.GetInfo("count")         # out-parameters are results
```

A `status_t` that is not `B_OK` raises, and the error names it:
`BMessage::FindInt32: Name not found (B_NAME_NOT_FOUND)`. To act on which,
`status_of(e) == B_NAME_NOT_FOUND`. A `const char*` is a `String`; a
`const void*` and its length are one `Span`.

## Threads

A looper's hooks run on its thread. Other threads talk to it with a
`BMessenger` — messages, or a message and its reply:

```mojo
var messenger = BMessenger(looper)
looper^.Run()
messenger.SendMessage(MSG_TICK)
var reply = BMessage()
messenger.SendMessage(BMessage(MSG_ASK), reply)   # waits for the answer
```

To touch a looper's objects from another thread, lock it:

```mojo
with messenger.Locked() as looper:
    var window = looper.as_BWindow()
    window.FindView("level").as_BSlider().SetValue(7)
```

`looper` is borrowed from the lock and cannot leave the block; the block's
end unlocks it; `Locked()` raises `B_BAD_VALUE` if the looper has gone.
`as_BWindow()` and its kin are checked downcasts, NULL when the object is not
one. A `BMessageRunner` sends a message at an interval: the clock for
animations and games.

## Controls, menus, layouts

Controls are views that send their message when used; the window, their
default target, gets it in `MessageReceived` (`Haiku/examples/controls`):

```mojo
panel.AddChild(BButton(BRect(20, 20, 120, 45), "button", "Click",
                       BMessage(MSG_CLICK)))
panel.AddChild(BSlider(BRect(20, 95, 340, 140), "level", "Level",
                       BMessage(MSG_LEVEL), 0, 10))
```

Put controls on a view in the panel colour
(`panel.SetViewUIColor(B_PANEL_BACKGROUND_COLOR)`), as Haiku's own do.
A layout adds views only once it is set on a view, so set it first and add
through it:

```mojo
window.SetLayout(BGroupLayout(B_VERTICAL, 10))
var layout = window.GetLayout().as_BGroupLayout()
_ = layout.AddView(BButton("one", "One", BMessage(MSG_ONE)))
_ = layout.AddItem(BSpaceLayoutItem.CreateGlue())
```

A `BListView` made in Mojo owns its items (Haiku's does not delete them):
`AddItem` adopts, `RemoveItem(index)` gives the item back. An alert answers
through an invoker: `alert^.Go(BInvoker(BMessage(MSG_ANSWER), messenger))`.

## Drawing off the screen, and files

A `BBitmap` that accepts views is a canvas you can read back:
`bitmap.Bits()` is a `Span` of its bytes, borrowed from the bitmap
(`Haiku/tests/graphics_check.mojo`). Fonts are values: `be_plain_font()`,
`font.SetSize(...)`, `view.SetFont(font)`.

Settings belong in the user's settings directory:

```mojo
var settings = BPath()
find_directory(B_USER_SETTINGS_DIRECTORY, settings)
var path = settings.Path() + "/MyApp settings"
```

Write a file beside the old one and rename it over (`BEntry(path +
".new").Rename(path, True)`), so a failed write never leaves half a file,
and say when a save fails.

## Games: the game pane

`BGamePane` is a window whose pixels are palette indices, composited by the
host's GPU with sprites, text and a Metal shader of your own
(`Haiku/examples/galaxigans`, `Haiku/tests/game_check.mojo`). The shape
that works:

- A Mojo type behind the pane handles a tick message: step the game, draw,
  `Present()`. A `BMessageRunner` sends the tick at the game's rate; the
  frame runs on the pane's thread with the pane locked.
- `pane.World()` is a `Span` of the world's bytes: write it directly, or use
  `Clear`, `FillRect`, `Plot`, `Blit`. Index 0 is transparent — the
  background shader shows through.
- Sprites are defined once (`DefineSprite`, a byte a pixel, depth 4 with a
  sprite palette each) and listed every frame: `ClearSprites()`, then
  `DrawSprite` for each, which places a sprite by its top-left corner.
- Text is drawn into the world (`SetTextFont`, then `DrawText`), so it is
  redrawn with it every frame.
- `SetBackgroundShader` takes Metal source with a `float3 background(pane
  p)`; `SetShaderParam(i, v)` reaches it as `p.param(i)`.
- `B_GAME_PANE_SCANLINE_PALETTE` gives each row its own colours 1 to 15:
  the copper bar, the tractor beam.
- Keys: poll `get_key_info()` once a tick; `keys.is_down(code)` takes a raw
  key code.
- Sound: `BChipPlayer().Play(abc, track, loop)` plays ABC notation on the
  machine's chips.

## Testing

Every program should have a `--selftest` that prints `PASS`/`FAIL` a check
and ends `SELFTEST PASS n/n` (`controls`, `galaxigans-deluxe`). A GUI program
can drive itself: `controls --selftest` works its own controls from the
application's `ReadyToRun`, under `Locked()`. A game with a fixed seed and a
fixed step can run headless and compare where it ends.

On the test machine, as measured:

- Mouse events never reach windows on a scripted guest; drive a control
  with `Invoke()`, or test pointer hooks by hand.
- `get_key_info()` reads the keyboard whichever window is active, so a key
  sent to wake the screen reaches a game too (Galaxigans quits on Escape).
- `hey <signature> <message> Window 0` sends a program a message from the
  shell (`Haiku/tests/dots_smoke.py`).
- A headless machine's `capture` shows game panes (Prose.app from
  2026-09-25).
- Output to a file is buffered until exit: `print(..., flush=True)` for a
  trace you want to watch.
