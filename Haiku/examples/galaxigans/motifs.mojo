# GalaxigansDeluxe -- a chip motif for each alien species, played when one
# of them leaves the formation and dives.
#
# The four cues in `tunes.mojo` are General MIDI and they mark the big
# moments: the title, the alien victory, the stage clear, the saucer. These
# are the opposite. They are one bar long, they run on the chip, and they
# are not music so much as a voice: this is a hornet coming at you, and it
# does not sound like the jellyfish did.
#
# Two rules keep them sparse, and both live in `Game.launch_diver`:
#   -- one motif every thirty seconds, never two at once;
#   -- and when the thirty seconds are up, the diver is chosen from the
#      species you have heard LEAST recently, so the same tune does not
#      come round twice in a row.
# The second rule is why fourteen motifs are worth writing: without it,
# random diving would play the grunt three times before you ever met the
# squid.
#
# Two voices each -- a lead with the character in it and a bass that says
# where it sits -- and each one moves somewhere across its bar rather than
# repeating a figure, because a motif you hear every half minute has to
# survive being remembered. The effects channel is chip B and is untouched:
# a motif and a shot are different chips, so shooting never cuts the tune.

# 0 grunt -- the cheapest alien in the box. Blunt low pulses that give up
# after four notes: it climbs a third, thinks better of it, and sits down.
comptime M_GRUNT = String("""X:1
M:4/4
L:1/8
Q:1/4=132
K:Cm
V:1
[I:chip v=0 wave=pulse pw=500 a=0 d=4 s=6 r=3 vol=12]
C2 _E2 G2 _E2 | C4
V:2
[I:chip v=1 wave=pulse pw=700 a=0 d=6 s=4 r=4 filt=1 cutoff=900 res=3 mode=lp vol=11]
C,4 C,4 | C,,4
""")

# 1 moth -- soft and unsteady. A triangle that cannot hold a pitch, over a
# bass that keeps sliding out from under it.
comptime M_MOTH = String("""X:1
M:4/4
L:1/8
Q:1/4=132
K:Am
V:1
[I:chip v=0 wave=tri a=1 d=3 s=9 r=6 vol=13]
c/2d/2c/2d/2 e/2f/2e/2d/2 | c/2=B/2c/2a/2 a2
V:2
[I:chip v=1 wave=tri a=2 d=0 s=10 r=8 vol=10]
A,4 F,4 | E,8
""")

# 2 beetle -- heavy. A filtered saw two octaves down, stamping in fives,
# with a scrape above it on the off-beat.
comptime M_BEETLE = String("""X:1
M:4/4
L:1/8
Q:1/4=112
K:Cm
V:1
[I:chip v=0 wave=saw a=0 d=5 s=4 r=4 filt=1 cutoff=800 res=4 mode=lp vol=13]
C,,2 C,,2 _E,,2 C,,2 | _B,,,4
V:2
[I:chip v=1 wave=noise a=0 d=2 s=0 r=2 vol=9]
z2 C2 z2 C2 | C2 C2
""")

# 3 scorpion -- a run up the minor scale and then the sting: four steps,
# a silence, and a stab two octaves above where you were listening.
comptime M_SCORPION = String("""X:1
M:4/4
L:1/8
Q:1/4=150
K:Cm
V:1
[I:chip v=0 wave=pulse pw=300 a=0 d=2 s=5 r=2 vol=13]
C D _E F | G2 z2 | c'2 c'2
V:2
[I:chip v=1 wave=saw a=0 d=3 s=6 r=3 filt=1 cutoff=1000 res=6 mode=lp vol=10]
C,8 | _A,,2 G,,2
""")

# 4 mantis -- angular. Jabs a tritone apart that refuse to resolve, and a
# bass that answers each one a beat late.
comptime M_MANTIS = String("""X:1
M:4/4
L:1/8
Q:1/4=140
K:C
V:1
[I:chip v=0 wave=pulse pw=250 a=0 d=2 s=0 r=2 vol=13]
e2 z2 ^A2 z2 | ^d2 z2 a2 e'2
V:2
[I:chip v=1 wave=pulse pw=400 a=0 d=3 s=3 r=3 vol=10]
z2 E,2 z2 ^A,,2 | z2 ^G,,2 A,,4
""")

# 5 hornet -- a buzz, and it is meant to be unpleasant. Sixteenths on two
# neighbouring notes, and the pair climbs twice before it lands.
comptime M_HORNET = String("""X:1
M:4/4
L:1/16
Q:1/4=160
K:C
V:1
[I:chip v=0 wave=pulse pw=180 a=0 d=1 s=0 r=1 vol=13]
baba baba c'bc'b c'bc'b | d'c'd'c' e'4
V:2
[I:chip v=1 wave=saw a=0 d=4 s=5 r=3 filt=1 cutoff=1200 res=7 mode=lp vol=10]
A,8 A,8 | ^A,8
""")

# 6 jellyfish -- no attack at all. It drifts down four notes and the bass
# never moves. The slowest motif of the fourteen, but not the longest: a
# long release on a triangle is enough to make it feel unhurried without
# leaving it ringing into the next thing that happens.
comptime M_JELLYFISH = String("""X:1
M:4/4
L:1/8
Q:1/4=112
K:Am
V:1
[I:chip v=0 wave=tri a=5 d=0 s=13 r=7 vol=13]
c2 =b2 a2 e2 | a4
V:2
[I:chip v=1 wave=tri a=6 d=0 s=12 r=8 vol=9]
A,,8 | A,,4
""")

# 7 spider -- skittering. A chromatic scramble that arrives nowhere, twice,
# each time from a different rung.
comptime M_SPIDER = String("""X:1
M:4/4
L:1/16
Q:1/4=150
K:C
V:1
[I:chip v=0 wave=pulse pw=220 a=0 d=1 s=0 r=1 vol=13]
cc^cd ^def ^fg^ga _bb4 | dd^de ^fga _b4 z4
V:2
[I:chip v=1 wave=pulse pw=600 a=0 d=2 s=2 r=2 vol=10]
C,4 z4 ^C,4 z4 | D,4 z4 z8
""")

# 8 stingray -- wide. Bottom to top and nothing in between, then it glides
# home through the fifth.
comptime M_STINGRAY = String("""X:1
M:4/4
L:1/8
Q:1/4=112
K:Gm
V:1
[I:chip v=0 wave=tri a=2 d=2 s=11 r=8 vol=13]
G,,4 g4 | d'2 _b2 g4
V:2
[I:chip v=1 wave=pulse pw=800 a=1 d=4 s=8 r=6 filt=1 cutoff=1000 res=4 mode=lp vol=10]
G,,8 | D,,4 G,,4
""")

# 9 squid -- burbling. A wide pulse through a resonant filter, folding back
# on itself and then opening out a fourth higher.
comptime M_SQUID = String("""X:1
M:4/4
L:1/8
Q:1/4=144
K:Cm
V:1
[I:chip v=0 wave=pulse pw=950 a=0 d=3 s=7 r=3 filt=1 cutoff=1100 res=7 mode=lp vol=13]
c/2_e/2c/2_e/2 g/2_e/2c/2_e/2 | f/2_a/2f/2_a/2 c'4
V:2
[I:chip v=1 wave=tri a=1 d=3 s=8 r=5 vol=10]
C,4 C,4 | F,,8
""")

# 10 wasp -- the hornet's meaner cousin: higher, a semitone instead of a
# tone so it grinds, and it never settles on the note it wants.
comptime M_WASP = String("""X:1
M:4/4
L:1/16
Q:1/4=176
K:C
V:1
[I:chip v=0 wave=pulse pw=150 a=0 d=1 s=0 r=1 vol=13]
c'bc'b c'bc'b d'c'd'c' d'c'd'c' | e'd'e'd' f'4
V:2
[I:chip v=1 wave=saw a=0 d=3 s=4 r=3 filt=1 cutoff=1400 res=8 mode=lp vol=10]
A,4 ^A,4 =B,4 c4 | ^c8
""")

# 11 crab -- sideways. The same two notes back and forth, going nowhere,
# and then the whole figure shuffles up a tone and goes nowhere there too.
comptime M_CRAB = String("""X:1
M:4/4
L:1/8
Q:1/4=126
K:Dm
V:1
[I:chip v=0 wave=pulse pw=600 a=0 d=3 s=5 r=3 vol=13]
D,2 A,,2 D,2 A,,2 | E,2 =B,,2 E,2 A,,2
V:2
[I:chip v=1 wave=noise a=0 d=2 s=0 r=2 vol=8]
C2 z2 C2 z2 | C2 z2 C2 C2
""")

# 12 drone -- one note and a second voice a semitone off it: what you hear
# is the beating between them. Halfway through, the second one moves.
comptime M_DRONE = String("""X:1
M:4/4
L:1/8
Q:1/4=120
K:C
V:1
[I:chip v=0 wave=pulse pw=500 a=1 d=0 s=13 r=6 vol=11]
a8 | a8
V:2
[I:chip v=1 wave=pulse pw=520 a=1 d=0 s=13 r=6 vol=11]
^g8 | =g8
""")

# 13 serpent -- it slides. Eight chromatic steps down with no rest in them,
# over a bass doing the same thing at half the speed.
comptime M_SERPENT = String("""X:1
M:4/4
L:1/8
Q:1/4=138
K:C
V:1
[I:chip v=0 wave=saw a=0 d=4 s=8 r=4 filt=1 cutoff=1300 res=8 mode=lp vol=13]
c =B _B A _A G _G F | E4
V:2
[I:chip v=1 wave=pulse pw=700 a=0 d=5 s=6 r=4 vol=10]
C,4 =B,,4 | _B,,4
""")


def motif_for(species: Int) raises -> String:
    """Species k's motif, in the same order as `art.species_name`."""
    if species == 0:
        return M_GRUNT
    if species == 1:
        return M_MOTH
    if species == 2:
        return M_BEETLE
    if species == 3:
        return M_SCORPION
    if species == 4:
        return M_MANTIS
    if species == 5:
        return M_HORNET
    if species == 6:
        return M_JELLYFISH
    if species == 7:
        return M_SPIDER
    if species == 8:
        return M_STINGRAY
    if species == 9:
        return M_SQUID
    if species == 10:
        return M_WASP
    if species == 11:
        return M_CRAB
    if species == 12:
        return M_DRONE
    return M_SERPENT
