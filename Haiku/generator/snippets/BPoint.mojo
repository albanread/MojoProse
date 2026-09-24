def write_to(self, mut writer: Some[Writer]):
    writer.write("BPoint(", self.x, ", ", self.y, ")")
