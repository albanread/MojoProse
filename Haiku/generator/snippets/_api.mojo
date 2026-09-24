# ===----------------------------------------------------------------------=== #
# Hand-written (Haiku/generator/snippets/_api.mojo)
# ===----------------------------------------------------------------------=== #


struct LooperLock(Movable):
    """A looper's lock, held while this value lives: `BMessenger.Locked()`,
    for a `with` block (design section 8.5)."""

    var _looper: Int

    def __init__(out self, messenger: BMessenger, timeout: Int64) raises:
        self._looper = external_call["mojobe_BMessenger_LockedTarget", Int](
            _address_of(messenger), timeout
        )
        if self._looper == 0:
            raise Error(
                "BMessenger::Locked: the looper has gone, or the timeout"
                " passed"
            )

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
