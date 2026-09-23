# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""The Be API's hook functions, one trait each.

A type implements the hooks it wants, and making a `BView` or a `BWindow`
from it builds that type's hook table at compile time: a hook it does not
implement never enters Mojo. See Haiku/docs/bridge-design.md, section 8.3.
"""

from ._core import BMessageRef, BPoint, BRect, BViewRef, BWindowRef


trait ViewDraw:
    """`BView::Draw`: draw the part of the view in `updateRect`."""

    def Draw(mut self, view: BViewRef, updateRect: BRect):
        """Draws the view.

        Args:
            view: The view, locked and valid for the call.
            updateRect: The part of the view to draw, in its coordinates.
        """
        ...


trait ViewMouseDown:
    """`BView::MouseDown`: a mouse button went down in the view."""

    def MouseDown(mut self, view: BViewRef, where: BPoint):
        """Handles a mouse button going down.

        Args:
            view: The view, locked and valid for the call.
            where: Where, in the view's coordinates.
        """
        ...


trait ViewMessageReceived:
    """`BView::MessageReceived`: a message for the view."""

    def MessageReceived(mut self, view: BViewRef, message: BMessageRef):
        """Handles a message; `view.base_MessageReceived` for the rest.

        Args:
            view: The view, locked and valid for the call.
            message: The message, valid for the call.
        """
        ...


trait WindowMessageReceived:
    """`BWindow::MessageReceived`: a message for the window."""

    def MessageReceived(mut self, window: BWindowRef, message: BMessageRef):
        """Handles a message; `window.base_MessageReceived` for the rest.

        Args:
            window: The window, locked and valid for the call.
            message: The message, valid for the call.
        """
        ...


trait WindowQuitRequested:
    """`BWindow::QuitRequested`: may the window close?"""

    def QuitRequested(mut self, window: BWindowRef) -> Bool:
        """Answers whether the window may close.

        Args:
            window: The window, locked and valid for the call.

        Returns:
            True to close the window.
        """
        ...
