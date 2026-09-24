#!/usr/bin/env python3
# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, MojoProse. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
# ===----------------------------------------------------------------------=== #
"""Dots, checked on a running Prose machine from the Mac: the program the
bridge must keep running (Haiku/docs/bridge-design.md, section 2).

Starts Dots in the guest, and from screen captures of the machine checks
the window, its menu bar, the canvas colour and the three starting dots
where the Mojo data puts them; sends Dots > Clear (`'clr '`, with `hey`)
and checks the dots are gone; asks it to quit and checks it exits 0.
Mouse clicks are not tested: they never reach windows on a scripted guest.

Usage:
  dots_smoke.py --run "RUNNER" --app PATH/Prose.app --dir GUEST_DIR

RUNNER runs one shell command line in the guest and prints its output (the
command is appended as the last argument); GUEST_DIR holds the built
`dots` and `libmojobe.so`. Prints PASS or FAIL per check, then
`SMOKE PASS n/n` or `SMOKE FAIL`.
"""

import argparse
import shlex
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

SIGNATURE = "application/x-vnd.Prose-dots"

# Dots' window content starts at (100, 100) on the screen; its canvas at
# window y 20; the dots are at canvas (60, 60), (200, 150) and (340, 240).
CANVAS = (30, 30, 46)
DOT = (255, 200, 0)
DOTS = [(160, 180), (300, 270), (440, 360)]
CANVAS_SAMPLES = [(120, 140), (480, 390), (230, 330), (400, 200)]
MENU_BAR = (300, 110)


def read_png(path):
    """(width, height, pixel(x, y) -> (r, g, b)) of an 8-bit RGB or RGBA
    PNG, without anything outside the standard library."""
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("%s: not a PNG" % path)
    offset, idat = 8, b""
    while offset < len(data):
        length, kind = struct.unpack(">I4s", data[offset : offset + 8])
        body = data[offset + 8 : offset + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(
                ">IIBBBBB", body
            )
        elif kind == b"IDAT":
            idat += body
        offset += 12 + length
    if depth != 8 or color not in (2, 6) or interlace:
        raise ValueError("%s: depth %d, colour %d: not read" % (path, depth, color))
    channels = 3 if color == 2 else 4
    stride = width * channels
    raw = zlib.decompress(idat)
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, line = raw[start], bytearray(raw[start + 1 : start + 1 + stride])
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up = previous[i]
            corner = previous[i - channels] if i >= channels else 0
            if kind == 1:
                line[i] = (line[i] + left) & 0xFF
            elif kind == 2:
                line[i] = (line[i] + up) & 0xFF
            elif kind == 3:
                line[i] = (line[i] + (left + up) // 2) & 0xFF
            elif kind == 4:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                guess = left if pa <= pb and pa <= pc else up if pb <= pc else corner
                line[i] = (line[i] + guess) & 0xFF
        rows.append(line)
        previous = line

    def pixel(x, y):
        at = x * channels
        return tuple(rows[y][at : at + 3])

    return width, height, pixel


class Smoke:
    def __init__(self, arguments):
        self.run_command = shlex.split(arguments.run)
        self.app = arguments.app
        self.dir = arguments.dir
        self.passed = 0
        self.failed = 0
        self.work = Path(tempfile.mkdtemp(prefix="dots-smoke-"))

    def guest(self, line):
        result = subprocess.run(
            self.run_command + [line], capture_output=True, text=True
        )
        return result.stdout

    def tell(self, verb):
        result = subprocess.run(
            ["osascript", "-e", 'tell application "%s" to %s' % (self.app, verb)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        return result.stdout + result.stderr

    def capture(self, name):
        path = self.work / (name + ".png")
        self.tell('capture to POSIX file "%s"' % path)
        return read_png(path)

    def check(self, what, ok, detail=""):
        print("%s: %s%s" % ("PASS" if ok else "FAIL", what,
                            " (%s)" % detail if detail else ""))
        if ok:
            self.passed += 1
        else:
            self.failed += 1

    def teams(self):
        out = self.guest("ps | grep '/dots' | grep -v grep")
        # the team id is the column after the command
        return [line.split()[1] for line in out.splitlines()
                if line.strip() and line.split()[0].endswith("/dots")]

    def main(self):
        for team in self.teams():
            self.guest("kill -9 %s" % team)
        self.guest(
            "cd %s && rm -f dots.status && (./dots > dots.out 2>&1; "
            "echo $? > dots.status) > /dev/null 2>&1 &" % shlex.quote(self.dir)
        )
        time.sleep(5)
        self.tell('press "escape"')  # the screen may have blanked
        time.sleep(1)
        _, _, before = self.capture("drawn")
        self.check("the canvas is Dots' colour",
                   all(before(x, y) == CANVAS for x, y in CANVAS_SAMPLES),
                   str([before(x, y) for x, y in CANVAS_SAMPLES]))
        self.check("three dots where the Mojo data puts them",
                   all(before(x, y) == DOT for x, y in DOTS),
                   str([before(x, y) for x, y in DOTS]))
        bar = before(*MENU_BAR)
        self.check("a menu bar above the canvas",
                   bar not in (CANVAS, DOT) and min(bar) > 150, str(bar))

        self.guest("hey %s 'clr ' Window 0 > /dev/null; sleep 1" % SIGNATURE)
        _, _, after = self.capture("cleared")
        self.check("Dots > Clear clears the dots (MessageReceived, FindView, "
                   "state[Canvas]() in Mojo)",
                   all(after(x, y) == CANVAS for x, y in DOTS),
                   str([after(x, y) for x, y in DOTS]))

        self.guest("hey %s quit > /dev/null; sleep 2" % SIGNATURE)
        status = self.guest("cat %s/dots.status" % shlex.quote(self.dir)).strip()
        output = self.guest("cat %s/dots.out" % shlex.quote(self.dir)).strip()
        self.check("a quit request ends it, status 0",
                   status.startswith("0") and not self.teams(),
                   "status %r, output %r" % (status, output[:200]))
        total = self.passed + self.failed
        if self.failed:
            print("SMOKE FAIL %d/%d (captures in %s)" % (self.passed, total,
                                                         self.work))
            return 1
        print("SMOKE PASS %d/%d" % (self.passed, total))
        return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--run", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--dir", required=True)
    sys.exit(Smoke(parser.parse_args()).main())
