module win32.ctrltbl;

import core.sys.windows.windows;
import std.string;
import win32.fonts;
import win32.handles;
import win32.misc;

struct control_desc {
	string class_;
	short x;
	short y;
	short xsize;
	short ysize;
	string title;
	DWORD id;
	DWORD style;
}
struct window_template {
	int num;
	int lower;
	ptrdiff_t winsize;
	int divy;
	const(control_desc)[] controls;
}

void create_controls(HWND hWnd, window_template *t, LPARAM cs) nothrow {
	int width = (cast(CREATESTRUCT *)cs).cx;
	int winheight = (cast(CREATESTRUCT *)cs).cy;
	t.winsize = MAKELONG(width, winheight);
	int top = 0;
	int height = t.divy;

	foreach (num, c; t.controls) {
		int x = scale_x(c.x);
		int y = scale_y(c.y);
		int xsize = scale_x(c.xsize);
		int ysize = scale_y(c.ysize);
		if (num == t.lower) {
			top = height;
			height = winheight - top;
		}
		if (x < 0) x += width;
		if (y < 0) y += height;
		if (xsize <= 0) xsize += width;
		if (ysize <= 0) ysize += height;
		HWND w = CreateWindowA(c.class_.toStringz, c.title.toStringz,
			WS_CHILD | WS_VISIBLE | c.style,
			x, top + y, xsize, ysize,
			hWnd, cast(HMENU)c.id, hinstance, NULL);
		if (c.class_[1] != 'y')
			SendMessageA(w, WM_SETFONT, cast(WPARAM)default_font(), 0);
	}
}

void move_controls(HWND hWnd, window_template *t, LPARAM lParam) nothrow {
	int width = LOWORD(lParam);
	int top, height;
	int i = 0;
	int dir = 1;
	int end = t.num;
	// move controls in reverse order when making the window larger,
	// so that they don't get drawn on top of each other
	if (lParam > t.winsize) {
		i = t.num - 1;
		dir = -1;
		end = -1;
	}
	for (; i != end; i += dir) {
		const control_desc *c = &t.controls[i];
		int x = scale_x(c.x);
		int y = scale_y(c.y);
		int xsize = scale_x(c.xsize);
		int ysize = scale_y(c.ysize);
		if (i < (t.num - t.lower)) {
			top = 0;
			height = t.divy;
		} else {
			top = t.divy;
			height = HIWORD(lParam) - t.divy;
		}
		if (top == 0 && x >= 0 && y >= 0 && xsize > 0 && ysize > 0)
			continue;
		if (x < 0) x += width;
		if (y < 0) y += height;
		if (xsize <= 0) xsize += width;
		if (ysize <= 0) ysize += height;
		MoveWindow(GetDlgItem(hWnd, c.id), x, top + y, xsize, ysize, true);
	}
	t.winsize = lParam;
}
