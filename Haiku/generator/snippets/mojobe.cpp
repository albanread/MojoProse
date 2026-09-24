// #pragma mark - Hand-written (Haiku/generator/snippets/mojobe.cpp)


BLooper*
mojobe_BMessenger_LockedTarget(const BMessenger* self, bigtime_t timeout,
	status_t* _status)
{
	*_status = self->LockTargetWithTimeout(timeout);
	if (*_status != B_OK)
		return NULL;

	// Locked, the target cannot go away until it is unlocked.
	BLooper* looper = NULL;
	self->Target(&looper);
	return looper;
}
