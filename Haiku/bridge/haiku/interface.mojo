# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""The application and interface kits' objects that Mojo makes and owns, and
the shadow classes that forward their hooks to Mojo.

Ownership follows the Be API (design section 8.2):

- An owned object (`BMessage`, `BView`, `BMenu`, `BMenuItem`, `BMenuBar`)
  is deleted with its Mojo value, unless something adopted it first: an
  adopting method takes it as a consuming (`var`) argument, and the Mojo
  value is gone.
- A self-owning object (`BWindow`) is handed to the system by the call that
  starts it -- `window^.Show()` -- and deletes itself when it quits.
"""

from std.builtin.rebind import downcast
from std.ffi import c_char, external_call
from std.memory.alloc import unsafe_alloc

from ._core import (
    BMessageRef,
    BPoint,
    BRect,
    BViewRef,
    BWindowRef,
    _FnPtr,
    _Ptr,
    _destroy,
    _fn_ptr,
    _type_tag,
)
from .hooks import (
    ViewDraw,
    ViewMessageReceived,
    ViewMouseDown,
    WindowMessageReceived,
    WindowQuitRequested,
)


# ===----------------------------------------------------------------------=== #
# Hook tables and trampolines
# ===----------------------------------------------------------------------=== #


struct _ViewHooks(ImplicitlyCopyable, RegisterPassable):
    """`mojobe_view_hooks`: a type tag and nullable function pointers,
    laid out as C's."""

    var type: UInt64
    var destroy: _FnPtr
    var Draw: _FnPtr
    var MouseDown: _FnPtr
    var MessageReceived: _FnPtr

    def __init__(out self):
        self.type = 0
        self.destroy = {}
        self.Draw = {}
        self.MouseDown = {}
        self.MessageReceived = {}


struct _WindowHooks(ImplicitlyCopyable, RegisterPassable):
    """`mojobe_window_hooks`: a type tag and nullable function pointers,
    laid out as C's."""

    var type: UInt64
    var destroy: _FnPtr
    var MessageReceived: _FnPtr
    var QuitRequested: _FnPtr

    def __init__(out self):
        self.type = 0
        self.destroy = {}
        self.MessageReceived = {}
        self.QuitRequested = {}


def _view_draw[
    T: ViewDraw
](context: _Ptr, view: _Ptr, updateRect: BRect) abi("C"):
    context.unsafe_bitcast[T]()[].Draw(BViewRef(view), updateRect)


def _view_mouse_down[
    T: ViewMouseDown
](context: _Ptr, view: _Ptr, where: BPoint) abi("C"):
    context.unsafe_bitcast[T]()[].MouseDown(BViewRef(view), where)


def _view_message_received[
    T: ViewMessageReceived
](context: _Ptr, view: _Ptr, message: _Ptr) abi("C"):
    context.unsafe_bitcast[T]()[].MessageReceived(
        BViewRef(view), BMessageRef(message)
    )


def _window_message_received[
    T: WindowMessageReceived
](context: _Ptr, window: _Ptr, message: _Ptr) abi("C"):
    context.unsafe_bitcast[T]()[].MessageReceived(
        BWindowRef(window), BMessageRef(message)
    )


def _window_quit_requested[
    T: WindowQuitRequested
](context: _Ptr, window: _Ptr) abi("C") -> Bool:
    return context.unsafe_bitcast[T]()[].QuitRequested(BWindowRef(window))


def _view_hooks[T: Movable & Deinitable]() -> _ViewHooks:
    """`T`'s hook table: a slot for each hook it implements, NULL for the
    rest, decided at compile time."""
    var hooks = _ViewHooks()
    hooks.type = _type_tag[T]()
    hooks.destroy = _fn_ptr(_destroy[T])
    comptime if conforms_to(T, ViewDraw):
        hooks.Draw = _fn_ptr(_view_draw[downcast[T, ViewDraw]])
    comptime if conforms_to(T, ViewMouseDown):
        hooks.MouseDown = _fn_ptr(_view_mouse_down[downcast[T, ViewMouseDown]])
    comptime if conforms_to(T, ViewMessageReceived):
        hooks.MessageReceived = _fn_ptr(
            _view_message_received[downcast[T, ViewMessageReceived]]
        )
    return hooks


def _window_hooks[T: Movable & Deinitable]() -> _WindowHooks:
    """`T`'s hook table for a window."""
    var hooks = _WindowHooks()
    hooks.type = _type_tag[T]()
    hooks.destroy = _fn_ptr(_destroy[T])
    comptime if conforms_to(T, WindowMessageReceived):
        hooks.MessageReceived = _fn_ptr(
            _window_message_received[downcast[T, WindowMessageReceived]]
        )
    comptime if conforms_to(T, WindowQuitRequested):
        hooks.QuitRequested = _fn_ptr(
            _window_quit_requested[downcast[T, WindowQuitRequested]]
        )
    return hooks


def _to_heap[T: Movable & Deinitable](var value: T) -> _Ptr:
    """Moves `value` to the heap, where it stays while its object lives."""
    var context = unsafe_alloc[T](1)
    context.unsafe_write(value^)
    return context.unsafe_bitcast[NoneType]()


# ===----------------------------------------------------------------------=== #
# BApplication and BMessage
# ===----------------------------------------------------------------------=== #


struct BApplication(Movable):
    """The application: one a team, made first, run by `Run()`."""

    var _ptr: _Ptr

    def __init__(out self, var signature: String) raises:
        """Makes the application.

        Args:
            signature: Its MIME signature, `application/x-vnd.…`.

        Raises:
            When BApplication's InitCheck fails.
        """
        var error = Int32(0)
        var app = external_call["mojobe_BApplication_new", _FnPtr](
            signature.as_c_string_span(), Pointer(to=error)
        )
        if not app:
            raise Error("BApplication failed with status ", error)
        self._ptr = app.value()

    def Run(mut self):
        """Runs the application's message loop until it quits."""
        _ = external_call["mojobe_BApplication_Run", Int32](self._ptr)

    def __deinit__(deinit self):
        external_call["mojobe_BApplication_delete", NoneType](self._ptr)


struct BMessage(Movable):
    """A message Mojo owns, until something adopts it."""

    var _ptr: _Ptr

    def __init__(out self, what: UInt32) raises:
        var message = external_call["mojobe_BMessage_new", _FnPtr](what)
        if not message:
            raise Error("out of memory making a BMessage")
        self._ptr = message.value()

    def __deinit__(deinit self):
        external_call["mojobe_BMessage_delete", NoneType](self._ptr)

    def _adopt(deinit self) -> _Ptr:
        """Hands the message over without deleting it."""
        return self._ptr


# ===----------------------------------------------------------------------=== #
# BView and BWindow
# ===----------------------------------------------------------------------=== #


struct BView(Movable):
    """A view made from a Mojo value, owned until a window or view adopts
    it."""

    var _ptr: _Ptr

    def __init__[
        T: Movable & Deinitable
    ](
        out self,
        frame: BRect,
        var name: String,
        resizingMode: UInt32,
        flags: UInt32,
        var state: T,
    ) raises:
        """Makes a view whose hooks are `state`'s.

        Args:
            frame: The view's frame in its parent's coordinates.
            name: The view's name, for `FindView`.
            resizingMode: `B_FOLLOW_…`.
            flags: `B_WILL_DRAW` and friends.
            state: The Mojo value behind the view; its type's hook traits
                are the hooks the view has.

        Raises:
            When the view cannot be made.
        """
        var hooks = _view_hooks[T]()
        var context = _to_heap(state^)
        var view = external_call["mojobe_MojoBView_new", _FnPtr](
            frame,
            name.as_c_string_span(),
            resizingMode,
            flags,
            Pointer(to=hooks),
            context,
        )
        if not view:
            _destroy[T](context)
            raise Error("out of memory making a BView")
        self._ptr = view.value()

    def __deinit__(deinit self):
        external_call["mojobe_BView_delete", NoneType](self._ptr)

    def _adopt(deinit self) -> _Ptr:
        return self._ptr


struct BWindow(Movable):
    """A window made from a Mojo value. It owns itself once `Show()` has
    handed it to the system."""

    var _ptr: _Ptr

    def __init__[
        T: Movable & Deinitable
    ](
        out self,
        frame: BRect,
        var title: String,
        type: UInt32,
        flags: UInt32,
        var state: T,
    ) raises:
        """Makes a window whose hooks are `state`'s.

        Raises:
            When the window cannot be made.
        """
        var hooks = _window_hooks[T]()
        var context = _to_heap(state^)
        var window = external_call["mojobe_MojoBWindow_new", _FnPtr](
            frame,
            title.as_c_string_span(),
            type,
            flags,
            Pointer(to=hooks),
            context,
        )
        if not window:
            _destroy[T](context)
            raise Error("out of memory making a BWindow")
        self._ptr = window.value()

    def Bounds(self) -> BRect:
        return external_call["mojobe_BWindow_Bounds", BRect](self._ptr)

    def AddChild(mut self, var child: BView):
        """Adds a view; the window adopts it."""
        external_call["mojobe_BWindow_AddChild", NoneType](
            self._ptr, child^._adopt()
        )

    def AddChild(mut self, var child: BMenuBar):
        """Adds a menu bar; the window adopts it."""
        external_call["mojobe_BWindow_AddChild", NoneType](
            self._ptr, child^._adopt_as_view()
        )

    def Show(deinit self):
        """Shows the window and hands it over: it runs on its own thread
        from now on and deletes itself when it quits. Reach it later
        through a `BMessenger`."""
        external_call["mojobe_BWindow_Show", NoneType](self._ptr)

    def __deinit__(deinit self):
        # Never shown: a window is deleted locked, by Quit().
        external_call["mojobe_BWindow_Quit", NoneType](self._ptr)


# ===----------------------------------------------------------------------=== #
# Menus
# ===----------------------------------------------------------------------=== #


struct BMenuItem(Movable):
    """A menu item, owned until a menu adopts it."""

    var _ptr: _Ptr

    def __init__(
        out self,
        var label: String,
        var message: BMessage,
        shortcut: String = "",
        modifiers: UInt32 = 0,
    ) raises:
        """Makes an item that sends `message`, which it adopts.

        Args:
            label: The item's label.
            message: What choosing it sends.
            shortcut: Its keyboard shortcut, one character, with Command.
            modifiers: Modifiers beyond Command.

        Raises:
            When the item cannot be made.
        """
        var key = c_char(0)
        if shortcut:
            key = c_char(shortcut.as_bytes()[0])
        var item = external_call["mojobe_BMenuItem_new", _FnPtr](
            label.as_c_string_span(), message^._adopt(), key, modifiers
        )
        if not item:
            raise Error("out of memory making a BMenuItem")
        self._ptr = item.value()

    def __deinit__(deinit self):
        external_call["mojobe_BMenuItem_delete", NoneType](self._ptr)

    def _adopt(deinit self) -> _Ptr:
        return self._ptr


struct BMenu(Movable):
    """A menu, owned until a menu or menu bar adopts it."""

    var _ptr: _Ptr

    def __init__(out self, var name: String) raises:
        var menu = external_call["mojobe_BMenu_new", _FnPtr](
            name.as_c_string_span()
        )
        if not menu:
            raise Error("out of memory making a BMenu")
        self._ptr = menu.value()

    def AddItem(mut self, var item: BMenuItem):
        """Adds an item; the menu adopts it."""
        _ = external_call["mojobe_BMenu_AddItem", Bool](
            self._ptr, item^._adopt()
        )

    def __deinit__(deinit self):
        external_call["mojobe_BMenu_delete", NoneType](self._ptr)

    def _adopt(deinit self) -> _Ptr:
        return self._ptr


struct BMenuBar(Movable):
    """A menu bar, owned until a window adopts it."""

    var _ptr: _Ptr

    def __init__(out self, frame: BRect, var name: String) raises:
        var bar = external_call["mojobe_BMenuBar_new", _FnPtr](
            frame, name.as_c_string_span()
        )
        if not bar:
            raise Error("out of memory making a BMenuBar")
        self._ptr = bar.value()

    def AddItem(mut self, var menu: BMenu):
        """Adds a menu; the bar adopts it."""
        var as_menu = external_call["mojobe_BMenuBar_as_BMenu", _Ptr](
            self._ptr
        )
        _ = external_call["mojobe_BMenu_AddSubmenu", Bool](
            as_menu, menu^._adopt()
        )

    def __deinit__(deinit self):
        external_call["mojobe_BView_delete", NoneType](
            external_call["mojobe_BMenuBar_as_BView", _Ptr](self._ptr)
        )

    def _adopt_as_view(deinit self) -> _Ptr:
        return external_call["mojobe_BMenuBar_as_BView", _Ptr](self._ptr)
