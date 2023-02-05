module win32.help;

import core.sys.windows.windows;
import std.string;
import ebmusv2;
import main;
import help;
import win32.fonts;
import win32.handles;

enum IDC_HELPTEXT = 1;

extern(Windows) ptrdiff_t CodeListWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	switch (uMsg) {
		case WM_CTLCOLORSTATIC:
			return cast(LRESULT)GetSysColorBrush(COLOR_WINDOW);
		case WM_CREATE: {
			HWND ed = CreateWindow("Edit", help_text.ptr,
				WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_READONLY,
				0, 0, 0, 0,
				hWnd, cast(HMENU)IDC_HELPTEXT, hinstance, NULL);
			HFONT font = fixed_font();
			SendMessage(ed, WM_SETFONT, cast(WPARAM)font, 0);
			break;
		}
		case WM_SIZE:
			MoveWindow(GetDlgItem(hWnd, IDC_HELPTEXT),
				0, 0, LOWORD(lParam), HIWORD(lParam), TRUE);
			break;
		default:
			return DefWindowProc(hWnd, uMsg, wParam, lParam);
	}
	return 0;
}

extern(Windows) ptrdiff_t AboutDlgProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	if (uMsg == WM_COMMAND && LOWORD(wParam) == IDOK) {
		EndDialog(hWnd, IDOK);
		return TRUE;
	}
	return FALSE;
}
