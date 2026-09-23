/*
 * Copyright 2026, MojoProse. All rights reserved.
 * Distributed under the terms of the Apache License v2.0 with LLVM Exceptions.
 */


/*!	libmojobe, P0: the entry points and shadow classes of the Haiku bridge,
	written by hand as the generator is to write them. See
	Haiku/docs/bridge-design.md.
*/


#include "mojobe.h"

#include <new>
#include <stdio.h>


namespace {


mojobe_rect
to_c(const BRect& rect)
{
	mojobe_rect result = { rect.left, rect.top, rect.right, rect.bottom };
	return result;
}


mojobe_point
to_c(const BPoint& point)
{
	mojobe_point result = { point.x, point.y };
	return result;
}


BRect
from_c(mojobe_rect rect)
{
	return BRect(rect.left, rect.top, rect.right, rect.bottom);
}


BPoint
from_c(mojobe_point point)
{
	return BPoint(point.x, point.y);
}


/*!	Counts the hooks of one object that are running, so that a hook entered
	again on the same object -- AddChild() calling AttachedToWindow(), say --
	goes to the base class instead of into Mojo a second time: two live
	`mut self` borrows of one Mojo value are not allowed (design section 9).
*/
class HookDepth {
public:
	HookDepth()
		:
		fDepth(0),
		fWarned(false)
	{
	}

	bool Enter(const char* hook)
	{
		if (fDepth > 0) {
			if (!fWarned) {
				fprintf(stderr, "mojobe: %s re-entered while another hook of "
					"the same object ran; the base class handled it\n", hook);
				fWarned = true;
			}
			return false;
		}
		fDepth++;
		return true;
	}

	void Leave()
	{
		fDepth--;
	}

private:
	int32	fDepth;
	bool	fWarned;
};


class MojoBView : public BView {
public:
	MojoBView(BRect frame, const char* name, uint32 resizingMode,
		uint32 flags, const mojobe_view_hooks* hooks, void* context)
		:
		BView(frame, name, resizingMode, flags),
		fHooks(*hooks),
		fContext(context)
	{
	}

	virtual ~MojoBView()
	{
		// While ~BView runs this is a BView, so no hook can reach the Mojo
		// state after it is gone.
		if (fHooks.destroy != NULL)
			fHooks.destroy(fContext);
	}

	virtual void Draw(BRect updateRect)
	{
		if (fHooks.Draw == NULL || !fDepth.Enter("Draw")) {
			BView::Draw(updateRect);
			return;
		}
		fHooks.Draw(fContext, this, to_c(updateRect));
		fDepth.Leave();
	}

	virtual void MouseDown(BPoint where)
	{
		if (fHooks.MouseDown == NULL || !fDepth.Enter("MouseDown")) {
			BView::MouseDown(where);
			return;
		}
		fHooks.MouseDown(fContext, this, to_c(where));
		fDepth.Leave();
	}

	virtual void MessageReceived(BMessage* message)
	{
		if (fHooks.MessageReceived == NULL
			|| !fDepth.Enter("MessageReceived")) {
			BView::MessageReceived(message);
			return;
		}
		fHooks.MessageReceived(fContext, this, message);
		fDepth.Leave();
	}

	//! The Mojo state, if it is of the type tagged.
	void* Context(uint64 type) const
	{
		return fHooks.type == type ? fContext : NULL;
	}

private:
	mojobe_view_hooks	fHooks;
	void*				fContext;
	HookDepth			fDepth;
};


class MojoBWindow : public BWindow {
public:
	MojoBWindow(BRect frame, const char* title, window_type type,
		uint32 flags, const mojobe_window_hooks* hooks, void* context)
		:
		BWindow(frame, title, type, flags),
		fHooks(*hooks),
		fContext(context)
	{
	}

	virtual ~MojoBWindow()
	{
		if (fHooks.destroy != NULL)
			fHooks.destroy(fContext);
	}

	virtual void MessageReceived(BMessage* message)
	{
		if (fHooks.MessageReceived == NULL
			|| !fDepth.Enter("MessageReceived")) {
			BWindow::MessageReceived(message);
			return;
		}
		fHooks.MessageReceived(fContext, this, message);
		fDepth.Leave();
	}

	virtual bool QuitRequested()
	{
		if (fHooks.QuitRequested == NULL || !fDepth.Enter("QuitRequested"))
			return BWindow::QuitRequested();
		bool quit = fHooks.QuitRequested(fContext, this);
		fDepth.Leave();
		return quit;
	}

	//! The Mojo state, if it is of the type tagged.
	void* Context(uint64 type) const
	{
		return fHooks.type == type ? fContext : NULL;
	}

private:
	mojobe_window_hooks	fHooks;
	void*				fContext;
	HookDepth			fDepth;
};


}	// namespace


extern "C" {


// #pragma mark - BApplication


BApplication*
mojobe_BApplication_new(const char* signature, status_t* _error)
{
	status_t error = B_NO_MEMORY;
	BApplication* application
		= new(std::nothrow) BApplication(signature, &error);
	if (application != NULL && error != B_OK) {
		delete application;
		application = NULL;
	}
	if (_error != NULL)
		*_error = error;
	return application;
}


void
mojobe_BApplication_delete(BApplication* self)
{
	delete self;
}


thread_id
mojobe_BApplication_Run(BApplication* self)
{
	return self->Run();
}


// #pragma mark - BWindow


BWindow*
mojobe_MojoBWindow_new(mojobe_rect frame, const char* title, uint32 type,
	uint32 flags, const mojobe_window_hooks* hooks, void* context)
{
	return new(std::nothrow) MojoBWindow(from_c(frame), title,
		(window_type)type, flags, hooks, context);
}


void*
mojobe_MojoBWindow_context(BWindow* self, uint64 type)
{
	MojoBWindow* window = dynamic_cast<MojoBWindow*>(self);
	return window != NULL ? window->Context(type) : NULL;
}


void
mojobe_BWindow_Show(BWindow* self)
{
	self->Show();
}


/*!	Deletes a window, as a window must be deleted: locked, then Quit(). For
	one that was never shown; a shown window quits by itself.
*/
void
mojobe_BWindow_Quit(BWindow* self)
{
	if (self->Lock())
		self->Quit();
}


void
mojobe_BWindow_AddChild(BWindow* self, BView* child)
{
	self->AddChild(child);
}


mojobe_rect
mojobe_BWindow_Bounds(BWindow* self)
{
	return to_c(self->Bounds());
}


BView*
mojobe_BWindow_FindView(BWindow* self, const char* name)
{
	return self->FindView(name);
}


bool
mojobe_BWindow_Lock(BWindow* self)
{
	return self->Lock();
}


void
mojobe_BWindow_Unlock(BWindow* self)
{
	self->Unlock();
}


void
mojobe_BWindow_base_MessageReceived(BWindow* self, BMessage* message)
{
	self->BWindow::MessageReceived(message);
}


bool
mojobe_BWindow_base_QuitRequested(BWindow* self)
{
	return self->BWindow::QuitRequested();
}


// #pragma mark - BView


BView*
mojobe_MojoBView_new(mojobe_rect frame, const char* name, uint32 resizingMode,
	uint32 flags, const mojobe_view_hooks* hooks, void* context)
{
	return new(std::nothrow) MojoBView(from_c(frame), name, resizingMode,
		flags, hooks, context);
}


void*
mojobe_MojoBView_context(BView* self, uint64 type)
{
	MojoBView* view = dynamic_cast<MojoBView*>(self);
	return view != NULL ? view->Context(type) : NULL;
}


void
mojobe_BView_delete(BView* self)
{
	delete self;
}


BWindow*
mojobe_BView_Window(BView* self)
{
	return self->Window();
}


mojobe_rect
mojobe_BView_Bounds(BView* self)
{
	return to_c(self->Bounds());
}


void
mojobe_BView_Invalidate(BView* self)
{
	self->Invalidate();
}


void
mojobe_BView_SetHighColor(BView* self, rgb_color color)
{
	self->SetHighColor(color);
}


void
mojobe_BView_FillRect(BView* self, mojobe_rect rect)
{
	self->FillRect(from_c(rect));
}


void
mojobe_BView_FillEllipse(BView* self, mojobe_point center, float xRadius,
	float yRadius)
{
	self->FillEllipse(from_c(center), xRadius, yRadius);
}


void
mojobe_BView_base_Draw(BView* self, mojobe_rect updateRect)
{
	self->BView::Draw(from_c(updateRect));
}


void
mojobe_BView_base_MouseDown(BView* self, mojobe_point where)
{
	self->BView::MouseDown(from_c(where));
}


void
mojobe_BView_base_MessageReceived(BView* self, BMessage* message)
{
	self->BView::MessageReceived(message);
}


// #pragma mark - BMessage


BMessage*
mojobe_BMessage_new(uint32 what)
{
	return new(std::nothrow) BMessage(what);
}


void
mojobe_BMessage_delete(BMessage* self)
{
	delete self;
}


uint32
mojobe_BMessage_what(const BMessage* self)
{
	return self->what;
}


// #pragma mark - Menus


BMenuBar*
mojobe_BMenuBar_new(mojobe_rect frame, const char* name)
{
	return new(std::nothrow) BMenuBar(from_c(frame), name);
}


BView*
mojobe_BMenuBar_as_BView(BMenuBar* self)
{
	return self;
}


BMenu*
mojobe_BMenuBar_as_BMenu(BMenuBar* self)
{
	return self;
}


BMenu*
mojobe_BMenu_new(const char* name)
{
	return new(std::nothrow) BMenu(name);
}


void
mojobe_BMenu_delete(BMenu* self)
{
	delete self;
}


bool
mojobe_BMenu_AddItem(BMenu* self, BMenuItem* item)
{
	return self->AddItem(item);
}


bool
mojobe_BMenu_AddSubmenu(BMenu* self, BMenu* submenu)
{
	return self->AddItem(submenu);
}


BMenuItem*
mojobe_BMenuItem_new(const char* label, BMessage* message, char shortcut,
	uint32 modifiers)
{
	return new(std::nothrow) BMenuItem(label, message, shortcut, modifiers);
}


void
mojobe_BMenuItem_delete(BMenuItem* self)
{
	delete self;
}


}	// extern "C"
