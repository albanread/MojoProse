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


void
mojobe_be_plain_font(BFont* result)
{
	new(result) BFont(be_plain_font);
}


void
mojobe_be_bold_font(BFont* result)
{
	new(result) BFont(be_bold_font);
}


void
mojobe_be_fixed_font(BFont* result)
{
	new(result) BFont(be_fixed_font);
}
