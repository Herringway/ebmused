import core.stdc.errno;
import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.sys.windows.windows;
import std.format : sformat;
import std.exception : assumeWontThrow;
import std.string : fromStringz;
import ebmusv2;
import structs;
import ctrltbl;
import sound;
import misc;
import packs;
import main;
import loadrom;
import metadata;
import brr;
import play;

extern(C):

enum IDC_ROM_FILE = 17;
enum IDC_ORIG_ROM_FILE = 18;
enum IDC_ROM_SIZE = 19;

enum IDC_LIST = 20;
enum IDC_SEARCH_TEXT = 21;
enum IDC_SEARCH = 22;
enum IDC_TITLE = 23;
enum IDC_TITLE_CHANGE = 24;

enum IDC_BGM_NUMBER = 25;
enum IDC_BGM_IPACK_1 = 30;
enum IDC_BGM_IPACK_2 = 31;
enum IDC_BGM_SPACK = 32;
enum IDC_BGM_SPCADDR = 33;
enum IDC_SAVE_INFO = 34;

enum IDC_CUR_IPACK_1 = 35;
enum IDC_CUR_IPACK_2 = 36;
enum IDC_CUR_SPACK = 37;
enum IDC_CUR_SPCADDR = 38;

enum IDC_LOAD_BGM = 40;
enum IDC_CHANGE_BGM = 41;

__gshared int selected_bgm;
private char[32] bgm_num_text = "BGM --:";

immutable control_desc[27] bgm_list_controls = [
	control_desc("ListBox", 10, 10,300,-20, NULL, IDC_LIST, WS_BORDER | LBS_NOTIFY | WS_VSCROLL ),

	control_desc("Static", 310, 10, 90, 20, "Current ROM:", 0, SS_RIGHT ),
	control_desc("Static", 410, 10,1000,20, NULL, IDC_ROM_FILE, 0 ),
	control_desc("Static", 310, 30, 90, 20, "Original ROM:", 0, SS_RIGHT ),
	control_desc("Static", 410, 30,1000,20, NULL, IDC_ORIG_ROM_FILE, SS_NOTIFY ),
	control_desc("Static", 310, 50, 90, 20, "Size:", 0, SS_RIGHT ),
	control_desc("Static", 410, 50,100, 20, NULL, IDC_ROM_SIZE, 0 ),

	control_desc("Static", 410,110,100, 20, "BGM --:", IDC_BGM_NUMBER, 0 ),
	control_desc("Static", 530,110,100, 20, "Currently loaded:", IDC_BGM_NUMBER+1, 0 ),
	control_desc("Static", 315,133, 90, 20, "Inst. packs:", 0, SS_RIGHT ),
	control_desc("Edit",   410,130, 25, 20, NULL, IDC_BGM_IPACK_1, WS_BORDER ), //(ROM) Main Pack textbox
	control_desc("Edit",   440,130, 25, 20, NULL, IDC_BGM_IPACK_2, WS_BORDER ), //(ROM) Secondary Pack textbox
	control_desc("Edit",   530,130, 25, 20, NULL, IDC_CUR_IPACK_1, WS_BORDER ), //(Current) Main Pack textbox
	control_desc("Edit",   560,130, 25, 20, NULL, IDC_CUR_IPACK_2, WS_BORDER ), //(Current) Secondary Pack textbox
	control_desc("Static", 325,157, 80, 20, "Song pack:", 0, SS_RIGHT ),
	control_desc("Edit",   410,155, 25, 20, NULL, IDC_BGM_SPACK, WS_BORDER ), //(ROM) Song Pack textbox
	control_desc("Edit",   530,155, 25, 20, NULL, IDC_CUR_SPACK, WS_BORDER ), //(Current) Song Pack textbox
	control_desc("Static", 325,182, 80, 20, "Song to play:", 0, SS_RIGHT ),
	control_desc("Edit",   410,180, 55, 20, NULL, IDC_BGM_SPCADDR, WS_BORDER ), //(ROM) Song ARAM textbox
	control_desc("ComboBox",530,180, 55, 200, NULL, IDC_CUR_SPCADDR, CBS_DROPDOWNLIST | WS_VSCROLL ), //(Current) Song ARAM ComboBox
	control_desc("Button", 485,130, 25, 30, "-.", IDC_LOAD_BGM, 0 ),
	control_desc("Button", 485,170, 25, 30, "<--", IDC_CHANGE_BGM, 0 ),
	control_desc("Button", 353,205,112, 20, "Update Song Table", IDC_SAVE_INFO, 0 ),
	control_desc("Edit",   320,250,230, 20, NULL, IDC_SEARCH_TEXT, WS_BORDER ),
	control_desc("Button", 560,250, 60, 20, "Search", IDC_SEARCH, 0 ),
	control_desc("Edit",   320,275,230, 20, NULL, IDC_TITLE, WS_BORDER | ES_AUTOHSCROLL ),
	control_desc("Button", 560,275, 60, 20, "Rename", IDC_TITLE_CHANGE, 0 ),
];
__gshared window_template bgm_list_template = window_template(
	bgm_list_controls.sizeof / (bgm_list_controls[0]).sizeof,
	bgm_list_controls.sizeof / (bgm_list_controls[0]).sizeof,
	0, 0, bgm_list_controls.ptr
);

private void set_bgm_info(BYTE *packs_used, int spc_addr) nothrow {
	for (int i = 0; i < 3; i++)
		SetDlgItemHex(hwndBGMList, IDC_BGM_IPACK_1+i, packs_used[i], 2);
	SetDlgItemHex(hwndBGMList, IDC_BGM_SPCADDR, spc_addr, 4);
}

private void show_bgm_info() nothrow {
	sprintf(&bgm_num_text[4], "%d (0x%02X):", selected_bgm+1, selected_bgm+1);
	SetDlgItemTextA(hwndBGMList, IDC_BGM_NUMBER, &bgm_num_text[0]);
	SetDlgItemTextA(hwndBGMList, IDC_TITLE, bgm_title[selected_bgm]);
	set_bgm_info(&pack_used[selected_bgm][0], song_address[selected_bgm]);
}

private void show_cur_info() nothrow {
	for (int i = 0; i < 3; i++)
		SetDlgItemHex(hwndBGMList, IDC_CUR_IPACK_1+i, packs_loaded[i], 2);

	HWND cb = GetDlgItem(hwndBGMList, IDC_CUR_SPCADDR);
	SendMessageA(cb, CB_RESETCONTENT, 0, 0);
	SendMessageA(cb, CB_ADDSTRING, 0, cast(LPARAM)"----".ptr);
	int song_pack = packs_loaded[2];
	if (song_pack < NUM_PACKS) {
		pack *p = &inmem_packs[song_pack];
		for (int i = 0; i < p.block_count; i++) {
			char[5] buf;
			sprintf(&buf[0], "%04X", p.blocks[i].spc_address);
			SendMessageA(cb, CB_ADDSTRING, 0, cast(LPARAM)&buf[0]);
		}
	}
	SendMessageA(cb, CB_SETCURSEL, current_block + 1, 0);
}

void load_instruments() nothrow {
	free_samples();
	memset(&spc[0], 0, 0x10000);
	for (int i = 0; i < 2; i++) {
		int p = packs_loaded[i];
		if (p >= NUM_PACKS) continue;
		int addr, size;
		try {
			rom.seek(rom_packs[p].start_address - 0xC00000 + rom_offset, 0);
			while ((size = rom.getw()) != 0) {
				addr = rom.getw();
				if (size + addr >= 0x10000) {
					MessageBox2("Invalid SPC block", "Error loading instruments", MB_ICONERROR);
					return;
				}
				rom.rawRead(spc[addr .. addr + size]);
			}
		} catch (Exception e) {
			MessageBox2(e.msg, "Error reading file", MB_ICONERROR);
		}
	}
	decode_samples(&spc[0x6C00]);
	inst_base = 0x6E00;
	if (samp[0].data == NULL)
		song_playing = FALSE;
	initialize_state();
}

private void load_music(BYTE *packs_used, int spc_addr) nothrow {
	packs_loaded[0] = packs_used[0];
	packs_loaded[1] = packs_used[1];
	load_songpack(packs_used[2]);
	select_block_by_address(spc_addr);
	show_cur_info();
	load_instruments();
}

private void song_selected(int index) nothrow {
	selected_bgm = index;
	show_bgm_info();
	load_music(&pack_used[index][0], song_address[index]);
}

private void song_search() nothrow {
	char[MAX_TITLE_LEN+1] str = 0;
	char *endhex;
	GetDlgItemTextA(hwndBGMList, IDC_SEARCH_TEXT, &str[0], MAX_TITLE_LEN+1);
	int num = strtol(&str[0], &endhex, 16) - 1;
	if (*endhex != '\0' || num < 0 || num >= NUM_SONGS) {
		num = selected_bgm;
		strlwr(&str[0]);
		do {
			char[MAX_TITLE_LEN+1] title = 0;
			if (++num == NUM_SONGS) num = 0;
			if (strstr(strlwr(strcpy(&title[0], bgm_title[num])), &str[0]))
				break;
		} while (num != selected_bgm);
	}
	SendDlgItemMessage(hwndBGMList, IDC_LIST, LB_SETCURSEL, num, 0);
	song_selected(num);
}

extern(Windows) LRESULT BGMListWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	char[MAX_TITLE_LEN+5] buf;
	switch (uMsg) {
	case WM_CREATE:
		create_controls(hWnd, &bgm_list_template, lParam);
		break;
	case WM_SIZE:
		move_controls(hWnd, &bgm_list_template, lParam);
		break;
	case WM_ROM_OPENED:
		SetDlgItemTextA(hWnd, IDC_ROM_FILE, rom_filename);
		SetDlgItemTextA(hWnd, IDC_ORIG_ROM_FILE, orig_rom_filename
			? orig_rom_filename : "None specified (click to set)");
		sprintf(&buf[0], "%.2f MB", rom_size / 1048576.0);
		SetDlgItemTextA(hWnd, IDC_ROM_SIZE, &buf[0]);
		HWND list = GetDlgItem(hWnd, IDC_LIST);
		SendMessageA(list, WM_SETREDRAW, FALSE, 0);
		for (int i = 0; i < NUM_SONGS; i++) {
			sprintf(&buf[0], "%02X: %s", i+1, bgm_title[i]);
			SendMessageA(list, LB_ADDSTRING, 0, cast(LPARAM)&buf[0]);
		}
		SendMessageA(list, WM_SETREDRAW, TRUE, 0);
		SendMessageA(list, LB_SETCURSEL, selected_bgm, 0);
		SetFocus(list);
		show_bgm_info();
		for (int i = 20; i <= 41; i++)
			EnableWindow(GetDlgItem(hWnd, i), TRUE);
		goto case;
	case WM_SONG_IMPORTED:
		show_cur_info();
		break;
	case WM_ROM_CLOSED:
		SetDlgItemText(hWnd, IDC_ROM_FILE, NULL);
		SetDlgItemText(hWnd, IDC_ORIG_ROM_FILE, NULL);
		SetDlgItemText(hWnd, IDC_ROM_SIZE, NULL);
		SendDlgItemMessage(hWnd, IDC_LIST, LB_RESETCONTENT, 0, 0);
		for (int i = 20; i <= 41; i++)
			EnableWindow(GetDlgItem(hWnd, i), FALSE);
		break;
	case WM_COMMAND: {
		WORD id = LOWORD(wParam), action = HIWORD(wParam);
		switch (id) {
		case IDC_ORIG_ROM_FILE:
			if (!rom.isOpen) break;
			if (get_original_rom())
				SetWindowTextA(cast(HWND)lParam, orig_rom_filename);
			break;
		case IDC_SEARCH:
			song_search();
			break;
		case IDC_LIST:
			if (action == LBN_SELCHANGE)
				song_selected(SendMessageA(cast(HWND)lParam, LB_GETCURSEL, 0, 0));
			break;
		case IDC_TITLE_CHANGE: {
			if (bgm_title[selected_bgm] != bgm_orig_title[selected_bgm])
				free(bgm_title[selected_bgm]);
			GetDlgItemTextA(hWnd, IDC_TITLE, &buf[4], MAX_TITLE_LEN+1);
			bgm_title[selected_bgm] = strdup(&buf[4]);
			sprintf(&buf[0], "%02X:", selected_bgm + 1);
			buf[3] = ' ';
			SendDlgItemMessage(hWnd, IDC_LIST, LB_DELETESTRING, selected_bgm, 0);
			SendDlgItemMessage(hWnd, IDC_LIST, LB_INSERTSTRING, selected_bgm, cast(LPARAM)&buf[0]);
			SendDlgItemMessage(hWnd, IDC_LIST, LB_SETCURSEL, selected_bgm, 0);

			metadata_changed = TRUE;
			break;
		}
		case IDC_SAVE_INFO: {
			BYTE[3] new_pack_used;
			for (int i = 0; i < 3; i++) {
				int pack = GetDlgItemHex(hWnd, IDC_BGM_IPACK_1 + i);
				if (pack < 0) break;
				new_pack_used[i] = cast(BYTE)pack;
			}
			int new_spc_address = GetDlgItemHex(hWnd, IDC_BGM_SPCADDR);
			if (new_spc_address < 0 || new_spc_address > 0xFFFF) break;
			try {
				rom.seek(BGM_PACK_TABLE + rom_offset + 3 * selected_bgm, SEEK_SET);
				rom.rawWrite(new_pack_used[]);
				memcpy(&pack_used[selected_bgm], &new_pack_used[0], 3);
				rom.seek(SONG_POINTER_TABLE + rom_offset + 2 * selected_bgm, SEEK_SET);
				rom.rawWrite([cast(ushort)new_spc_address]);
				rom.flush();
			} catch (Exception e) {
				MessageBox2(e.msg, "Save", MB_ICONERROR);
				break;
			}
			song_address[selected_bgm] = cast(ushort)new_spc_address;
			MessageBox2(assumeWontThrow(sformat(buf[], "Info for BGM %02X saved!", selected_bgm + 1)), "Song Table Updated", MB_OK);
			break;
		}
		case IDC_CUR_IPACK_1:
		case IDC_CUR_IPACK_2:
		case IDC_CUR_SPACK:
			if (action == EN_KILLFOCUS) {
				int num = GetDlgItemHex(hWnd, id);
				if (num < 0 || packs_loaded[id - IDC_CUR_IPACK_1] == num)
					break;
				if (id == IDC_CUR_SPACK) {
					load_songpack(num);
					select_block(-1);
					show_cur_info();
				} else {
					packs_loaded[id - IDC_CUR_IPACK_1] = cast(ubyte)num;
					load_instruments();
				}
			}
			break;
		case IDC_CUR_SPCADDR:
			if (action == CBN_SELCHANGE) {
				select_block(SendMessageA(cast(HWND)lParam, CB_GETCURSEL, 0, 0) - 1);
			}
			break;
		case IDC_LOAD_BGM: {
			BYTE[3] pack_used;
			int spc_address;
			for (int i = 0; i < 3; i++) {
				pack_used[i] = cast(ubyte)GetDlgItemHex(hWnd, IDC_BGM_IPACK_1 + i);
			}
			spc_address = GetDlgItemHex(hWnd, IDC_BGM_SPCADDR);
			load_music(&pack_used[0], spc_address);
			break;
		}
		case IDC_CHANGE_BGM:
			{	block *b = get_cur_block();
				if (b) set_bgm_info(&packs_loaded[0], b.spc_address);
			}
			break;
		default: break;
		}
		break;
	}
	default:
		return DefWindowProcA(hWnd, uMsg, wParam, lParam);
	}
	return 0;
}
