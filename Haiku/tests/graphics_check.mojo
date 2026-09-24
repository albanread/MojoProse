# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""Drawing through the bridge, read back through app_server (design section
12, "pixels"): a Mojo program draws into an offscreen BBitmap with a BView
and reads the pixels from the bitmap's bytes, a Span; then fonts, regions and
the screen. Prints PASS or FAIL for each check, then `SELFTEST PASS n/n` or
`SELFTEST FAIL`.

Build on Prose, as Dots is built:
    mojo build -I Haiku/bridge Haiku/tests/graphics_check.mojo \\
        -o graphics_check -Xlinker -L. -Xlinker -lmojobe -Xlinker -lbe
"""

from haiku import BApplication, BBitmap, BPoint, BRect, BRegion, BScreen
from haiku import BView, B_FOLLOW_ALL, B_MAIN_SCREEN_ID, B_RGB32, B_WILL_DRAW
from haiku import be_bold_font, be_plain_font, rgb


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


def pixel(bits: Span[UInt8, _], bytes_per_row: Int, x: Int, y: Int) -> String:
    """A B_RGB32 pixel (bytes blue, green, red, alpha) as "r,g,b"."""
    var at = y * bytes_per_row + x * 4
    return String(bits[at + 2], ",", bits[at + 1], ",", bits[at])


def main() raises:
    var checks = Checks()
    var app = BApplication("application/x-vnd.Prose-graphics-check")

    # Pixels: a view in an offscreen bitmap, drawn through the bridge.
    var bitmap = BBitmap(BRect(0, 0, 63, 63), B_RGB32, True)
    bitmap.AddChild(BView(bitmap.Bounds(), "canvas", B_FOLLOW_ALL, B_WILL_DRAW))
    checks.check("the bitmap locks", bitmap.Lock())
    var canvas = bitmap.FindView("canvas")
    canvas.SetHighColor(rgb(255, 200, 0))
    canvas.FillRect(BRect(0, 0, 31, 31))
    canvas.SetHighColor(rgb(30, 30, 46))
    canvas.FillRect(BRect(32, 32, 63, 63))
    canvas.SetHighColor(rgb(0, 128, 255))
    canvas.StrokeLine(BPoint(0, 63), BPoint(63, 63))
    canvas.Sync()
    bitmap.Unlock()
    var bits = bitmap.Bits()
    var bpr = Int(bitmap.BytesPerRow())
    checks.check("Bits(): a span of BitsLength() bytes",
                 len(bits) == Int(bitmap.BitsLength()) and len(bits) == bpr * 64)
    checks.check("FillRect's colour, read from the bitmap",
                 pixel(bits, bpr, 10, 10) == "255,200,0", pixel(bits, bpr, 10, 10))
    checks.check("the second FillRect's",
                 pixel(bits, bpr, 40, 40) == "30,30,46", pixel(bits, bpr, 40, 40))
    checks.check("StrokeLine's, on the last row",
                 pixel(bits, bpr, 5, 63) == "0,128,255", pixel(bits, bpr, 5, 63))
    # Nothing erases a view in a bitmap but an update: undrawn pixels keep
    # the new bitmap's zeroed bytes (measured; not the view's white).
    checks.check("undrawn pixels keep the bitmap's zeroed bytes",
                 pixel(bits, bpr, 40, 10) == "0,0,0", pixel(bits, bpr, 40, 10))

    # A span in: ImportBits from Mojo's bytes.
    var small = BBitmap(BRect(0, 0, 3, 0), B_RGB32)
    var green = List[UInt8]()
    for _ in range(4):
        green.append(0)
        green.append(255)
        green.append(0)
        green.append(255)
    small.ImportBits(Span(green), 16, 0, B_RGB32)
    checks.check("ImportBits(a Span of Mojo's bytes)",
                 pixel(small.Bits(), 16, 2, 0) == "0,255,0",
                 pixel(small.Bits(), 16, 2, 0))

    # Fonts: a value class, copied and compared.
    var font = be_plain_font()
    checks.check("be_plain_font(): a size", font.Size() > 0, String(font.Size()))
    checks.check("the bold font is another font", be_bold_font() != font)
    var larger = font
    larger.SetSize(font.Size() * 2)
    checks.check("a copy is a value of its own",
                 larger.Size() == font.Size() * 2 and larger != font)
    var height = larger.GetHeight()
    checks.check("GetHeight(): a font_height",
                 height.ascent > 0 and height.descent > 0, String(height.ascent))
    checks.check("StringWidth scales with the size",
                 larger.StringWidth("Prose") > font.StringWidth("Prose") * 1.5)
    if bitmap.Lock():
        canvas.SetFont(larger)
        checks.check("SetFont, then GetFont: the same font",
                     canvas.GetFont() == larger)
        bitmap.Unlock()

    # Regions, and the screen.
    var region = BRegion(BRect(0, 0, 9, 9))
    region.Include(BRect(20, 20, 29, 29))
    checks.check("BRegion: two rectangles",
                 region.CountRects() == 2 and region.Contains(BPoint(25, 25))
                 and not region.Contains(BPoint(15, 15)))
    checks.check("BRegion.Frame()", region.Frame() == BRect(0, 0, 29, 29))
    var screen = BScreen(B_MAIN_SCREEN_ID)
    checks.check("BScreen: valid, 32-bit",
                 screen.IsValid() and screen.ColorSpace() == B_RGB32)
    checks.check("BScreen.Frame(): the machine's display",
                 screen.Frame().Width() > 0, String(screen.Frame()))

    _ = bitmap^
    _ = app^
    var total = checks.passed + checks.failed
    if checks.failed:
        print("SELFTEST FAIL", checks.passed, "/", total)
    else:
        print("SELFTEST PASS", String(checks.passed) + "/" + String(total))
