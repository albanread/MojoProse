# ===----------------------------------------------------------------------=== #
# Hand-written (Haiku/generator/snippets/_values.mojo): helpers, and the
# constants of value types, which are `extern const` objects in the headers
# and so have no value clang can give the generator.
# ===----------------------------------------------------------------------=== #


def rgb(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) -> rgb_color:
    """An `rgb_color`, opaque unless told otherwise."""
    return rgb_color(red, green, blue, alpha)


comptime B_ORIGIN = BPoint(0, 0)
"""`B_ORIGIN`: the point (0, 0)."""

comptime B_SOLID_HIGH = pattern(0xFFFFFFFFFFFFFFFF)
"""`B_SOLID_HIGH`: every pixel in the high colour."""

comptime B_SOLID_LOW = pattern(0)
"""`B_SOLID_LOW`: every pixel in the low colour."""

comptime B_MIXED_COLORS = pattern(0x55AA55AA55AA55AA)
"""`B_MIXED_COLORS`: a checkerboard of the high and low colours."""
