module win32.packlist;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.sys.windows.windows;
import core.sys.windows.commctrl;
import std.format;
import ebmusv2;
import structs;
import win32.ctrltbl;
import win32.misc;
import main;
import loadrom;
import ranges;
import metadata;
import packs;

enum IDC_RLIST_CAPTION = 10;
enum IDC_ROM_LIST = 11;
enum IDC_MLIST_CAPTION = 12;
enum IDC_INMEM_LIST = 13;

enum IDC_RANGE_OPTS_HDR = 20;
enum IDC_RANGE_START = 21;
enum IDC_RANGE_TO = 22;
enum IDC_RANGE_END = 23;
enum IDC_RANGE_ADD = 24;
enum IDC_RANGE_REMOVE = 25;

enum IDC_PACK_OPTS_HDR = 30;
enum IDC_PACK_SAVE = 31;
enum IDC_PACK_ADDRESS = 32;
enum IDC_PACK_MOVE = 33;
enum IDC_PACK_RESET = 34;

enum IDC_SONG_OPTS_HDR = 40;
enum IDC_SONG_ADDRESS = 41;
enum IDC_SONG_NEW = 42;
enum IDC_SONG_MOVE = 43;
enum IDC_SONG_UP = 44;
enum IDC_SONG_DOWN = 45;
enum IDC_SONG_DEL = 46;

private __gshared HWND rom_list, inmem_list;
private __gshared int sort_by;
private __gshared ptrdiff_t inmem_sel;

static const control_desc[22] pack_list_controls = [
	//The format here is X position, Y position, height, and width. The negative numbers mean it starts from the bottom
	//The upper half of the SPC Packs tab - list of all packs in the game
	{ "Static",   10, 10,100, 18, "All Packs:", IDC_RLIST_CAPTION, 0 },
	{ WC_LISTVIEW,10, 30,-20,-60, NULL, IDC_ROM_LIST, WS_BORDER | LVS_REPORT | LVS_SINGLESEL },

	{ "Static",   10,-22, 35, 20, "Range:", IDC_RANGE_OPTS_HDR, 0 },
	{ "Edit",     50,-25, 60, 20, NULL, IDC_RANGE_START, WS_BORDER }, //Range Start textbox
	{ "Static",  110,-22, 19, 18, "to", IDC_RANGE_TO, SS_CENTER },
	{ "Edit",    129,-25, 60, 20, NULL, IDC_RANGE_END, WS_BORDER }, //Range End textbox
	{ "Button",  195,-25, 52, 20, "Add", IDC_RANGE_ADD, 0 }, //Add button
	{ "Button",  249,-25, 52, 20, "Remove", IDC_RANGE_REMOVE, 0 }, //Remove button

	//The lower half of the SPC Packs tab - info about anything that's been modified
	{ "Static",   10, 10,100, 18, "Modified packs:", IDC_MLIST_CAPTION, 0 },
	{ WC_LISTVIEW,10, 30,-20,-90, NULL, IDC_INMEM_LIST, WS_BORDER | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS },

	{ "Static",   10,-52,130, 20, "ROM address for the pack:", IDC_PACK_OPTS_HDR, WS_DISABLED },
	{ "Edit",    145,-55, 60, 20, NULL, IDC_PACK_ADDRESS, WS_BORDER | WS_DISABLED }, //ROM Address textbox
	{ "Button",  210,-55, 40, 20, "Apply", IDC_PACK_MOVE, WS_DISABLED }, //ROM Address Apply button

	{ "Static",   10,-27,130, 20, "ARAM offset for the song:", IDC_SONG_OPTS_HDR, WS_DISABLED },
	{ "Edit",    145,-30, 60, 20, NULL, IDC_SONG_ADDRESS, WS_BORDER | WS_DISABLED }, //ARAM Address textbox
	{ "Button",  210,-30, 40, 20, "Apply", IDC_SONG_MOVE, WS_DISABLED }, //ARAM Address Apply button

	//Buttons on the right for modifying the pack
	{ "Button",  290,-55, 118, 20, "Save Changes", IDC_PACK_SAVE, WS_DISABLED }, //Same as Ctrl-S I think
	{ "Button",  410,-55, 118, 20, "Revert", IDC_PACK_RESET, WS_DISABLED }, //Wipes all changes
	{ "Button",  290,-30, 78, 20, "New Song", IDC_SONG_NEW, WS_DISABLED }, //adds a new song entry in the current modified pack
	{ "Button",  370,-30, 78, 20, "Delete Song", IDC_SONG_DEL, WS_DISABLED }, //Deleltes the currently-selected song
	{ "Button",  450,-30, 38, 20, "Up", IDC_SONG_UP, WS_DISABLED }, //Moves the currently-selected song
	{ "Button",  490,-30, 38, 20, "Down", IDC_SONG_DOWN, WS_DISABLED },

];

static window_template pack_list_template = window_template(pack_list_controls.length, 14, 0, 0, pack_list_controls[]);

static void show_blocks(HWND packlist, pack *p, LV_ITEMA *lvi) {
	char[MAX_TITLE_LEN+5] buf;
	block *b = p.blocks;
	ptrdiff_t packno = lvi.lParam >> 16;
	for (int i = 1; i <= p.block_count; i++, b++) {
		lvi.mask = LVIF_PARAM;
		lvi.iSubItem = 0;
		lvi.lParam = (lvi.lParam & 0xFFFF0000) | i;
		ListView_InsertItemA(packlist, lvi);
		lvi.mask = LVIF_TEXT;
		lvi.iSubItem = 1;
		lvi.pszText = &buf[0];
		sprintf(&buf[0], "%04X-%04X", b.spc_address, b.spc_address + b.size - 1);
		ListView_SetItemA(packlist, lvi);
		lvi.iSubItem = 2;
		sprintf(&buf[0], "%d", b.size);
		ListView_SetItemA(packlist, lvi);

		lvi.iSubItem = 4;
		if (b.spc_address == 0x0500) {
			lvi.pszText = cast(char*)"Program".ptr;
		} else if (b.spc_address >= 0x6C00 && b.spc_address < 0x6E00) {
			lvi.pszText = cast(char*)"Sample pointers".ptr;
		} else if (b.spc_address >= 0x6E00 && b.spc_address < 0x6F80) {
			lvi.pszText = cast(char*)"Instruments".ptr;
		} else if (b.spc_address == 0x6F80) {
			lvi.pszText = cast(char*)"Note style tables".ptr;
		} else if (b.spc_address >= 0x7000 && b.spc_address <= 0xE800) {
			lvi.pszText = cast(char*)"Samples".ptr;
		} else if (b.spc_address >= 0x4800 && b.spc_address < 0x6C00) {
			strcpy(&buf[0], "Unused song");
			for (int song = 0; song < NUM_SONGS; song++) {
				if (pack_used[song][2] == packno && song_address[song] == b.spc_address) {
					sformat!"%02X: %s\0"(buf[], song+1, bgm_title[song]);
					break;
				}
			}
		} else {
			lvi.pszText = cast(char*)"Unknown".ptr;
		}
		ListView_SetItemA(packlist, lvi);
		lvi.iItem++;
	}
}

static void show_or_hide_blocks(HWND packlist, LV_ITEMA *lvi) {
	int packno = HIWORD(lvi.lParam);
	pack *pack = (packlist == rom_list ? &rom_packs[0] : &inmem_packs[0]) + packno;

	LV_FINDINFOA lvfi;
	lvfi.flags = LVFI_PARAM;
	lvfi.lParam = packno << 16 | 1;
	int block = ListView_FindItemA(packlist, -1, &lvfi);
	if (block >= 0) {
		for (int i = 0; i < pack.block_count; i++)
			ListView_DeleteItem(packlist, block);
	} else {
		show_blocks(packlist, pack, lvi);
	}
}

extern(Windows) static int comparator(LPARAM first, LPARAM second, LPARAM column) {
	int[2] p = [ HIWORD(first), HIWORD(second) ];
	int[2] val;
	for (int i = 0; i < 2; i++) {
		int v = 0;
		if (p[i] == 0xFF) { // Free area
			Area *a = &areas[LOWORD(i ? second : first)];
			if (column == 1)
				v = a.address;
			else if (column == 2)
				v = (a+1).address - a.address;
			else if (column == 3)
				v = -4;
		} else { // Pack
			pack *rp = &rom_packs[p[i]];
			if (column == 1)
				v = rp.start_address;
			else if (column == 2)
				v = calc_pack_size(rp);
			else if (column == 3)
				v = -rp.status;
		}
		val[i] = v;
	}
	if (val[0] < val[1]) return -1;
	if (val[0] > val[1]) return 1;
	if (first < second) return -1;
	if (first > second) return 1;
	return 0;
}

static void center_on_item(HWND packlist, LPARAM lParam) {
	LV_FINDINFO lvfi;
	lvfi.flags = LVFI_PARAM;
	lvfi.lParam = lParam;
	int index = ListView_FindItem(packlist, -1, &lvfi);
	if (index < 0) return;
	RECT rc;
	GetClientRect(packlist, &rc);
	SetFocus(packlist);
	ListView_SetItemState(packlist, index,
		LVIS_FOCUSED | LVIS_SELECTED,
		LVIS_FOCUSED | LVIS_SELECTED);
	// Center the view around the selection
	POINT pt;
	ListView_GetItemPosition(packlist, index, &pt);
	ListView_Scroll(packlist, 0, pt.y - (rc.bottom >> 1));
}

static void hide_free_ranges() {
	LV_FINDINFO lvfi;
	lvfi.flags = LVFI_STRING;
	lvfi.psz = "--";
	int index;
	while ((index = ListView_FindItem(rom_list, -1, &lvfi)) >= 0)
		ListView_DeleteItem(rom_list, index);
}

static void show_free_ranges() {
	LV_ITEMA lvi;
	char[14] buf;
	lvi.iItem = ListView_GetItemCount(rom_list);
	for (int i = 0; i < area_count; i++) {
		if (areas[i].pack != AREA_FREE) continue;
		lvi.mask = LVIF_TEXT | LVIF_PARAM;
		lvi.pszText = cast(char*)"--".ptr;
		lvi.iSubItem = 0;
		lvi.lParam = 0xFF0000 | i;
		ListView_InsertItemA(rom_list, &lvi);
		lvi.mask = LVIF_TEXT;
		lvi.iSubItem = 1;
		lvi.pszText = &buf[0];
		sprintf(&buf[0], "%06X-%06X", areas[i].address, areas[i+1].address - 1);
		ListView_SetItemA(rom_list, &lvi);
		lvi.iSubItem = 2;
		sprintf(&buf[0], "%d", areas[i+1].address - areas[i].address);
		ListView_SetItemA(rom_list, &lvi);
		lvi.iSubItem = 3;
		lvi.pszText = cast(char*)"Free".ptr;
		ListView_SetItemA(rom_list, &lvi);
		lvi.iItem++;
	}
}

static void show_rom_packs() {
	HWND packlist = rom_list;

	LVITEMA lvi;
	lvi.iItem = 0;
	char[14] buf;
	SendMessage(packlist, WM_SETREDRAW, FALSE, 0);
	for (int i = 0; i < NUM_PACKS; i++) {
		pack *pack = &rom_packs[i];

		lvi.mask = LVIF_TEXT | LVIF_PARAM;
		lvi.lParam = i << 16;
		lvi.pszText = &buf[0];
		lvi.iSubItem = 0;
		sprintf(&buf[0], "%02X", i);
		ListView_InsertItemA(packlist, &lvi);

		int size = calc_pack_size(pack);
		lvi.mask = LVIF_TEXT;
		lvi.iSubItem = 1;
		sprintf(&buf[0], "%06X-%06X",
			pack.start_address, pack.start_address + size - 1);
		ListView_SetItemA(packlist, &lvi);

		lvi.iSubItem = 2;
		sprintf(&buf[0], "%d", size);
		ListView_SetItemA(packlist, &lvi);

		lvi.iSubItem = 3;
		static const(char)*[4] status_text = [
			"Original", "Modified", "Invalid", "Saved"
		];
		lvi.pszText = cast(char*)status_text[pack.status];
		ListView_SetItemA(packlist, &lvi);

		lvi.iItem++;
		if (i == packs_loaded[2] && !(inmem_packs[i].status & IPACK_CHANGED))
			show_blocks(packlist, pack, &lvi);
	}
	show_free_ranges(/*packlist*/);
	if (sort_by != 0)
		ListView_SortItems(packlist, &comparator, sort_by);

	SendMessage(packlist, WM_SETREDRAW, TRUE, 0);
	center_on_item(packlist, packs_loaded[2] << 16 | (1 + current_block));

}

static void show_inmem_packs() {
	HWND packlist = inmem_list;
	LVITEMA lvi;

	lvi.iItem = 0;
	SendMessage(packlist, WM_SETREDRAW, FALSE, 0);
	for (int i = 0; i < NUM_PACKS; i++) {
		pack *pack = &inmem_packs[i];
		if (!(pack.status & IPACK_CHANGED)) continue;
		char[25] buf;

		lvi.mask = LVIF_TEXT | LVIF_PARAM;
		lvi.lParam = i << 16;
		lvi.pszText = &buf[0];
		lvi.iSubItem = 0;
		sprintf(&buf[0], "%02X", i);
		ListView_InsertItemA(packlist, &lvi);

		int size = calc_pack_size(pack);
		lvi.mask = LVIF_TEXT;
		lvi.iSubItem = 1;
		sprintf(&buf[0], "%06X-%06X", pack.start_address, pack.start_address + size - 1);
		ListView_SetItemA(packlist, &lvi);

		lvi.iSubItem = 2;
		sprintf(&buf[0], "%d", size);
		ListView_SetItemA(packlist, &lvi);

		lvi.iSubItem = 3;
		int conflict = check_range(pack.start_address, pack.start_address + size, i);
		switch (conflict) {
		case AREA_NOT_IN_FILE: lvi.pszText = cast(char*)"Invalid address".ptr; break;
		case AREA_NON_SPC: lvi.pszText = cast(char*)"Out of range".ptr; break;
		case AREA_FREE: lvi.pszText = cast(char*)"Ready to save".ptr; break;
		default: sprintf(&buf[0], "Overlap with %02X", conflict); break;
		}
		ListView_SetItemA(packlist, &lvi);

		lvi.iItem++;
		if (i == packs_loaded[2])
			show_blocks(packlist, pack, &lvi);

	}
	SendMessage(packlist, WM_SETREDRAW, TRUE, 0);
	center_on_item(packlist, packs_loaded[2] << 16 | (1 + current_block));
}

static void packs_saved() {
	inmem_sel = -1;
	ListView_DeleteAllItems(inmem_list);
	show_inmem_packs();
}

extern(Windows) LRESULT PackListWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	try {
	switch (uMsg) {
	case WM_CREATE: {
		inmem_sel = -1;
		create_controls(hWnd, &pack_list_template, lParam);

		rom_list = GetDlgItem(hWnd, IDC_ROM_LIST);
		inmem_list = GetDlgItem(hWnd, IDC_INMEM_LIST);
		ListView_SetExtendedListViewStyle(rom_list, LVS_EX_FULLROWSELECT);
		ListView_SetExtendedListViewStyle(inmem_list, LVS_EX_FULLROWSELECT);
		LVCOLUMNA lvc;
		lvc.mask = LVCF_TEXT | LVCF_WIDTH;
		for (int i = 0; i < 5; i++) {
			static const(char)*[5] colname = [ "#", "Address", "Size", "Status", "Description" ];
			static const WORD[5] cx = [ 30, 120, 60, 100, 270 ];
			lvc.pszText = cast(char*)colname[i];
			lvc.cx = scale_x(cx[i]);
			ListView_InsertColumnA(rom_list, i, &lvc);
			ListView_InsertColumnA(inmem_list, i, &lvc);
		}
		break;
	}
	case WM_ROM_OPENED:
		show_rom_packs();
		show_inmem_packs();
		for (int i = 20; i <= 25; i++)
			EnableWindow(GetDlgItem(hWnd, i), TRUE);
		break;
	case WM_ROM_CLOSED:
		inmem_sel = -1;
		ListView_DeleteAllItems(rom_list);
		ListView_DeleteAllItems(inmem_list);
		for (int i = 20; i <= 46; i++)
			EnableWindow(GetDlgItem(hWnd, i), FALSE);
		break;
	case WM_PACKS_SAVED:
	update_all:
		packs_saved();
		ListView_DeleteAllItems(rom_list);
		show_rom_packs();
		goto case;
	case WM_SONG_IMPORTED:
	update_inmem:
		inmem_sel = -1;
		ListView_DeleteAllItems(inmem_list);
		show_inmem_packs();
		break;
	case WM_SIZE:
		// make the top listview twice as big as the bottom
		pack_list_template.divy = (HIWORD(lParam) - 120) * 2 / 3 + 30;
		move_controls(hWnd, &pack_list_template, lParam);
		break;
	case WM_NOTIFY: {
		NMLISTVIEW *nm = cast(LPNMLISTVIEW)lParam;
		HWND hwnd = nm.hdr.hwndFrom;
		UINT code = nm.hdr.code;
		if (code == LVN_ITEMACTIVATE) {
			int index = ListView_GetNextItem(hwnd, -1, LVNI_SELECTED);
			LV_ITEMA lvi;
			lvi.mask = LVIF_PARAM;
			lvi.iItem = index;
			lvi.iSubItem = 0;
			if (!ListView_GetItemA(hwnd, &lvi)) break;
			if (LOWORD(lvi.lParam) == 0) {
				// Double-clicked on a pack - show/hide its blocks
				lvi.iItem++;
				show_or_hide_blocks(hwnd, &lvi);
			} else {
				// Double-clicked on a block - load it
				int pack = HIWORD(lvi.lParam);
				if (pack >= NUM_PACKS) break;
				int block = LOWORD(lvi.lParam) - 1;
				load_songpack(pack);
				if (hwnd == rom_list)
					select_block_by_address(rom_packs[pack].blocks[LOWORD(block)].spc_address);
				else
					select_block(block);
			}
		} else if (code == LVN_COLUMNCLICK) {
			sort_by = nm.iSubItem;
			ListView_SortItems(hwnd, &comparator, sort_by);
			int index = ListView_GetNextItem(hwnd, -1, LVNI_SELECTED);
			ListView_EnsureVisible(hwnd, index, TRUE);
		} else if (code == LVN_ITEMCHANGED) {
			if (hwnd == inmem_list && nm.uNewState & LVIS_SELECTED) {
				inmem_sel = nm.lParam;
				printf("Selected %x\n", inmem_sel);
				for (int i = 30; i <= 46; i++) {
					EnableWindow(GetDlgItem(hWnd, i), TRUE);
				}
			}
		} else {
//			printf("Notify %d\n", code);
		}
		break;
	}
	case WM_COMMAND: {
		WORD id = LOWORD(wParam);
		int pack_ = HIWORD(inmem_sel);
		pack *p = &inmem_packs[pack_];
		switch (id) {
		case IDC_RANGE_ADD:
		case IDC_RANGE_REMOVE: {
			int start = GetDlgItemHex(hWnd, IDC_RANGE_START);
			if (start < 0) break;
			int end = GetDlgItemHex(hWnd, IDC_RANGE_END);
			if (end < 0) break;

			int from = (id == IDC_RANGE_ADD) ? AREA_NON_SPC : AREA_FREE;
			int to   = (id == IDC_RANGE_ADD) ? AREA_FREE : AREA_NON_SPC;
			printf("changing range\n");
			change_range(start, end + 1, from, to);
			metadata_changed = TRUE;
			hide_free_ranges();
			show_free_ranges();
			goto update_inmem;
		}
		case IDC_PACK_SAVE:
			if (save_pack(pack_)) {
				save_metadata();
				goto update_all;
			}
			break;
		case IDC_PACK_MOVE: {
			int addr = GetDlgItemHex(hWnd, IDC_PACK_ADDRESS);
			if (addr < 0) break;
			printf("moving %d to %x\n", pack_, addr);
			p.start_address = addr;
			goto update_inmem;
		}
		case IDC_PACK_RESET:
			if (pack_ == packs_loaded[2]) {
				load_songpack(0xFF);
				select_block(-1);
			}
			free_pack(&inmem_packs[pack_]);
			goto update_inmem;
		case IDC_SONG_NEW: {
			int addr = GetDlgItemHex(hWnd, IDC_SONG_ADDRESS);
			if (addr < 0) break;
			load_songpack(pack_);
			block b = { 21, cast(ushort)addr, cast(ubyte*)calloc(21, 1) };
			*cast(WORD *)b.data = cast(ushort)(addr + 4);
			new_block(&b);
			goto update_inmem;
		}
		case IDC_SONG_MOVE: {
			int addr = GetDlgItemHex(hWnd, IDC_SONG_ADDRESS);
			if (addr < 0) break;
			int block = LOWORD(inmem_sel) - 1;
			if (block < 0 || block >= p.block_count) break;
			load_songpack(pack_);
			select_block(block);
			if (cur_song.order_length) {
				cur_song.address = cast(ushort)addr;
				cur_song.changed = TRUE;
				save_cur_song_to_pack();
				goto update_inmem;
			}
			break;
		}
		case IDC_SONG_UP:
		case IDC_SONG_DOWN: {
			int from = LOWORD(inmem_sel) - 1;
			if (from < 0 || from >= p.block_count) break;
			int to = from + (id == IDC_SONG_UP ? -1 : 1);
			if (to < 0 || to >= p.block_count) break;
			load_songpack(pack_);
			select_block(from);
			move_block(to);
			goto update_inmem;
		}
		case IDC_SONG_DEL: {
			int block = LOWORD(inmem_sel) - 1;
			if (block < 0 || block >= p.block_count) break;
			load_songpack(pack_);
			delete_block(block);
			goto update_inmem;
		}
		default: break;
		}
	}
	goto default;
	default:
		return DefWindowProc(hWnd, uMsg, wParam, lParam);
	}
} catch (Exception) {}
	return 0;
}
