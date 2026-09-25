# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""GalaxigansDeluxe's stage on Prose: what the MojoCocoa game pane gave the
game -- sprites, an indexed field, a text overlay, sound and the keys -- over
Prose's BGamePane and BChipPlayer, through the `haiku` bridge.

Each piece keeps the MojoCocoa names the game calls, so the game itself is
the MojoCocoa one. What differs is who draws: MojoCocoa rendered each layer
into a Metal frame; here the game records what it wants during a tick, and
`render(pane)` hands it to the pane once, before `Present()`:

  - Sprites: definitions are parsed art and palettes, uploaded to the pane
    (DefineSprite, SetSpriteColors) the first time it renders; each frame,
    the shown instances are listed with DrawSprite, centred where the game
    put them.
  - Field: the world is the pane's own bytes -- `active_plane()` writes into
    them directly, as the game wrote into MojoCocoa's index plane -- and its
    palette and per-line colours are applied at render.
  - Hud: text drawn into the world with the pane's glyphs, its colours given
    palette indices of their own; it is kept until the game clears it and
    drawn every frame, since the world is cleared every frame.
  - Sound: the chip player. The cues and motifs are ABC already; the effects
    MojoCocoa synthesised are short ABC figures here (`SFX_*`).
  - Keys: `get_key_info()` once a tick; `key_held` and `letter_held` read it.
"""

from haiku import BChipPlayer, BGamePaneRef, BPoint, key_info, rgb, rgb_color


# ── the keys, as raw key codes ────────────────────────────────────────────

comptime KEY_ESCAPE = 0x01
comptime KEY_1 = 0x12
comptime KEY_2 = 0x13
comptime KEY_4 = 0x15
comptime KEY_RETURN = 0x47
comptime KEY_SPACE = 0x5E
comptime KEY_LEFT = 0x61
comptime KEY_RIGHT = 0x63

# A to Z, in the order of their letters.
comptime LETTER_KEYS: List[Int] = [
    0x3C, 0x50, 0x4E, 0x3E, 0x29, 0x3F, 0x40, 0x41, 0x2E, 0x42, 0x43, 0x44,
    0x52, 0x51, 0x2F, 0x30, 0x27, 0x2A, 0x3D, 0x2B, 0x2D, 0x4F, 0x28, 0x4D,
    0x2C, 0x4C,
]


def key_held(keys: key_info, key: Int) -> Bool:
    return keys.is_down(UInt32(key))


def letter_held(keys: key_info) -> Int:
    """The ASCII code of a letter key held down, or 0."""
    for i in range(26):
        if keys.is_down(UInt32(materialize[LETTER_KEYS]()[i])):
            return 65 + i
    return 0


# ── sprites ─────────────────────────────────────────────────────────────

@fieldwise_init
struct SpriteArt(Copyable, Movable):
    """A sprite's art: one byte a pixel, 0 transparent, 1 to 15 its palette."""

    var width: Int
    var height: Int
    var pixels: List[UInt8]


def parse_sprite_rows(rows: String) raises -> SpriteArt:
    """The pane's text format: '/'-separated rows, '.' transparent, hex
    digits indexing the sprite's sixteen colours."""
    var pixels = List[UInt8]()
    var width = 0
    var height = 0
    for row in rows.split("/"):
        var line = String(row)
        if line.byte_length() == 0:
            continue
        if width == 0:
            width = line.byte_length()
        elif line.byte_length() != width:
            raise Error("sprite rows of different lengths")
        for byte in line.as_bytes():
            var c = Int(byte)
            if c >= 48 and c <= 57:
                pixels.append(UInt8(c - 48))
            elif c >= 65 and c <= 70:
                pixels.append(UInt8(c - 55))
            elif c >= 97 and c <= 102:
                pixels.append(UInt8(c - 87))
            else:
                pixels.append(0)
        height += 1
    return SpriteArt(width, height, pixels^)


struct SpriteDef(Copyable, Movable):
    var width: Int
    var height: Int
    var frames: List[SpriteArt]
    var colours: List[rgb_color]  # 1 to 15
    var shapes: List[Int32]       # the pane's, once uploaded

    def __init__(out self, var art: SpriteArt):
        self.width = art.width
        self.height = art.height
        self.frames = List[SpriteArt]()
        self.frames.append(art^)
        self.colours = List[rgb_color](length=15, fill=rgb(255, 255, 255))
        self.shapes = List[Int32]()


@fieldwise_init
struct SpriteInstance(Copyable, Movable):
    var definition: Int
    var x: Float64
    var y: Float64
    var frame: Int
    var shown: Bool
    var scale: Float64


struct Sprites(Movable):
    """MojoCocoa's Sprites, over the pane's: definitions and instances."""

    var defs: List[SpriteDef]
    var instances: List[SpriteInstance]
    var uploaded: Int  # the definitions the pane has

    def __init__(out self):
        self.defs = List[SpriteDef]()
        self.instances = List[SpriteInstance]()
        self.uploaded = 0

    def define_sprite(mut self, rows: String) raises -> Int:
        """Define a sprite from its text rows; returns the handle. Its
        palette is sprite palette handle + 1 on the pane (1 to 63)."""
        if len(self.defs) >= 63:
            raise Error("sprites: the pane has 63 sprite palettes")
        self.defs.append(SpriteDef(parse_sprite_rows(rows)))
        return len(self.defs) - 1

    def add_frame(mut self, id: Int, rows: String) raises -> Bool:
        var art = parse_sprite_rows(rows)
        if art.width != self.defs[id].width or art.height != self.defs[id].height:
            return False
        self.defs[id].frames.append(art^)
        return True

    def sprite_rgb(mut self, id: Int, index: Int, r: Int, g: Int, b: Int):
        if index >= 1 and index <= 15:
            self.defs[id].colours[index - 1] = rgb(UInt8(r), UInt8(g), UInt8(b))

    def frame_count(self, id: Int) -> Int:
        return len(self.defs[id].frames)

    def place(mut self, definition: Int, x: Float64, y: Float64) -> Int:
        self.instances.append(SpriteInstance(definition, x, y, 0, True, 1.0))
        return len(self.instances) - 1

    def move_to(mut self, inst: Int, x: Float64, y: Float64):
        self.instances[inst].x = x
        self.instances[inst].y = y

    def show(mut self, inst: Int):
        self.instances[inst].shown = True

    def hide(mut self, inst: Int):
        self.instances[inst].shown = False

    def set_frame(mut self, inst: Int, frame: Int):
        self.instances[inst].frame = frame

    def tick(mut self, dt: Float64):
        pass  # nothing animates itself: the game sets every frame

    def render(mut self, pane: BGamePaneRef[_]) raises:
        # Definitions reach the pane once: shapes, and their palettes.
        while self.uploaded < len(self.defs):
            var d = self.uploaded
            var slot = UInt8(d + 1)
            pane.SetSpriteColors(slot, 1, Span(self.defs[d].colours))
            for f in range(len(self.defs[d].frames)):
                self.defs[d].shapes.append(pane.DefineSprite(
                    Span(self.defs[d].frames[f].pixels),
                    UInt32(self.defs[d].width), UInt32(self.defs[d].height), 4,
                ))
            self.uploaded += 1
        # A frame's sprites are listed afresh: Present() keeps the list.
        pane.ClearSprites()
        # The pane places a sprite by its top-left corner; the game by its
        # centre.
        for i in range(len(self.instances)):
            ref it = self.instances[i]
            if not it.shown:
                continue
            ref d = self.defs[it.definition]
            var frame = it.frame % len(d.shapes)
            pane.DrawSprite(
                d.shapes[frame],
                Int32(it.x - Float64(d.width) * it.scale / 2.0),
                Int32(it.y - Float64(d.height) * it.scale / 2.0),
                Float32(it.scale), 0.0, 1.0, UInt8(it.definition + 1),
            )


# ── the field: the pane's world, and its colours ───────────────────────

@fieldwise_init
struct Plane(ImplicitlyCopyable, Movable):
    """The world being drawn this frame: the pane's own bytes."""

    var address: Int
    var stride: Int
    var width: Int
    var height: Int

    def cls(self, index: Int):
        var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=self.address)
        for i in range(self.stride * self.height):
            p[unsafe_offset=i] = UInt8(index)

    def fill_rect(self, x: Int, y: Int, w: Int, h: Int, index: UInt8):
        var x0 = max(x, 0)
        var y0 = max(y, 0)
        var x1 = min(x + w, self.width)
        var y1 = min(y + h, self.height)
        if x0 >= x1 or y0 >= y1:
            return
        var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=self.address)
        for row in range(y0, y1):
            var at = row * self.stride
            for column in range(x0, x1):
                p[unsafe_offset=at + column] = index


struct Field(Movable):
    """MojoCocoa's IndexedPane: the plane, the palette, per-line colours."""

    var plane: Plane
    var colours: List[Tuple[Int, rgb_color]]
    var lines: List[Tuple[Int, Int, rgb_color]]

    def __init__(out self):
        self.plane = Plane(0, 0, 0, 0)
        self.colours = List[Tuple[Int, rgb_color]]()
        self.lines = List[Tuple[Int, Int, rgb_color]]()

    def bind(mut self, pane: BGamePaneRef[_]) raises:
        """This frame's world, before the game draws."""
        var world = pane.World()
        self.plane = Plane(
            Int(world.unsafe_ptr()), Int(pane.BytesPerRow()),
            Int(pane.WorldWidth()), Int(pane.WorldHeight()),
        )

    def active_plane(self) -> Plane:
        return self.plane

    def set_rgb(mut self, index: Int, r: Int, g: Int, b: Int):
        self.colours.append((index, rgb(UInt8(r), UInt8(g), UInt8(b))))

    def set_line_rgb(mut self, y: Int, index: Int, r: Int, g: Int, b: Int):
        self.lines.append((y, index, rgb(UInt8(r), UInt8(g), UInt8(b))))

    def render(mut self, pane: BGamePaneRef[_]):
        for c in self.colours:
            pane.SetColor(UInt8(c[0]), c[1])
        self.colours.clear()
        for line in self.lines:
            if line[0] >= 0:
                pane.SetScanlineColor(UInt32(line[0]), UInt8(line[1]), line[2])
        self.lines.clear()


# ── the HUD: text in the world ────────────────────────────────────────────

comptime HUD_FIRST_COLOUR = 32  # the HUD's colours take palette 32 onwards

@fieldwise_init
struct Line(Copyable, Movable):
    var x: Int
    var y: Int
    var text: String
    var colour: Int
    var scale: Int


struct Hud(Movable):
    """MojoCocoa's TextOverlay: lines of text at a scale of 8 pixels a
    character, kept until cleared and drawn into the world every frame."""

    var lines: List[Line]
    var palette: List[rgb_color]
    var given: Int  # the palette entries the pane has
    var sized: Bool
    var lift: List[Int]  # per slot: how far a cell is taller than 8 * scale, halved

    def __init__(out self):
        self.lines = List[Line]()
        self.palette = List[rgb_color]()
        self.given = 0
        self.sized = False
        self.lift = List[Int](length=4, fill=0)

    def clear(mut self):
        self.lines.clear()

    def draw_text(mut self, x: Int, y: Int, text: String, r: Int, g: Int,
                  b: Int, scale: Int):
        var colour = rgb(UInt8(r), UInt8(g), UInt8(b))
        var index = -1
        for i in range(len(self.palette)):
            if self.palette[i] == colour:
                index = i
        if index < 0:
            self.palette.append(colour)
            index = len(self.palette) - 1
        self.lines.append(Line(x, y, text, HUD_FIRST_COLOUR + index, scale))

    def render(mut self, pane: BGamePaneRef[_]) raises:
        if not self.sized:
            # Slots 0 to 3 are scales 2 to 5, sized so that a character is
            # 8 * scale pixels across, as MojoCocoa's overlay drew them.
            # (The pane takes sizes from 4 to 64 points: scale 5 comes out a
            # little narrower than 40 pixels a character.)
            for slot in range(4):
                var want = 8 * (slot + 2)
                var size = min(Float32(want) * 1.6, 64.0)
                pane.SetTextFont(None, size, UInt32(slot))
                var got = Int(pane.TextWidth("M", UInt32(slot)))
                if got > 0 and got != want:
                    size = min(max(size * Float32(want) / Float32(got), 4.0), 64.0)
                    pane.SetTextFont(None, size, UInt32(slot))
                # A font's cell is taller than it is wide, where MojoCocoa's
                # was 8 * scale square: centre it on the square, or the
                # bottom line runs off the world.
                var height = Int(pane.TextHeight(UInt32(slot)))
                self.lift[slot] = max(height - want, 0) // 2
            self.sized = True
        while self.given < len(self.palette):
            pane.SetColor(UInt8(HUD_FIRST_COLOUR + self.given),
                          self.palette[self.given])
            self.given += 1
        for line in self.lines:
            var slot = min(max(line.scale - 2, 0), 3)
            pane.DrawText(Int32(line.x), Int32(line.y - self.lift[slot]),
                          line.text, UInt8(line.colour), UInt32(slot))


# ── sound: the chip player ───────────────────────────────────────────────

comptime SFX_SHOOT = 0
comptime SFX_EXPLODE = 1
comptime SFX_HURT = 2
comptime SFX_COIN = 3
comptime SFX_BANG = 4
comptime SFX_SAUCER = 5
comptime SFX_BOSS_HUM = 6

# Tracks: the big cues, the species motifs, and the effects, so an effect
# never cuts a tune (MojoCocoa's chip A and chip B, and its GM synth).
comptime TRACK_CUE = 0
comptime TRACK_MOTIF = 1
comptime TRACK_SFX = 2


def sfx_abc(sfx: Int) -> String:
    """The effects, as short ABC figures on the chip."""
    var head = String("X:1\nM:4/4\nL:1/32\nQ:1/4=240\nK:C\n")
    if sfx == SFX_SHOOT:
        return head + "c'ge"
    if sfx == SFX_EXPLODE:
        return head + "E,D,C,B,,A,,G,,"
    if sfx == SFX_HURT:
        return head + "G,F,E,D,C,4"
    if sfx == SFX_COIN:
        return head + "e'2g'4"
    if sfx == SFX_BANG:
        return head + "C,,4E,,4C,,8"
    if sfx == SFX_SAUCER:
        return head + "g'e'g'e'g'e'g'e'"
    return head + "C,,8D,,8C,,8"  # the boss's hum


struct Sound(Movable):
    """MojoCocoa's audio deck, over the chip player -- or silence, on a
    machine without one."""

    var chip: Optional[BChipPlayer]

    def __init__(out self):
        try:
            self.chip = BChipPlayer()
        except e:
            print("GalaxigansDeluxe: no sound:", e)
            self.chip = None

    def play(self, abc: String, track: Int, loop: Bool = False) -> Bool:
        if not self.chip:
            return False
        try:
            self.chip.value().Play(abc, UInt32(track), loop)
            return True
        except:
            return False

    def stop(self, track: Int):
        if self.chip:
            try:
                self.chip.value().Stop(UInt32(track))
            except:
                pass


comptime P = Sound


def sfx_play(deck: P, sfx: Int) -> Bool:
    return deck.play(sfx_abc(sfx), TRACK_SFX)


def play_tune(deck: P, abc: String, loop: Bool = False) -> Bool:
    return deck.play(abc, TRACK_MOTIF, loop)


def stop_tune(deck: P):
    deck.stop(TRACK_MOTIF)


def play_tune_gm(deck: P, abc: String) -> Bool:
    return deck.play(abc, TRACK_CUE)


def stop_tune_gm(deck: P):
    deck.stop(TRACK_CUE)
