// #pragma mark - Hand-written (Haiku/generator/snippets/mojobe.cpp)


BLooper*
mojobe_BMessenger_LockedTarget(const BMessenger* self, bigtime_t timeout)
{
	if (self->LockTargetWithTimeout(timeout) != B_OK)
		return NULL;

	// Locked, the target cannot go away until it is unlocked.
	BLooper* looper = NULL;
	self->Target(&looper);
	return looper;
}
