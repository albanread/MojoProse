# expect: use of uninitialized value 'window'
"""A reference got from a window cannot be used once the window is handed
to the system: it runs on its own thread then, and may be gone."""

from haiku import BApplication, BRect, BView, BWindow, B_TITLED_WINDOW


def main() raises:
    var app = BApplication("application/x-vnd.Prose-must-not-compile")
    var window = BWindow(BRect(0, 0, 99, 99), "W", B_TITLED_WINDOW, 0)
    window.AddChild(BView(BRect(0, 0, 9, 9), "view", 0, 0))
    var view = window.FindView("view")
    window^.Show()
    view.Invalidate()
    _ = app.Run()
