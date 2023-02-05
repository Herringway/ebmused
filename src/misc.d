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

void enable_menu_items(const(BYTE)* list, int flags) nothrow {
	while (*list) EnableMenuItem(hmenu, *list++, flags);
}

HFONT oldfont;
COLORREF oldtxt, oldbk;

void set_up_hdc(HDC hdc) nothrow {
	oldfont = SelectObject(hdc, hfont);
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
