# expect: cannot implicitly convert 'BViewRef[view.origin]' value to 'BViewRef[ImmUntrackedOrigin]'
"""A hook cannot keep the reference it was given: it is borrowed from the
hook's call."""

from haiku import BRect, BViewRef
from haiku.hooks import ViewDraw


struct Keeper(Movable, ViewDraw):
    var last: BViewRef[ImmUntrackedOrigin]

    def __init__(out self):
        self.last = BViewRef[ImmUntrackedOrigin]()

    def Draw(mut self, view: BViewRef[_], updateRect: BRect):
        self.last = view


def main():
    _ = Keeper()
