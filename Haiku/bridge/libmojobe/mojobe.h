/*
 * Copyright 2026, MojoProse. All rights reserved.
 * Distributed under the terms of the Apache License v2.0 with LLVM Exceptions.
 */
#ifndef MOJOBE_H
#define MOJOBE_H


/*!	The C interface libmojobe gives Mojo programs to the Haiku API: one entry
	point per method, and the hook tables of the shadow classes a Mojo type
	stands behind. See Haiku/docs/bridge-design.md, sections 7 and 8.

	P0: written by hand for BApplication, BWindow, BView, BMessage and the
	menus, as the generator is to write it.
*/


#include <Application.h>
#include <Menu.h>
#include <MenuBar.h>
#include <MenuItem.h>
#include <Message.h>
#include <View.h>
#include <Window.h>


extern "C" {


/*!	BRect and BPoint as C sees them. Haiku's BRect and BPoint declare their
	own copy constructors, which makes them non-trivial for calls: the C++
	ABI passes and returns them by hidden reference, not in s0-s3 as a
	C struct of floats goes. So no BRect or BPoint crosses this interface;
	these do, laid out the same, and the entry points convert.
*/
struct mojobe_rect {
	float	left;
	float	top;
	float	right;
	float	bottom;
};


struct mojobe_point {
	float	x;
	float	y;
};


/*!	A Mojo type's hooks for a BView. A NULL slot is a hook the type does not
	implement: the view does what BView does, without entering Mojo.

	The type tag names the Mojo type (a hash of its qualified name), so that
	mojobe_MojoBView_context() hands a view's Mojo state only to a caller
	asking for that type. A function's address cannot serve: Mojo takes one
	through a thunk of its own wherever it is taken.
*/
struct mojobe_view_hooks {
	uint64	type;
	void	(*destroy)(void* context);
	void	(*Draw)(void* context, BView* view, mojobe_rect updateRect);
	void	(*MouseDown)(void* context, BView* view, mojobe_point where);
	void	(*MessageReceived)(void* context, BView* view, BMessage* message);
};


/*!	A Mojo type's hooks for a BWindow; the type tag as for a view. */
struct mojobe_window_hooks {
	uint64	type;
	void	(*destroy)(void* context);
	void	(*MessageReceived)(void* context, BWindow* window,
				BMessage* message);
	bool	(*QuitRequested)(void* context, BWindow* window);
};


// BApplication
BApplication*	mojobe_BApplication_new(const char* signature,
					status_t* _error);
void			mojobe_BApplication_delete(BApplication* self);
thread_id		mojobe_BApplication_Run(BApplication* self);

// BWindow, as the Mojo* shadow
BWindow*		mojobe_MojoBWindow_new(mojobe_rect frame, const char* title,
					uint32 type, uint32 flags,
					const mojobe_window_hooks* hooks, void* context);
void*			mojobe_MojoBWindow_context(BWindow* self, uint64 type);
void			mojobe_BWindow_Show(BWindow* self);
void			mojobe_BWindow_Quit(BWindow* self);
void			mojobe_BWindow_AddChild(BWindow* self, BView* child);
mojobe_rect		mojobe_BWindow_Bounds(BWindow* self);
BView*			mojobe_BWindow_FindView(BWindow* self, const char* name);
bool			mojobe_BWindow_Lock(BWindow* self);
void			mojobe_BWindow_Unlock(BWindow* self);
void			mojobe_BWindow_base_MessageReceived(BWindow* self,
					BMessage* message);
bool			mojobe_BWindow_base_QuitRequested(BWindow* self);

// BView, as the Mojo* shadow
BView*			mojobe_MojoBView_new(mojobe_rect frame, const char* name,
					uint32 resizingMode, uint32 flags,
					const mojobe_view_hooks* hooks, void* context);
void*			mojobe_MojoBView_context(BView* self, uint64 type);
void			mojobe_BView_delete(BView* self);
BWindow*		mojobe_BView_Window(BView* self);
mojobe_rect		mojobe_BView_Bounds(BView* self);
void			mojobe_BView_Invalidate(BView* self);
void			mojobe_BView_SetHighColor(BView* self, rgb_color color);
void			mojobe_BView_FillRect(BView* self, mojobe_rect rect);
void			mojobe_BView_FillEllipse(BView* self, mojobe_point center,
					float xRadius, float yRadius);
void			mojobe_BView_base_Draw(BView* self,
					mojobe_rect updateRect);
void			mojobe_BView_base_MouseDown(BView* self, mojobe_point where);
void			mojobe_BView_base_MessageReceived(BView* self,
					BMessage* message);

// BMessage
BMessage*		mojobe_BMessage_new(uint32 what);
void			mojobe_BMessage_delete(BMessage* self);
uint32			mojobe_BMessage_what(const BMessage* self);

// Menus
BMenuBar*		mojobe_BMenuBar_new(mojobe_rect frame, const char* name);
BView*			mojobe_BMenuBar_as_BView(BMenuBar* self);
BMenu*			mojobe_BMenuBar_as_BMenu(BMenuBar* self);
BMenu*			mojobe_BMenu_new(const char* name);
void			mojobe_BMenu_delete(BMenu* self);
bool			mojobe_BMenu_AddItem(BMenu* self, BMenuItem* item);
bool			mojobe_BMenu_AddSubmenu(BMenu* self, BMenu* submenu);
BMenuItem*		mojobe_BMenuItem_new(const char* label, BMessage* message,
					char shortcut, uint32 modifiers);
void			mojobe_BMenuItem_delete(BMenuItem* self);


}	// extern "C"


#endif	// MOJOBE_H
