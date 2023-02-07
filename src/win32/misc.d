module win32.misc;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.sys.windows.windows;
import core.sys.windows.commctrl;
import std.conv;
import std.exception;
import std.experimental.logger;
import std.string;
import std.stdio;
import std.traits;
import std.windows.syserror;
import misc;
import win32.handles;

private int dpi_x;
private int dpi_y;

enum WM_ROM_OPENED = WM_USER;
enum WM_ROM_CLOSED = WM_USER+1;
enum WM_SONG_IMPORTED = WM_USER+2;
enum WM_SONG_LOADED = WM_USER+3;
enum WM_SONG_NOT_LOADED = WM_USER+4;
enum WM_PACKS_SAVED = WM_USER+5;

struct ListHeader {
	string label;
	int width;
}

void enable_menu_items(const(ubyte)* list, int flags) {
	while (*list) {
		enforce(EnableMenuItem(hmenu, *list++, flags) != -1, "Control not found");
	}
}

void setDlgItemText(HWND dlg, uint u, scope const char[] str) {
	wenforce(SetDlgItemTextA(dlg, u, str.toStringz));
}

// Like Set/GetDlgItemInt but for hex.
// (Why isn't this in the Win32 API? Darned decimal fascists)
void SetDlgItemHex(HWND hwndDlg, int idControl, UINT uValue, int size) {
	char[9] buf = 0;
	setDlgItemText(hwndDlg, idControl, sformat!"%0*X"(buf[], size, uValue));
}

uint GetDlgItemHex(HWND hwndDlg, int idControl) {
	char[9] buf;
	const count = GetDlgItemTextA(hwndDlg, idControl, &buf[0], 9);
	wenforce(count);

	return buf[0 .. count].to!uint;
}

// MessageBox takes the focus away and doesn't restore it - annoying,
// since the user will probably want to correct the error.
int MessageBox2(const char[] error, const char[] title, int flags) nothrow {
	HWND focus = GetFocus();
	int ret = MessageBoxA(hwndMain, error.toStringz, title.toStringz, flags);
	SetFocus(focus);
	return ret;
}

void TabCtrl_InsertItem(HWND w, int i, const(TC_ITEMA)* p) nothrow {
    SendMessageA(w, TCM_INSERTITEMA, i, cast(LPARAM) p);
}
void ListView_InsertItemA(HWND w, const(LV_ITEMA)* p) nothrow {
	SendMessageA(w, LVM_INSERTITEMA, 0, cast(LPARAM) p);
}
void ListView_InsertColumnA(HWND w, int i, const(LV_COLUMNA)* p) nothrow {
    SendMessageA(w, LVM_INSERTCOLUMNA, i, cast(LPARAM) p);
}
void ListView_SetItemA(HWND w, const(LV_ITEMA)* i) nothrow {
    SendMessageA(w, LVM_SETITEMA, 0, cast(LPARAM) i);
}
void ListView_FindItemA(HWND w, int i, const(LV_FINDINFOA)* p) nothrow {
    SendMessageA(w, LVM_FINDITEMA, i, cast(LPARAM) p);
}
void ListView_GetItemA(HWND w, LPLVITEMA pitem) nothrow {
    SendMessageA(w, LVM_GETITEMA, 0, cast(LPARAM) pitem);
}

void setup_dpi_scale_values() {
	// Use the old DPI system, which works as far back as Windows 2000 Professional
	HDC screen;
	if (0) {
		// Per-monitor DPI awareness checking would go here
	} else if ((screen = GetDC(null)) != null) {
		// https://docs.microsoft.com/en-us/previous-versions/ms969894(v=msdn.10)
		dpi_x = GetDeviceCaps(screen, LOGPIXELSX);
		dpi_y = GetDeviceCaps(screen, LOGPIXELSY);

		ReleaseDC(null, screen);
	} else {
		info("GetDC failed; filling in default values for DPI.");
		dpi_x = 96;
		dpi_y = 96;
	}

	infof("DPI values initialized: %d %d", dpi_x, dpi_y);
}

extern(Windows) auto wrappedWindowsCallback(alias func)(Parameters!func args) nothrow {
	try {
		return func(args);
	} catch (Throwable e) {
		assumeWontThrow(errorf("FATAL UNCAUGHT ERROR: %s", e));
		MessageBox2(e.msg, "FATAL ERROR", MB_ICONERROR);
		exit(-1);
	}
}

int scale_x(int n) nothrow {
	return n * dpi_x / 96;
}

int scale_y(int n) nothrow {
	return n * dpi_y / 96;
}
auto errorClassToIcon(ErrorClass errorClass) @safe pure nothrow {
	final switch (errorClass) {
		case ErrorClass.error: return MB_ICONERROR;
		case ErrorClass.warning: return MB_ICONEXCLAMATION;
	}
}
T handleErrorsUI(T)(lazy T val) {
	try {
		return val;
	} catch (Exception e) {
		handleError(e);
	}
	static if (!is(T == void)) {
		return val.init;
	}
}
T handleErrorsUI(T)(lazy T val, T defaultValue) {
	try {
		return val;
	} catch (Exception e) {
		handleError(e);
	}
	return defaultValue;
}

void handleError(Exception e) nothrow {
	assumeWontThrow(errorf("%s", e));
	if (auto ebmusedException = cast(EbmusedException)e) {
		MessageBox2(ebmusedException.msg, ebmusedException.title, errorClassToIcon(ebmusedException.errorClass));
	} else {
		MessageBox2(e.msg, "Unknown error", MB_ICONERROR);
	}
}
