# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""The bridge's core: the Be API's value types, and references to objects
the kits own.

A reference (`BViewRef`, `BWindowRef`, `BMessageRef`) is what a hook
receives: valid for that call, on the looper's thread, with its lock held.
P0 does not have the compiler enforce that (design section 15, question 1);
a program must not keep one past its hook.
"""

from std.ffi import external_call
from std.reflection import reflect

comptime _Ptr = OpaquePointer[MutUntrackedOrigin]
"""A `void*` the bridge passes through."""

comptime _FnPtr = OptionalPointer[NoneType, MutUntrackedOrigin]
"""A C function pointer, or NULL, as the hook tables hold them."""


def _fn_ptr[F: TrivialRegisterPassable](func: F) -> _Ptr:
    """A C ABI function as the `void*` a hook table holds, as the standard
    library's CPython type slots do it."""
    return {
        _mlir_value = __mlir_op.`pop.pointer.bitcast`[
            _type=OpaquePointer[MutUntrackedOrigin]._mlir_type
        ](func)
    }


def _type_tag[T: AnyType]() -> UInt64:
    """`T`'s tag in a hook table: FNV-1a of its qualified name."""
    var hash = UInt64(0xCBF29CE484222325)
    for byte in reflect[T].name[qualified_builtins=True]().as_bytes():
        hash = (hash ^ UInt64(byte)) * 0x100000001B3
    return hash


def _destroy[T: Movable & Deinitable](context: _Ptr) abi("C"):
    """A hook table's destroy: ends the Mojo state of a view or window as its
    C++ object is deleted."""
    var state = context.unsafe_bitcast[T]()
    state.unsafe_deinit_pointee()
    state.unsafe_free()


def _state[
    T: Movable & Deinitable
](entry: StaticString, object: _Ptr) raises -> ref[MutUntrackedOrigin] T:
    """The Mojo state behind a view or window, if it is a `T`."""
    var context: _FnPtr
    if entry == "view":
        context = external_call["mojobe_MojoBView_context", _FnPtr](
            object, _type_tag[T]()
        )
    else:
        context = external_call["mojobe_MojoBWindow_context", _FnPtr](
            object, _type_tag[T]()
        )
    if not context:
        raise Error("the ", entry, "'s Mojo state is not of the type asked for")
    return context.value().unsafe_bitcast[T]()[]


# ===----------------------------------------------------------------------=== #
# Value types, laid out as Haiku's headers lay them out.
# ===----------------------------------------------------------------------=== #


@fieldwise_init
struct BPoint(TrivialRegisterPassable, Writable):
    """A point: `BPoint`, two floats."""

    var x: Float32
    var y: Float32

    def write_to(self, mut writer: Some[Writer]):
        writer.write("BPoint(", self.x, ", ", self.y, ")")


@fieldwise_init
struct BRect(TrivialRegisterPassable, Writable):
    """A rectangle: `BRect`, four floats, the right and bottom edges
    included."""

    var left: Float32
    var top: Float32
    var right: Float32
    var bottom: Float32

    def Width(self) -> Float32:
        """The width, as `BRect::Width()` has it (right - left)."""
        return self.right - self.left

    def Height(self) -> Float32:
        """The height, as `BRect::Height()` has it (bottom - top)."""
        return self.bottom - self.top

    def write_to(self, mut writer: Some[Writer]):
        writer.write(
            "BRect(",
            self.left,
            ", ",
            self.top,
            ", ",
            self.right,
            ", ",
            self.bottom,
            ")",
        )


@fieldwise_init
struct rgb_color(TrivialRegisterPassable):
    """A colour: `rgb_color`, four bytes."""

    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8


def rgb(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) -> rgb_color:
    """An `rgb_color`, opaque unless told otherwise."""
    return rgb_color(red, green, blue, alpha)


def fourcc(code: StaticString) -> UInt32:
    """A four-character code, `'clr '` in C++: the first character in the
    top byte."""
    var bytes = code.as_bytes()
    return (
        (UInt32(bytes[0]) << 24)
        | (UInt32(bytes[1]) << 16)
        | (UInt32(bytes[2]) << 8)
        | UInt32(bytes[3])
    )


# ===----------------------------------------------------------------------=== #
# References
# ===----------------------------------------------------------------------=== #


@fieldwise_init
struct BMessageRef(TrivialRegisterPassable):
    """A message the kit owns, valid for the hook it was given to."""

    var _ptr: _Ptr
    var what: UInt32
    """The message's code, `BMessage::what`."""

    def __init__(out self, ptr: _Ptr):
        self._ptr = ptr
        self.what = external_call["mojobe_BMessage_what", UInt32](ptr)


@fieldwise_init
struct BViewRef(TrivialRegisterPassable):
    """A view the kit owns, valid in a hook or with its window locked."""

    var _ptr: _Ptr

    def Bounds(self) -> BRect:
        return external_call["mojobe_BView_Bounds", BRect](self._ptr)

    def Invalidate(self):
        external_call["mojobe_BView_Invalidate", NoneType](self._ptr)

    def SetHighColor(self, color: rgb_color):
        external_call["mojobe_BView_SetHighColor", NoneType](self._ptr, color)

    def FillRect(self, rect: BRect):
        external_call["mojobe_BView_FillRect", NoneType](self._ptr, rect)

    def FillEllipse(self, center: BPoint, xRadius: Float32, yRadius: Float32):
        external_call["mojobe_BView_FillEllipse", NoneType](
            self._ptr, center, xRadius, yRadius
        )

    def Window(self) -> BWindowRef:
        return BWindowRef(
            external_call["mojobe_BView_Window", _Ptr](self._ptr)
        )

    def state[T: Movable & Deinitable](self) raises -> ref[MutUntrackedOrigin] T:
        """The Mojo value the view was made from.

        Raises:
            When the view was not made from a `T`.
        """
        return _state[T]("view", self._ptr)

    def base_Draw(self, updateRect: BRect):
        """`BView::Draw`, the view's own drawing."""
        external_call["mojobe_BView_base_Draw", NoneType](
            self._ptr, updateRect
        )

    def base_MouseDown(self, where: BPoint):
        """`BView::MouseDown`, the view's own handling."""
        external_call["mojobe_BView_base_MouseDown", NoneType](self._ptr, where)

    def base_MessageReceived(self, message: BMessageRef):
        """`BView::MessageReceived`, the view's own handling."""
        external_call["mojobe_BView_base_MessageReceived", NoneType](
            self._ptr, message._ptr
        )


@fieldwise_init
struct BWindowRef(TrivialRegisterPassable):
    """A window, valid in its hooks or while locked."""

    var _ptr: _Ptr

    def Bounds(self) -> BRect:
        return external_call["mojobe_BWindow_Bounds", BRect](self._ptr)

    def FindView(self, var name: String) raises -> BViewRef:
        """The window's view of that name.

        Raises:
            When the window has no view of that name.
        """
        var view = external_call["mojobe_BWindow_FindView", _FnPtr](
            self._ptr, name.as_c_string_span()
        )
        if not view:
            raise Error("the window has no view named '", name, "'")
        return BViewRef(view.value())

    def state[T: Movable & Deinitable](self) raises -> ref[MutUntrackedOrigin] T:
        """The Mojo value the window was made from.

        Raises:
            When the window was not made from a `T`.
        """
        return _state[T]("window", self._ptr)

    def base_MessageReceived(self, message: BMessageRef):
        """`BWindow::MessageReceived`, the window's own handling."""
        external_call["mojobe_BWindow_base_MessageReceived", NoneType](
            self._ptr, message._ptr
        )

    def base_QuitRequested(self) -> Bool:
        """`BWindow::QuitRequested`, the window's own answer."""
        return external_call["mojobe_BWindow_base_QuitRequested", Bool](
            self._ptr
        )
