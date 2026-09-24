# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""The bridge's hand-written core: how pointers, strings, errors and Mojo
state cross to libmojobe. Everything else in the package is generated from
the Haiku headers (Haiku/generator/mojobe_gen.py).

Pointers cross the C interface as addresses (`Int`): the C side declares the
real types, and on arm64 an address and a pointer travel alike. A reference
to an object the kit owns may be NULL; calling a method through a NULL
reference stops the program with the method's name, rather than letting C++
dereference it.
"""

from std.ffi import c_char, external_call
from std.memory.alloc import unsafe_alloc
from std.os import abort
from std.reflection import reflect

comptime _Ptr = OpaquePointer[MutUntrackedOrigin]
"""A `void*` that is not NULL."""

comptime _NPtr = OptionalPointer[NoneType, MutUntrackedOrigin]
"""An object pointer that may be NULL."""

comptime _FnPtr = OptionalPointer[NoneType, MutUntrackedOrigin]
"""A C function pointer, or NULL, as the hook tables hold them."""


def _addr(pointer: _NPtr) -> Int:
    """The address C gets for a pointer that may be NULL."""
    return Int(pointer.value()) if pointer else 0


def _nonnull(pointer: _NPtr, method: StaticString) -> Int:
    """The address of the object a method is called on.

    A NULL reference stops the program, naming the method, instead of being
    dereferenced by C++.
    """
    if not pointer:
        abort(String("haiku: ", method, "() called through a NULL reference"))
    return Int(pointer.value())


def _address_of[T: AnyType](ref value: T) -> Int:
    """The address of a value that holds a C++ object (a `BMessenger`), for
    C: the value itself, not a copy."""
    return Int(Pointer(to=value))


def _ptr_from(address: Int) -> _NPtr:
    """The pointer C returned as an address; `None` for NULL."""
    if address == 0:
        return None
    return _Ptr(unsafe_from_address=address)


def _string_from(address: Int) -> String:
    """A string the kit returned, copied; "" for NULL."""
    if address == 0:
        return ""
    return String(
        unsafe_from_utf8_ptr=Pointer[UInt8, ImmUntrackedOrigin](
            unsafe_from_address=address
        )
    )


def _char(string: String) -> c_char:
    """A C++ `char` argument: the string's first byte, or 0 for ""."""
    if not string:
        return 0
    return c_char(string.as_bytes()[0])


def _string_from_char(character: c_char) -> String:
    """A C++ `char` result as a one-byte string; "" for 0."""
    if character == 0:
        return ""
    return String(chr(Int(UInt8(character))))


def _check(status: Int32, what: StaticString) raises:
    """Raises when a method's `status_t` is not `B_OK`, with its
    `strerror()` text."""
    if status == 0:
        return
    var text = external_call["strerror", Int](status)
    raise Error(what, ": ", _string_from(text))


def _fn_ptr[F: TrivialRegisterPassable](func: F) -> _Ptr:
    """A C ABI function as the `void*` a hook table holds, as the standard
    library's CPython type slots do it."""
    return {
        _mlir_value = __mlir_op.`pop.pointer.bitcast`[
            _type=OpaquePointer[MutUntrackedOrigin]._mlir_type
        ](func)
    }


def _type_tag[T: AnyType]() -> UInt64:
    """`T`'s tag in a hook table: FNV-1a of its qualified name. A function's
    address cannot name a type: Mojo takes it through a thunk made where it
    is taken."""
    var hash = UInt64(0xCBF29CE484222325)
    for byte in reflect[T].name[qualified_builtins=True]().as_bytes():
        hash = (hash ^ UInt64(byte)) * 0x100000001B3
    return hash


def _destroy[T: Movable & Deinitable](context: _Ptr) abi("C"):
    """A hook table's destroy: ends the Mojo state of an object as its C++
    object is deleted."""
    var state = context.unsafe_bitcast[T]()
    state.unsafe_deinit_pointee()
    state.unsafe_free()


def _to_heap[T: Movable & Deinitable](var value: T) -> _Ptr:
    """Moves `value` to the heap, where it stays while its object lives."""
    var context = unsafe_alloc[T](1)
    context.unsafe_write(value^)
    return context.unsafe_bitcast[NoneType]()


def _state_at[
    T: Movable & Deinitable, origin: MutOrigin
](context: Int, what: StaticString) raises -> ref[origin] T:
    """The Mojo state at `context`, which libmojobe found for `T`'s tag,
    borrowed as `origin`: the reference it was asked through."""
    if context == 0:
        raise Error("the ", what, "'s Mojo state is not of the type asked for")
    return Pointer[T, MutUntrackedOrigin](
        unsafe_from_address=context
    ).unsafe_origin_cast[origin]()[]


struct _HookCall(Movable):
    """What the references a hook receives are borrowed from: a local of the
    hook's trampoline, which ends when the hook returns. A reference cannot
    outlive it, so a hook cannot keep one."""

    def __init__(out self):
        pass


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
