# expect: cannot implicitly convert 'BWindow' value to 'BHandler'
"""An owned value becomes its base class's only if both end the same way:
a window quits, a BHandler Mojo owns is deleted."""

from haiku import BApplication, BHandler, BRect, BWindow, B_TITLED_WINDOW


def main() raises:
    var app = BApplication("application/x-vnd.Prose-must-not-compile")
    var window = BWindow(BRect(0, 0, 99, 99), "W", B_TITLED_WINDOW, 0)
    var handler: BHandler = window^
    _ = handler^
    _ = app^
