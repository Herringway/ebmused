import core.sys.windows.windows;
import ebmusv2;
import main;

extern(C):

struct control_desc {
	immutable(char)* class_; short x, y, xsize, ysize; immutable(char)* title; DWORD id; DWORD style;
}
struct window_template {
	int num, lower, winsize, divy; const(control_desc) *controls;
}

void create_controls(HWND hWnd, window_template *t, LPARAM cs) nothrow {
	int top = 0;
	int width = (cast(CREATESTRUCT *)cs).cx;
	int winheight = (cast(CREATESTRUCT *)cs).cy;
	t.winsize = MAKELONG(width, winheight);
	int height = t.divy;
	control_desc *c = cast(control_desc*)t.controls;

	for (int num = t.num; num; num--, c++) {
		int x = c.x, y = c.y, xsize = c.xsize, ysize = c.ysize;
		if (num == t.lower) {
			top = t.divy;
			height = winheight - t.divy;
		}
		if (x < 0) x += width;
		if (y < 0) y += height;
		if (xsize <= 0) xsize += width;
		if (ysize <= 0) ysize += height;
		HWND w = CreateWindowA(c.class_, c.title,
			WS_CHILD | WS_VISIBLE | c.style,
			x, top + y, xsize, ysize,
			hWnd, cast(HMENU)c.id, hinstance, NULL);
		if (c.class_[1] != 'y')
			SendMessageA(w, WM_SETFONT, cast(WPARAM)hfont, 0);
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
		int x = c.x, y = c.y, xsize = c.xsize, ysize = c.ysize;
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
		MoveWindow(GetDlgItem(hWnd, c.id), x, top + y, xsize, ysize, TRUE);
	}
	t.winsize = lParam;
}
