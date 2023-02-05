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
import main;

private int dpi_x;
private int dpi_y;

private HFONT hFixedFont;
private HFONT hDefaultGUIFont;
private HFONT hTabsFont;
private HFONT hOrderFont;

void enable_menu_items(const(ubyte)* list, int flags) nothrow {
	while (*list) EnableMenuItem(hmenu, *list++, flags);
}

HFONT oldfont;
COLORREF oldtxt, oldbk;

void set_up_hdc(HDC hdc) nothrow {
	oldfont = SelectObject(hdc, default_font());
	oldtxt = SetTextColor(hdc, GetSysColor(COLOR_WINDOWTEXT));
	oldbk = SetBkColor(hdc, GetSysColor(COLOR_3DFACE));
}

void reset_hdc(HDC hdc) nothrow {
	SelectObject(hdc, oldfont);
	SetTextColor(hdc, oldtxt);
	SetBkColor(hdc, oldbk);
}

int fgetw(FILE *f) nothrow {
	int lo, hi;
	lo = fgetc(f); if (lo < 0) return -1;
	hi = fgetc(f); if (hi < 0) return -1;
	return lo | hi<<8;
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

void *array_insert(void **array, int *size, int elemsize, int index) nothrow {
	int new_size = elemsize * ++*size;
	char *a = cast(char*)realloc(*array, new_size);
	index *= elemsize;
	*array = a;
	a += index;
	memmove(a + elemsize, a, new_size - (index + elemsize));
	return a;
}

/*void array_delete(void *array, int *size, int elemsize, int index) {
	int new_size = elemsize * --*size;
	char *a = array;
	index *= elemsize;
	a += index;
	memmove(a, a + elemsize, new_size - index);
}*/

size_t filelength(FILE* f) nothrow {
	fseek(f, 0L, SEEK_END);
	auto size = ftell(f);
	fseek(f, 0L, SEEK_SET);
	return size;
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

char* strlwr(char* str) nothrow {
	import core.stdc.ctype : tolower;
	for(char* p = str; *p != 0;) {
		*p = cast(char)tolower(*p);
	}
	return str;
}

char getc(ref File file) nothrow {
	char[1] buf;
	try {
		file.rawRead(buf[]);
	} catch (Exception) {}
	return buf[0];
}

ushort getw(ref File file) nothrow {
	ushort[1] buf;
	try {
		file.rawRead(buf[]);
	} catch (Exception) {}
	return buf[0];
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

void set_up_fonts() nothrow {
	LOGFONT lf;
	LOGFONT lf2;
	NONCLIENTMETRICS ncm = {0};
	// This size is different in 2000 and XP. That could be causing different values to be returned
	// between the Windows SDK and MinGW builds for the new iPaddedBorderWidth field?
	// So don't use that field for now.
	// https://docs.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-nonclientmetricsa#remarks
	ncm.cbSize = NONCLIENTMETRICS.sizeof;
	BOOL ncmInitialized = SystemParametersInfo(SPI_GETNONCLIENTMETRICS, NONCLIENTMETRICS.sizeof, &ncm, 0);

	HFONT h = GetStockObject(ANSI_FIXED_FONT);
	auto err = GetObject(GetStockObject(ANSI_FIXED_FONT), LOGFONT.sizeof, &lf);
	if (err != LOGFONT.sizeof) {
		assumeWontThrow(infof("ANSI_FIXED_FONT: only %d bytes written to lf!\n", err));
		hFixedFont = h;
	} else {
	    lf.lfFaceName = "Consolas\0";
		if (!ncmInitialized) {
			lf.lfHeight = scale_y(lf.lfHeight + 3);
			lf.lfWidth = 0;
		} else {
			// Make the font wide enough to nearly fill the instrument view
			// (Courier New/Consolas are roughly twice as tall as they are wide, and the header has
			// 20 characters)
			lf.lfWidth = (scale_x(180) - ncm.iScrollWidth) / 20;
			lf.lfHeight = lf.lfWidth * 2;
		}
	}

	// TODO: Supposedly it is better to use SystemParametersInfo to get a NONCLIENTMETRICS struct,
	// which contains an appropriate LOGFONT for stuff and changes with theme.
	hDefaultGUIFont = GetStockObject(DEFAULT_GUI_FONT);

	err = GetObject(hDefaultGUIFont, LOGFONT.sizeof, &lf);
	if (err != LOGFONT.sizeof) {
		assumeWontThrow(infof("DEFAULT_GUI_FONT: only %d bytes written to lf!\n", err));
		hOrderFont = GetStockObject(SYSTEM_FONT);
	} else {
	    lf.lfWeight = FW_BOLD;
	    lf.lfHeight = scale_y(16);
	    hTabsFont = CreateFontIndirect(&lf);
	}

	if (!ncmInitialized) {
		err = GetObject(GetStockObject(SYSTEM_FONT), LOGFONT.sizeof, &lf2);
		if (err != LOGFONT.sizeof) {
			printf("SYSTEM_FONT: only %d bytes written to lf2!\n", err);
			hTabsFont = hDefaultGUIFont;
		}
		lf.lfHeight = scale_y(lf2.lfHeight - 1);
		hTabsFont = CreateFontIndirect(&lf);
	} else {
		lf = ncm.lfMessageFont;
		lf.lfHeight = scale_y(16);
		hTabsFont = CreateFontIndirect(&lf);
	}
}

void destroy_fonts() nothrow {
	DeleteObject(hFixedFont);
	DeleteObject(hDefaultGUIFont);
	DeleteObject(hTabsFont);
	DeleteObject(hOrderFont);
}

HFONT fixed_font() nothrow {
	return hFixedFont;
}

HFONT default_font() nothrow {
	return hDefaultGUIFont;
}

HFONT tabs_font() nothrow {
	return hTabsFont;
}

HFONT order_font() nothrow {
	return hOrderFont;
}