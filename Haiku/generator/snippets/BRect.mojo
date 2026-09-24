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
