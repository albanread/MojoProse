# GalaxigansDeluxe -- a Galaxian/Galaga-style fixed shooter: the complete port
# of MACVM's Galaxigans (world/49_galaxigans.mst, itself a faithful port of the
# x64 assembler original) onto the Mojo game pane.
#
# What "complete" means, against examples/galaxigans (the BASIC port): the
# ten-species creature library and the twelve-level table with the original's
# cosmos shaders; the dive AI whose random seed IS the flight plan; the bonus
# saucer with its beating warble and its rare spinning mine; the CAPTURE BOSS
# with a tractor beam that comes for the pilot row -- drawn once as a cone in
# palette index 1 and animated by rewriting what index 1 means on each
# scanline (the copper-bar trick, through the pane's per-line palette); the
# victory dance the survivors perform over the game-over card; the four
# melodic cues, played on the system General MIDI synth as MACVM plays them;
# and a hall of fame that survives a restart.
#
# Every constant is the original's (galaxigans_data.inc, by way of the .mst):
# a 640x360 field, an 8x5 formation on a 56x34 grid from (96,56), sway +/-16
# at 1px a frame, a dive every 60 frames that peels for 12 then homes, four
# bullets at 7px a frame on an 8-frame cooldown, six bombs at 4px every 22, a
# saucer every 420 frames worth 200, a 90-frame respawn beat. It was tuned at
# ~30 frames a second, so it steps at 30 Hz on a fixed clock however fast the
# display runs.
#
# Controls: Left/Right steer, Space fires -- one shot per press, no autofire
# (the original's shoot_held / shoot_release beat). Escape quits.
#
# GAMEPANE_FRAMES=n renders n frames headless and prints a one-line summary.
# With nobody at the keys an autopilot plays (also GDX_AUTOPLAY=1 with a
# window), so a headless run exercises the whole game and not just the title.

from std.math import sin
from std.os import getenv
from std.sys import argv, exit
from haiku import BApplication, BGamePane, BGamePaneRef, BMessage, BMessageRef
from haiku import BEntry, BMessageRunner, BMessenger, BPath, BRect, get_key_info
from haiku import key_info
from haiku import B_GAME_PANE_SCANLINE_PALETTE, B_QUIT_REQUESTED
from haiku import B_USER_SETTINGS_DIRECTORY, find_directory
from haiku.hooks import GamePaneMessageReceived, GamePaneQuitRequested
from stage import (
    KEY_ESCAPE, KEY_LEFT, KEY_RIGHT, KEY_SPACE, KEY_RETURN,
    KEY_1, KEY_2, KEY_4,
    SFX_SHOOT, SFX_EXPLODE, SFX_HURT, SFX_COIN, SFX_BANG, SFX_SAUCER,
    SFX_BOSS_HUM,
    P, Sprites, Hud, Field, key_held, letter_held,
    sfx_play, play_tune, stop_tune, play_tune_gm, stop_tune_gm,
)
from art import (
    SPECIES_COUNT, species_name,
    define_species_sprite, define_mine_sprite, define_boss_sprite,
    define_pilot_sprite, define_ship_sprite, define_saucer_sprite,
)
from cosmos import COSMOS_SHADER
from tunes import TUNE_ALIEN_VICTORY, TUNE_TITLE, TUNE_STAGE_CLEAR, TUNE_SAUCER
from motifs import motif_for

# ── the field, straight from the original's galaxigans_data.inc ──────────
comptime FIELD_W = 640
comptime FIELD_H = 360
comptime PLAYER_Y = 310
comptime COLS = 8
comptime ROWS = 5
comptime COL_GAP = 56
comptime ROW_GAP = 34
comptime GRID_X = 96
comptime GRID_Y = 56
comptime DIVE_PERIOD = 60
comptime BOMB_PERIOD = 22
comptime SAUCER_PERIOD = 420
# The triumphal dance: the survivors orbit the middle of the field on a
# breathing-radius pinwheel while the game-over card sits over them.
comptime DANCE_CX = 320
comptime DANCE_CY = 180
comptime DANCE_R0 = 95
comptime DANCE_R1 = 70
comptime DANCE_ANGLE_STEP = 6
comptime DANCE_RAD_STEP = 10
comptime DANCE_LENGTH = 420
# The floor between two species motifs: thirty seconds, in frames at 30 Hz.
# A motif is a bar long, so this is not a fade or a crossfade rule -- it is
# twenty-eight seconds of no music at all between them, which is what makes
# the one you do hear mean something.
comptime MOTIF_GAP = 900
# The attract cycle: the title holds ~20s, the hall of fame ~33s, and round
# again -- the machine never stops on its own, it waits for a player.
comptime ATTRACT_LENGTH = 600
# Five seconds, not seventeen. A table nobody can dismiss is a table
# people sit through resenting, and space dismisses this one.
comptime HISCORE_LENGTH = 300
# How long the table sits after the third letter -- long enough to read your
# own name in it, short enough not to be a wait.
comptime HISCORE_LINGER = 90
# The capture boss, and the pilot row it comes for.
comptime BOSS_FIRST = 40
comptime BOSS_DWELL = 60
comptime BOSS_RESPAWN = 360
comptime BOSS_STATION_Y = 18
comptime BOSS_CAPTURE_Y = 140
comptime BOSS_SCORE = 500
comptime BEAM_CHARGE = 30
comptime BEAM_HOLD = 90
comptime PILOT_ROW_Y = 344
comptime PILOT_X0 = 14
comptime PILOT_GAP = 16
# The original flies its saucer at y=20; the HUD's own row is up there, so it
# crosses just below, clear of the score.
comptime SAUCER_Y = 30
comptime SAUCER_BOMB_GAP = 28
comptime MINE_SCORE = 150

# Indexed-plane palette: the layer is cleared to 0 (transparent, the shader
# shows through) and carries only what the game plots. Index 1 is the beam,
# whose colour is per LINE.
comptime IX_BEAM = 1
comptime IX_BULLET = 20
comptime IX_BOMB = 21
comptime IX_SPARK_GOLD = 22
comptime IX_SPARK_RED = 23

# States.
comptime ATTRACT = 0
comptime PLAYING = 1
comptime CLEARED = 2
comptime OVER = 3
comptime HISCORE = 4

comptime A_FORM = 0
comptime A_DIVE = 1
comptime A_RETURN = 2
comptime A_DEAD = 3

comptime B_IDLE = 0
comptime B_ENTER = 1
comptime B_STATION = 2
comptime B_DESCEND = 3
comptime B_CHARGE = 4
comptime B_BEAM = 5
comptime B_RETURN = 6

comptime EV_NONE = 0
comptime EV_WARN = 1
comptime EV_CHARGED = 2
comptime EV_GRAB = 3
comptime EV_DONE = 4

comptime TAU = 6.283185307179586


def sine_at(i: Int) -> Int:
    """A 256-step integer sine in [-256, 256] -- the original's sineLUT.

    The dive weave asks for one per diver per frame and the whole flight
    path stays in integers, so it is the same curve every run. Computed
    rather than tabled: it is the identical value, and a function needs no
    owner to borrow from inside a loop over the fleet."""
    var k = ((i % 256) + 256) % 256
    return Int(round(sin(Float64(k) * TAU / 256.0) * 256.0))


def sign(v: Int) -> Int:
    return 1 if v > 0 else (-1 if v < 0 else 0)


# ── one alien: a slot in the formation, and its own flight plan while diving ──
struct Galaxigan(Copyable, Movable):
    """In formation I track my slot plus the fleet's sway; launched, I fly my
    own swoop at the player, drop out of the bottom and glide back in from the
    top. My dive is not scripted: the seed I am launched with packs the weave
    speed, phase and amplitude and two behaviour bits, so every swoop differs."""
    var x: Int
    var y: Int
    var home_x: Int
    var home_y: Int
    var state: Int
    var dt: Int
    var seed: Int
    var bank: Int
    var alive: Bool
    var species: Int          # 0-based index into the creature library
    var sprite: Int           # instance handle

    def __init__(out self, hx: Int, hy: Int) raises:
        self.x = hx
        self.y = hy
        self.home_x = hx
        self.home_y = hy
        self.state = A_FORM
        self.dt = 0
        self.seed = 0
        self.bank = 0
        self.alive = True
        self.species = 0
        self.sprite = -1

    def reset(mut self) raises:
        self.x = self.home_x
        self.y = self.home_y
        self.state = A_FORM
        self.dt = 0
        self.seed = 0
        self.bank = 0
        self.alive = True

    def is_diving(self) raises -> Bool:
        return self.state == A_DIVE

    def kill(mut self) raises:
        self.alive = False
        self.state = A_DEAD

    def points(self) raises -> Int:
        """The rarer species (higher up the library) are worth more, and a
        diver is worth double -- the arcade's own bargain."""
        var base = 40 + (self.species + 1) * 10
        return base * 2 if self.state == A_DIVE else base

    def dive_with_seed(mut self, s: Int) raises:
        self.state = A_DIVE
        self.dt = 0
        self.seed = s

    def follow_formation(mut self, sway: Int) raises:
        self.x = self.home_x + sway
        self.y = self.home_y
        self.bank = 0

    def return_step(mut self, sway: Int) raises:
        """The glide home: drop from above the field into my own slot,
        tracking the swaying column on the way in."""
        self.y += 4
        self.x = self.home_x + sway
        self.bank = 0
        if self.y >= self.home_y:
            self.y = self.home_y
            self.state = A_FORM

    def dive_step(mut self, player_x: Int) raises -> Bool:
        """One frame of the dive -- the ported swoop. True when I have left
        the bottom of the field and should re-enter from the top."""
        self.dt += 1
        var vy = 2 + self.dt // 4
        vy = min(vy, 8 if (self.seed & 128) == 0 else 10)
        self.y += vy
        var speed = ((self.seed >> 3) & 7) + 3
        var phase = (self.seed >> 8) & 255
        var amp = (self.seed & 7) + 2
        var weave = sine_at(self.dt * speed + phase) * amp // 256
        # The peel: for the first 12 steps I only weave, breaking formation
        # outward before I start hunting. After that the homing pull leans me
        # toward the player -- gently, or hard if my seed says so.
        if self.dt >= 12:
            var pull = 1 if (self.seed & 64) == 0 else 3
            weave = weave + pull if self.x < player_x else weave - pull
        self.x += weave
        self.bank = sign(weave)
        return self.y > FIELD_H + 8

    def move_to(mut self, ax: Int, ay: Int) raises:
        self.x = ax
        self.y = ay
        self.bank = 0

    def reenter_at(mut self, sway: Int) raises:
        self.state = A_RETURN
        self.dt = 0
        self.x = self.home_x + sway
        self.y = -20

    def hits(self, px: Int, py: Int, hw: Int) raises -> Bool:
        """My hit box, generous by half a pixel in the player's favour."""
        return self.alive and abs(self.x - px) < hw + 8 and abs(self.y - py) < 12


# ── a shot: one player bullet, or one enemy bomb ─────────────────────────
struct Shot(Copyable, Movable):
    """One projectile in a fixed-size pool. The pool never grows: the
    original DIMs four bullets and six bombs, and running out IS the rate
    limit."""
    var x: Int
    var y: Int
    var dy: Int
    var live: Bool

    def __init__(out self) raises:
        self.x = 0
        self.y = 0
        self.dy = 0
        self.live = False

    def fire_from(mut self, ax: Int, ay: Int, ady: Int) raises:
        self.x = ax
        self.y = ay
        self.dy = ady
        self.live = True

    def step(mut self) raises:
        if not self.live:
            return
        self.y += self.dy
        if self.y < -8 or self.y > FIELD_H + 8:
            self.live = False

    def hits(self, tx: Int, ty: Int, hw: Int, hh: Int) raises -> Bool:
        return self.live and abs(self.x - tx) < hw and abs(self.y - ty) < hh


# ── the saucer's rare spinning mine ──────────────────────────────────────
struct Mine(Copyable, Movable):
    """The saucer drops me instead of a bomb about one time in eight. I drift
    down slowly, spinning -- threat and treat: touching the ship kills it,
    shooting me pays 150. Eight rotation frames, a full turn every 32."""
    var x: Int
    var y: Int
    var anim: Int
    var live: Bool
    var sprite: Int

    def __init__(out self) raises:
        self.x = 0
        self.y = 0
        self.anim = 0
        self.live = False
        self.sprite = -1

    def frame(self) raises -> Int:
        return (self.anim // 4) % 8

    def drop_at(mut self, ax: Int, ay: Int) raises:
        self.x = ax
        self.y = ay
        self.anim = 0
        self.live = True

    def step(mut self) raises:
        """Half a pixel a frame -- down on the odd ticks only -- so it hangs
        in the field far longer than a bomb and has to be dealt with."""
        if not self.live:
            return
        self.anim += 1
        if (self.anim & 1) == 1:
            self.y += 1
        if self.y > FIELD_H + 8:
            self.live = False

    def hits(self, tx: Int, ty: Int, hw: Int, hh: Int) raises -> Bool:
        return self.live and abs(self.x - tx) < hw + 8 and abs(self.y - ty) < hh + 8


# ── the capture boss ─────────────────────────────────────────────────────
struct Boss(Copyable, Movable):
    """A 32x32 crab that comes for your PILOTS, not your ship: enter, hover,
    descend to the middle of the field, charge, and fire a tractor beam down
    into the pilot row. A pilot rises up the beam; if it reaches me that life
    is gone. Shoot me while I am down there and the pilot drops home, saved,
    for 500. The lifecycle is the original's, with its own rule that I never
    appear, and never grab, when the player is down to a last pilot."""
    var state: Int
    var x: Int
    var y: Int
    var anim: Int
    var timer: Int
    var beam_t: Int
    var sprite: Int

    def __init__(out self) raises:
        self.state = B_IDLE
        self.x = 304
        self.y = -36
        self.anim = 0
        self.timer = BOSS_FIRST
        self.beam_t = 0
        self.sprite = -1

    def set_idle(mut self) raises:
        self.state = B_IDLE
        self.x = 304
        self.y = -36
        self.anim = 0
        self.beam_t = 0
        self.timer = BOSS_FIRST

    def is_idle(self) raises -> Bool:
        return self.state == B_IDLE

    def is_vulnerable(self) raises -> Bool:
        """Down where a bullet can reach me."""
        return self.state == B_DESCEND or self.state == B_CHARGE or self.state == B_BEAM

    def is_beaming(self) raises -> Bool:
        return self.state == B_CHARGE or self.state == B_BEAM

    def frame(self) raises -> Int:
        """Two idle poses alternating, then the charge and beam poses -- the
        emitter eye grows, which is the tell."""
        if self.state == B_BEAM:
            return 3
        if self.state == B_CHARGE:
            return 2
        return (self.anim // 16) % 2

    def beam_x(self) raises -> Int:
        return self.x + 16

    def beam_top(self) raises -> Int:
        return self.y + 24

    def beam_bottom(self) raises -> Int:
        if self.state == B_BEAM:
            return 350
        return min(self.y + 24 + self.beam_t * 14, 350)

    def wake(mut self) raises:
        self.state = B_ENTER
        self.x = 304
        self.y = -36
        self.anim = 0

    def retreat(mut self) raises:
        self.state = B_RETURN

    def vanish(mut self) raises:
        self.state = B_IDLE
        self.y = -60
        self.timer = BOSS_RESPAWN

    def step(mut self, lives: Int, enabled: Bool) raises -> Int:
        """One frame. Answers an event the game acts on."""
        self.anim += 1
        if self.state == B_IDLE:
            if not (enabled and lives > 1):
                return EV_NONE
            self.timer -= 1
            if self.timer > 0:
                return EV_NONE
            self.wake()
            return EV_WARN
        if self.state == B_ENTER:
            if self.y < BOSS_STATION_Y:
                self.y += 2
            else:
                self.state = B_STATION
                self.timer = BOSS_DWELL
            return EV_NONE
        if self.state == B_STATION:
            self.timer -= 1
            if self.timer > 0:
                return EV_NONE
            if lives <= 1:                 # down to the last pilot? go home
                self.state = B_RETURN
                return EV_NONE
            self.state = B_DESCEND
            return EV_NONE
        if self.state == B_DESCEND:
            self.x = self.x + 3 if self.x < 304 else self.x - 3
            if self.y < BOSS_CAPTURE_Y:
                self.y += 3
                return EV_NONE
            self.state = B_CHARGE
            self.beam_t = 0
            return EV_CHARGED
        if self.state == B_CHARGE:
            self.beam_t += 1
            if self.beam_t < BEAM_CHARGE:
                return EV_NONE
            self.state = B_BEAM
            self.beam_t = 0
            return EV_CHARGED
        if self.state == B_BEAM:
            self.beam_t += 1
            if self.beam_t >= BEAM_HOLD:
                self.state = B_RETURN
                return EV_DONE
            return EV_GRAB
        if self.state == B_RETURN:
            self.y -= 4
            if self.y < -40:
                self.vanish()
            return EV_NONE
        return EV_NONE

    def hits(self, bx: Int, by: Int) raises -> Bool:
        """A bullet in my 32x32 box, while I am down."""
        return self.is_vulnerable() and bx >= self.x and bx < self.x + 32 and by >= self.y and by < self.y + 32


# ── explosion debris ─────────────────────────────────────────────────────
struct Spark(Copyable, Movable):
    var x: Int
    var y: Int
    var vx: Int
    var vy: Int
    var life: Int
    var colour: Int

    def __init__(out self, ax: Int, ay: Int, avx: Int, avy: Int, c: Int) raises:
        self.x = ax
        self.y = ay
        self.vx = avx
        self.vy = avy
        self.life = 18
        self.colour = c

    def step(mut self) raises:
        self.x += self.vx
        self.y += self.vy
        self.vy += 1
        self.life -= 1


# ── the hall of fame ─────────────────────────────────────────────────────
# The original keeps six rows in .DATA -- ACE 30000 down to WOW 4000 -- and
# slots your score in as YOU. Here it is a file in the home directory, one
# `NAME SCORE` per line, so a score survives a restart; anything wrong with
# the file means the defaults, never a crash.

def hall_path() raises -> String:
    """Prose keeps a program's settings in the user's settings directory."""
    var settings = BPath()
    try:
        find_directory(B_USER_SETTINGS_DIRECTORY, settings)
    except:
        return String("")
    return settings.Path() + "/GalaxigansDeluxe hall of fame"


def parse_int(s: String) -> Int:
    var n = 0
    var any = False
    for b in s.as_bytes():
        var c = Int(b)
        if c >= 48 and c <= 57:
            n = n * 10 + (c - 48)
            any = True
        elif any:
            break
    return n


def load_hall(mut names: List[String], mut scores: List[Int]) raises:
    names = ["ACE", "ZAP", "BUG", "FOE", "POW", "WOW"]
    scores = [30000, 22000, 16000, 11000, 7000, 4000]
    var path = hall_path()
    if path.byte_length() == 0:
        return
    var text: String
    try:
        with open(path, "r") as f:
            text = f.read()
    except:
        return
    var nn = List[String]()
    var ns = List[Int]()
    for line in text.split("\n"):
        var t = String(line.strip())
        if t.byte_length() == 0:
            continue
        var parts = t.split(" ")
        if len(parts) < 2:
            continue
        nn.append(String(parts[0]))
        ns.append(parse_int(String(parts[len(parts) - 1])))
    if len(nn) == 6:
        names = nn^
        scores = ns^


def save_hall(names: List[String], scores: List[Int]) raises:
    """Written beside the old one and renamed over it, so a failed write
    never leaves half a hall of fame; and a failure is said, not swallowed."""
    var path = hall_path()
    if path.byte_length() == 0:
        return
    var text = String("")
    for i in range(len(names)):
        text += names[i] + " " + String(scores[i]) + "\n"
    try:
        with open(path + ".new", "w") as f:
            f.write(text)
        BEntry(path + ".new").Rename(path, True)
    except e:
        print("GalaxigansDeluxe: the hall of fame was not saved:", e)


# ── the level table, the themes, the scenes ──────────────────────────────

def theme_rows(theme: Int) raises -> List[Int]:
    """The species for grid rows 0..4, top row first (and toughest).

    SIX themes now rather than four, so the fourteen creatures all get a
    wave. Six and twelve share a factor, so themes repeat every six levels
    while the backdrop repeats every twelve -- which means level 7 wears
    theme 0 against a different sky, and no two of the twelve look alike."""
    if theme == 1:
        return [5, 8, 1, 2, 0]      # + ray: hornet stingray moth beetle grunt
    if theme == 2:
        return [9, 6, 8, 7, 4]      # new-heavy: squid jellyfish stingray spider mantis
    if theme == 3:
        return [6, 5, 8, 3, 1]      # full mix: jellyfish hornet stingray scorpion moth
    if theme == 4:
        return [11, 10, 12, 12, 0]  # hive: crab wasp drone drone grunt
    if theme == 5:
        return [13, 11, 10, 4, 2]   # deep: serpent crab wasp mantis beetle
    return [5, 1, 0, 0, 2]          # classic: hornet moth grunt grunt beetle


def level_scene(level: Int) raises -> Int:
    return level                    # the twelve scenes in table order


def level_theme(level: Int) raises -> Int:
    return level % 6


def level_boss(level: Int) raises -> Bool:
    """The capture boss turns up every third level -- the original's own
    boss column."""
    return level % 3 == 2


def scene_name(scene: Int) raises -> String:
    var names: List[String] = [
        "NEBULA", "GALAXY", "BLACK HOLE", "ALIEN WORLD", "MOON", "SUPERNOVA",
        "WORMHOLE", "GAS GIANT", "AURORA", "PULSAR", "PLASMA", "BINARY STARS",
    ]
    return names[scene % 12]


def beam_ramp() raises -> List[Int]:
    """The cyan energy ramp, dim -> white -> dim so it reads as flow."""
    return [16, 48, 64, 28, 96, 120, 48, 152, 184, 88, 200, 232,
            176, 244, 255, 88, 200, 232, 48, 152, 184, 28, 96, 120]


def score6(n: Int) raises -> String:
    """Six digits, zero-padded -- the arcade's own score format."""
    var t = String(n)
    while t.byte_length() < 6:
        t = String("0") + t
    return t


# ── the game ─────────────────────────────────────────────────────────────
struct Game(Movable):
    var rng: Int
    var state: Int
    var state_timer: Int
    var frame: Int
    var ship_x: Int
    var lives: Int
    var score: Int
    var hi_score: Int
    var wave: Int
    var level: Int
    var scene: Int
    var theme: Int
    var motif_gap: Int        # frames until a diving species may play its motif again
    var motif_age: List[Int]  # the frame each species' motif last played, -1 for never
    var respawn: Int
    var cooldown: Int
    var fire_was_down: Bool
    var fleet: List[Galaxigan]
    var sway_x: Int
    var sway_dir: Int
    var dive_timer: Int
    var bomb_timer: Int
    var bullets: List[Shot]
    var bombs: List[Shot]
    var mines: List[Mine]
    var sparks: List[Spark]
    var flap: Int
    var dance_t: Int
    var mine_drops: Int
    var saucer_drops: Int
    var hall_names: List[String]
    var hall_scores: List[Int]
    var hi_new_row: Int
    var initials: String
    var last_letter: Int
    var hi_done: Int
    var boss: Boss
    var boss_on: Bool
    var abducting: Int        # 0 nobody, 1 rising up the beam, 2 falling home
    var abductee_x: Int
    var abductee_y: Int
    var beam_phase: Int
    var pilots_taken: Int
    var saucer_x: Int
    var saucer_dir: Int
    var saucer_timer: Int
    var saucer_wah: Int
    var saucer_bomb_t: Int
    # sprite definitions and instances
    var species_def: List[Int]
    var ship_spr: Int
    var saucer_spr: Int
    var pilot_spr: List[Int]
    var boss_spr: Int
    var trace: Bool           # GDX_TRACE=1: one line per event, for a headless run
    var pacifist: Bool        # GDX_PACIFIST=1: the autopilot never fires, so the saucer and the boss play out
    var keep_scores: Bool     # False on an autopilot run: a test must not write the player's hall
    var keys: key_info        # this tick's keyboard, for the initials

    def __init__(out self, mut sprites: Sprites) raises:
        self.rng = 0x2545F4914F6CDD1D
        self.state = ATTRACT
        self.state_timer = 0
        self.frame = 0
        self.ship_x = FIELD_W // 2
        self.lives = 3
        self.score = 0
        self.hi_score = 0
        self.wave = 1
        self.level = 0
        self.scene = 0
        self.theme = 0
        self.motif_gap = 0
        self.motif_age = List[Int](length=SPECIES_COUNT, fill=-1)
        self.respawn = 0
        self.cooldown = 0
        self.fire_was_down = False
        self.fleet = List[Galaxigan]()
        self.sway_x = 0
        self.sway_dir = 1
        self.dive_timer = DIVE_PERIOD
        self.bomb_timer = BOMB_PERIOD  # wave 1; start_wave re-arms from the ramp
        self.bullets = List[Shot]()
        self.bombs = List[Shot]()
        self.mines = List[Mine]()
        self.sparks = List[Spark]()
        self.flap = 0
        self.dance_t = 0
        self.mine_drops = 0
        self.saucer_drops = 0
        self.hall_names = List[String]()
        self.hall_scores = List[Int]()
        self.hi_new_row = 0
        self.initials = String()
        self.last_letter = 0
        self.hi_done = 0
        self.boss = Boss()
        self.boss_on = False
        self.abducting = 0
        self.abductee_x = 0
        self.abductee_y = 0
        self.beam_phase = 0
        self.pilots_taken = 0
        self.saucer_x = -60
        self.saucer_dir = 0
        self.saucer_timer = SAUCER_PERIOD
        self.saucer_wah = 0
        self.saucer_bomb_t = SAUCER_BOMB_GAP
        self.species_def = List[Int]()
        self.ship_spr = -1
        self.saucer_spr = -1
        self.pilot_spr = List[Int]()
        self.boss_spr = -1
        self.trace = False
        self.pacifist = False
        self.keep_scores = True
        self.keys = key_info(0, 0, 0, 0, 0)

        load_hall(self.hall_names, self.hall_scores)
        self.hi_score = self.hall_scores[0]

        # Definitions, built once. The fleet is forty instances over ten
        # species definitions; a level change re-points them.
        for k in range(SPECIES_COUNT):
            self.species_def.append(define_species_sprite(sprites, k))
        var mine_def = define_mine_sprite(sprites)
        var boss_def = define_boss_sprite(sprites)
        var pilot_def = define_pilot_sprite(sprites)
        var ship_def = define_ship_sprite(sprites)
        var saucer_def = define_saucer_sprite(sprites)

        self.ship_spr = sprites.place(ship_def, -100.0, -100.0)
        self.saucer_spr = sprites.place(saucer_def, -100.0, -100.0)
        sprites.hide(self.saucer_spr)
        self.boss_spr = sprites.place(boss_def, -100.0, -100.0)
        sprites.hide(self.boss_spr)
        self.boss.sprite = self.boss_spr
        for _ in range(4):
            var p = sprites.place(pilot_def, -100.0, -100.0)
            sprites.hide(p)
            self.pilot_spr.append(p)
        for _ in range(6):
            var m = Mine()
            m.sprite = sprites.place(mine_def, -100.0, -100.0)
            sprites.hide(m.sprite)
            self.mines.append(m^)
        for r in range(ROWS):
            for c in range(COLS):
                var a = Galaxigan(GRID_X + c * COL_GAP, GRID_Y + r * ROW_GAP)
                a.sprite = sprites.place(self.species_def[0], -100.0, -100.0)
                sprites.hide(a.sprite)
                self.fleet.append(a^)
        for _ in range(4):
            self.bullets.append(Shot())
        for _ in range(6):
            self.bombs.append(Shot())

    def log(self, msg: String):
        if self.trace:
            print("[gdx]", self.frame, msg, flush=True)  # a trace is watched live

    # ── randomness: xorshift64*, seeded fixed, so a headless run is the
    # same run every time ──
    def rand(mut self) raises -> Float64:
        var x = self.rng
        x ^= (x >> 12) & 0xFFFFFFFFFFFFF
        x ^= (x << 25) & 0xFFFFFFFFFFFFFFFF
        x ^= (x >> 27) & 0x1FFFFFFFFF
        self.rng = x & 0xFFFFFFFFFFFFFFFF
        return Float64((self.rng >> 11) & 0x1FFFFFFFFFFFFF) / 9007199254740992.0

    # ── setup ────────────────────────────────────────────────────────────
    def new_game(mut self, mut sprites: Sprites) raises:
        self.score = 0
        self.lives = 3
        self.wave = 1
        self.flap = 0
        self.state = ATTRACT
        self.state_timer = ATTRACT_LENGTH
        # A game opens with an introduction: the floor starts at zero, so
        # the first alien to leave the formation brings its motif with it.
        self.motif_gap = 0
        self.start_wave(sprites)

    def dive_period_now(self) raises -> Int:
        """Each wave dives harder -- the original ramps gDivePeriod so.

        Four frames a wave, not six: at six the period hit its floor by wave
        8, so waves 8 through 12 dived at exactly the same rate and only the
        backdrop changed. Four reaches the same floor at wave 12, which is
        where the table wraps -- so every wave in the cycle is faster than
        the one before it and none of the ramp is spent early.
        """
        return max(DIVE_PERIOD - (self.wave - 1) * 4, 18)

    def bomb_period_now(self) raises -> Int:
        """Bombs fall closer together as the waves go by.

        This did not scale at all: every wave dropped at BOMB_PERIOD, so a
        formation that dived twice as often still shot at the same rate and
        wave 12 was only busier, not harder.

        One frame a wave, reaching eleven at wave 12 -- half the opening
        cadence over the whole cycle. Steeper than that bottoms out early
        and wastes the back half of the table, which is the mistake the dive
        ramp above had made.
        """
        return max(BOMB_PERIOD - (self.wave - 1), 11)

    def mine_chance_now(self) raises -> Int:
        """One in N of the saucer's drops is a mine. Rarer early, common
        late; 1-in-3 is the floor, because near-always is not a decision."""
        return max(8 - (self.wave - 1) // 2, 3)

    def start_wave(mut self, mut sprites: Sprites) raises:
        """A wave is a reset, not a reallocation: the objects persist. Pick
        this level's cosmos and formation and re-arm the timers. The table
        wraps, so wave 13 is level 1's backdrop with wave 13's cadence."""
        self.level = (self.wave - 1) % 12
        self.scene = level_scene(self.level)
        self.theme = level_theme(self.level)
        self.ship_x = FIELD_W // 2
        self.respawn = 0
        self.cooldown = 0
        self.fire_was_down = False
        self.sway_x = 0
        self.sway_dir = 1
        self.dive_timer = self.dive_period_now()
        self.bomb_timer = self.bomb_period_now()
        self.saucer_x = -60
        self.saucer_dir = 0
        self.saucer_timer = SAUCER_PERIOD
        self.saucer_wah = 0
        self.saucer_bomb_t = SAUCER_BOMB_GAP
        for i in range(len(self.fleet)):
            self.fleet[i].reset()
        self.dress_fleet(sprites)
        for i in range(len(self.bullets)):
            self.bullets[i].live = False
        for i in range(len(self.bombs)):
            self.bombs[i].live = False
        for i in range(len(self.mines)):
            self.mines[i].live = False
        self.mine_drops = 0
        self.saucer_drops = 0
        self.boss_on = level_boss(self.level)
        self.boss.set_idle()
        self.abducting = 0
        self.abductee_x = 0
        self.abductee_y = 0
        self.beam_phase = 0
        self.sparks = List[Spark]()

    def dress_fleet(mut self, mut sprites: Sprites) raises:
        """Each row becomes one species: its definition (art and palette
        already loaded) is what the instance now points at."""
        var rows = theme_rows(self.theme)
        for i in range(len(self.fleet)):
            var sp = rows[i // COLS]
            self.fleet[i].species = sp
            sprites.instances[self.fleet[i].sprite].definition = self.species_def[sp]

    def alive_count(self) raises -> Int:
        var n = 0
        for i in range(len(self.fleet)):
            if self.fleet[i].alive:
                n += 1
        return n

    # ── the frame ────────────────────────────────────────────────────────
    def step(mut self, mut sprites: Sprites, mut field: Field, deck: P,
             left: Bool, right: Bool, fire_down: Bool,
             typing: Bool = False) raises:
        self.frame += 1
        if self.state == PLAYING:
            self.step_play(sprites, field, deck, left, right, fire_down)
        elif self.state == ATTRACT:
            self.step_attract(sprites, deck, fire_down)
        elif self.state == CLEARED:
            self.step_cleared(sprites)
        elif self.state == OVER:
            self.step_over()
        elif self.state == HISCORE:
            self.step_hiscores(sprites, typing, fire_down)

    def fire_pressed(mut self, down: Bool) raises -> Bool:
        """Tap to fire: the key must be RELEASED between shots."""
        var pressed = down and not self.fire_was_down
        self.fire_was_down = down
        return pressed

    def step_attract(mut self, mut sprites: Sprites, deck: P, fire_down: Bool) raises:
        """The title, with the fleet swaying behind it. Fire starts a game;
        if nobody does, the title hands over to the hall of fame and the
        cabinet keeps cycling for as long as it is left alone."""
        self.sway_fleet()
        for i in range(len(self.fleet)):
            if self.fleet[i].alive:
                self.fleet[i].follow_formation(self.sway_x)
        if self.fire_pressed(fire_down):
            self.state = PLAYING
            self.start_wave(sprites)
            self.log(String("game start, wave ") + String(self.wave) + " " + scene_name(self.scene) + (" with boss" if self.boss_on else ""))
            _ = play_tune_gm(deck, TUNE_TITLE)
            return
        self.state_timer -= 1
        if self.state_timer <= 0:
            self.hi_new_row = 0
            self.state = HISCORE
            self.state_timer = HISCORE_LENGTH

    def step_cleared(mut self, mut sprites: Sprites) raises:
        self.state_timer -= 1
        if self.state_timer <= 0:
            self.wave += 1
            self.state = PLAYING
            self.start_wave(sprites)

    def step_over(mut self) raises:
        """Game over: the survivors break formation and dance -- the angle
        steps once a frame plus each alien's own offset around the wheel, and
        the radius breathes at HALF that rate, so the pinwheel opens and
        closes as it turns. Integer sines throughout."""
        self.state_timer -= 1
        self.dance_t += 1
        var i = 0
        for k in range(len(self.fleet)):
            if self.fleet[k].alive:
                var radius = DANCE_R0 + sine_at(self.dance_t // 2 + i * DANCE_RAD_STEP) * DANCE_R1 // 256
                var angle = self.dance_t + i * DANCE_ANGLE_STEP
                self.fleet[k].move_to(
                    DANCE_CX + sine_at(angle + 64) * radius // 256,
                    DANCE_CY + sine_at(angle) * radius // 256,
                )
                i += 1
        self.step_sparks()
        if self.state_timer <= 0:
            if self.score > self.hi_score:
                self.hi_score = self.score
            self.enter_hiscores()

    def enter_hiscores(mut self) raises:
        """Slot the score into the hall -- sorted, six rows, named YOU -- save
        it, and show the table before the attract resumes."""
        self.hi_new_row = 0
        var names = List[String]()
        var scores = List[Int]()
        var inserted = False
        for i in range(len(self.hall_names)):
            if not inserted and self.score > self.hall_scores[i]:
                names.append(String("YOU"))
                scores.append(self.score)
                inserted = True
                self.hi_new_row = len(names)
            names.append(self.hall_names[i])
            scores.append(self.hall_scores[i])
        if inserted:
            while len(names) > 6:
                _ = names.pop()
                _ = scores.pop()
            self.hall_names = names^
            self.hall_scores = scores^
            if self.keep_scores:
                save_hall(self.hall_names, self.hall_scores)
            self.log(String("hall of fame: row ") + String(self.hi_new_row))
        self.state = HISCORE
        self.state_timer = HISCORE_LENGTH
        self.initials = String()
        self.last_letter = 0
        self.hi_done = 0

    def step_hiscores(
        mut self, mut sprites: Sprites, typing: Bool, fire_down: Bool
    ) raises:
        """Take three letters, then linger a few seconds and go back.

        Only when the score EARNED a row -- being asked for your initials
        after not placing is the machine rubbing it in. Without a row, or
        headless, this is the old countdown.
        """
        if typing and self.hi_new_row > 0 and self.initials.byte_length() < 3:
            var c = letter_held(self.keys)
            # Edge-triggered on the letter, not the frame: a key held down
            # should give one letter, and releasing it should allow the same
            # letter again -- AAA is a perfectly good set of initials.
            if c != 0 and c != self.last_letter:
                self.initials += chr(c)
                self.log(String("initials: ") + self.initials)
                if self.initials.byte_length() == 3:
                    self.hall_names[self.hi_new_row - 1] = self.initials
                    if self.keep_scores:
                        save_hall(self.hall_names, self.hall_scores)
                    # A few seconds to admire it, then the attract resumes.
                    self.hi_done = HISCORE_LINGER
            self.last_letter = c
            if self.hi_done == 0:
                return                      # the clock waits for the player

        # Space ends it. Through `fire_pressed`, so the shot the player was
        # holding when they died does not skip the table before they have
        # seen it: the key has to be released and pressed again, which is
        # the same rule firing already has.
        if typing and self.fire_pressed(fire_down):
            self.new_game(sprites)
            return

        if self.hi_done > 0:
            self.hi_done -= 1
            if self.hi_done > 0:
                return
        self.state_timer -= 1
        if self.state_timer <= 0:
            self.new_game(sprites)

    def begin_dance(mut self, deck: P) raises:
        """The aliens have won: they leave formation, and their own tune
        plays over it -- 'Alien Victory', the square-lead triumph."""
        self.state = OVER
        self.state_timer = DANCE_LENGTH
        self.dance_t = 0
        self.log(String("game over: the dance, score ") + String(self.score))
        stop_tune(deck)          # no bug still humming under the fanfare
        _ = play_tune_gm(deck, TUNE_ALIEN_VICTORY)

    def step_play(mut self, mut sprites: Sprites, mut field: Field, deck: P,
                  left: Bool, right: Bool, fire_down: Bool) raises:
        if self.respawn > 0:
            self.respawn -= 1
        else:
            self.step_ship(deck, left, right, fire_down)
        for i in range(len(self.bullets)):
            self.bullets[i].step()
        for i in range(len(self.bombs)):
            self.bombs[i].step()
        self.sway_fleet()
        self.step_fleet(deck)
        self.step_saucer(deck)
        for i in range(len(self.mines)):
            self.mines[i].step()
        self.step_boss(field, deck)
        self.step_sparks()
        self.check_collisions(sprites, deck)
        if self.state == PLAYING and self.alive_count() == 0:
            self.state = CLEARED
            self.state_timer = 120
            self.log(String("wave ") + String(self.wave) + " cleared, score " + String(self.score))
            _ = play_tune_gm(deck, TUNE_STAGE_CLEAR)

    # ── the player ───────────────────────────────────────────────────────
    def step_ship(mut self, deck: P, left: Bool, right: Bool, fire_down: Bool) raises:
        if left:
            self.ship_x -= 4
        if right:
            self.ship_x += 4
        self.ship_x = min(max(self.ship_x, 12), FIELD_W - 12)
        if self.cooldown > 0:
            self.cooldown -= 1
        if self.fire_pressed(fire_down):
            self.fire(deck)

    def fire(mut self, deck: P) raises:
        if self.cooldown > 0:
            return
        for i in range(len(self.bullets)):
            if not self.bullets[i].live:
                self.bullets[i].fire_from(self.ship_x, PLAYER_Y - 12, -7)
                self.cooldown = 8
                _ = sfx_play(deck, SFX_SHOOT)
                return

    # ── the fleet ────────────────────────────────────────────────────────
    def sway_fleet(mut self) raises:
        self.sway_x += self.sway_dir
        if self.sway_x >= 16:
            self.sway_dir = -1
        if self.sway_x <= -16:
            self.sway_dir = 1

    def step_fleet(mut self, deck: P) raises:
        if self.motif_gap > 0:
            self.motif_gap -= 1
        self.dive_timer -= 1
        if self.dive_timer <= 0:
            self.dive_timer = self.dive_period_now()
            self.launch_diver(deck)
        self.bomb_timer -= 1
        if self.bomb_timer <= 0:
            self.bomb_timer = self.bomb_period_now()
            self.drop_bomb()
        var ship_x = self.ship_x
        var sway = self.sway_x
        for i in range(len(self.fleet)):
            if not self.fleet[i].alive:
                continue
            if self.fleet[i].state == A_DIVE:
                if self.fleet[i].dive_step(ship_x):
                    self.fleet[i].reenter_at(sway)
            elif self.fleet[i].state == A_RETURN:
                self.fleet[i].return_step(sway)
            else:
                self.fleet[i].follow_formation(sway)

    def launch_diver(mut self, deck: P) raises:
        """Pick a live alien still sitting in formation and launch it, with a
        random seed for its flight plan -- and, if the floor has run out,
        var it announce itself."""
        var candidates = List[Int]()
        for i in range(len(self.fleet)):
            if self.fleet[i].alive and self.fleet[i].state == A_FORM:
                candidates.append(i)
        if len(candidates) == 0:
            return
        var pick = candidates[Int(self.rand() * Float64(len(candidates)))]
        if self.motif_gap <= 0:
            # The thirty seconds are up, so this dive carries a tune -- and
            # at one tune every half minute, WHICH tune matters more than
            # which alien. So the diver becomes the one whose species has
            # been silent longest, and the same motif cannot come round
            # twice while another is waiting to be heard. Everything still
            # equal, the random pick stands.
            var best = pick
            var best_age = self.motif_age[self.fleet[pick].species]
            for c in range(len(candidates)):
                var i = candidates[c]
                var age = self.motif_age[self.fleet[i].species]
                if age < best_age:
                    best = i
                    best_age = age
            pick = best
        var seed = Int(self.rand() * 65535.0)
        self.fleet[pick].dive_with_seed(seed)
        if self.motif_gap <= 0:
            self.motif_gap = MOTIF_GAP
            var sp = self.fleet[pick].species
            self.motif_age[sp] = self.frame
            _ = play_tune(deck, motif_for(sp), loop=False)
            self.log(String("motif: ") + species_name(sp))

    def drop_bomb(mut self) raises:
        """The lowest diver drops the bomb -- a bomb from the back of the
        formation would be a free hit on nobody."""
        var lowest = -1
        for i in range(len(self.fleet)):
            if self.fleet[i].alive and self.fleet[i].is_diving():
                if lowest < 0 or self.fleet[i].y > self.fleet[lowest].y:
                    lowest = i
        if lowest < 0:
            return
        var bx = self.fleet[lowest].x
        var by = self.fleet[lowest].y + 10
        for i in range(len(self.bombs)):
            if not self.bombs[i].live:
                self.bombs[i].fire_from(bx, by, 4)
                return

    # ── the bonus saucer ─────────────────────────────────────────────────
    def step_saucer(mut self, deck: P) raises:
        if self.saucer_dir == 0:
            self.saucer_timer -= 1
            if self.saucer_timer <= 0:
                self.saucer_timer = SAUCER_PERIOD
                self.saucer_dir = 1 if self.rand() < 0.5 else -1
                self.saucer_wah = 0                  # the warble starts on arrival
                _ = play_tune_gm(deck, TUNE_SAUCER)        # the pad swell, under it
                self.saucer_x = -30 if self.saucer_dir > 0 else FIELD_W + 30
                self.log(String("saucer enters from the ") + ("left" if self.saucer_dir > 0 else "right"))
        else:
            self.saucer_x += self.saucer_dir * 2
            # The wah-wah: one note runs 0.9s, so it is re-triggered on a loop
            # while the saucer is on screen and simply stops when it leaves.
            if self.saucer_wah > 0:
                self.saucer_wah -= 1
            else:
                self.saucer_wah = 50
                _ = sfx_play(deck, SFX_SAUCER)
            self.saucer_drop()
            if self.saucer_x < -40 or self.saucer_x > FIELD_W + 40:
                self.saucer_dir = 0

    def saucer_drop(mut self) raises:
        """Something from its belly every 28 frames while it is over the
        field -- and one drop in N is a MINE rather than a bomb.

        The original's ratio is one in eight (Rng & 7); that is wave one's,
        and `mine_chance_now` tightens it every second wave to a floor of
        one in two. A mine is the saucer's most dangerous drop, so how often
        it chooses one is the clearest dial the saucer has."""
        if self.saucer_x < 0 or self.saucer_x > FIELD_W - 16:
            return
        self.saucer_bomb_t -= 1
        if self.saucer_bomb_t > 0:
            return
        self.saucer_bomb_t = SAUCER_BOMB_GAP
        self.saucer_drops += 1
        if Int(self.rand() * Float64(self.mine_chance_now())) == 0:
            for i in range(len(self.mines)):
                if not self.mines[i].live:
                    self.mines[i].drop_at(self.saucer_x, SAUCER_Y + 12)
                    self.mine_drops += 1
                    self.log(String("saucer drops a MINE at x=") + String(self.saucer_x))
                    return
        else:
            for i in range(len(self.bombs)):
                if not self.bombs[i].live:
                    self.bombs[i].fire_from(self.saucer_x, SAUCER_Y + 12, 4)
                    return

    # ── the capture boss ─────────────────────────────────────────────────
    def step_boss(mut self, mut field: Field, deck: P) raises:
        # A freed pilot falls home from wherever the beam had got it to --
        # in ANY boss state, including after the boss is gone.
        if self.abducting == 2:
            self.abductee_y += 5
            if self.abductee_y >= PILOT_ROW_Y:
                self.abducting = 0
        var lives = self.lives
        var enabled = self.boss_on
        var event = self.boss.step(lives, enabled)
        if event == EV_WARN:
            _ = sfx_play(deck, SFX_HURT)
            self.log(String("boss wakes"))
        elif event == EV_CHARGED:
            _ = sfx_play(deck, SFX_BOSS_HUM)
            self.log(String("boss ") + ("beam" if self.boss.state == B_BEAM else "charge") + " at y=" + String(self.boss.y))
        elif event == EV_DONE:
            self.release_pilot()
        elif event == EV_GRAB:
            self.drag_pilot(deck)
        if self.boss.is_beaming():
            self.cascade_beam(field)

    def drag_pilot(mut self, deck: P) raises:
        """The abduction: a pilot leaves the row and rises up the beam. It
        reaching the boss costs a life -- and if that was the last one, the
        aliens have won and the dance begins."""
        if self.abducting == 0:
            if self.lives <= 1:                   # never take the last pilot
                return
            self.abducting = 1
            self.abductee_x = self.boss.beam_x() - 6
            self.abductee_y = PILOT_ROW_Y
            self.log(String("the beam takes hold of a pilot"))
            return
        if self.abducting != 1:
            return
        self.abductee_y -= 3
        if self.abductee_y > self.boss.y + 26:
            return
        # It made it to the boss.
        self.lives -= 1
        self.pilots_taken += 1
        self.abducting = 0
        self.log(String("pilot TAKEN, lives ") + String(self.lives))
        _ = sfx_play(deck, SFX_HURT)
        self.burst_at(self.boss.beam_x(), self.boss.y + 26, IX_SPARK_GOLD)
        if self.lives <= 0:
            self.begin_dance(deck)
            self.boss.vanish()
        else:
            self.boss.retreat()

    def release_pilot(mut self) raises:
        """The beam times out with nobody taken: whatever is halfway up
        falls home."""
        if self.abducting == 1:
            self.abducting = 2
            self.log(String("pilot freed, falling home"))

    def check_boss_hit(mut self, deck: P) raises:
        """Shooting the boss frees any pilot in the beam (it drops home,
        saved) and pays 500 -- the reason to stand under a tractor beam."""
        for i in range(len(self.bullets)):
            if self.bullets[i].live and self.boss.hits(self.bullets[i].x, self.bullets[i].y):
                self.bullets[i].live = False
                self.score += BOSS_SCORE
                self.log(String("boss SHOT +500"))
                self.burst_at(self.boss.x + 16, self.boss.y + 16, IX_SPARK_RED)
                _ = sfx_play(deck, SFX_EXPLODE)
                self.release_pilot()
                self.boss.retreat()
                return

    def cascade_beam(mut self, mut field: Field) raises:
        """The beam's colour FLOWS without redrawing a pixel: the cone is
        drawn once in palette index 1, and index 1 means something different
        on every scanline. Stepping the ramp by (y + phase) each frame sends
        the bands downward -- the copper-bar trick."""
        var top = self.boss.beam_top()
        var bot = self.boss.beam_bottom()
        var ramp = beam_ramp()
        self.beam_phase += 1
        for y in range(top, bot + 1):
            if y >= 0 and y < FIELD_H:
                var k = ((y - top + self.beam_phase) // 2) % 8
                field.set_line_rgb(y, IX_BEAM, ramp[k * 3], ramp[k * 3 + 1], ramp[k * 3 + 2])

    # ── collisions ───────────────────────────────────────────────────────
    def check_collisions(mut self, mut sprites: Sprites, deck: P) raises:
        for b in range(len(self.bullets)):
            if not self.bullets[b].live:
                continue
            if self.saucer_dir != 0 and self.bullets[b].hits(self.saucer_x, SAUCER_Y + 4, 12, 8):
                self.bullets[b].live = False
                self.score += 200
                self.log(String("saucer shot +200"))
                self.burst_at(self.saucer_x, SAUCER_Y + 4, IX_SPARK_GOLD)
                _ = sfx_play(deck, SFX_COIN)
                self.saucer_dir = 0
                self.saucer_x = -80
            if not self.bullets[b].live:
                continue
            var bx = self.bullets[b].x
            var by = self.bullets[b].y
            for a in range(len(self.fleet)):
                if self.fleet[a].hits(bx, by, 4):
                    self.bullets[b].live = False
                    self.score += self.fleet[a].points()
                    self.burst_at(self.fleet[a].x, self.fleet[a].y, IX_SPARK_RED)
                    _ = sfx_play(deck, SFX_EXPLODE)
                    self.fleet[a].kill()
                    sprites.hide(self.fleet[a].sprite)
                    break

        self.check_boss_hit(deck)

        # Shooting a mine is the treat: 150, the best points on the screen.
        for b in range(len(self.bullets)):
            if not self.bullets[b].live:
                continue
            var bx = self.bullets[b].x
            var by = self.bullets[b].y
            for m in range(len(self.mines)):
                if self.mines[m].hits(bx, by, 4, 4):
                    self.bullets[b].live = False
                    self.mines[m].live = False
                    sprites.hide(self.mines[m].sprite)
                    self.score += MINE_SCORE
                    self.log(String("mine shot +150"))
                    self.burst_at(self.mines[m].x, self.mines[m].y, IX_SPARK_GOLD)
                    _ = sfx_play(deck, SFX_BANG)
                    break

        if self.respawn > 0:
            return
        # And touching one is the threat.
        for m in range(len(self.mines)):
            if self.mines[m].hits(self.ship_x, PLAYER_Y, 6, 6):
                self.mines[m].live = False
                sprites.hide(self.mines[m].sprite)
                self.lose_life(deck)
        for b in range(len(self.bombs)):
            if self.bombs[b].hits(self.ship_x, PLAYER_Y, 8, 10):
                self.bombs[b].live = False
                self.lose_life(deck)
        for a in range(len(self.fleet)):
            if self.fleet[a].is_diving() and self.fleet[a].hits(self.ship_x, PLAYER_Y, 6):
                self.burst_at(self.fleet[a].x, self.fleet[a].y, IX_SPARK_RED)
                self.fleet[a].kill()
                sprites.hide(self.fleet[a].sprite)
                self.lose_life(deck)

    def lose_life(mut self, deck: P) raises:
        if self.state != PLAYING:
            return
        self.burst_at(self.ship_x, PLAYER_Y, IX_SPARK_GOLD)
        _ = sfx_play(deck, SFX_HURT)
        self.lives -= 1
        self.respawn = 90
        self.log(String("ship lost, lives ") + String(self.lives))
        self.ship_x = FIELD_W // 2
        if self.lives <= 0:
            self.begin_dance(deck)

    # ── explosions ───────────────────────────────────────────────────────
    def burst_at(mut self, bx: Int, by: Int, c: Int) raises:
        var n = 14
        for i in range(1, n + 1):
            var ang = i * 256 // n
            self.sparks.append(Spark(
                bx, by,
                sine_at(ang) * 5 // 256,
                sine_at(ang + 64) * 5 // 256 - 2,
                c,
            ))
        while len(self.sparks) > 240:
            _ = self.sparks.pop(0)

    def step_sparks(mut self) raises:
        var keep = List[Spark]()
        for i in range(len(self.sparks)):
            var s = self.sparks[i].copy()
            s.step()
            if s.life > 0:
                keep.append(s^)
        self.sparks = keep^

    # ── drawing ──────────────────────────────────────────────────────────
    def draw(mut self, mut sprites: Sprites, mut field: Field, mut hud: Hud, hud_key: Int) raises:
        """The indexed layer: cleared to 0 so the shader shows through, then
        sparks, bullets, bombs and the beam cone. Then the sprites, then the
        HUD -- which is re-rasterised only when its text changes."""
        var plane = field.active_plane()
        plane.cls(0)
        for i in range(len(self.sparks)):
            plane.fill_rect(self.sparks[i].x, self.sparks[i].y, 2, 2, UInt8(self.sparks[i].colour))
        for i in range(len(self.bullets)):
            if self.bullets[i].live:
                plane.fill_rect(self.bullets[i].x - 1, self.bullets[i].y, 3, 8, UInt8(IX_BULLET))
        for i in range(len(self.bombs)):
            if self.bombs[i].live:
                plane.fill_rect(self.bombs[i].x - 2, self.bombs[i].y, 4, 6, UInt8(IX_BOMB))
        # The tractor beam: a cone from the boss's mouth to the floor, drawn
        # ONCE in index 1 -- whose colour the cascade has already made
        # different on every scanline. Half-width 4 -> 20 down its length.
        if self.boss.is_beaming():
            var top = self.boss.beam_top()
            var bot = self.boss.beam_bottom()
            var span = max(bot - top, 1)
            var bx = self.boss.beam_x()
            for y in range(top, bot + 1):
                var hw = 4 + (y - top) * 16 // span
                plane.fill_rect(bx - hw, y, hw * 2, 1, UInt8(IX_BEAM))
        self.place_sprites(sprites)
        if hud_key != 0:
            self.draw_hud(hud)

    def put(self, mut sprites: Sprites, inst: Int, cx: Int, cy: Int) raises:
        """Sprites are anchored at their CENTRE here (the .mst's are placed
        by top-left), so every caller hands over the middle of the thing."""
        sprites.show(inst)
        sprites.move_to(inst, Float64(cx), Float64(cy))

    def place_sprites(mut self, mut sprites: Sprites) raises:
        """The fleet flaps: every eighth frame the whole formation switches
        to its species' second frame. The high-score scene stands alone."""
        if self.state == HISCORE:
            for i in range(len(self.fleet)):
                sprites.hide(self.fleet[i].sprite)
            for i in range(len(self.mines)):
                sprites.hide(self.mines[i].sprite)
            sprites.hide(self.boss_spr)
            for i in range(len(self.pilot_spr)):
                sprites.hide(self.pilot_spr[i])
            sprites.hide(self.saucer_spr)
            sprites.hide(self.ship_spr)
            return
        self.flap = (self.frame // 8) % 2
        for i in range(len(self.fleet)):
            if self.fleet[i].alive:
                self.put(sprites, self.fleet[i].sprite, self.fleet[i].x, self.fleet[i].y)
                sprites.set_frame(self.fleet[i].sprite, self.flap)
            else:
                sprites.hide(self.fleet[i].sprite)
        for i in range(len(self.mines)):
            if self.mines[i].live:
                self.put(sprites, self.mines[i].sprite, self.mines[i].x, self.mines[i].y)
                sprites.set_frame(self.mines[i].sprite, self.mines[i].frame())
            else:
                sprites.hide(self.mines[i].sprite)
        if self.boss.is_idle():
            sprites.hide(self.boss_spr)
        else:
            self.put(sprites, self.boss_spr, self.boss.x + 16, self.boss.y + 16)
            sprites.set_frame(self.boss_spr, self.boss.frame())
        # The pilots along the bottom, one per life. A pilot in the beam has
        # LEFT the row: drawn wherever the beam has dragged it to.
        var in_row = self.lives - 1 if self.abducting > 0 else self.lives
        for i in range(len(self.pilot_spr)):
            if i < in_row:
                self.put(sprites, self.pilot_spr[i], PILOT_X0 + i * PILOT_GAP + 6, PILOT_ROW_Y + 8)
            else:
                sprites.hide(self.pilot_spr[i])
        if self.abducting > 0:
            self.put(sprites, self.pilot_spr[3], self.abductee_x + 6, self.abductee_y + 8)
        if self.saucer_dir == 0:
            sprites.hide(self.saucer_spr)
        else:
            self.put(sprites, self.saucer_spr, self.saucer_x, SAUCER_Y + 4)
        if self.state == PLAYING and self.respawn == 0:
            self.put(sprites, self.ship_spr, self.ship_x, PLAYER_Y)
        elif self.respawn > 0 and (self.respawn // 4) % 2 == 0:
            self.put(sprites, self.ship_spr, self.ship_x, PLAYER_Y)   # blink through the pause
        else:
            sprites.hide(self.ship_spr)

    def hud_signature(self) raises -> String:
        """Everything the HUD text depends on, as one string: it is
        re-rasterised only when this changes."""
        var s = String(self.state) + ":" + String(self.score) + ":" + String(max(self.hi_score, self.score))
        s += ":" + String(self.wave) + ":" + String(self.lives) + ":" + String(self.scene)
        if self.state == HISCORE:
            s += ":" + String(self.hi_new_row) + ":" + String((self.frame // 8) % 2)
        return s

    def draw_hud(mut self, mut hud: Hud) raises:
        hud.clear()
        if self.state == HISCORE:
            self.draw_hiscores(hud)
            return
        hud.draw_text(10, 8, String("SCORE ") + String(self.score), 255, 255, 255, 2)
        hud.draw_text(250, 8, String("HI ") + String(max(self.hi_score, self.score)), 255, 220, 90, 2)
        hud.draw_text(440, 8, String("WAVE ") + String(self.wave), 140, 220, 255, 2)
        hud.draw_text(440, 336, scene_name(self.scene), 150, 150, 190, 2)
        hud.draw_text(10, 336, String("SHIPS ") + String(self.lives), 120, 200, 255, 2)
        if self.state == ATTRACT:
            hud.draw_text(176, 140, String("GALAXIGANS"), 255, 210, 60, 5)
            hud.draw_text(152, 200, String("SPACE TO START   ARROWS TO STEER"), 220, 220, 255, 2)
        elif self.state == CLEARED:
            hud.draw_text(200, 150, String("WAVE CLEARED"), 120, 255, 140, 4)
            hud.draw_text(200, 200, String("NEXT: ") + scene_name(level_scene(self.wave % 12)), 220, 220, 255, 2)
        elif self.state == OVER:
            hud.draw_text(220, 160, String("GAME OVER"), 255, 90, 90, 4)
            hud.draw_text(236, 210, String("SCORE ") + String(self.score), 255, 220, 120, 2)

    def draw_hiscores(mut self, mut hud: Hud) raises:
        hud.draw_text(130, 46, String("H I G H   S C O R E S"), 255, 210, 60, 3)

        # THE PLAYER'S OWN SCORE, flashing, above the table. It is the thing
        # they came to see, and reading it out of a six-row list is not the
        # same as being shown it.
        if (self.frame // 10) % 2 == 0:
            hud.draw_text(196, 86, String("YOUR SCORE  ") + score6(self.score),
                          255, 255, 255, 2)
        else:
            hud.draw_text(196, 86, String("YOUR SCORE  ") + score6(self.score),
                          255, 160, 40, 2)

        var y = 110
        for i in range(len(self.hall_names)):
            var row = i + 1
            var line = String(row) + "  " + self.hall_names[i] + "  " + score6(self.hall_scores[i])
            # The row you just took blinks gold; the rest sit quiet.
            if row == self.hi_new_row and (self.frame // 8) % 2 == 0:
                hud.draw_text(190, y, line, 255, 220, 90, 2)
            elif row == self.hi_new_row:
                hud.draw_text(190, y, line, 255, 220, 90, 2)
            else:
                hud.draw_text(190, y, line, 150, 200, 255, 2)
            y += 26
        if self.hi_new_row > 0 and self.initials.byte_length() < 3:
            # Three boxes, the one being typed blinking. An arcade asks for
            # initials by showing you the space they go in.
            hud.draw_text(150, 300, String("ENTER YOUR INITIALS"), 120, 255, 140, 2)
            var slot = String()
            for i in range(3):
                if i < self.initials.byte_length():
                    slot += String(self.initials[byte = i : i + 1]) + " "
                elif i == self.initials.byte_length() and (self.frame // 8) % 2 == 0:
                    slot += "_ "
                else:
                    slot += ". "
            hud.draw_text(268, 330, slot, 255, 240, 120, 3)
        elif self.hi_new_row > 0:
            hud.draw_text(208, 300, String("A PLACE IN THE HALL"), 120, 255, 140, 2)
        if self.initials.byte_length() == 3 or self.hi_new_row == 0:
            hud.draw_text(232, 356, String("SPACE TO CONTINUE"), 150, 160, 180, 2)

    def summary(self) raises -> String:
        var names: List[String] = ["attract", "playing", "cleared", "over", "hiscore"]
        var boss_state: List[String] = ["idle", "enter", "station", "descend", "charge", "beam", "return"]
        var mines_live = 0
        for i in range(len(self.mines)):
            if self.mines[i].live:
                mines_live += 1
        return (
            names[self.state] + " score " + String(self.score) + " lives " + String(self.lives)
            + " wave " + String(self.wave) + " (" + scene_name(self.scene) + ") alive "
            + String(self.alive_count()) + " mines " + String(mines_live) + " (dropped "
            + String(self.mine_drops) + " of " + String(self.saucer_drops) + " saucer drops) boss "
            + boss_state[self.boss.state] + " pilots taken " + String(self.pilots_taken)
        )

    # ── the autopilot: a player for a headless run ───────────────────────
    def autopilot(self) raises -> Tuple[Bool, Bool, Bool]:
        """Left, right, fire. Dodges the nearest falling thing, otherwise
        parks under the lowest diver or the nearest formation column, and
        taps fire every other frame."""
        if self.state == ATTRACT:
            return (False, False, self.state_timer < ATTRACT_LENGTH - 30 and (self.frame % 40) < 2)
        if self.state != PLAYING:
            return (False, False, False)
        var target = self.ship_x
        var best_y = -1
        for i in range(len(self.fleet)):
            if self.fleet[i].alive and self.fleet[i].is_diving() and self.fleet[i].y > best_y and self.fleet[i].y < PLAYER_Y - 40:
                best_y = self.fleet[i].y
                target = self.fleet[i].x
        if best_y < 0:
            var best_d = 100000
            for i in range(len(self.fleet)):
                if self.fleet[i].alive:
                    var d = abs(self.fleet[i].x - self.ship_x)
                    if d < best_d:
                        best_d = d
                        target = self.fleet[i].x
        # A diver about to arrive, or anything falling within reach: step
        # aside from it first.
        for i in range(len(self.fleet)):
            if self.fleet[i].alive and self.fleet[i].is_diving() and abs(self.fleet[i].x - self.ship_x) < 26 and self.fleet[i].y > PLAYER_Y - 80:
                target = self.ship_x + 44 if self.fleet[i].x <= self.ship_x else self.ship_x - 44
        for i in range(len(self.bombs)):
            if self.bombs[i].live and abs(self.bombs[i].x - self.ship_x) < 20 and self.bombs[i].y > PLAYER_Y - 70:
                target = self.ship_x + 40 if self.bombs[i].x <= self.ship_x else self.ship_x - 40
        for i in range(len(self.mines)):
            if self.mines[i].live and abs(self.mines[i].x - self.ship_x) < 24 and self.mines[i].y > PLAYER_Y - 90:
                target = self.ship_x + 48 if self.mines[i].x <= self.ship_x else self.ship_x - 48
        var left = target < self.ship_x - 2
        var right = target > self.ship_x + 2
        return (left, right, (self.frame % 2) == 0 and not self.pacifist)


comptime MSG_TICK = 0x7469636B  # 'tick'


struct Galaxigans(GamePaneMessageReceived, GamePaneQuitRequested, Movable):
    """The pane's Mojo state: the game and its stage. A tick is a frame,
    run on the pane's thread with the pane locked -- from a message runner
    at the game's 30 Hz, or back to back when headless."""

    var game: Game
    var sprites: Sprites
    var field: Field
    var hud: Hud
    var deck: P
    var app: BMessenger
    var headless: Bool
    var auto: Bool
    var frames_left: Int
    var frames: Int
    var last_hud: String
    var last_scene: Int
    var prepared: Bool
    var selftest: Bool
    var selftest_failed: Bool

    def __init__(out self, app: BMessenger, headless: Bool, auto: Bool,
                 frames: Int) raises:
        self.sprites = Sprites()
        self.game = Game(self.sprites)
        self.field = Field()
        self.hud = Hud()
        self.deck = P()
        self.app = app
        self.headless = headless
        self.auto = auto
        self.frames_left = frames
        self.frames = 0
        self.last_hud = String("")
        self.last_scene = -1
        self.prepared = False
        self.selftest = False
        self.selftest_failed = False

    def MessageReceived(
        mut self, gamePane: BGamePaneRef[_], message: BMessageRef[_]
    ):
        if message.what != MSG_TICK:
            gamePane.base_MessageReceived(message)
            return
        try:
            self.frame(gamePane)
        except e:
            print("GalaxigansDeluxe:", e)
            self.quit()

    def check_selftest(mut self, summary: String):
        """The game is deterministic -- a fixed seed, a fixed step -- so 200
        frames of the autopilot end the same everywhere: as MojoCocoa's run
        recorded them, wave 1 NEBULA with 31 left, and 630 points."""
        var checks = List[Tuple[String, Bool]]()
        checks.append(("200 frames presented", self.frames == 200))
        checks.append(("wave 1, NEBULA", "wave 1 (NEBULA)" in summary))
        checks.append(("31 aliens left, as MojoCocoa's run", "alive 31" in summary))
        checks.append(("630 points", "score 630" in summary))
        checks.append(("three ships", "lives 3" in summary))
        var passed = 0
        for check in checks:
            print("PASS:" if check[1] else "FAIL:", check[0])
            if check[1]:
                passed += 1
        self.selftest_failed = passed != len(checks)
        if self.selftest_failed:
            print("SELFTEST FAIL", passed, "/", len(checks))
            exit(1)  # the state goes with the pane: main cannot say it later
        else:
            print("SELFTEST PASS", String(passed) + "/" + String(len(checks)))

    def QuitRequested(mut self, gamePane: BGamePaneRef[_]) -> Bool:
        self.quit()  # closing the pane ends the game
        return True

    def quit(self):
        try:
            self.app.SendMessage(B_QUIT_REQUESTED)
        except:
            pass

    def prepare(mut self, pane: BGamePaneRef[_]) raises:
        try:
            pane.SetBackgroundShader(COSMOS_SHADER)  # layer 0: the cosmos
        except e:
            print("GalaxigansDeluxe: the cosmos did not compile:",
                  pane.ShaderError())
        self.field.set_rgb(IX_BULLET, 255, 240, 120)
        self.field.set_rgb(IX_BOMB, 255, 90, 220)
        self.field.set_rgb(IX_SPARK_GOLD, 255, 200, 60)
        self.field.set_rgb(IX_SPARK_RED, 255, 80, 40)
        self.prepared = True

    def frame(mut self, pane: BGamePaneRef[_]) raises:
        if not self.prepared:
            self.prepare(pane)
        var keys = key_info(0, 0, 0, 0, 0)
        if not self.headless:
            keys = get_key_info()
            # 1, 2, 4 -- x1, x2, x4: the window grows, and the pane scales
            # the world into it; not one game coordinate changes.
            for zoom in [1, 2, 4]:
                if key_held(keys, [KEY_1, KEY_2, KEY_4][zoom // 2]):
                    pane.ResizeTo(Float32(FIELD_W * zoom - 1),
                                  Float32(FIELD_H * zoom - 1))
            if key_held(keys, KEY_ESCAPE):
                self.quit()
                return
        self.game.keys = keys
        var controls = (
            self.game.autopilot() if self.auto
            else (key_held(keys, KEY_LEFT), key_held(keys, KEY_RIGHT),
                  key_held(keys, KEY_SPACE) or key_held(keys, KEY_RETURN))
        )
        self.game.step(self.sprites, self.field, self.deck, controls[0],
                       controls[1], controls[2], typing=not self.auto)
        if self.game.scene != self.last_scene:
            pane.SetShaderParam(0, Float32(self.game.scene))
            self.last_scene = self.game.scene
        var signature = self.game.hud_signature()
        var redraw = signature != self.last_hud
        if redraw:
            self.last_hud = signature
        self.field.bind(pane)  # this frame's world
        self.game.draw(self.sprites, self.field, self.hud, 1 if redraw else 0)
        self.field.render(pane)    # colours, and the beam's per-line ones
        self.hud.render(pane)      # the text, into the world
        self.sprites.render(pane)  # over the world, by the host
        pane.Present()
        self.frames += 1
        if self.headless:
            self.frames_left -= 1
            if self.frames_left <= 0:
                var summary = self.game.summary()
                print("GalaxigansDeluxe:", summary, "-- presented",
                      self.frames, "frames")
                if self.selftest:
                    self.check_selftest(summary)
                self.quit()
            else:
                pane.PostMessage(MSG_TICK)  # the next frame, at once


def main() raises:
    # --selftest: 200 frames headless, against MojoCocoa's recorded run.
    var selftest = len(argv()) > 1 and argv()[1] == "--selftest"
    var frames = 200 if selftest else parse_int(getenv("GAMEPANE_FRAMES"))
    var headless = selftest or getenv("GAMEPANE_FRAMES").byte_length() > 0
    var auto = headless or getenv("GDX_AUTOPLAY").byte_length() > 0
    var app = BApplication("application/x-vnd.Prose-GalaxigansDeluxe")
    var state = Galaxigans(BMessenger(app), headless, auto, frames)
    state.selftest = selftest
    state.game.new_game(state.sprites)
    state.game.trace = getenv("GDX_TRACE").byte_length() > 0
    state.game.pacifist = getenv("GDX_PACIFIST").byte_length() > 0
    state.game.keep_scores = not auto
    # GDX_WAVE=n: start at wave n -- the .mst's forceNextWave, for walking the
    # level table (and the boss, which first appears on wave 3) without
    # playing every wave out.
    var start_wave = parse_int(getenv("GDX_WAVE"))
    if start_wave > 1:
        state.game.wave = start_wave
        state.game.start_wave(state.sprites)

    # A window whose pixels are palette indices, the world scaled x2 into
    # it; per-line palettes for the tractor beam's copper bars.
    var pane = BGamePane(
        BRect(80, 80, 80 + FIELD_W * 2 - 1, 80 + FIELD_H * 2 - 1),
        "GalaxigansDeluxe",
        FIELD_W,
        FIELD_H,
        state^,
        2,
        UInt32(B_GAME_PANE_SCANLINE_PALETTE),
    )
    var messenger = BMessenger(pane)
    pane^.Show()
    if headless:
        messenger.SendMessage(MSG_TICK)
        _ = app.Run()
        return
    # The game was tuned at ~30 frames a second: a fixed 30 Hz tick.
    var ticks = BMessageRunner(messenger, BMessage(MSG_TICK), 33333)
    _ = app.Run()
    _ = ticks^
