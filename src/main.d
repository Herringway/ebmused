
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
import metadata;
import packlist;
import play;
import song;
import tracker;

extern(C):

enum NUM_TABS = 4;
auto hwndBGMList() { return tab_hwnd[0]; }
auto hwndInstruments() { return tab_hwnd[1]; }
auto hwndEditor() { return tab_hwnd[2]; }
auto hwndPackList() { return tab_hwnd[3]; }

enum {
	MAIN_WINDOW_WIDTH = 720,
	MAIN_WINDOW_HEIGHT = 540,
	TAB_CONTROL_WIDTH = 600,
	TAB_CONTROL_HEIGHT = 25,
	CODELIST_WINDOW_WIDTH = 640,
	CODELIST_WINDOW_HEIGHT = 480
}

__gshared structs.song cur_song;
__gshared ubyte[3] packs_loaded = [ 0xFF, 0xFF, 0xFF ];
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
		bool ret = file && open_orig_rom(file);
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


struct spcDetails {
	ushort music_table_addr;
	ushort instrument_table_addr;
	ushort music_addr;
	ubyte music_index;
}

bool try_parse_music_table(const(ubyte) *spc, spcDetails *out_details) nothrow {
	if (memcmp(&spc[0], "\x1C\x5D\xF5".ptr, 3) != 0) return false;
	ushort addr_hi = *(cast(ushort*)&spc[3]);

	// Check for Konami-only branch
	if (spc[5] == 0xF0) {
		spc += 2; // skip two bytes (beq ..)
	}

	if (spc[5] != 0xFD) return false;

	// Check for Starfox branch
	if (memcmp(&spc[6], "\xD0\x03\xC4".ptr, 3) == 0 && spc[10] == 0x6F) {
		spc += 5; // skip these 5 bytes
	}

	if (spc[6] != 0xF5) return false; // mov a,
	ushort addr_lo = *(cast(ushort*)&spc[7]); //       $....+x

	if (spc[9] != 0xDA || spc[10] != 0x40) return false; // mov $40,ya

	// Validate retrieved address
	if (addr_lo != addr_hi - 1) return false;

	out_details.music_table_addr = addr_lo;
	return true;
}

bool try_parse_music_address(const(ubyte)* spc, spcDetails *out_details) nothrow {
	ushort loop_addr = *cast(ushort *)&spc[0x40];
	ushort *terminator = cast(ushort *)&spc[loop_addr];
	while (terminator[0]) {
		// Make sure terminator stays in bounds and allows space for one pattern block after it.
		// Also arbitrarily limit number of patterns between loop and terminator to 256.
		if (cast(ubyte *)terminator < &spc[0x10000 - 16 - 2]
			&& terminator - cast(ushort *)&spc[loop_addr] <= 0x100
		) {
			terminator++;
		} else {
			return false;
		}
	}

	// Count all unique patterns past the terminator.
	ushort[8]* patterns = cast(ushort[8]*)&terminator[1];
	uint numPatterns = 0;
	const size_t maxPatterns = (&spc[0xFFFF] - cast(ubyte *)patterns) / (ushort[8]).sizeof; // Amount of patterns that can possibly fit.
	// Pattern is only valid if all channel addresses are ordered. (Ignore 0x0000 channel addresses)
	for (uint i = 0;
		i < maxPatterns // Limit count to as many as can possibly fit in memory
			&& (patterns[i][0] < patterns[i][1] || !patterns[i][1])
			&& (patterns[i][1] < patterns[i][2] || !patterns[i][2])
			&& (patterns[i][2] < patterns[i][3] || !patterns[i][3])
			&& (patterns[i][3] < patterns[i][4] || !patterns[i][4])
			&& (patterns[i][4] < patterns[i][5] || !patterns[i][5])
			&& (patterns[i][5] < patterns[i][6] || !patterns[i][6])
			&& (patterns[i][6] < patterns[i][7] || !patterns[i][7])
			;
		i++) {
		numPatterns = i + 1;
	}

	// sanity check. Assert smallest pattern is greater than 0xFF and number of patterns is less than as many as can fit in memory
	if (patterns[0][0] <= 0xFF || numPatterns == 0 || numPatterns >= maxPatterns) return false;

	// Find the first pattern by iterating backwards until one pattern doesn't point at a pattern address.
	ushort *music_addr_ptr = cast(ushort*)&spc[loop_addr];
	bool patternExists = true;
	for (WORD* prev = &music_addr_ptr[-1]; prev && patternExists; prev--) {
		patternExists = false;
		// if any patterns contain prev, continue
		for (uint i = 0; i < numPatterns; i++) {
			if (patterns[i] == *cast(ushort[8]*)(&spc[*prev])) {
				patternExists = true;
				music_addr_ptr = prev;
				break;
			}
		}
	}

	// sanity check
	if (cast(ubyte*)music_addr_ptr - spc <= 0xFF) return false;

	out_details.music_addr = cast(ushort)(cast(ubyte*)music_addr_ptr - spc);
	return true;
}

bool try_parse_inst_directory(const BYTE *spc, spcDetails *out_details) nothrow {
	if (memcmp(spc, "\xCF\xDA\x14\x60\x98".ptr, 5) == 0 && memcmp(&spc[6], "\x14\x98".ptr, 2) == 0 && spc[9] == 0x15) {
		out_details.instrument_table_addr = spc[5] | (spc[8] << 8);
		return true;
	}

	return false;
}

enum SPC_RESULTS {
	HAS_MUSIC = 1 << 0,
	HAS_MUSIC_TABLE = 1 << 1,
	HAS_INSTRUMENTS = 1 << 2
}
SPC_RESULTS try_parse_spc(const(ubyte)* spc, spcDetails *out_details) nothrow {
	bool foundMusic = false,
		foundMusicTable = false,
		foundInst = false;
	// For i in 0 .. 0xFF00, and also stop if all 3 things we're looking for have been found
	for (int i = 0; i < 0xFF00 && !(foundMusicTable && foundInst); i++) {
		if (!foundMusicTable && spc[i] == 0x1C)
			foundMusicTable = try_parse_music_table(&spc[i], out_details);
		else if (!foundInst && spc[i] == 0xCF)
			foundInst = try_parse_inst_directory(&spc[i], out_details);
	}

	foundMusic = try_parse_music_address(spc, out_details);

	// If we couldn't find the music via snooping the $40 address, try checking if we found a music table.
	if (!foundMusic && foundMusicTable) {
		// Try to get the bgm index from one of these locations, the first that isn't 0...
		ubyte bgm_index = spc[0x00] ? spc[0x00]
			: spc[0x04] ? spc[0x04]
			: spc[0x08] ? spc[0x08]
			: spc[0xF3] ? spc[0xF3]
			: spc[0xF4];
		if (bgm_index) {
			out_details.music_index = bgm_index;
			out_details.music_addr = (cast(ushort *)&spc[out_details.music_table_addr])[bgm_index];
			foundMusic = true;
		} else {
			// If we couldn't find the bgm index, try to guess it from the table using the pointer at 0x40
			ushort music_addr = *(cast(ushort*)(&spc[0x40]));
			ushort closestDiff = 0xFFFF;
			for (uint i = 0; i < 0xFF; i++) {
				ushort addr = (cast(ushort *)(&spc[out_details.music_table_addr]))[i];
				if (music_addr < addr && addr - music_addr < closestDiff) {
					closestDiff = cast(ushort)(addr - music_addr);
					bgm_index = cast(ubyte)i;
				}
			}

			if (music_addr > 0xFF) {
				out_details.music_addr = music_addr;
				out_details.music_index = 0;
				foundMusic = true;
			}
		}
	}

	SPC_RESULTS results = cast(SPC_RESULTS)0;
	if (foundMusicTable) results |= SPC_RESULTS.HAS_MUSIC_TABLE;
	if (foundMusic) results |= SPC_RESULTS.HAS_MUSIC;
	if (foundInst) results |= SPC_RESULTS.HAS_INSTRUMENTS;
	return results;
}
static void import_spc() nothrow {
	char *file = open_dialog(&GetOpenFileNameA,
		cast(char*)"SPC Savestates (*.spc)\0*.spc\0All Files\0*.*\0".ptr,
		null,
		OFN_FILEMUSTEXIST | OFN_HIDEREADONLY);
	if (!file) return;

	FILE *f = fopen(file, "rb");
	if (!f) {
		MessageBox2(strerror(errno).fromStringz, "Import", MB_ICONEXCLAMATION);
		return;
	}

	// Backup the currently loaded SPC in case we need to restore it upon an error.
	// This can be updated once methods like decode_samples don't rely on the global "spc" variable.
	BYTE[0x10000] backup_spc;
	memcpy(&backup_spc[0], &spc[0], 0x10000);
	WORD original_sample_ptr_base = sample_ptr_base;

	BYTE[0x80] dsp;

	if (fseek(f, 0x100, SEEK_SET) == 0
		&& fread(&spc[0], 0x10000, 1, f) == 1
		&& fread(&dsp[0], 0x80, 1, f) == 1
	) {
		sample_ptr_base = dsp[0x5D] << 8;
		free_samples();
		decode_samples(&spc[sample_ptr_base]);

		spcDetails details;
		SPC_RESULTS results = try_parse_spc(&spc[0], &details);
		if (results) {
			if (results & SPC_RESULTS.HAS_INSTRUMENTS) {
				printf("Instrument table found: %#X\n", details.instrument_table_addr);
				inst_base = details.instrument_table_addr;
			}
			if (results & SPC_RESULTS.HAS_MUSIC) {
				printf("Music table found: %#X\n", details.music_table_addr);
				printf("Music index found: %#X\n", details.music_index);
				printf("Music found: %#X\n", details.music_addr);

				free_song(&cur_song);
				decompile_song(&cur_song, details.music_addr, 0xffff);
			}

			initialize_state();
			SendMessage(tab_hwnd[current_tab], WM_SONG_IMPORTED, 0, 0);
		} else {
			// Restore SPC state and samples
			memcpy(&spc[0], &backup_spc[0], 0x10000);
			sample_ptr_base = original_sample_ptr_base;
			free_samples();
			decode_samples(&spc[sample_ptr_base]);

			MessageBox2("Could not parse SPC.", "SPC Import", MB_ICONEXCLAMATION);
		}
	} else {
		// Restore SPC state
		memcpy(&spc[0], &backup_spc[0], 0x10000);

		if (feof(f))
			MessageBox2("End-of-file reached while reading the SPC file", "Import", MB_ICONEXCLAMATION);
		else
			MessageBox2("Error reading the SPC file", "Import", MB_ICONEXCLAMATION);
	}

	fclose(f);
}

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

private immutable blankSPC = cast(immutable(ubyte)[])import("blank.spc");

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
				const spc_size = blankSPC.length;
				const WORD header_size = 0x100;
				const WORD footer_size = 0x100;

				// Copy blank SPC to byte array
				ubyte* new_spc = cast(ubyte*)malloc(spc_size);
				new_spc[0 .. spc_size] = blankSPC;

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
				const ubyte bgm = cast(ubyte)(selected_bgm + 1);
				memcpy(new_spc + 0x1F4, &bgm, 1);

				// Save byte array to file
				fwrite(new_spc, spc_size, 1, f);
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
	try {
		save_metadata();
	} catch(Exception e) {
		MessageBox2(e.msg, filename, MB_ICONEXCLAMATION);
	}
	return success;
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
		LOGFONT original_font;
		GetObjectA(GetStockObject(SYSTEM_FONT), LOGFONT.sizeof, &original_font);

		LOGFONT tabs_font;
		GetObjectA(hfont, LOGFONT.sizeof, &tabs_font);
		tabs_font.lfHeight = scale_y(original_font.lfHeight) - 2;
		// strcpy(tabs_font.lfFaceName, "Tahoma");
		// TODO: Refactor so this new font can be deleted
		HFONT hTabsFont = CreateFontIndirect(&tabs_font);
		SendMessageA(tabs, WM_SETFONT, cast(size_t)hTabsFont, TRUE);
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
		case ID_IMPORT_SPC: import_spc(); break;
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
				CW_USEDEFAULT, CW_USEDEFAULT, scale_x(CODELIST_WINDOW_WIDTH), scale_y(CODELIST_WINDOW_HEIGHT),
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

		setup_dpi_scale_values();
		InitCommonControls();

	//	SetUnhandledExceptionFilter(exfilter);

		hfont = GetStockObject(DEFAULT_GUI_FONT);

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
		return msg.wParam;
	}
}
