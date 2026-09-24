# expect: cannot implicitly convert 'BLooperRef[origin_of($CONTEXTMGR)]' value to 'BLooperRef[ImmUntrackedOrigin]'
"""A locked looper's reference is borrowed from the lock: it cannot be kept
past the `with` block that unlocks it."""

from haiku import BLooper, BLooperRef, BMessenger


def main() raises:
    var looper = BLooper("looper")
    var messenger = BMessenger(looper)
    _ = looper^.Run()
    var kept = BLooperRef[ImmUntrackedOrigin]()
    with messenger.Locked() as locked:
        kept = locked
    _ = kept.Thread()
