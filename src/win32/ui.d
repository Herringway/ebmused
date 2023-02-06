module win32.ui;

import core.stdc.stdio;
import core.stdc.string;
import core.stdc.errno;
import core.stdc.stdlib;
import core.sys.windows.windows;
import core.sys.windows.commdlg;
import core.sys.windows.commctrl;

import win32.bgmlist;
import win32.dialogs;
import win32.fonts;
import win32.handles;
import win32.help;
import win32.id;
import win32.inst;
import win32.misc;
import win32.sound;
import win32.tracker;
import brr;
import ebmusv2;
import loadrom;
import main;
import misc;
import packs;
import play;
import structs;

import std.exception;
import std.experimental.logger;
import std.string;

version(win32):

pragma(lib, "user32");
pragma(lib, "gdi32");
pragma(lib, "comdlg32");
pragma(lib, "comctl32");
pragma(lib, "winmm");

__gshared int current_tab;

void tab_selected(int new_) {
	if (new_ < 0 || new_ >= NUM_TABS) return;
	current_tab = new_;

	for (int i = 0; i < NUM_TABS; i++) {
		if (tab_hwnd[i]) {
			DestroyWindow(tab_hwnd[i]);
			tab_hwnd[i] = NULL;
		}
	}

	RECT rc;
	GetClientRect(hwndMain, &rc);
	tab_hwnd[new_] = CreateWindowW(tab_class[new_], NULL,
		WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN,
		0, scale_y(25), rc.right, rc.bottom - scale_y(25),
		hwndMain, NULL, hinstance, NULL);

	SendMessageA(tab_hwnd[new_], rom.isOpen ? WM_ROM_OPENED : WM_ROM_CLOSED, 0, 0);
	SendMessageA(tab_hwnd[new_], cur_song.order_length ? WM_SONG_LOADED : WM_SONG_NOT_LOADED, 0, 0);
}

private void import_() nothrow {
	if (packs_loaded[2] >= NUM_PACKS) {
		MessageBox2("No song pack selected", "Import", MB_ICONEXCLAMATION);
		return;
	}

	string file = openFilePrompt("EarthBound Music files (*.ebm)\0*.ebm\0All Files\0*.*\0");
	if (file == "") return;

	FILE *f = fopen(file.toStringz, "rb");
	auto size = filelength(f);
	if (!f) {
		MessageBox2(strerror(errno).fromStringz, "Import", MB_ICONEXCLAMATION);
		return;
	}

	block b;
	if (!fread(&b, 4, 1, f) || b.spc_address + b.size > 0x10000 || size != 4 + b.size) {
		MessageBox2("File is not an EBmused export", "Import", MB_ICONEXCLAMATION);
		goto err1;
	}
	b.data = cast(ubyte*)malloc(b.size);
	fread(b.data, b.size, 1, f);
	new_block(&b);
	SendMessageA(tab_hwnd[current_tab], WM_SONG_IMPORTED, 0, 0);
err1:
	fclose(f);
}

extern(Windows) LRESULT MainWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	switch (uMsg) {
	case 0x3BB: case 0x3BC: case 0x3BD: // MM_WOM_OPEN, CLOSE, DONE
		winmm_message(uMsg);
		break;
	case WM_CREATE: {
		HWND tabs = CreateWindowW("SysTabControl32", NULL,
			WS_CHILD | WS_VISIBLE | TCS_BUTTONS, 0, 0, scale_x(TAB_CONTROL_WIDTH), scale_y(TAB_CONTROL_HEIGHT),
			hWnd, NULL, hinstance, NULL);
		TC_ITEMA item;
		item.mask = TCIF_TEXT;
		for (int i = 0; i < NUM_TABS; i++) {
			item.pszText = cast(char*)tab_name[i];
			TabCtrl_InsertItem(tabs, i, &item);
		}
		SendMessage(tabs, WM_SETFONT, cast(size_t)tabs_font(), true);
		break;
	}
	case WM_SIZE:
		int tabs_height = scale_y(TAB_CONTROL_HEIGHT);
		MoveWindow(tab_hwnd[current_tab], 0, tabs_height, LOWORD(lParam), HIWORD(lParam) - tabs_height, TRUE);
		break;
	case WM_COMMAND: {
		WORD id = LOWORD(wParam);
		switch (id) {
		case ID_OPEN: {
			string file = openFilePrompt("SNES ROM files (*.smc, *.sfc)\0*.smc;*.sfc\0All Files\0*.*\0");
			try {
				if ((file != "") && open_rom(file, ofn.Flags & OFN_READONLY)) {
					SendMessageA(tab_hwnd[current_tab], WM_ROM_CLOSED, 0, 0);
					SendMessageA(tab_hwnd[current_tab], WM_ROM_OPENED, 0, 0);
				}
			} catch (Exception e) {
				MessageBox2(e.msg, "Could not open ROM", MB_ICONERROR);
			}
			break;
		}
		case ID_SAVE_ALL:
			save_all_packs();
			break;
		case ID_CLOSE:
			if (!handleErrorsUI(close_rom(), true)) break;
			SendMessageA(tab_hwnd[current_tab], WM_ROM_CLOSED, 0, 0);
			SetWindowTextW(hWnd, "EarthBound Music Editor");
			break;
		case ID_IMPORT: import_(); break;
		case ID_IMPORT_SPC: handleErrorsUI(import_spc()); break;
		case ID_IMPORT_NSPC: handleErrorsUI(import_nspc()); break;
		case ID_EXPORT: export_(); break;
		case ID_EXPORT_SPC: export_spc(); break;
		case ID_EXPORT_NSPC: handleErrorsUI(export_nspc()); break;
		case ID_EXIT: DestroyWindow(hWnd); break;
		case ID_OPTIONS: {
			DialogBoxA(hinstance, MAKEINTRESOURCEA(IDD_OPTIONS), hWnd, &OptionsDlgProc);
			break;
		}
		case ID_CUT:
		case ID_COPY:
		case ID_PASTE:
		case ID_DELETE:
		case ID_SPLIT_PATTERN:
		case ID_JOIN_PATTERNS:
		case ID_MAKE_SUBROUTINE:
		case ID_UNMAKE_SUBROUTINE:
		case ID_TRANSPOSE:
		case ID_CLEAR_SONG:
		case ID_ZOOM_OUT:
		case ID_ZOOM_IN:
		case ID_INCREMENT_DURATION:
		case ID_DECREMENT_DURATION:
		case ID_SET_DURATION_1:
		case ID_SET_DURATION_2:
		case ID_SET_DURATION_3:
		case ID_SET_DURATION_4:
		case ID_SET_DURATION_5:
		case ID_SET_DURATION_6:
			handleErrorsUI(editor_command(id));
			break;
		case ID_PLAY:
			if (cur_song.order_length == 0)
				MessageBox2("No song loaded", "Play", MB_ICONEXCLAMATION);
			else if (samp[0].data == NULL)
				MessageBox2("No instruments loaded", "Play", MB_ICONEXCLAMATION);
			else {
				if (sound_init()) song_playing = TRUE;
			}
			break;
		case ID_STOP:
			song_playing = FALSE;
			break;
		case ID_OCTAVE_1: case ID_OCTAVE_1+1: case ID_OCTAVE_1+2:
		case ID_OCTAVE_1+3: case ID_OCTAVE_1+4:
			octave = id - ID_OCTAVE_1;
			CheckMenuRadioItem(hmenu, ID_OCTAVE_1, ID_OCTAVE_1+4,
				id, MF_BYCOMMAND);
			break;
		case ID_HELP:
			CreateWindowW("ebmused_codelist", "Code list",
				WS_OVERLAPPEDWINDOW | WS_VISIBLE,
				CW_USEDEFAULT, CW_USEDEFAULT, scale_x(CODELIST_WINDOW_WIDTH), scale_y(CODELIST_WINDOW_HEIGHT),
				NULL, NULL, hinstance, NULL);
			break;
		case ID_ABOUT: {
			DialogBoxA(hinstance, MAKEINTRESOURCEA(IDD_ABOUT), hWnd, &AboutDlgProc);
			break;
		}
		default: assumeWontThrow(infof("Command %d not yet implemented\n", id)); break;
		}
		break;
	}
	case WM_NOTIFY: {
		NMHDR *pnmh = cast(LPNMHDR)lParam;
		try {
			if (pnmh.code == TCN_SELCHANGE) {
				tab_selected(TabCtrl_GetCurSel(pnmh.hwndFrom));
			}
		} catch (Exception) {}
		break;
	}
	case WM_CLOSE:
		if (!handleErrorsUI(close_rom(), true)) break;
		DestroyWindow(hWnd);
		break;
	case WM_DESTROY:
		PostQuitMessage(0);
		break;
	default:
		return DefWindowProc(hWnd, uMsg, wParam, lParam);
	}
	return 0;
}

extern(Windows) ptrdiff_t WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow) {
	import core.runtime;
	import std.experimental.logger;
	Runtime.initialize();
	static if (!is(typeof(cast(shared)sharedLog) == typeof(sharedLog))) {
		sharedLog = new FileLogger("trace.log");
	} else {
		sharedLog = cast(shared)(new FileLogger("trace.log"));
	}
	hinstance = hInstance;
	WNDCLASSW wc;
	MSG msg;

	wc.style         = 0;
	wc.lpfnWndProc   = &MainWndProc;
	wc.cbClsExtra    = 0;
	wc.cbWndExtra    = 0;
	wc.hInstance     = hInstance;
	wc.hIcon         = LoadIconA(hInstance, MAKEINTRESOURCEA(1));
	wc.hCursor       = LoadCursor(NULL, IDC_ARROW);
	wc.hbrBackground = cast(HBRUSH)(COLOR_3DFACE + 1);
	wc.lpszMenuName  = MAKEINTRESOURCEW(IDM_MENU);
	wc.lpszClassName = "ebmused_main";
	RegisterClassW(&wc);

	wc.lpszMenuName  = NULL;
	for (int i = 0; i < NUM_TABS; i++) {
		wc.lpfnWndProc   = tab_wndproc[i];
		wc.lpszClassName = tab_class[i];
		RegisterClassW(&wc);
	}

	wc.lpfnWndProc   = &InstTestWndProc;
	wc.lpszClassName = "ebmused_insttest";
	RegisterClassW(&wc);
	wc.lpfnWndProc   = &StateWndProc;
	wc.lpszClassName = "ebmused_state";
	RegisterClassW(&wc);

	wc.hbrBackground = NULL;
	wc.lpfnWndProc   = &CodeListWndProc;
	wc.lpszClassName = "ebmused_codelist";
	RegisterClassW(&wc);
	wc.lpfnWndProc   = &OrderWndProc;
	wc.lpszClassName = "ebmused_order";
	RegisterClassW(&wc);

	wc.style         = CS_HREDRAW;
	wc.lpfnWndProc   = &TrackerWndProc;
	wc.lpszClassName = "ebmused_tracker";
	RegisterClassW(&wc);

	setup_dpi_scale_values();
	InitCommonControls();

//	SetUnhandledExceptionFilter(exfilter);

	onTimerTick = &load_pattern_into_tracker;
	set_up_fonts();

	hwndMain = CreateWindowW("ebmused_main", "EarthBound Music Editor",
		WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
		CW_USEDEFAULT, CW_USEDEFAULT, scale_x(MAIN_WINDOW_WIDTH), scale_y(MAIN_WINDOW_HEIGHT),
		NULL, NULL, hInstance, NULL);
	ShowWindow(hwndMain, nCmdShow);

	hmenu = GetMenu(hwndMain);
	CheckMenuRadioItem(hmenu, ID_OCTAVE_1, ID_OCTAVE_1+4, ID_OCTAVE_1+2, MF_BYCOMMAND);

	hcontextmenu = LoadMenuA(hInstance, MAKEINTRESOURCEA(IDM_CONTEXTMENU));

	HACCEL hAccel = LoadAcceleratorsA(hInstance, MAKEINTRESOURCEA(IDA_ACCEL));

	tab_selected(0);

	while (GetMessage(&msg, NULL, 0, 0) > 0) {
		if (!TranslateAccelerator(hwndMain, hAccel, &msg)) {
			TranslateMessage(&msg);
		}
		DispatchMessage(&msg);
	}
	DestroyMenu(hcontextmenu);
	destroy_fonts();
	return msg.wParam;
}