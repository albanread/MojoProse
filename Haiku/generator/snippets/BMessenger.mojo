def Locked(self, timeout: Int64 = B_INFINITE_TIMEOUT) raises -> LooperLock:
    """Locks the looper this messenger targets, from any thread, for a
    `with` block:

        with messenger.Locked() as looper:
            looper.as_BWindow().FindView("canvas").Invalidate()

    The reference `looper` is borrowed from the lock, and cannot outlive
    the block; the looper is unlocked when it ends.

    Raises:
        When the looper has gone, or `timeout` passed first.
    """
    return LooperLock(self, timeout)
