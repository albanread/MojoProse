// #pragma mark - Hand-written (Haiku/generator/snippets/mojobe.h)


// Locks the looper a BMessenger targets and returns it; NULL, with the
// status, when the looper has gone or the timeout passed first.
BLooper* mojobe_BMessenger_LockedTarget(const BMessenger* self,
	bigtime_t timeout, status_t* _status);
