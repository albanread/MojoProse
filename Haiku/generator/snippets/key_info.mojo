def is_down(self, key: UInt32) -> Bool:
    """Whether the key with this raw key code is down: bit 7 - key % 8 of
    byte key / 8 of key_states, as the Be Book has it."""
    var byte = Int(key) >> 3
    var word = self.states0
    if byte >= 12:
        word = self.states3
    elif byte >= 8:
        word = self.states2
    elif byte >= 4:
        word = self.states1
    var value = (word >> UInt32((byte & 3) * 8)) & 0xFF
    return (value & (UInt32(1) << UInt32(7 - (Int(key) & 7)))) != 0
