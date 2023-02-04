
import id;
//#include <io.h>
import core.stdc.stdio;
import core.stdc.string;
import core.stdc.errno;
import core.stdc.stdlib;
import core.sys.windows.windows;
import core.sys.windows.commdlg;
import core.sys.windows.commctrl;

import std.algorithm.comparison : min;
import std.exception;
import std.format;
import std.string;
import ebmusv2;
import sound;
import misc;
import packs;
import structs;
import help;
import brr;
import bgmlist;
import loadrom;
import inst;
import packlist;
import metadata;
import tracker;

extern(C):

enum NUM_TABS = 4;
enum hwndBGMList = cast(void*)0;
enum hwndInstruments = cast(void*)1;
enum hwndEditor = cast(void*)2;
enum hwndPackList = cast(void*)3;

__gshared song cur_song;
__gshared BYTE[3] packs_loaded = [ 0xFF, 0xFF, 0xFF ];
__gshared ptrdiff_t current_block = -1;
__gshared song_state pattop_state, state;
__gshared int octave = 2;
__gshared ptrdiff_t midiDevice = -1;
__gshared HINSTANCE hinstance;
__gshared HWND hwndMain;
__gshared HMENU hmenu, hcontextmenu;
__gshared HFONT hfont;
__gshared HWND[NUM_TABS] tab_hwnd;

__gshared int current_tab;
__gshared const wchar*[NUM_TABS] tab_class = [
	"ebmused_bgmlist",
	"ebmused_inst",
	"ebmused_editor",
	"ebmused_packs"
];
__gshared const char *[NUM_TABS] tab_name = [
	"Song Table",
	"Instruments",
	"Sequence Editor",
	"Data Packs"
];
__gshared const WNDPROC[NUM_TABS] tab_wndproc = [
	&BGMListWndProc,
	&InstrumentsWndProc,
	&EditorWndProc,
	&PackListWndProc,
];


__gshared char[MAX_PATH] filename;
__gshared OPENFILENAMEA ofn;
alias DialogCallback = extern(Windows) BOOL function(LPOPENFILENAMEA) nothrow;
private char *open_dialog(DialogCallback func,
	char *filter, char *extension, DWORD flags) nothrow
{
	filename[0] = '\0';
	ofn.lStructSize = ofn.sizeof;
	ofn.hwndOwner = hwndMain;
	ofn.lpstrFilter = filter;
	ofn.lpstrDefExt = extension;
	ofn.lpstrFile = &filename[0];
	ofn.nMaxFile = MAX_PATH;
	ofn.Flags = flags | OFN_NOCHANGEDIR;
	return func(&ofn) ? &filename[0] : NULL;
}

BOOL get_original_rom() nothrow {
	char *file = open_dialog(&GetOpenFileNameA,
		cast(char*)"SNES ROM files (*.smc, *.sfc)\0*.smc;*.sfc\0All Files\0*.*\0".ptr,
		NULL,
		OFN_FILEMUSTEXIST | OFN_HIDEREADONLY);
	try {
		BOOL ret = file && open_orig_rom(file);
		metadata_changed |= ret;
		return ret;
	} catch (Exception) {
		return false;
	}
}

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
		0, 25, rc.right, rc.bottom - 25,
		hwndMain, NULL, hinstance, NULL);

	SendMessageA(tab_hwnd[new_], rom.isOpen ? WM_ROM_OPENED : WM_ROM_CLOSED, 0, 0);
	SendMessageA(tab_hwnd[new_], cur_song.order_length ? WM_SONG_LOADED : WM_SONG_NOT_LOADED, 0, 0);
}

private void import_() nothrow {
	if (packs_loaded[2] >= NUM_PACKS) {
		MessageBox2("No song pack selected", "Import", MB_ICONEXCLAMATION);
		return;
	}

	char *file = open_dialog(&GetOpenFileNameA,
		cast(char*)"EarthBound Music files (*.ebm)\0*.ebm\0All Files\0*.*\0".ptr, NULL, OFN_FILEMUSTEXIST | OFN_HIDEREADONLY);
	if (!file) return;

	FILE *f = fopen(file, "rb");
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

/*static void import_spc() {
	char *file = open_dialog(GetOpenFileName,
		"SPC Savestates (*.spc)\0*.spc\0All Files\0*.*\0",
		NULL,
		OFN_FILEMUSTEXIST | OFN_HIDEREADONLY);
	if (!file) return;

	FILE *f = fopen(file, "rb");
	if (!f) {
		MessageBox2(strerror(errno), "Import", MB_ICONEXCLAMATION);
		return;
	}

	fseek(f, 0x100, SEEK_SET);
	fread(spc, 65536, 1, f);
	fseek(f, 0x1015D, SEEK_SET);
	int samp_ptrs = fgetc(f) << 8;
	decode_samples((WORD *)&spc[samp_ptrs]);
	for (int i = 0; i < 0xfff0; i++) {
		if (memcmp(&spc[i], "\x8D\x06\xCF\xDA\x14\x60\x98", 7) == 0) {
			inst_base = spc[i+7] | spc[i+10] << 8;
			printf("Instruments found: %X\n", inst_base);
			break;
		}
	}
	int song_addr = spc[0x40] | spc[0x41] << 8;
	free_song(&cur_song);
	decompile_song(&cur_song, song_addr - 2, 0xffff);
	initialize_state();
	SendMessageA(tab_hwnd[current_tab], WM_SONG_IMPORTED, 0, 0);

	fclose(f);
}*/

private void export_() nothrow {
	block *b = save_cur_song_to_pack();
	if (!b) {
		MessageBox2("No song loaded", "Export", MB_ICONEXCLAMATION);
		return;
	}

	char *file = open_dialog(&GetSaveFileNameA, cast(char*)"EarthBound Music files (*.ebm)\0*.ebm\0".ptr, cast(char*)"ebm".ptr, OFN_OVERWRITEPROMPT);
	if (!file) return;

	FILE *f = fopen(file, "wb");
	if (!f) {
		MessageBox2(strerror(errno).fromStringz, "Export", MB_ICONEXCLAMATION);
		return;
	}
	fwrite(b, 4, 1, f);
	fwrite(b.data, b.size, 1, f);
	fclose(f);
}

static void export_spc() nothrow {
	if (cur_song.order_length < 1) {
		MessageBox2("No song loaded.", "Export SPC", MB_ICONEXCLAMATION);
	} else {
		char *file = open_dialog(&GetSaveFileNameA, cast(char*)"SPC files (*.spc)\0*.spc\0".ptr, cast(char*)"spc".ptr, OFN_OVERWRITEPROMPT);
		if (file) {
			FILE *f = fopen(file, "wb");
			if (!f) {
				MessageBox2(strerror(errno).fromStringz, "Export SPC", MB_ICONEXCLAMATION);
			} else {
				HRSRC res = FindResource(hinstance, MAKEINTRESOURCE(IDRC_SPC), RT_RCDATA);
				HGLOBAL res_handle = res ? LoadResource(NULL, res) : NULL;
				if (!res_handle) {
					MessageBox2("Blank SPC could not be loaded.", "Export SPC", MB_ICONEXCLAMATION);
				} else {
					BYTE* res_data = cast(BYTE*)LockResource(res_handle);
					DWORD spc_size = SizeofResource(NULL, res);
					const WORD header_size = 0x100;
					const WORD footer_size = 0x100;

					// Copy blank SPC to byte array
					BYTE* new_spc = cast(BYTE*)malloc(spc_size);
					memcpy(new_spc, res_data, spc_size);

					// Copy packs/blocks to byte array
					for (int pack_ = 0; pack_ < 3; pack_++) {
						if (packs_loaded[pack_] < NUM_PACKS) {
							pack *p = load_pack(packs_loaded[pack_]);
							for (int block_ = 0; block_ < p.block_count; block_++) {
								block *b = &p.blocks[block_];

								// Copy block to new_spc
								const int size = min(b.size, spc_size - b.spc_address - footer_size);
								memcpy(new_spc + header_size + b.spc_address, b.data, size);

								if (size > spc_size - footer_size) {
									printf("SPC pack %d block %d too large.\n", packs_loaded[pack_], block_);
								}
							}
						}
					}

					// Set pattern repeat location
					const WORD repeat_address = cast(WORD)(cur_song.address + 0x2*cur_song.repeat_pos);
					memcpy(new_spc + 0x140, &repeat_address, 2);

					// Set BGM to load
					const BYTE bgm = cast(BYTE)(selected_bgm + 1);
					memcpy(new_spc + 0x1F4, &bgm, 1);

					// Save byte array to file
					fwrite(new_spc, spc_size, 1, f);
				}
				fclose(f);
			}
		}
	}
}

BOOL save_all_packs() nothrow {
	char[60] buf;
	save_cur_song_to_pack();
	int packs = 0;
	BOOL success = TRUE;
	for (int i = 0; i < NUM_PACKS; i++) {
		if (inmem_packs[i].status & IPACK_CHANGED) {
			BOOL saved = save_pack(i);
			success &= saved;
			packs += saved;
		}
	}
	if (packs) {
		SendMessageA(tab_hwnd[current_tab], WM_PACKS_SAVED, 0, 0);
		MessageBox2(assumeWontThrow(sformat(buf[], "%d pack(s) saved", packs)), "Save", MB_OK);
	}
	save_metadata();
	return success;
}

extern(Windows) LRESULT MainWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	switch (uMsg) {
	case 0x3BB: case 0x3BC: case 0x3BD: // MM_WOM_OPEN, CLOSE, DONE
		winmm_message(uMsg);
		break;
	case WM_CREATE: {
		HWND tabs = CreateWindowW("SysTabControl32", NULL,
			WS_CHILD | WS_VISIBLE | TCS_BUTTONS, 0, 0, 600, 25,
			hWnd, NULL, hinstance, NULL);
		TC_ITEMA item;
		item.mask = TCIF_TEXT;
		for (int i = 0; i < NUM_TABS; i++) {
			item.pszText = cast(char*)tab_name[i];
			TabCtrl_InsertItem(tabs, i, &item);
		}
		break;
	}
	case WM_SIZE:
		MoveWindow(tab_hwnd[current_tab], 0, 25, LOWORD(lParam), HIWORD(lParam) - 25, TRUE);
		break;
	case WM_COMMAND: {
		WORD id = LOWORD(wParam);
		switch (id) {
		case ID_OPEN: {
			char *file = open_dialog(&GetOpenFileNameA,
				cast(char*)"SNES ROM files (*.smc, *.sfc)\0*.smc;*.sfc\0All Files\0*.*\0".ptr, NULL, OFN_FILEMUSTEXIST);
			try {
				if (file && open_rom(file, ofn.Flags & OFN_READONLY)) {
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
			if (!close_rom()) break;
			SendMessageA(tab_hwnd[current_tab], WM_ROM_CLOSED, 0, 0);
			SetWindowTextA(hWnd, "EarthBound Music Editor");
			break;
		case ID_IMPORT: import_(); break;
//		case ID_IMPORT_SPC: import_spc(); break;
		case ID_EXPORT: export_(); break;
		case ID_EXPORT_SPC: export_spc(); break;
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
			editor_command(id);
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
				CW_USEDEFAULT, CW_USEDEFAULT, 640, 480,
				NULL, NULL, hinstance, NULL);
			break;
		case ID_ABOUT: {
			DialogBoxA(hinstance, MAKEINTRESOURCEA(IDD_ABOUT), hWnd, &AboutDlgProc);
			break;
		}
		default: printf("Command %d not yet implemented\n", id); break;
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
		if (!close_rom()) break;
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

version(win32) {
	extern(Windows) ptrdiff_t WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow) {
		import core.runtime;
		import std.experimental.logger;
		Runtime.initialize();
		sharedLog = cast(shared)new FileLogger("trace.log");
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

		InitCommonControls();

	//	SetUnhandledExceptionFilter(exfilter);

		hwndMain = CreateWindowW("ebmused_main", "EarthBound Music Editor",
			WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
			CW_USEDEFAULT, CW_USEDEFAULT, 720, 540,
			NULL, NULL, hInstance, NULL);
		ShowWindow(hwndMain, nCmdShow);

		hmenu = GetMenu(hwndMain);
		CheckMenuRadioItem(hmenu, ID_OCTAVE_1, ID_OCTAVE_1+4, ID_OCTAVE_1+2, MF_BYCOMMAND);

		hcontextmenu = LoadMenuA(hInstance, MAKEINTRESOURCEA(IDM_CONTEXTMENU));

		hfont = GetStockObject(DEFAULT_GUI_FONT);

		HACCEL hAccel = LoadAcceleratorsA(hInstance, MAKEINTRESOURCEA(IDA_ACCEL));

		//if (_ARGC > 1)
		//	open_rom(_ARGV[1], FALSE);
		tab_selected(0);

		while (GetMessage(&msg, NULL, 0, 0) > 0) {
			if (!TranslateAccelerator(hwndMain, hAccel, &msg)) {
				TranslateMessage(&msg);
			}
			DispatchMessage(&msg);
		}
		DestroyMenu(hcontextmenu);
		return msg.wParam;
	}
}
