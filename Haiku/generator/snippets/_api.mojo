# ===----------------------------------------------------------------------=== #
# Hand-written (Haiku/generator/snippets/_api.mojo)
# ===----------------------------------------------------------------------=== #


struct LooperLock(Movable):
    """A looper's lock, held while this value lives: `BMessenger.Locked()`,
    for a `with` block (design section 8.5)."""

    var _looper: Int

    def __init__(out self, messenger: BMessenger, timeout: Int64) raises:
        var status = Int32(-1)
        self._looper = external_call["mojobe_BMessenger_LockedTarget", Int](
            _address_of(messenger), timeout, Pointer(to=status)
        )
        if self._looper == 0:
            # B_BAD_VALUE when the looper has gone (no target), B_TIMED_OUT
            # when the timeout passed first (BMessenger.cpp)
            _check(status if status != 0 else -1, "BMessenger::Locked")

    def __enter__(ref self) -> BLooperRef[origin_of(self)]:
        """The locked looper, borrowed from the lock."""
        return BLooperRef[origin_of(self)](_ptr_from(self._looper))

    def _unlock(mut self):
        if self._looper != 0:
            external_call["mojobe_BLooper_Unlock", NoneType](self._looper)
            self._looper = 0

    def __exit__(mut self):
        self._unlock()

    def __exit__(mut self, error: Error) -> Bool:
        self._unlock()
        return False

    def __deinit__(deinit self):
        if self._looper != 0:
            external_call["mojobe_BLooper_Unlock", NoneType](self._looper)
