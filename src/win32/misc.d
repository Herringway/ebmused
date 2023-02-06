module win32.misc;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.sys.windows.windows;
import core.sys.windows.commctrl;
import std.exception;
import std.logger;
import std.string;
import std.stdio;
import ebmusv2;
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

void enable_menu_items(const(ubyte)* list, int flags) nothrow {
	while (*list) EnableMenuItem(hmenu, *list++, flags);
}

void setDlgItemText(HWND dlg, uint u, scope const char[] str) nothrow {
	if (!SetDlgItemTextA(dlg, u, str.toStringz)) {
		wchar[256] buf;
		FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, null, GetLastError(), MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), &buf[0], buf.length, null);
		assumeWontThrow(infof("Error setting text: %s", strip(buf.fromStringz)));
	}
}

// Like Set/GetDlgItemInt but for hex.
// (Why isn't this in the Win32 API? Darned decimal fascists)
BOOL SetDlgItemHex(HWND hwndDlg, int idControl, UINT uValue, int size) nothrow {
	char[9] buf;
	sprintf(&buf[0], "%0*X", size, uValue);
	return SetDlgItemTextA(hwndDlg, idControl, &buf[0]);
}

int GetDlgItemHex(HWND hwndDlg, int idControl) nothrow {
	char[9] buf;
	int n = -1;
	if (GetDlgItemTextA(hwndDlg, idControl, &buf[0], 9)) {
		char *endp;
		n = strtol(&buf[0], &endp, 16);
		if (*endp != '\0') n = -1;
	}
	return n;
}

// MessageBox takes the focus away and doesn't restore it - annoying,
// since the user will probably want to correct the error.
int MessageBox2(const char[] error, const char[] title, int flags) nothrow {
	HWND focus = GetFocus();
	int ret = MessageBoxA(hwndMain, error.toStringz, title.toStringz, flags);
	SetFocus(focus);
	return ret;
}

int TabCtrl_InsertItem(HWND w, int i, const(TC_ITEMA)* p) nothrow {
    return cast(int) SendMessageA(w, TCM_INSERTITEMA, i, cast(LPARAM) p);
}

int ListView_InsertItemA(HWND w, const(LV_ITEMA)* p) nothrow {
	return cast(int) SendMessageA(w, LVM_INSERTITEMA, 0, cast(LPARAM) p);
}
int ListView_InsertColumnA(HWND w, int i, const(LV_COLUMNA)* p) nothrow {
    return cast(int) SendMessageA(w, LVM_INSERTCOLUMNA, i, cast(LPARAM) p);
}
BOOL ListView_SetItemA(HWND w, const(LV_ITEMA)* i) nothrow {
    return cast(BOOL) SendMessageA(w, LVM_SETITEMA, 0, cast(LPARAM) i);
}
int ListView_FindItemA(HWND w, int i, const(LV_FINDINFOA)* p) nothrow {
    return cast(int) SendMessageA(w, LVM_FINDITEMA, i, cast(LPARAM) p);
}
BOOL ListView_GetItemA(HWND w, LPLVITEMA pitem) nothrow {
    return cast(BOOL) SendMessageA(w, LVM_GETITEMA, 0, cast(LPARAM) pitem);
}

void setup_dpi_scale_values() nothrow {
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
		printf("GetDC failed; filling in default values for DPI.\n");
		dpi_x = 96;
		dpi_y = 96;
	}

	assumeWontThrow(infof("DPI values initialized: %d %d\n", dpi_x, dpi_y));
}

int scale_x(int n) nothrow {
	return MulDiv(n, dpi_x, 96);
}

int scale_y(int n) nothrow {
	return MulDiv(n, dpi_y, 96);
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
	} catch (EbmusedException e) {
		MessageBox2(e.title, e.msg, errorClassToIcon(e.errorClass));
	} catch (Exception e) {
		MessageBox2("Unknown error", e.msg, MB_ICONERROR);
	}
	static if (!is(T == void)) {
		return val.init;
	}
}
T handleErrorsUI(T)(lazy T val, T defaultValue) {
	try {
		return val;
	} catch (EbmusedException e) {
		MessageBox2(e.title, e.msg, errorClassToIcon(e.errorClass));
	} catch (Exception e) {
		MessageBox2("Unknown error", e.msg, MB_ICONERROR);
	}
	return defaultValue;
}
