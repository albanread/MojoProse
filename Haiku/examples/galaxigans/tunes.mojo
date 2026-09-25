# GalaxigansDeluxe -- the four melodic cues, transcribed note for note from
# the assembler original's galaxigans_music.was by way of MACVM's port. The
# %%MIDI program lines are General MIDI numbers: 80 square lead, 52 choir,
# 9 glockenspiel, 91 polysynth pad -- which is what MACVM plays them on.

# 'Alien Victory' -- the square-lead triumph the aliens dance to.
comptime TUNE_ALIEN_VICTORY = String("""X:1
M:4/4
L:1/8
Q:1/4=210
%%MIDI program 80
K:Cm
V:1
G,4 _B,4 | c4 _e4 | _e2d2c2_B2 | G,8 | G,2G,2_A,2_B,2 | c2_e2g2_e2 | c4_B4 | G,8 | _E2F2G2_A2 | _B2c2_e2g2 | f/e/d/c/_B/A/_A/G/ | _E8 |""")

# 'Stage Alert' -- the ominous choir build when a game starts.
comptime TUNE_TITLE = String("""X:1
M:4/4
L:1/8
Q:1/4=84
%%MIDI program 52
K:Am
V:1
z4 A,2 E2 | A2 c2 e2 d2 | c4 B4 | A8 |""")

# 'You Win!' -- the glockenspiel fanfare for a cleared wave.
comptime TUNE_STAGE_CLEAR = String("""X:1
M:4/4
L:1/8
Q:1/4=234
%%MIDI program 9
K:C
V:1
ceg c""")

# 'Saucer Wooh' -- the pad swell under the saucer's warble.
comptime TUNE_SAUCER = String("""X:1
M:4/4
L:1/8
Q:1/4=160
%%MIDI program 91
K:C
V:1
G z G z | GABc cBAG |""")
