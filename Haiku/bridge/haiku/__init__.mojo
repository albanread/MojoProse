# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""The Haiku API for Mojo programs on Prose, through libmojobe.

P0 of the bridge (Haiku/docs/bridge-design.md): BApplication, BWindow,
BView, BMessage and menus, written by hand as the generator will write
them. Link programs with `-lmojobe -lbe`.
"""

from ._core import (
    BMessageRef,
    BPoint,
    BRect,
    BViewRef,
    BWindowRef,
    fourcc,
    rgb,
    rgb_color,
)
from .interface import (
    BApplication,
    BMenu,
    BMenuBar,
    BMenuItem,
    BMessage,
    BView,
    BWindow,
)

# Constants, as Haiku's headers define them (measured with the build's own
# clang against the Prose sysroot).
comptime B_TITLED_WINDOW: UInt32 = 1
comptime B_DOCUMENT_WINDOW: UInt32 = 11
comptime B_NOT_RESIZABLE: UInt32 = 0x2
comptime B_NOT_ZOOMABLE: UInt32 = 0x40
comptime B_ASYNCHRONOUS_CONTROLS: UInt32 = 0x80000
comptime B_QUIT_ON_WINDOW_CLOSE: UInt32 = 0x100000
comptime B_AUTO_UPDATE_SIZE_LIMITS: UInt32 = 0x400000

comptime B_FOLLOW_NONE: UInt32 = 0
comptime B_FOLLOW_LEFT: UInt32 = 0x202
comptime B_FOLLOW_RIGHT: UInt32 = 0x404
comptime B_FOLLOW_TOP: UInt32 = 0x1010
comptime B_FOLLOW_BOTTOM: UInt32 = 0x3030
comptime B_FOLLOW_LEFT_RIGHT: UInt32 = 0x204
comptime B_FOLLOW_TOP_BOTTOM: UInt32 = 0x1030
comptime B_FOLLOW_ALL: UInt32 = 0x1234

comptime B_WILL_DRAW: UInt32 = 0x20000000
comptime B_FULL_UPDATE_ON_RESIZE: UInt32 = 0x80000000
comptime B_FRAME_EVENTS: UInt32 = 0x4000000
comptime B_NAVIGABLE: UInt32 = 0x2000000

comptime B_QUIT_REQUESTED: UInt32 = 0x5F515251
comptime B_ABOUT_REQUESTED: UInt32 = 0x5F414252

comptime B_SHIFT_KEY: UInt32 = 0x1
comptime B_COMMAND_KEY: UInt32 = 0x2
