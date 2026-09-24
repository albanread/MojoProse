# The Haiku bridge — design

*MojoProse, 2026-09-23. Gate G7 of `PORT-JOURNAL.md`. P0 and P1 are built
and run on Prose (Dots): the bridge is now generated from the headers.
Sections 16 and 17 record what building them measured, including corrections
to sections 3, 7 and 8.*

How Mojo programs on Prose use the Haiku API — open windows, draw, take the
mouse and the keyboard, send messages, show menus and alerts — as real Haiku
programs, not as guests in a toolkit of their own.

## 1. Decisions in brief

| | decision | because |
|---|---|---|
| D1 | A **generated bridge**: C entry points for the API, and C++ *shadow* subclasses that forward hooks to Mojo | Mojo speaks C; the Be API is C++ and is driven by subclassing (§3) |
| D2 | The bridge is compiled by a C++ compiler for Haiku, as a shared library, `libmojobe.so` | Vtables, mangling, inline methods and multiple inheritance stay the C++ compiler's business |
| D3 | **One trait per hook**; the bridge builds each Mojo type's hook table at compile time with `conforms_to` | A hook the program does not implement never enters Mojo |
| D4 | Four kinds of handle: **value**, **owned**, **reference**, **self-owning** | The Be API's ownership rules, stated in Mojo's types |
| D5 | Hooks run on their looper's thread with its lock held; references are valid only there or in a `Locked` block; other threads use `BMessenger` | That is Haiku's model; the bridge does not invent another |
| D6 | **One hook at a time per object**: a re-entrant hook on the same object falls to the base class | Two live `mut self` borrows of one Mojo object are not allowed |
| D7 | `status_t` failures raise; a hook cannot raise into C++, so its trampoline catches, reports and falls back to the base | Mojo errors must not cross the C boundary |
| D8 | The Be Book's names (`FillRect`, `SetHighColor`, `B_TITLED_WINDOW`) | The Be Book, and `prose_api.sqlite`, document the Mojo API as it stands |
| D9 | The generator reads the real headers through clang, plus a small hand-written annotation file; its output is committed | Nothing typed by hand that a header can say; ownership, which a header cannot say, written once |
| D10 | v1 covers the application, interface and messaging core, menus, controls, alerts, bitmaps, fonts and Prose's game pane (§13) | Enough for real applications and Galaxigans Deluxe |

## 2. What the program looks like

```mojo
from haiku import BApplication, BMenu, BMenuBar, BMenuItem, BMessage, BPoint
from haiku import BRect, BView, BWindow, fourcc, rgb
from haiku import BMessageRef, BViewRef, BWindowRef
from haiku import B_FOLLOW_ALL, B_QUIT_ON_WINDOW_CLOSE
from haiku import B_QUIT_REQUESTED, B_TITLED_WINDOW, B_WILL_DRAW
from haiku.hooks import ViewDraw, ViewMouseDown, WindowMessageReceived

comptime MSG_CLEAR = fourcc("clr ")


struct Canvas(Movable, ViewDraw, ViewMouseDown):
    var dots: List[BPoint]

    def __init__(out self, var dots: List[BPoint]):
        self.dots = dots^

    def Draw(mut self, view: BViewRef, updateRect: BRect):
        view.SetHighColor(rgb(30, 30, 46))
        view.FillRect(view.Bounds())
        view.SetHighColor(rgb(255, 200, 0))
        for p in self.dots:
            view.FillEllipse(p, 4, 4)

    def MouseDown(mut self, view: BViewRef, where: BPoint):
        self.dots.append(where)
        view.Invalidate()


struct Main(Movable, WindowMessageReceived):
    def __init__(out self):
        pass

    def MessageReceived(mut self, window: BWindowRef, message: BMessageRef):
        if message.what == MSG_CLEAR:
            try:
                var canvas = window.FindView("canvas")
                canvas.state[Canvas]().dots.clear()  # the window is locked
                canvas.Invalidate()
            except e:                   # hooks do not raise (section 8.6)
                print("Dots:", e)
        else:
            window.base_MessageReceived(message)    # BWindow's own handling


def main() raises:
    var app = BApplication("application/x-vnd.Prose-dots")
    var window = BWindow(BRect(100, 100, 500, 400), "Dots",
        B_TITLED_WINDOW, B_QUIT_ON_WINDOW_CLOSE, Main())

    var menu = BMenu("Dots")
    _ = menu.AddItem(BMenuItem("Clear", BMessage(MSG_CLEAR), "C"))
    _ = menu.AddItem(BMenuItem("Quit", BMessage(B_QUIT_REQUESTED), "Q"))
    var bar = BMenuBar(BRect(0, 0, 400, 19), "menubar")
    _ = bar.AddItem(menu^)              # the bar adopts the menu
    window.AddChild(bar^)               # and the window the bar

    var frame = window.Bounds()
    frame.top = 20
    window.AddChild(BView(frame, "canvas", B_FOLLOW_ALL, B_WILL_DRAW,
        Canvas(List[BPoint]())))
    window^.Show()                      # the window runs, and owns itself
    _ = app.Run()
```

(`Haiku/examples/dots/dots.mojo`, which starts with three dots. The results
C++ returns — `AddItem`'s `bool`, `Run`'s `thread_id` — are Mojo results
too, and Mojo warns when one is dropped silently.)

Every object here is the real thing: `BWindow` is a `BWindow` in the
application's team, drawn by app_server under the user's decorator and theme,
and `Canvas.Draw` runs on that window's thread when app_server asks it to.
This is what "native, not alien" means for Mojo.

## 3. Why a bridge

Objective-C, which MojoCocoa reaches, is C underneath: every call is
`objc_msgSend(object, selector, …)`, and classes are data the program can
inspect and create. C++ has no such runtime:

1. A method is a call to a mangled symbol (`_ZN7BWindow4ShowEv`) with `this`
   in `x0`.
2. A virtual method is a slot in a vtable, whose layout exists only inside the
   compiler that read the headers.
3. Objects are made by constructors and ended by destructors, which run code.
4. Many methods are **inline** and have no symbol at all (`BRect::Width()`);
   templates (`BLayoutBuilder`) do not exist until instantiated.
5. The API is driven by **subclassing**: a program overrides `BView::Draw`,
   `MouseDown`, `MessageReceived`, `BWindow::QuitRequested`, and the kits call
   the program through the vtable.

Mojo's foreign-function interface speaks C, both ways:
`external_call["symbol", R](args…)` calls C, and a function declared
`abi("C")` can be handed to C as a pointer — including a **generic** one,
instantiated per type, as the standard library does for CPython type slots
(`_tp_dealloc_wrapper[T](…) abi("C")`). Its C calling convention on arm64 is
AAPCS64 proper for Haiku (`CABIAAPCS.cpp`, Darwin only differing for
variadics): a C struct of four floats passes in `s0`–`s3`. **A `BRect` does
not** — measured in P0, see section 16: Haiku's `BRect` and `BPoint` declare
copy constructors, so C++ passes them by hidden reference, and the bridge's
C interface carries plain mirror structs instead.

So something has to make C++ look like C in both directions. That is the
bridge.

## 4. Requirements

- **R1 Native.** Real Be objects, real threads, real messages. Nothing drawn
  by the bridge itself.
- **R2 Safe where Mojo can say it.** Ownership, lifetime, thread and error
  rules expressed in types and checked by the compiler where possible; where
  not, checked at run time and reported, not crashed.
- **R3 Complete where mechanical.** Every public method of an included class,
  generated from the headers. No hand-typed signature, layout or constant.
- **R4 Fast enough.** One extra call per API call. Nothing per pixel through
  the bridge: bulk pixels go through `BBitmap` or the game pane.
- **R5 Maintainable.** Regenerate when the headers change; the hand-written
  part small and in one place.
- **R6 Testable.** The ABI proved against the C++ compiler; drawing proved by
  pixels read back through app_server.

## 5. Options considered

| | how | verdict |
|---|---|---|
| A | A hand-written C shim | Open-ended, and drifts from the headers. Rejected |
| **B** | **A generated bridge: C entry points plus shadow subclasses** | **Chosen**: no compiler change, every C++ feature handled by a C++ compiler, complete by generation |
| C | Compiler knowledge of C++: a database of layouts, vtable slots and mangled names; direct calls; vtables synthesized for Mojo types | The MojoCocoa ideal, and possible later — but a large compiler project, and inline functions and templates still need compiled C++ (Swift embeds a C++ compiler for them). B's Mojo API does not change if C replaces B underneath |
| D | An event queue: Be objects live in C++ threads, Mojo polls for events and sends commands | Rejected: Be hooks are synchronous. `Draw` must draw now, on the window's thread, under its lock; `QuitRequested` must answer now. A queue either blocks the window thread on Mojo or draws a frame late |

## 6. Architecture

```
  Mojo program
      │  import haiku
      ▼
  haiku (Mojo package)      value types, handles, hook traits, constants
      │   generated: haiku/_api.mojo, _values.mojo, _constants.mojo,
      │              hooks.mojo, __init__.mojo  (from the headers)
      │   written:   haiku/_core.mojo (pointers, strings, errors, state),
      │              Haiku/generator/snippets (value types' inline methods)
      │  external_call / abi("C") function pointers
      ▼
  libmojobe.so (C++)        mojobe_*  C entry points  +  Mojo* shadow classes
      │   generated from the headers; built for Haiku
      ▼
  libbe.so, libroot.so …    the Haiku API, unchanged
```

The generator (§10) produces both halves from one model of the headers, so
they cannot disagree.

## 7. The C++ half: `libmojobe`

### 7.1 Entry points

One `extern "C"` function per constructor, method and inline function of an
included class:

```cpp
// BView::FillRect(BRect rect, ::pattern pattern = B_SOLID_HIGH)
extern "C" void mojobe_BView_FillRect(BView* self, BRect rect, pattern p)
	{ self->FillRect(rect, p); }

extern "C" BView* mojobe_BView_new(BRect frame, const char* name,
	uint32 resizingMode, uint32 flags);
extern "C" void mojobe_BView_delete(BView* self);   // virtual destructor
```

- **Names:** `mojobe_<Class>_<Method>`; overloads get a suffix spelled from
  their parameter types (`mojobe_BView_new__BRect_charP_uint32_uint32`),
  not from the annotation file, and every entry point carries its C++
  signature as a comment. *(P1: the generator needs no overload names.)*
- **Arguments:** `this` first. Value types by value, **each as a plain C
  mirror struct** (`mojobe_BRect`) converted inside (section 16.1, 17.1); all
  other objects by pointer; strings as `const char*` (UTF-8, as Haiku is
  throughout).
- **Default arguments** become Mojo default arguments, not C overloads.
- **Exceptions** never cross: every entry point is `noexcept`; `bad_alloc`
  becomes `NULL` or `B_NO_MEMORY`; anything else calls `debugger()` with the
  entry point's name, because it is a bridge bug. *(Owed: P1's entry points
  are not yet `noexcept`; constructors use `new(std::nothrow)`.)*
- **Locking** is never implicit. Haiku requires the looper's lock for most
  view and window calls; the bridge leaves that where Haiku puts it, and the
  Mojo half enforces it (§8.5).

### 7.2 Shadow classes

For each class a program subclasses — v1: `BApplication`, `BWindow`,
`BView`, `BHandler`, `BLooper`, `BGamePane` — a C++ subclass forwards the
Be Book's **hook functions** (not every virtual: `SetHighColor` is virtual,
but it is not a hook) to a table of Mojo function pointers:

```cpp
struct mojobe_view_hooks {                 // one table per Mojo type, constant
	uint64	type;                          // names the Mojo type (§16.2)
	void	(*destroy)(void* context);
	void	(*Draw)(void* context, BView* view, BRect updateRect);
	void	(*MouseDown)(void* context, BView* view, BPoint where);
	void	(*MessageReceived)(void* context, BView* view, BMessage* message);
	// … one slot per hook; NULL when the Mojo type has no such hook
};

class MojoBView : public BView {
public:
	MojoBView(BRect frame, const char* name, uint32 resizingMode,
		uint32 flags, const mojobe_view_hooks* hooks, void* context);
	virtual ~MojoBView();                  // hooks->destroy(context) first

	virtual void Draw(BRect updateRect)
	{
		if (fHooks->Draw == NULL || !_Enter())
			return BView::Draw(updateRect);
		fHooks->Draw(fContext, this, updateRect);
		_Leave();
	}
	// … likewise for each hook
private:
	const mojobe_view_hooks*	fHooks;
	void*						fContext;   // the Mojo object, on the heap
	int32						fDepth;     // §9
};

// the base implementation, for a Mojo hook that wants BView's behaviour too
extern "C" void mojobe_BView_base_MessageReceived(BView* self, BMessage* m)
	{ self->BView::MessageReceived(m); }
```

- The **context** is the Mojo object, moved to the heap when the shadow is
  made and freed by `destroy` when the C++ object dies. It never moves, so the
  pointer the C++ side holds stays valid.
- The destructor calls `destroy` **before** the base destructor runs. While
  `~BView` runs the object is a `BView`, so no hook can reach freed Mojo
  state.
- A slot left `NULL` costs one comparison and never enters Mojo: a view that
  does not implement `MouseMoved` pays nothing for the mouse moving over it.
- Multiple inheritance, thunks and RTTI are the C++ compiler's work.
  `dynamic_cast<BView*>` on a `MojoBView` works as on any subclass.

## 8. The Mojo half: the `haiku` package

### 8.1 Value types

Generated with the headers' layout, and each checked at compile time against
the numbers clang computed for the Haiku target:

```mojo
struct BRect(TrivialRegisterPassable):
    var left: Float32
    var top: Float32
    var right: Float32
    var bottom: Float32

comptime assert size_of[BRect]() == 16    # from clang's record layout
```

Their inline methods (`Width()`, `Contains()`, `InsetBy()`) are written in
Mojo — they are arithmetic — and a conformance test runs every one against
the C++ through the bridge.

### 8.2 Four kinds of handle

| kind | examples | who deletes | in Mojo |
|---|---|---|---|
| **value** | `BRect`, `BPoint`, `rgb_color`, `BMessenger` | nobody: copied | plain structs |
| **owned** | `BMessage`, `BBitmap`, `BFont`, a `BView` not yet added | Mojo, in `__deinit__` | a struct holding the pointer; moved, never copied |
| **reference** | `BViewRef`, `BWindowRef`, `BMessageRef` | the kit | a non-owning pointer, valid in a hook or a `Locked` block; may be NULL |
| **self-owning** | `BWindow`, `BApplication`, `BAlert` | itself (`Quit()`, `Go()`) | consumed by the call that hands it to the system: `window^.Show()` |

**Adoption** is a consuming parameter. `BWindow.AddChild(var child: BView)`
takes the owned `BView`; the window owns it now, and the Mojo value is gone —
using it afterwards is a compile error, not a double free. Which parameters
adopt is written in the annotation file, from the Be Book:

```
BView::AddChild(child)          adopts child
BWindow::AddChild(child)        adopts child
BMenu::AddItem(item)            adopts item
BView::RemoveChild(child)       returns ownership of child
BLooper::PostMessage(message)   copies           # the caller keeps it
BAlert::Go()                    deletes self
```

**Methods** are shared through a trait per class (P1): `_BViewMethods`
holds every `BView` method, and both `BViewRef` and the owned `BView`
conform, so a method is written once. A bridged base's trait is inherited
(`_BMenuMethods` inherits `_BViewMethods`); an unbridged base's methods
(`BHandler`'s, `BLooper`'s) are carried by the nearest bridged class. A class's
methods take objects as `Some[_AsBView]`: any reference or owned value of
`BView` or a subclass, borrowed. Upcasts are implicit (`bar^` passes where
a `BView` is adopted; a `BMenuBarRef` is a `BViewRef`), through an entry
point per base (`mojobe_BMenuBar_as_BView`) so C++ does any pointer
adjustment.

**References may be NULL.** A method returning an object pointer returns a
reference, which is NULL when C++ returns NULL (`FindView` of a name that is
not there, `Parent()` of a top view): test it with `if`. Calling a method
through a NULL reference stops the program with the method's name
(`haiku: BView::Name() called through a NULL reference`), rather than
letting C++ dereference it.

**Self-owning objects** are handed over, not kept: after `window^.Show()` the
window runs its own thread and deletes itself when it quits, so Mojo holds no
handle that could dangle. To reach it later, from any thread and safely even
after it has gone, a program keeps a `BMessenger`, as Haiku programs do.

### 8.3 Hooks

One trait per hook, generated:

```mojo
trait ViewDraw:
    def Draw(mut self, view: BViewRef, updateRect: BRect): ...

trait ViewMouseDown:
    def MouseDown(mut self, view: BViewRef, where: BPoint): ...
```

A type implements the hooks it wants — `struct Canvas(ViewDraw,
ViewMouseDown)` — and making a `BView` from it builds that type's table once,
at compile time:

```mojo
def _BView_hooks[T: Movable & Deinitable]() -> _BViewHooks:
    var hooks = _BViewHooks()
    hooks.type = _type_tag[T]()
    hooks.destroy = _fn_ptr(_destroy[T])
    comptime if conforms_to(T, ViewDraw):
        hooks.Draw = _fn_ptr(_BView_Draw[downcast[T, ViewDraw]])
    comptime if conforms_to(T, ViewMouseDown):
        hooks.MouseDown = _fn_ptr(_BView_MouseDown[downcast[T, ViewMouseDown]])
    # …
    return hooks

def _BView_Draw[T: ViewDraw](context: _Ptr, view: Int, updateRect: BRect) abi("C"):
    context.unsafe_bitcast[T]()[].Draw(BViewRef(_ptr_from(view)), updateRect)
```

(As generated in P1. The hook traits' methods do not raise, so there is
nothing for a trampoline to catch: §8.6.)

Every mechanism here is one the standard library already uses: generic
`abi("C")` functions and `comptime if conforms_to(T, Trait)`.

Some hooks answer: `QuitRequested(mut self, window: BWindowRef) -> Bool`.
Calling the base class is a method on the reference:
`window.base_MessageReceived(message)`.

### 8.4 Making subclassed objects

`BView(frame, name, resizingMode, flags, Canvas(...))` moves the `Canvas` to
the heap, takes `_view_hooks[Canvas]()`, and calls `mojobe_MojoBView_new`.
It returns an **owned** `BView`, ready to be adopted by `AddChild`.

The Mojo state behind a view is reached through a reference —
`view.state[Canvas]()` — and references exist only inside a hook or a
`Locked` block, both of which hold the lock. Asking for the wrong type
raises.

### 8.5 Threads and locks

Haiku's rules, stated once:

1. A hook runs on its looper's thread with the looper locked. Everything it
   receives (`BView.Ref`, `BMessage.Ref`) is valid for the call.
2. A Mojo hook object belongs to that looper. Two windows do not share one.
3. Between loopers, a program sends messages: `BMessenger.SendMessage`,
   `PostMessage`. That is how Haiku programs talk across threads.
4. Touching a looper's objects from another thread takes its lock:

   ```mojo
   with window.Locked() as w:          # BLooper::Lock / Unlock
       w.FindView("canvas").Invalidate()
   ```

   `Locked` fails, and raises, if the window has gone.
5. Mojo's own parallelism (`parallelize`) is fine inside a hook, for
   computation. Worker threads must not touch Be objects: they do not hold the
   lock.

References cannot be stored beyond their call: `BView.Ref` carries an origin
tied to the hook or the `Locked` block that produced it, so keeping one in a
struct field is refused by the compiler.

### 8.6 Errors

- A method that returns `status_t` raises when the status is not `B_OK`,
  with the method and `strerror(status)`: `BMessage::FindInt32: Name not
  found`. *(P1 raises a plain `Error`; `HaikuError`, carrying the status,
  is owed.)* A constructor with a `status_t*` parameter (`BApplication`'s,
  named `init_check` in the annotations) raises with that status, and a
  failed object is deleted; classes with only `InitCheck()` are owed.
- Hooks cannot raise into C++. *As built:* the hook traits' methods are
  declared without `raises`, so the compiler makes each hook handle its own
  errors (Dots' `MessageReceived` wraps `FindView` in `try`), and no Mojo
  error ever reaches a trampoline. The catch-and-report trampoline above is
  what a raising hook trait would need; P1 did not need one.

### 8.7 Messages and strings

`BMessage` gets its typed accessors generated (`AddString`, `FindInt32`,
`AddRect`, …) with Mojo types; `what` codes are `fourcc("clr ")`, evaluated
at compile time. `String` crosses as UTF-8, which is what Haiku uses
everywhere.

### 8.8 Names

The Be Book's, for classes, methods, constants and hooks, so its pages
document the Mojo API. The Mojo additions are few and all in `haiku._core`:
`Ref`, `Locked`, `state`, `base_…`, `fourcc`, `HaikuError`.

## 9. Re-entrancy

Most hooks arrive as messages, one at a time on the looper's thread, but a few
are called from inside other calls: `AttachedToWindow` runs inside `AddChild`,
`FrameResized` can run inside `ResizeTo`. A hook that triggers another hook on
**the same object** would hold two `mut self` borrows of one Mojo value at
once, which Mojo forbids.

So each shadow counts: a hook entered while another hook of the same object
is running goes to the **base class** instead, and a debug build says so
once. Hooks of *different* objects nest freely — that is `AddChild` calling
the child's `AttachedToWindow` from the parent's hook, which is common and
fine.

## 10. The generator

`Haiku/generator/mojobe_gen.py` (Python, standard library only), with its
annotations in `Haiku/generator/bridge.toml`. It runs in about 4 s.

- **Input:** the Haiku headers from the Prose sysroot, parsed by clang for
  `aarch64-unknown-haiku` (`-Xclang -ast-dump=json`); the class list and
  annotations of `bridge.toml`. Constants and value-type layouts are not
  computed by the generator: it writes a probe of `extern "C"` globals
  (`(long long)(B_WILL_DRAW)`, `sizeof(BRect)`, `offsetof(BRect, top)`, the
  type's size and signedness), has the same clang compile it to LLVM IR,
  and reads the numbers back — clang's own evaluation, `_rule_()` macros
  and all. A name that is not a number fails to compile in the probe and is
  left out, found by halving.
- **Annotations** carry what headers cannot: the value types; per class its
  handle kind, its hooks, the methods that hand it over (`Show`), how to
  delete one never handed over, and the constructor parameter that reports
  its status; which parameters adopt (`[adopts]`, from the Be Book); which
  pointer parameters are read as well as written (`[inout]`); a skip list
  with a reason for each entry. No overload names and no signatures.
- **Rules** it applies without annotations (P1, section 17): value types
  cross as C mirror structs; named enums become Mojo types; `status_t`
  results raise; non-const pointers to numbers, enums and value types, and
  `const char**`, are results; `const char*` is a `String`, or
  `Optional[String] = None` where C++ defaults it to `NULL`; object
  pointers are references, or `Some[_As…]` parameters; C++ default
  arguments become Mojo ones where they can be said (literals, constants,
  `NULL`), and a parameter after one that cannot keeps none; archive
  constructors, operators and statics are left out; an override already
  reached through a bridged base is left out; an overload a call could not
  tell from an earlier one is left out.
- **Output:** `libmojobe` sources, the generated `haiku/*.mojo` modules, and a
  manifest of every method included, skipped, and why. Generated files are
  committed so every regeneration is a reviewable diff.
- **Out of scope for generation:** templates (`BLayoutBuilder`: v1 uses the
  non-template `BGroupLayout` and `BGridLayout`, and a Mojo builder can come
  later), operators other than `==` on value types, variadic functions, and
  function-pointer parameters (the few that matter, such as
  `BSoundPlayer`'s buffer callback, get hand-written trampolines).
- It runs on the Mac with the build's own clang and the Prose sysroot, like
  everything else in MojoProse. The same clang, with `ld.lld`, also builds
  and links `libmojobe.so` on the Mac against the sysroot's `libbe`;
  P1's tests used the one Prose's own clang built, from the same sources.

## 11. Building, linking, shipping

- `libmojobe.so` is built by Bazel's Haiku target toolchain (G2), from the
  committed sources. clang and the GCC that built `libbe` share the Itanium
  C++ ABI; the ABI oracle (§12) is what proves it for our types, and if it
  ever disagrees, `libmojobe` is built with GCC instead.
- On Prose, a program that imports `haiku` links with `-lmojobe -lbe`: the
  `haiku` package states its libraries, so `mojo build` adds them.
- A Haiku application wants an application signature in its resources for
  Tracker and the roster. `BApplication("application/x-vnd.…")` is enough to
  run; `mojo build` then `mimeset` makes Tracker agree; icons come later
  with `rc`.
- `libmojobe.so` and the precompiled `haiku` package ship in the Prose image
  beside the compiler (G8).

## 12. Testing

| test | proves |
|---|---|
| ABI oracle | Mojo and the C++ compiler agree on every value type by value and by return, and on every hook signature |
| value types | Mojo's `BRect.InsetBy` and friends match the C++ inline ones |
| pixels | drawing through the bridge, read back through app_server, is exact — as `tools/blittest` does for app_server itself |
| lifetime | a window quits while Mojo holds a messenger: sends fail cleanly, nothing is freed twice; a view's Mojo state is destroyed exactly once |
| threads | hooks run on the right thread; `Locked` from another thread works, and fails cleanly after `Quit()` |
| re-entrancy | a hook that resizes its own view gets the base `FrameResized`, and says so in a debug build |
| examples | Dots (§2), a menu and controls application, and Galaxigans Deluxe on the game pane |

## 13. Scope of v1

- **App kit:** `BApplication`, `BLooper`, `BHandler`, `BMessage`,
  `BMessenger`, `BMessageRunner`.
- **Interface kit:** `BWindow`, `BView`, `BBitmap`, `BFont`, `BScreen`,
  `BRegion`, `BMenuBar`, `BMenu`, `BMenuItem`, `BPopUpMenu`, `BButton`,
  `BCheckBox`, `BRadioButton`, `BTextControl`, `BSlider`, `BStringView`,
  `BListView`, `BScrollView`, `BAlert`, `BGroupLayout`, `BGridLayout`.
- **Storage kit:** `BPath`, `BEntry`, `BFilePanel`, `find_directory`.
- **Prose:** `BGamePane`, `BChipPlayer`.
- Everything else waits until a program needs it; the generator makes adding
  a class a line in the allowlist and its annotations.

## 14. Phasing

| step | what | done when |
|---|---|---|
| P0 | By hand, what the generator will write, for `BApplication`, `BWindow`, `BView` and `BMessage` with three hooks | Dots runs on Prose. It answers the Mojo questions with running code: per-type tables, adoption by consuming parameters, `Ref` origins |
| P1 | The generator, for the same classes | its output replaces P0's, and Dots still runs — **done 2026-09-24** (§17) |
| P2 | The v1 scope, the ABI oracle, the tests | §12 passes on Prose |
| P3 | Galaxigans Deluxe and a document | the game plays on Prose; `writing-a-mojo-app.md` |

P0 needs a Mojo compiler that targets Haiku (G4 onwards, or the host compiler
of G1 cross-compiling) and the standard library taught Haiku (G5).

## 15. Open questions

1. **`Ref` origins.** Tying a reference's lifetime to a hook call is what Mojo
   origins are for, but the exact spelling for a pointer handed in from C is
   for P0 to settle. The fallback is a run-time check: each shadow stamps a
   generation number on the references it gives out. *Still open after P1,
   and now with a measured case (§17.6): a reference got from an owned value
   (`parent.FindView("child")`) does not keep the value alive, and Mojo ends
   the value at its last use — deleting the view the reference points into.
   A reference returned by a method of an owned value should carry that
   value's origin; P2 decides how.*
2. **Hook traits.** A trait per hook is precise but long to write out; a type
   that wants twelve hooks lists twelve traits. The alternative, one trait
   with default bodies and no per-hook tables, sends every hook through Mojo.
   P0 decides with real code.
3. **Where the generator runs.** On the Mac with the Haiku sysroot, as above,
   or on Prose with its own clang against its own headers. Either produces
   the same committed output. *P1: on the Mac; its output is deterministic
   (two runs, identical files).*
4. **Signals and `debugger()`.** A crash in a hook should reach Haiku's debug
   server like any crash, with a useful Mojo stack. Whether Mojo's frames
   unwind cleanly there is for G6.

## 16. What P0 measured (2026-09-23)

Dots (section 2, plus three starting dots) runs on Prose: `libmojobe.so` built
there by Prose's clang, Dots by the Haiku-built `mojo`. Checked by screen
capture and pixel count: the window, its menu bar, the canvas colour and the
three dots where the Mojo data puts them; after `'clr '` reaches the window
(sent with `hey`), `MessageReceived` runs in Mojo, `FindView` and
`state[Canvas]()` find the view's Mojo value, and the redrawn canvas has no
dots; a quit request ends the loop and the program exits 0. `MouseDown` is
built but unproved: mouse events never reach windows on the scripted guest,
so it wants a person with a mouse.

1. **`BRect` and `BPoint` go by hidden reference.** Their copy constructors
   are user-declared (inline), which makes them non-trivial for calls in the
   Itanium C++ ABI — GCC and clang agree, and `libbe`'s own `BWindow`
   constructor takes its frame as a pointer. The first Dots crashed in
   `strlen` inside `BWindow()`: the entry point read the frame's address from
   `x0`, where Mojo had put the title, and the title from `x1`, the window
   type — `strlen(0x1)`. The C interface now carries `mojobe_rect` and
   `mojobe_point` (true C structs, `s0`–`s3`) in parameters, results and hook
   signatures, and converts inside. The generator must do this for every
   value class with a user-declared copy constructor; the ABI oracle (section
   12) is what catches the next one. `rgb_color`, a C struct, passes as is.
2. **A function's address does not name a type.** Mojo takes the address of
   `_destroy[T]` through a thunk made where the address is taken
   (`…__init__…_closure_0`), so two places get two addresses. Each hook table
   carries a **type tag** instead — FNV-1a of `reflect[T].name
   [qualified_builtins=True]()` — and `state[T]()` asks for the tag.
3. **One trait per hook works** (question 2): `comptime if conforms_to(T,
   ViewDraw)` with `downcast[T, ViewDraw]` (from `std.builtin.rebind`)
   instantiates the right trampoline, and a hook a type lacks is a NULL slot.
4. **Adoption by consuming arguments works**: `_adopt(deinit self)` hands
   the pointer over without the destructor; menus into the bar, the bar and
   the view into the window, the window to the system with `window^.Show()`;
   quitting frees each exactly once (a clean exit, no double free).
5. **`Ref` origins are still open** (question 1): P0's references are plain
   trivially-copyable structs. Nothing stops a program keeping one past its
   hook.
6. This Mojo's spellings: `__deinit__`, not `__del__`; a `String` handed to
   C must be owned (`var`), as `as_c_string_span()` may add the NUL;
   `unsafe_bitcast`; `OptionalPointer` for nullable function pointers, in
   `RegisterPassable` (not trivially) structs, as the stdlib's CPython slots.

## 17. What P1 measured (2026-09-24)

The generator (§10) writes both halves for P0's seven classes —
`BApplication`, `BWindow`, `BView`, `BMessage`, `BMenu`, `BMenuBar`,
`BMenuItem` — and its output replaces P0's hand-written bridge: 641 methods
included and 379 left out, each with its reason in `Haiku/bridge/MANIFEST.md`,
and 916 constants. Three quarters of what is left out (284) is left out for
a type the bridge does not carry yet (`BHandler`, `BMessenger`, `BBitmap`,
`BGradient`, `BSize`, …), which P2's scope brings in; the rest are overrides
already reached through a base (33), statics (18), overloads a call could
not tell apart (13), in/out pointers with by-value twins (12), and the
annotated skips.

Dots builds against the output unchanged but for two results it now
discards, and passes on Prose: `Haiku/tests/dots_smoke.py`, 5/5 — the
window, its menu bar, the canvas colour and the three dots, captured from
the machine's screen; Dots ▸ Clear (`'clr '`, sent with `hey`) through
`MessageReceived`, `FindView` and `state[Canvas]()` in Mojo; a quit request,
exit status 0. `Haiku/tests/bridge_check.mojo` checks the other ways a
signature is carried, against `libbe` itself: 28/28.

1. **Every value type crosses as a mirror struct**, not only those with a
   user-declared copy constructor (§16.1): `rgb_color` passes in registers,
   but clang warns (`-Wreturn-type-c-linkage`) of an `extern "C"` function
   returning one, because its member functions make it a C++ type to C.
   Mirroring all of them is uniform and costs nothing.
2. **Named enums are Mojo types.** `window_type` and `window_look` are both
   32-bit; as `UInt32`, `BWindow`'s two constructors — `(frame, title, type,
   flags)` and `(frame, title, look, feel, flags)` — could not be told apart
   once `workspace`'s default is counted, and one had to go. As structs
   (`B_TITLED_WINDOW = window_type(1)`, `Equatable`, with `|`) both work, and
   a look where a type is wanted is a compile error. Anonymous enums and
   `const` integers stay integers (`B_WILL_DRAW: UInt32`).
3. **Out-parameters are results.** `status_t FindInt32(const char* name,
   int32* value)` is `FindInt32(name) raises -> Int32`; `GetInfo(name,
   type_code*, int32*)` returns a tuple. A pointer that is read too
   (`ConvertToParent(BPoint*)`) is named in `[inout]` and left out; each has
   a by-value twin, which stays (a first version left the twin out as well:
   the annotation named a parameter, and both overloads have one of that
   name; `bridge_check` now calls the twins).
4. **Overloads that Mojo cannot tell apart are left out**, checked as calls:
   two collide if, for some number of arguments both accept, their parameter
   types agree that far. `BMessage`'s old `FindInt32(name, int32 n = 0)`
   collides with the raising `FindInt32(name)` and `FindInt32(name, index)`,
   declared before it, which stay. A constructor that reports its status is
   tried first (`BApplication(signature, status_t*)` over
   `BApplication(signature)`).
5. **clang's JSON AST, as it is:** a location's file is written only when it
   changes, so the generator follows the document in order; a
   copy-initialised default's source range starts at its `=`; typedefs are
   not desugared below the top level (`int32 *` has no `int *` form), so the
   generator resolves them itself; a string macro converts to `long long`
   without complaint, so the probe requires an arithmetic type; members'
   access follows the `AccessSpecDecl`s in order, from the class's default.
6. **A reference does not keep its owner alive.** `bridge_check`'s first run
   stopped with `haiku: BView::Name() called through a NULL reference`:
   after `var child = parent.FindView("child")`, Mojo ended `parent` at its
   last use, deleting the child view `child` pointed into, and `Parent()`
   read freed memory. The NULL check caught it by luck. This is §15's first
   question, measured.
7. **An adopting method that fails leaks.** `BMenu::AddItem` returns `false`
   when it cannot add the item, and the caller keeps it; the Mojo value is
   already consumed. Owed: an adopting method returning `bool` should hand
   the value back, or delete it.
8. **`const` results become mutable references** (`const BMessage*
   BMessage::Previous()`). Owed.
9. **Testing a headless machine:** the guest's `screenshot` and the host's
   capture both gave black frames while the machine's screen was blanked; a
   key press (Prose.app's `press "escape"`) wakes it, and `dots_smoke.py`
   sends one before capturing.

Still owed after P1, besides 6–8: `HaikuError` (§8.6), `noexcept` entry
points (§7.1), `Locked` (§8.5), the ABI oracle (§12), value types' inline
methods beyond `BRect.Width`/`Height` (hand-written snippets for now, with
`B_ORIGIN` and the `pattern` constants, which the headers declare `extern`),
`InitCheck()` for classes without a status parameter, and `MouseDown`, which
still wants a person with a mouse.
