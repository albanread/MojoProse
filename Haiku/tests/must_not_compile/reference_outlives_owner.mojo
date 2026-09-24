# expect: cannot implicitly convert 'BViewRef[origin_of(parent)]' value to 'BViewRef[ImmUntrackedOrigin]'
"""A reference cannot outlive the value it was got from."""

from haiku import BRect, BView, BViewRef


def child_of_a_view_that_ends_here() raises -> BViewRef[ImmUntrackedOrigin]:
    var parent = BView(BRect(0, 0, 99, 99), "parent", 0, 0)
    parent.AddChild(BView(BRect(0, 0, 9, 9), "child", 0, 0))
    return parent.FindView("child")


def main() raises:
    _ = child_of_a_view_that_ends_here()
