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
