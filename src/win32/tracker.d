module win32.tracker;

import std.algorithm.comparison : max, min;
import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.sys.windows.windows;
import core.sys.windows.mmsystem;
import win32.id;
import ebmusv2;
import structs;
import win32.ctrltbl;
import main;
import win32.handles;
import win32.sound;
import text;
import parser;
import play;
import win32.fonts;
import win32.misc;
import songed;
import song;
import packs;
import midi;
import win32.inst;

__gshared HWND hwndTracker;
__gshared private HWND hwndOrder;
__gshared private HWND hwndState;

enum IDC_CHANSTATE_CAPTION = 1; // child of hwndState
private immutable char[17] cs_title = "Channel state (0)";

enum IDC_ORDER = 1;
enum IDC_REP_CAPTION = 2;
enum IDC_REPEAT = 3;
enum IDC_REP_POS_CAPTION = 4;
enum IDC_REPEAT_POS = 5;
enum IDC_PAT_LIST_CAPTION = 6;
enum IDC_PAT_LIST = 7;
enum IDC_PAT_ADD = 8;
enum IDC_PAT_INS = 9;
enum IDC_PAT_DEL = 10;
enum IDC_TRACKER = 15;
enum IDC_STATE = 16;
enum IDC_EDITBOX_CAPTION = 17;
enum IDC_EDITBOX = 18;
enum IDC_ENABLE_CHANNEL_0 = 20;

immutable control_desc[15] editor_controls = [
// Upper
	{ "Static",          10, 13, 42, 20, "Patterns:", 0, 0 }, //"Order" label
	{ "ebmused_order",   56, 10,-420,20, null, IDC_ORDER, WS_BORDER }, //Pattern order list
	{ "Static",        -360, 13, 55, 20, "Loop Song:", IDC_REP_CAPTION, 0 },
	{ "Edit",          -303, 10, 30, 20, null, IDC_REPEAT, WS_BORDER | ES_NUMBER }, //Loop textbox
	{ "Static",        -266, 13, 40, 20, "Position:", IDC_REP_POS_CAPTION, 0 },
	{ "Edit",          -223, 10, 30, 20, null, IDC_REPEAT_POS, WS_BORDER | ES_NUMBER }, //Loop position textbox
	{ "Static",        -187, 13, 45, 20, "Pattern:", IDC_PAT_LIST_CAPTION, 0 },
	{ "ComboBox",      -147,  9, 40,300, null, IDC_PAT_LIST, CBS_DROPDOWNLIST | WS_VSCROLL },
	{ "Button",        -100,  9, 30, 20, "Add", IDC_PAT_ADD, 0 },
	{ "Button",         -70,  9, 30, 20, "Ins", IDC_PAT_INS, 0 },
	{ "Button",         -40,  9, 30, 20, "Del", IDC_PAT_DEL, 0 },
	{ "ebmused_tracker", 10, 60,-20,-70, null, IDC_TRACKER, WS_BORDER | WS_VSCROLL },
// Lower
	{ "ebmused_state",   10,  0,430,-10, null, IDC_STATE, 0 },
	{ "Static",         450,  0,100, 15, null, IDC_EDITBOX_CAPTION, 0 },
	{ "Edit",           450,15,-460,-25, null, IDC_EDITBOX, WS_BORDER | ES_MULTILINE | ES_AUTOVSCROLL | ES_NOHIDESEL },
];
private window_template editor_template = {
	editor_controls.length, 3, 0, 0, editor_controls[]
};

immutable control_desc[2] state_controls = [
	{ "Button",           0,  0,150,  0, "Global state", 0, BS_GROUPBOX },
	{ "Button",         160,  0,270,  0, cs_title, IDC_CHANSTATE_CAPTION, BS_GROUPBOX },
];
__gshared private window_template state_template = { 2, 2, 0, 0, state_controls[] };

__gshared private int pos_width, font_height;
private immutable ubyte[12] zoom_levels = [ 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 96 ];
__gshared private int zoom = 6, zoom_idx = 4;
__gshared private int tracker_width = 0;
__gshared private int tracker_height;
__gshared private bool editbox_had_focus;

__gshared private int cursor_chan;
// the following 4 variables are all set by cursor_moved()
// current track or subroutine cursor is in
__gshared private track *cursor_track;
__gshared private ubyte *sel_from;
__gshared private ubyte *sel_start;
__gshared private ubyte *sel_end;
// these are what must be updated before calling cursor_moved()
__gshared int cursor_pos;
__gshared private Parser cursor;

__gshared private int pat_length;
__gshared private PAINTSTRUCT ps;

void tracker_scrolled() {
	SetScrollPos(hwndTracker, SB_VERT, state.patpos, true);
	InvalidateRect(hwndTracker, null, false);
	InvalidateRect(hwndState, null, false);
}

private void scroll_to(int new_pos) {
	if (new_pos == state.patpos) return;
	if (new_pos < state.patpos)
		state = pattop_state;
	while (state.patpos < new_pos && do_cycle_no_sound(&state)) {}
	tracker_scrolled();
}

private COLORREF get_bkcolor(int sub_loops) {
	if (sub_loops == 0)
		return 0xFFFFFF;
	int c = 0x808080;
	if (sub_loops & 1) c += 0x550000;
	if (sub_loops & 2) c += 0x005500;
	if (sub_loops & 4) c += 0x000055;
	if (sub_loops & 8) c += 0x2A2A2A;
	return c;
}

private void get_font_size(HWND hWnd) {
	TEXTMETRIC tm;
	HDC hdc = GetDC(hWnd);
	HFONT oldfont = SelectObject(hdc, default_font());
	GetTextMetrics(hdc, &tm);
	SelectObject(hdc, oldfont);
	ReleaseDC(hWnd, hdc);
	pos_width = tm.tmAveCharWidth * 6;
	font_height = tm.tmHeight;
}

private void get_sel_range() {
	ubyte *s = sel_from;
	ubyte *e = cursor.ptr;

	if (e == null) {
		sel_start = null;
		sel_end = null;
	} else {
		if (s > e) { ubyte *tmp = s; s = e; e = tmp; }
		if (*e != 0) e = next_code(e);
		sel_start = s;
		sel_end = e;
	}
}

private void show_track_text() {
	char *txt = null;
	track *t = cursor_track;
	if (t.size) {
		txt = cast(char*)malloc(text_length(t.track, t.track + t.size));
		track_to_text(txt, t.track, t.size);
	}
	SetDlgItemTextA(hwndEditor, IDC_EDITBOX, txt);
	free(txt);
}

private void cursor_moved(bool select) {
	char[23] caption;
	track *t;

	if (!cur_song.order_length) return;

	int ycoord = (cursor_pos - state.patpos) * font_height / zoom;
	if (ycoord < 0) {
		scroll_to(cursor_pos);
	} else if (ycoord + font_height > tracker_height) {
		scroll_to((cursor_pos + zoom) - (tracker_height * zoom / font_height));
	}

	if (cursor.sub_count) {
		t = &cur_song.sub[cursor.sub_start];
		sprintf(&caption[0], "Subroutine %d", cursor.sub_start);
	} else {
		int ch = cursor_chan;
		t = &cur_song.pattern[cur_song.order[state.ordnum]][ch];
		sprintf(&caption[0], "Track %d", ch);
		if (cursor.ptr == null)
			strcat(&caption[0], " (not present)");
	}
	printf("t = %p\n", t);
	if (t != cursor_track) {
		SetDlgItemTextA(hwndEditor, IDC_EDITBOX_CAPTION, &caption[0]);
		cursor_track = t;
		show_track_text();
	}

	if (!select) sel_from = cursor.ptr;
	get_sel_range();
	if (cursor.ptr != null) {
		int esel_start = text_length(t.track, sel_start);
		int esel_end = esel_start + text_length(sel_start, sel_end) - 1;
		SendDlgItemMessage(hwndEditor, IDC_EDITBOX, EM_SETSEL, esel_start, esel_end);
		SendDlgItemMessage(hwndEditor, IDC_EDITBOX, EM_SCROLLCARET, 0, 0);
	}
	InvalidateRect(hwndTracker, null, false);
}

private void set_cur_chan(int ch) {
	char[17] titleCopy = cs_title;
	cursor_chan = ch;
	titleCopy[15] = cast(char)('0' + ch);
	SetDlgItemTextA(hwndState, IDC_CHANSTATE_CAPTION, &titleCopy[0]);
	InvalidateRect(hwndState, null, false);
}

void load_pattern_into_tracker() nothrow {
	try {
		if (hwndTracker == null) return;

		InvalidateRect(hwndOrder, null, false);
		InvalidateRect(hwndState, null, false);
		SendDlgItemMessage(hwndEditor, IDC_PAT_LIST,
			CB_SETCURSEL, cur_song.order[pattop_state.ordnum], 0);

		parser_init(&cursor, &state.chan[cursor_chan]);
		cursor_pos = state.patpos + state.chan[cursor_chan].next;
		cursor_track = null;
		cursor_moved(false);

		pat_length = 0;
		for (int ch = 0; ch < 8; ch++) {
			if (pattop_state.chan[ch].ptr == null) continue;
			Parser p;
			parser_init(&p, &pattop_state.chan[ch]);
			do {
				if (*p.ptr >= 0x80 && *p.ptr < 0xE0)
					pat_length += p.note_len;
			} while (parser_advance(&p));
			break;
		}
		SetScrollRange(hwndTracker, SB_VERT, 0, pat_length, true);
	} catch (Exception e) {
		handleError(e);
	}
}

private void pattern_changed() {
	int pos = state.patpos;
	scroll_to(0);
	state.ordnum--;
	load_pattern();
	scroll_to(pos);
	load_pattern_into_tracker();
	cur_song.changed = true;
}

private void restore_cursor(track *t, int offset) {
	ubyte *target_ptr = t.track + offset;
	cursor_home(false);
	do {
		if (cursor.ptr == target_ptr)
			break;
	} while (cursor_fwd(false));
	cursor_moved(false);
}

extern(Windows) ptrdiff_t TransposeDlgProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	switch (uMsg) {
	case WM_INITDIALOG:
		// need to return true to set default focus
		break;
	case WM_COMMAND:
		if (LOWORD(wParam) == IDOK)
			EndDialog(hWnd, GetDlgItemInt(hWnd, 3, null, true));
		else if (LOWORD(wParam) == IDCANCEL)
			EndDialog(hWnd, 0);
		break;
	default: return false;
	}
	return true;
}

__gshared private WNDPROC EditWndProc;
// Custom window procedure for the track/subroutine Edit control
extern(Windows) private LRESULT TrackEditWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	if (uMsg == WM_SETFOCUS) {
		editbox_had_focus = true;
	} else if (uMsg == WM_KEYDOWN && wParam == VK_ESCAPE) {
		SetFocus(hwndTracker);
		return 0;
	} else if (uMsg == WM_CHAR && wParam == '\r') {
		int len = GetWindowTextLength(hWnd) + 1;
		char[] p = (cast(char*)malloc(len))[0 .. len];
		scope(exit) {
			free(&p[0]);
		}
		Parser c = cursor;
		GetWindowTextA(hWnd, &p[0], len);
		try {
			text_to_track(p, *cursor_track, !!c.sub_count);
			// Find out where the editbox's caret was, and
			// move the tracker cursor appropriately.
			DWORD start;
			SendMessage(hWnd, EM_GETSEL, cast(WPARAM)&start, 0);
			p[start] = '\0';
			track *t = cursor_track;
			int new_pos = calc_track_size_from_text(&p[0]);
			pattern_changed();
			// XXX: may point to middle of a code
			restore_cursor(t, new_pos);
			SetFocus(hwndTracker);
		} catch (Exception e) {
			MessageBox2(e.msg, "", MB_ICONERROR);
		}
		return 0;
	}
	return CallWindowProc(EditWndProc, hWnd, uMsg, wParam, lParam);
}

private void goto_order(int pos) {
	int i;
	initialize_state();
	for (i = 0; i < pos; i++) {
		// If there are any non-null tracks in this pattern, then
		// we want to step through the whole pattern once by calling
		// `do_cycle_no_sound` until it returns false.
		for (int ch = 0; ch < 8; ch++) {
			if (state.chan[ch].ptr != null) {
				// We've found a non-null track. Simulate the current pattern.
				while (do_cycle_no_sound(&state)) {}
				// We're done with the current pattern. Move on to the next one.
				break;
			}
		}
		load_pattern();
	}
	load_pattern_into_tracker();
}

private void pattern_added() {
	char[12] buf;
	sprintf(&buf[0], "%d", cur_song.patterns - 1);
	SendDlgItemMessage(hwndEditor, IDC_PAT_LIST, CB_ADDSTRING,
		0, cast(LPARAM)&buf[0]);
}

private void pattern_deleted() {
	SendDlgItemMessage(hwndEditor, IDC_PAT_LIST, CB_DELETESTRING,
		cur_song.patterns, 0);
}

private void show_repeat() {
	SetDlgItemInt(hwndEditor, IDC_REPEAT, cur_song.repeat, false);
	SetDlgItemInt(hwndEditor, IDC_REPEAT_POS, cur_song.repeat_pos, false);
}

extern(Windows) LRESULT EditorWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	static const ubyte[21] editor_menu_cmds = [
		ID_CUT, ID_COPY, ID_PASTE, ID_DELETE,
		ID_SPLIT_PATTERN, ID_JOIN_PATTERNS,
		ID_MAKE_SUBROUTINE, ID_UNMAKE_SUBROUTINE, ID_TRANSPOSE,
		ID_CLEAR_SONG,
		ID_ZOOM_IN, ID_ZOOM_OUT,
		ID_INCREMENT_DURATION, ID_DECREMENT_DURATION,
		ID_SET_DURATION_1, ID_SET_DURATION_2,
		ID_SET_DURATION_3, ID_SET_DURATION_4,
		ID_SET_DURATION_5, ID_SET_DURATION_6,
		0
	];
	try {
		switch (uMsg) {
		case WM_CREATE:
			get_font_size(hWnd);
			editor_template.divy = (cast(CREATESTRUCT *)lParam).cy - (font_height * 7 + 17);
			create_controls(hWnd, &editor_template, lParam);
			for (int i = 0; i < 8; i++) {
				char[2] buf = [ cast(char)('0' + i), 0 ];
				HWND b = CreateWindowA("Button", &buf[0],
					WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
					hWnd, cast(HMENU)(IDC_ENABLE_CHANNEL_0 + i), hinstance, null);
				SendMessage(b, BM_SETCHECK, chmask >> i & 1, 0);
				// This font was set up earlier by the ebmused_order control
				SendMessage(b, WM_SETFONT, cast(size_t)order_font(), 0);
			}
			EditWndProc = cast(WNDPROC)SetWindowLongPtr(GetDlgItem(hWnd, IDC_EDITBOX), GWLP_WNDPROC, cast(LONG_PTR)&TrackEditWndProc);
			break;
		case WM_SONG_IMPORTED:
		case WM_SONG_LOADED:
			EnableWindow(hWnd, true);
			enable_menu_items(&editor_menu_cmds[0], MF_ENABLED);
			show_repeat();
			HWND cb = GetDlgItem(hWnd, IDC_PAT_LIST);
			SendMessage(cb, CB_RESETCONTENT, 0, 0);
			for (int i = 0; i < cur_song.patterns; i++) {
				char[11] buf;
				sprintf(&buf[0], "%d", i);
				SendMessage(cb, CB_ADDSTRING, 0, cast(LPARAM)&buf[0]);
			}
			load_pattern_into_tracker();
			break;
		case WM_ROM_CLOSED:
		case WM_SONG_NOT_LOADED:
			EnableWindow(hWnd, false);
			enable_menu_items(&editor_menu_cmds[0], MF_GRAYED);
			break;
		case WM_DESTROY:
			save_cur_song_to_pack();
			enable_menu_items(&editor_menu_cmds[0], MF_GRAYED);
			break;
		case WM_COMMAND:
			int id = LOWORD(wParam);
			if (id == IDC_REPEAT || id == IDC_REPEAT_POS) {
				if (HIWORD(wParam) != EN_KILLFOCUS) break;
				BOOL success;
				UINT n = GetDlgItemInt(hWnd, id, &success, false);
				int *p = id == IDC_REPEAT ? &cur_song.repeat : &cur_song.repeat_pos;
				if (success) {
					UINT limit = (id == IDC_REPEAT ? 256 : cur_song.order_length);
					if (n < limit && *p != n) {
						*p = n;
						cur_song.changed = true;
					}
				}
				SetDlgItemInt(hWnd, id, *p, false);
			} else if (id == IDC_PAT_LIST) {
				if (HIWORD(wParam) != CBN_SELCHANGE) break;
				cur_song.order[state.ordnum] =
					cast(int)SendMessage(cast(HWND)lParam, CB_GETCURSEL, 0, 0);
				scroll_to(0);
				pattern_changed();
			} else if (id == IDC_PAT_ADD || id == IDC_PAT_INS) {
				int pat = id == IDC_PAT_ADD ? cur_song.patterns : cur_song.order[state.ordnum];
				int ord = cur_song.order_length;
				if (id == IDC_PAT_ADD)
				{
					track *t = pattern_insert(pat);
					memset(t, 0, track.sizeof * 8);
					pattern_added();
				}
				order_insert(ord, pat);
				goto_order(ord);
				cur_song.changed = true;
			} else if (id == IDC_PAT_DEL) {
				if (cur_song.patterns == 1) break;
				pattern_delete(cur_song.order[state.ordnum]);
				pattern_deleted();
				goto_order(state.ordnum + 1);
				cur_song.changed = true;
				show_repeat();
			} else if (id >= IDC_ENABLE_CHANNEL_0) {
				chmask ^= 1 << (id - IDC_ENABLE_CHANNEL_0);
			}
			break;
		case WM_SIZE:
			editor_template.divy = HIWORD(lParam) - (font_height * 7 + 17);
			move_controls(hWnd, &editor_template, lParam);
			int start = scale_x(10) + GetSystemMetrics(SM_CXBORDER) + pos_width;
			int right = start;
			for (int i = 0; i < 8; i++) {
				int left = right + 1;
				right = start + (tracker_width * (i + 1) >> 3);
				MoveWindow(GetDlgItem(hWnd, IDC_ENABLE_CHANNEL_0+i),
					left, scale_y(40), right - left, scale_y(20), true);
			}
			break;
		default:
			return DefWindowProc(hWnd, uMsg, wParam, lParam);
		}
	} catch (Exception e) {
		handleError(e);
	}
	return 0;
}

extern(Windows) LRESULT OrderWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	try {
		switch (uMsg) {
		case WM_CREATE:
			hwndOrder = hWnd;
			break;
		case WM_LBUTTONDOWN: {
			int pos = LOWORD(lParam) / scale_x(25);
			if (pos >= cur_song.order_length) break;
			SetFocus(hWnd);
			goto_order(pos);
			break;
		}
		case WM_KILLFOCUS: InvalidateRect(hWnd, null, false); break;
		case WM_KEYDOWN:
			if (wParam == VK_LEFT) {
				goto_order(state.ordnum - 1);
			} else if (wParam == VK_RIGHT) {
				goto_order(state.ordnum + 1);
			} else if (wParam == VK_INSERT) {
				order_insert(state.ordnum + 1, cur_song.order[state.ordnum]);
				show_repeat();
				InvalidateRect(hWnd, null, false);
				cur_song.changed = true;
			} else if (wParam == VK_DELETE) {
				if (cur_song.order_length <= 1) break;
				order_delete(state.ordnum);
				show_repeat();
				goto_order(state.ordnum);
				cur_song.changed = true;
			}
			break;
		case WM_PAINT: {
			HDC hdc = BeginPaint(hWnd, &ps);
			SelectObject(hdc, order_font());
			RECT rc;
			GetClientRect(hWnd, &rc);
			int order_width = scale_x(25);
			for (int i = 0; i < cur_song.order_length; i++) {
				char[6] buf;
				int len = sprintf(&buf[0], "%d", cur_song.order[i]);
				rc.right = rc.left + order_width;
				COLORREF tc = 0, bc = 0;
				if (i == pattop_state.ordnum) {
					tc = SetTextColor(hdc, GetSysColor(COLOR_HIGHLIGHTTEXT));
					bc = SetBkColor(hdc, GetSysColor(COLOR_HIGHLIGHT));
				}
				ExtTextOutA(hdc, rc.left, rc.top, ETO_OPAQUE, &rc, &buf[0], len, null);
				if (i == pattop_state.ordnum) {
					SetTextColor(hdc, tc);
					SetBkColor(hdc, bc);
					if (GetFocus() == hWnd)
						DrawFocusRect(hdc, &rc);
				}
				rc.left = rc.right;
			}
			rc.right = ps.rcPaint.right;
			FillRect(hdc, &rc, cast(HBRUSH)(COLOR_WINDOW + 1));
			EndPaint(hWnd, &ps);
			break;
		}

		default: return DefWindowProc(hWnd, uMsg, wParam, lParam);
		}
	} catch (Exception e) {
		handleError(e);
	}
	return 0;
}

private void tracker_paint(HWND hWnd) {
	HDC hdc = BeginPaint(hWnd, &ps);
	RECT rc;
	char[8] codes;
	int length;
	int pos;
	set_up_hdc(hdc);

	if (cur_song.order_length == 0) {
		static const char[28] str = "No song is currently loaded.";
		GetClientRect(hWnd, &rc);
		SetTextAlign(hdc, TA_CENTER);
		int x = (rc.left + rc.right) >> 1;
		int y = (rc.top + rc.bottom - font_height) >> 1;
		ExtTextOutA(hdc, x, y, ETO_OPAQUE, &rc, &str[0], str.length, null);
		//if (get_cur_block() != null) {
		//	y += font_height;
		//	TextOutA(hdc, x, y, "Additional information:", 23);
		//	y += font_height;
		//	TextOutA(hdc, x, y, decomp_error, cast(int)strlen(decomp_error));
		//}
		goto paint_end;
	}

	SetTextColor(hdc, 0xFFFFFF);
	SetBkColor(hdc, 0x808080);
	rc.left = 0;
	rc.right = pos_width;
	pos = state.patpos;
	rc.top = -(pos % zoom);
	pos += rc.top;
	// simulate rounding towards zero, so these numbers
	// will be properly aligned with the notes
	rc.top = (rc.top + zoom) * font_height / zoom - font_height;
	while (rc.top < ps.rcPaint.bottom) {
		int len = sprintf(&codes[0], "%d", pos);
		rc.bottom = rc.top + font_height;
		ExtTextOutA(hdc, rc.left, rc.top, ETO_OPAQUE, &rc, &codes[0], len, null);
		rc.top = rc.bottom;
		pos += zoom;
	}

	for (int chan = 0; chan < 8; chan++) {
		channel_state *cs = &state.chan[chan];
		Parser p;
		parser_init(&p, cs);
		pos = state.patpos + cs.next;

		rc.left = rc.right + 1; // skip divider
		rc.right = pos_width + (tracker_width * (chan + 1) >> 3);
		rc.top = 0;
		int chan_xleft = rc.left;
		int next_y;

		if (p.ptr == null) {
			rc.bottom = ps.rcPaint.bottom;
			FillRect(hdc, &rc, cast(HBRUSH)(COLOR_GRAYTEXT + 1));
			goto draw_divider;
		}

		rc.bottom = cs.next * font_height / zoom;
		SetTextColor(hdc, 0);
		SetBkColor(hdc, get_bkcolor(p.sub_count));
		ExtTextOut(hdc, 0, 0, ETO_OPAQUE, &rc, null, 0, null);
		rc.top = rc.bottom;
		while (rc.top < ps.rcPaint.bottom) {
			// the [00] at the end of the track is not considered part
			// of the selection, but we want to highlight it anyway
			bool highlight = (p.ptr >= sel_start && p.ptr < sel_end)
				|| p.ptr == cursor.ptr;
			bool real_highlight =
				p.sub_count == cursor.sub_count &&
				p.sub_ret == cursor.sub_ret;

			ubyte chr = *p.ptr;
			SIZE extent;
			if (chr >= 0x80 && chr < 0xE0) {
				length = 3;
				if (chr >= 0xCA)
					length = sprintf(&codes[0], "%02X", chr);
				else if (chr == 0xC9)
					memcpy(&codes[0], "---".ptr, 3);
				else if (chr == 0xC8)
					memcpy(&codes[0], "...".ptr, 3);
				else {
					chr &= 0x7F;
					memcpy(&codes[0], &"C-C#D-D#E-F-F#G-G#A-A#B-"[2*(chr%12)], 2);
					codes[2] = '1' + chr/12;
				}

				pos += p.note_len;
				next_y = (pos - state.patpos)*font_height/zoom;
note:			GetTextExtentPoint32A(hdc, &codes[0], length, &extent);
				rc.bottom = rc.top + extent.cy;
				SetTextAlign(hdc, TA_RIGHT);
				ExtTextOutA(hdc, rc.right - 1, rc.top, ETO_OPAQUE, &rc,
					&codes[0], length, null);
				if (highlight) {
					COLORREF bc;
					if (real_highlight) {
						SetTextColor(hdc, GetSysColor(COLOR_HIGHLIGHTTEXT));
						bc = SetBkColor(hdc, GetSysColor(COLOR_HIGHLIGHT));
					} else {
						SetTextColor(hdc, GetSysColor(COLOR_HIGHLIGHT));
						bc = SetBkColor(hdc, GetSysColor(COLOR_HIGHLIGHTTEXT));
					}
					rc.left = rc.right - extent.cx - 2;
					ExtTextOutA(hdc, rc.right - 1, rc.top, ETO_OPAQUE, &rc,
						&codes[0], length, null);
					SetTextColor(hdc, 0);
					SetBkColor(hdc, bc);
					if (p.ptr == cursor.ptr && GetFocus() == hWnd)
						DrawFocusRect(hdc, &rc);
				}
				SetTextAlign(hdc, TA_LEFT);

				rc.left = chan_xleft;
				rc.top = rc.bottom;
				rc.bottom = next_y;
				ExtTextOutA(hdc, 0, 0, ETO_OPAQUE, &rc, null, 0, null);
				rc.top = rc.bottom;
			} else if (chr == 0) {
				if (p.sub_count == 0) {
					next_y = ps.rcPaint.bottom;
					SetTextColor(hdc, GetSysColor(COLOR_WINDOWTEXT));
					SetBkColor(hdc, GetSysColor(COLOR_3DFACE));
					strcpy(&codes[0], "End".ptr);
					length = 3;
					goto note;
				}
			} else {
				length = sprintf(&codes[0], "%02X", chr);
				if (chr < 0x80 && p.ptr[1] < 0x80)
					length += sprintf(&codes[2], "%02X", p.ptr[1]);

				if (highlight) {
					if (real_highlight) {
						SetTextColor(hdc, GetSysColor(COLOR_HIGHLIGHTTEXT));
						SetBkColor(hdc, GetSysColor(COLOR_HIGHLIGHT));
					} else {
						SetTextColor(hdc, GetSysColor(COLOR_HIGHLIGHT));
						SetBkColor(hdc, GetSysColor(COLOR_HIGHLIGHTTEXT));
					}
				}
				int r = rc.right;
				GetTextExtentPoint32A(hdc, &codes[0], length, &extent);
				rc.right = rc.left + extent.cx + 2;
				rc.bottom = rc.top + extent.cy;
				ExtTextOutA(hdc, rc.left + 1, rc.top, ETO_OPAQUE, &rc,
					&codes[0], length, null);
				if (highlight) {
					SetTextColor(hdc, 0);
					SetBkColor(hdc, get_bkcolor(p.sub_count));
					if (p.ptr == cursor.ptr && GetFocus() == hWnd)
						DrawFocusRect(hdc, &rc);
				}
				rc.left = rc.right;
				rc.right = r;
			}
			parser_advance(&p);
			if (chr == 0 || chr == 0xEF)
				SetBkColor(hdc, get_bkcolor(p.sub_count));
		}
draw_divider:
		// Why is this all the way down here? Well, it turns out that
		// when ClearType is enabled, TextOut draws one pixel to both
		// the left and right of where you'd expect it to. If this line
		// is drawn before doing the column - as would logically make sense -
		// it gets overwritten, and ugliness ensues.
		MoveToEx(hdc, chan_xleft - 1, ps.rcPaint.top, null);
		LineTo(hdc, chan_xleft - 1, ps.rcPaint.bottom);
	}
paint_end:
	reset_hdc(hdc);
	EndPaint(hWnd, &ps);
}

private bool cursor_fwd(bool select) {
	int byte_ = *cursor.ptr;
	if (select) {
		// Don't select past end of subroutine
		if (byte_ == 0x00) return false;
		// Skip subroutines
		if (byte_ == 0xEF) {
			do
				cursor_fwd(false);
			while (cursor.sub_count != 0);
			return true;
		}
	}
	if (byte_ >= 0x80 && byte_ < 0xE0)
		cursor_pos += cursor.note_len;
	return parser_advance(&cursor);
}

private bool cursor_home(bool select) {
	if (select && cursor.sub_count) {
		// Go to the top of the subroutine
		if (cursor.ptr == cursor_track.track)
			return false;
		// Start from the top of the track, and search down
		Parser target = cursor;
		if (!cursor_home(false))
			return false;
		do {
			if (!cursor_fwd(false)) {
				// This should never happen
				cursor = target;
				return false;
			}
		} while (cursor.sub_ret != target.sub_ret
		      || cursor.sub_count != target.sub_count);
	} else {
		// Go to the top of the track
		if (cursor.ptr == pattop_state.chan[cursor_chan].ptr)
			return false;
		parser_init(&cursor, &pattop_state.chan[cursor_chan]);
		cursor_pos = 0;
	}
	return true;
}

/// \brief Attempts to move the cursor back by one control code.
/// \return Returns false if the cursor cannot be moved backwards due
/// to already being at the top of the track, otherwise returns true.
private bool cursor_back(bool select) {
	int prev_pos;
	Parser prev;
	Parser target = cursor;
	if (!cursor_home(select))
		return false;
	do {
		prev_pos = cursor_pos;
		prev = cursor;
		if (!cursor_fwd(select)) break;
	} while (cursor.ptr != target.ptr
	      || cursor.sub_ret != target.sub_ret
	      || cursor.sub_count != target.sub_count);
	cursor_pos = prev_pos;
	cursor = prev;
	return true;
}

private bool cursor_end(bool select) {
	while (cursor_fwd(select)) {}
	return true;
}

private bool cursor_on_note() {
	// Consider the ending [00] on a track/subroutine as a note, since it's
	// displayed on the right (for end of track) and you can insert notes there.
	return *cursor.ptr == 0 || (*cursor.ptr >= 0x80 && *cursor.ptr < 0xE0);
}

private bool cursor_up(bool select) {
	bool on_note = cursor_on_note();
	Parser target = cursor;
	if (!cursor_home(select))
		return false;
	int prev_pos;
	Parser prev;
	prev.ptr = null;
	if (on_note) {
		// find previous note
		do {
			if (cursor_on_note()) {
				prev_pos = cursor_pos;
				prev = cursor;
			}
			if (!cursor_fwd(select)) break;
		} while (cursor.ptr != target.ptr
		      || cursor.sub_ret != target.sub_ret
		      || cursor.sub_count != target.sub_count);
	} else {
		// find previous start-of-line code
		bool at_start = true;
		do {
			if (cursor_on_note()) {
				at_start = true;
			} else if (at_start) {
				prev_pos = cursor_pos;
				prev = cursor;
				at_start = false;
			}
			if (!cursor_fwd(select)) break;
		} while (cursor.ptr != target.ptr
		      || cursor.sub_ret != target.sub_ret
		      || cursor.sub_count != target.sub_count);
	}
	if (prev.ptr == null)
		return false;
	cursor_pos = prev_pos;
	cursor = prev;
	return true;
}

private bool cursor_down(bool select) {
	bool on_note = cursor_on_note();
	while (cursor_fwd(select) && !cursor_on_note()) {}
	if (!on_note)
		while (cursor_fwd(select) && cursor_on_note()) {}
	return true;
}

private void cursor_to_xy(int x, int y, bool select) {
	x -= pos_width;
	int ch = x * 8 / tracker_width;
	if (ch < 0 || ch > 7) return;
	if (select && ch != cursor_chan) return;

	channel_state *cs = &state.chan[ch];
	Parser p;
	int pos = 0;
	parser_init(&p, cs);
	if (p.ptr != null) {
		char[8] codes;
		int chan_xleft  = (tracker_width * ch       >> 3) + 1;
//		int chan_xright = (tracker_width * (ch + 1) >> 3);

		HDC hdc = GetDC(hwndTracker);
		HFONT oldfont = SelectObject(hdc, default_font());

		int target_pos = state.patpos + y * zoom / font_height;
		pos = state.patpos + cs.next;

		int px = chan_xleft;
		Parser maybe_new_cursor;
		maybe_new_cursor.ptr = null;
		do {
			ubyte chr = *p.ptr;
			SIZE extent;
			if (chr >= 0x80 && chr < 0xE0) {
				int nextpos = pos + p.note_len;
				if (nextpos >= target_pos) {
					if (maybe_new_cursor.ptr != null)
						p = maybe_new_cursor;
					break;
				}
				pos = nextpos;
				px = chan_xleft;
				maybe_new_cursor.ptr = null;
			} else if (chr == 0) {
				/* nothing */
			} else {
				int length = sprintf(&codes[0], "%02X", chr);
				if (chr < 0x80 && p.ptr[1] < 0x80)
					length += sprintf(&codes[2], "%02X", p.ptr[1]);
				GetTextExtentPoint32A(hdc, &codes[0], length, &extent);
				px += extent.cx + 2;
				if (x < px && maybe_new_cursor.ptr == null)
					maybe_new_cursor = p;
			}
		} while (parser_advance(&p));
		SelectObject(hdc, oldfont);
		ReleaseDC(hwndTracker, hdc);
	}
	if (select) {
		if (p.sub_count != cursor.sub_count) return;
		if (p.sub_count && p.sub_ret != cursor.sub_ret) return;
		// Avoid excessive repainting
		if (p.ptr == cursor.ptr) return;
	} else {
		set_cur_chan(ch);
	}
	cursor_pos = pos;
	cursor = p;
	printf("cursor_pos = %d\n", cursor_pos);
	cursor_moved(select);
}

bool move_cursor(bool function(bool select) func, bool select) {
	if (cursor.ptr == null) return false;
	if (func(select)) {
		cursor_moved(select);
		return true;
	}
	return false;
}

// Inserts code at the cursor
private void track_insert(int size, const ubyte *data) {
	track *t = cursor_track;
	int off = cast(int)(cursor.ptr - t.track);
	t.size += size;
	t.track = cast(ubyte*)realloc(t.track, t.size + 1);
	ubyte *ins = t.track + off;
	memmove(ins + size, ins, t.size - (off + size));
	t.track[t.size] = '\0';
	memcpy(ins, data, size);
	pattern_changed();
	restore_cursor(t, off);
}

private bool copy_sel() {
	ubyte *start = sel_start;
	ubyte *end = sel_end;
	if (start == end) return false;
	try {
		validate_track(start, cast(int)(end - start), !!cursor.sub_count);
	} catch (Exception) {
		return false;
	}
	if (!OpenClipboard(hwndMain)) return false;
	EmptyClipboard();
	HGLOBAL hglb = GlobalAlloc(GMEM_MOVEABLE, text_length(start, end));
	track_to_text(cast(char*)GlobalLock(hglb), start, cast(int)(end - start));
	GlobalUnlock(hglb);
	SetClipboardData(CF_TEXT, hglb);
	CloseClipboard();
	return true;
}

private void paste_sel() {
	if (!OpenClipboard(hwndMain)) return;
	HGLOBAL hglb = GetClipboardData(CF_TEXT);
	if (hglb) {
		char* txtP = cast(char*)GlobalLock(hglb);
		char[] txt = txtP[0 .. strlen(txtP)];
		track temp_track = { 0, null };
		try {
			text_to_track(txt, temp_track, !!cursor.sub_count);
			track_insert(temp_track.size, temp_track.track);
			free(temp_track.track);
		} catch (Exception e) {
			MessageBox2(e.msg, "", MB_ICONERROR);
		}
		GlobalUnlock(hglb);
	}
	CloseClipboard();
}

private void delete_sel(bool cut) {
	track *t = cursor_track;
	if (t.track == null) return;
	ubyte* start = sel_start;
	ubyte* end = sel_end;
	if (end == t.track + t.size) {
		// Don't let the track end with a note-length code
		try {
			validate_track(t.track, cast(int)(start - t.track), !!cursor.sub_count);
		} catch (Exception e) {
			MessageBox2(e.msg, "", MB_ICONERROR);
			return;
		}
	}
	if (cut) {
		if (!copy_sel()) return;
	}
	memmove(start, end, t.track + (t.size + 1) - end);
	t.size -= (end - start);
	if (t.size == 0 && !cursor.sub_count) {
		free(t.track);
		t.track = null;
		start = null;
	}
	pattern_changed();
	restore_cursor(t, cast(int)(start - t.track));
}

private void updateOrInsertDuration(ubyte function(ubyte, int) callback, int durationOrOffset)
{
	// We cannot insert a duration code before an 0x00 code,
	// so ensure that's not the case before proceeding.
	if (cursor_track.track != null
		&& *cursor.ptr != 0)
	{
		ubyte* original_pos = cursor.ptr;
		track* t = cursor_track;
		int off = cast(int)(cursor.ptr - t.track);
		if (*cursor.ptr >= 0x01 && *cursor.ptr <= 0x7F)
		{
			ubyte duration = callback(*cursor.ptr, durationOrOffset);
			if (duration != 0)
			{
				*cursor.ptr = duration;
				cur_song.changed = true;
				InvalidateRect(hwndTracker, null, false);
			}
		}
		else
		{
			// A duration code isn't selected so
			// find the last duration and last note, if any.
			ubyte* last_duration_pos = null;
			ubyte* last_note_pos = null;
			cursor_home(false);
			while (cursor.ptr != original_pos)
			{
				if (*cursor.ptr >= 0x01 && *cursor.ptr <= 0x7F)
					last_duration_pos = cursor.ptr;
				else if (*cursor.ptr >= 0x80 && *cursor.ptr <= 0xDF)
					last_note_pos = cursor.ptr;

				// Advance the cursor if possible and continue, otherwise break.
				if (!cursor_fwd(false))
					break;
			}

			// If we found a duration and a note doesn't follow it (meaning
			// the selected note follows the duration code), set the duration.
			if (last_duration_pos != null
				&& last_duration_pos > last_note_pos)
			{
				ubyte duration = callback(*last_duration_pos, durationOrOffset);
				if (duration != 0)
				{
					*last_duration_pos = duration;

					// restore the cursor position.
					//cursor.ptr = original_pos;
					pattern_changed();
					restore_cursor(t, off);
				}
			}
			else if (last_note_pos != null)
			{
				// Else if we found a note position and it comes after the last
				// duration code (or there is none), insert a duration.
				ubyte duration = callback(last_duration_pos == null ? state.chan[cursor_chan].note_len : *last_duration_pos, durationOrOffset);
				if (duration != 0)
				{
					track_insert(1, cast(ubyte *)&duration);
					cursor_fwd(false);
				}
			}
		}
	}
}

private ubyte setDurationOffsetCallback(ubyte originalDuration, int offset)
{
	ubyte newDuration = cast(ubyte)min(max(0x00, originalDuration + offset), 0xFF);
	return (newDuration >= 0x01 && newDuration <= 0x7F) ? newDuration : 0;
}

private ubyte setDurationCallback(ubyte originalDuration, int duration)
{
	return cast(ubyte)((duration >= 0x01 && duration <= 0x7F) ? duration : 0);
}

private void incrementDuration()
{
	updateOrInsertDuration(&setDurationOffsetCallback, 1);
}

private void decrementDuration()
{
	updateOrInsertDuration(&setDurationOffsetCallback, -1);
}

private void setDuration(ubyte duration)
{
	updateOrInsertDuration(&setDurationCallback, duration);
}

void editor_command(int id) {
	switch (id) {
	case ID_CUT: delete_sel(true); break;
	case ID_COPY: copy_sel(); break;
	case ID_PASTE: paste_sel(); break;
	case ID_DELETE: delete_sel(false); break;
	case ID_CLEAR_SONG:
		free_song(&cur_song);
		cur_song.changed = true;
		cur_song.order_length = 1;
		cur_song.order = cast(int*)malloc(int.sizeof);
		cur_song.order[0] = 0;
		cur_song.repeat = 0;
		cur_song.repeat_pos = 0;
		cur_song.patterns = 1;
		cur_song.pattern = cast(track[8]*)calloc(track.sizeof, 8);
		cur_song.subs = 0;
		cur_song.sub = null;
		initialize_state();
		SendMessage(hwndEditor, WM_SONG_IMPORTED, 0, 0);
		break;
	case ID_SPLIT_PATTERN:
		if (split_pattern(cursor_pos)) {
			pattern_added();
			pattern_changed();
			show_repeat();
		}
		break;
	case ID_JOIN_PATTERNS:
		if (join_patterns()) {
			pattern_deleted();
			pattern_changed();
			show_repeat();
		}
		break;
	case ID_MAKE_SUBROUTINE: {
		if (cursor.sub_count) {
			MessageBox2("Cursor is already in a subroutine!",
				"Make Subroutine", MB_ICONEXCLAMATION);
			break;
		}
		ubyte* start = sel_start;
		ubyte* end = sel_end;
		int count;
		int sub = create_sub(start, end, &count);
		if (sub < 0) break;
		track *t = cursor_track;
		int old_size = t.size;

		if (start >= (t.track + 4)
			&& start[-4] == 0xEF
			&& *cast(WORD *)&start[-3] == sub
			&& count + start[-1] <= 255)
		{
			count += start[-1];
			start -= 4;
		}
		if (end[0] == 0xEF
			&& *cast(WORD *)&end[1] == sub
			&& count + end[3] <= 255)
		{
			count += end[3];
			end += 4;
		}
		memmove(start + 4, end, t.track + (old_size + 1) - end);
		t.size = cast(int)(old_size + 4 - (end - start));
		start[0] = 0xEF;
		start[1] = sub & 255;
		start[2] = cast(ubyte)(sub >> 8);
		start[3] = cast(ubyte)(count);
		pattern_changed();
		restore_cursor(&cur_song.sub[sub], 0);
		break;
	}
	// Substitute a subroutine back into the main track
	case ID_UNMAKE_SUBROUTINE: {
		if (!cursor.sub_count) break;
		ubyte *src = cursor_track.track;
		int subsize = cursor_track.size;
		track *t = &cur_song.pattern[cur_song.order[state.ordnum]][cursor_chan];
		int off = cast(int)(cursor.sub_ret - t.track);
		int count = cursor.sub_ret[-1];
		int old_size = t.size;
		t.size = (old_size - 4 + (subsize * count));
		t.track = cast(ubyte*)realloc(t.track, t.size + 1);
		memmove(t.track + (off - 4) + (subsize * count), t.track + off,
			(old_size + 1) - off);
		ubyte *dest = t.track + (off - 4);
		for (int i = 0; i < count; i++) {
			memcpy(dest, src, subsize);
			dest += subsize;
		}
		pattern_changed();
		break;
	}
	case ID_TRANSPOSE: {
		ptrdiff_t delta = DialogBox(hinstance, MAKEINTRESOURCE(IDD_TRANSPOSE),
			hwndMain, &TransposeDlgProc);
		if (delta == 0) break;
		for (ubyte *p = sel_start; p < sel_end; p = next_code(p)) {
			int note = *p - 0x80;
			if (note < 0 || note >= 0x48) continue;
			note += delta;
			note %= 0x48;
			if (note < 0) note += 0x48;
			*p = cast(ubyte)(0x80 + note);
		}
		cur_song.changed = true;
		show_track_text();
		InvalidateRect(hwndTracker, null, false);
		break;
	}
	case ID_ZOOM_IN:
		if (zoom == 1) break;
		zoom = zoom_levels[--zoom_idx];
		InvalidateRect(hwndTracker, null, false);
		break;
	case ID_ZOOM_OUT:
		if (zoom >= 96) break;
		zoom = zoom_levels[++zoom_idx];
		InvalidateRect(hwndTracker, null, false);
		break;
	case ID_INCREMENT_DURATION:
		incrementDuration();
		break;
	case ID_DECREMENT_DURATION:
		decrementDuration();
		break;
	case ID_SET_DURATION_1:
		setDuration(0x60);
		break;
	case ID_SET_DURATION_2:
		setDuration(0x30);
		break;
	case ID_SET_DURATION_3:
		setDuration(0x18);
		break;
	case ID_SET_DURATION_4:
		setDuration(0x0C);
		break;
	case ID_SET_DURATION_5:
		setDuration(0x06);
		break;
	case ID_SET_DURATION_6:
		setDuration(0x03);
		break;
	default: break;
	}
}

private void addOrInsertNote(int note)
{
	if (note > 0x0 && note < 0x70) {
		note |= 0x80;
		if (cursor.ptr == cursor_track.track + cursor_track.size) {
			track_insert(1, cast(ubyte *)&note);
		} else if (*cursor.ptr >= 0x80 && *cursor.ptr < 0xE0) {
			*cursor.ptr = cast(ubyte)note;
			cur_song.changed = true;
			show_track_text();
		} else {
			return;
		}
		move_cursor(&cursor_fwd, false);
	}
}

private void tracker_keydown(WPARAM wParam) {
	bool control = !!(GetKeyState(VK_CONTROL) & 0x8000);
	bool shift = !!(GetKeyState(VK_SHIFT) & 0x8000);
	switch (wParam) {
	case VK_PRIOR: scroll_to(state.patpos - 96); break;
	case VK_NEXT:  scroll_to(state.patpos + 96); break;
	case VK_HOME:  move_cursor(&cursor_home, shift); break;
	case VK_END:   move_cursor(&cursor_end, shift); break;
	case VK_LEFT:  move_cursor(&cursor_back, shift); break;
	case VK_RIGHT: move_cursor(&cursor_fwd, shift); break;
	case VK_TAB:
		set_cur_chan((cursor_chan + (shift ? -1 : 1)) & 7);
		parser_init(&cursor, &state.chan[cursor_chan]);
		cursor_pos = state.patpos + state.chan[cursor_chan].next;
		cursor_moved(false);
		break;
	case VK_UP:
		if (control)
			scroll_to(state.patpos - zoom);
		else
			move_cursor(&cursor_up, shift);
		break;
	case VK_DOWN:
		if (control)
			scroll_to(state.patpos + zoom);
		else
			move_cursor(&cursor_down, shift);
		break;
	case VK_OEM_4: { // left bracket - insert code
		HWND ed = GetDlgItem(hwndEditor, IDC_EDITBOX);
		DWORD start;
		SendMessage(ed, EM_GETSEL, cast(WPARAM)&start, 0);
		SendMessage(ed, EM_SETSEL, start, start);
		SendMessage(ed, EM_REPLACESEL, 0, cast(LPARAM)"[ ".ptr);
		SendMessage(ed, EM_SETSEL, start+1, start+1);
		SetFocus(ed);
		break;
	}
	case VK_INSERT:
		if (shift)
			paste_sel();
		else
			track_insert(1, cast(ubyte *)"\xC9".ptr);
		break;
	case VK_BACK:
		if (!move_cursor(&cursor_back, false))
			break;
		shift = 0;
		goto case;
	case VK_DELETE:
		delete_sel(shift);
		break;
	case VK_ADD:
		incrementDuration();
		break;
	case VK_SUBTRACT:
		decrementDuration();
		break;
	case VK_NUMPAD1:
		setDuration(0x60);
		break;
	case VK_NUMPAD2:
		setDuration(0x30);
		break;
	case VK_NUMPAD3:
		setDuration(0x18);
		break;
	case VK_NUMPAD4:
		setDuration(0x0C);
		break;
	case VK_NUMPAD5:
		setDuration(0x06);
		break;
	case VK_NUMPAD6:
		setDuration(0x03);
		break;
	default:
		if (control) {
			if (wParam == 'C') copy_sel();
			else if (wParam == 'V') paste_sel();
			else if (wParam == 'X') delete_sel(true);
			else if (wParam == VK_OEM_COMMA) decrementDuration();
			else if (wParam == VK_OEM_PERIOD) incrementDuration();
			else if (wParam == '1') setDuration(0x60);
			else if (wParam == '2') setDuration(0x30);
			else if (wParam == '3') setDuration(0x18);
			else if (wParam == '4') setDuration(0x0C);
			else if (wParam == '5') setDuration(0x06);
			else if (wParam == '6') setDuration(0x03);
		}
		else
		{
			int note = note_from_key(cast(int)wParam, shift);
			addOrInsertNote(note);
		}
		break;
	}
}

extern(Windows) LRESULT TrackerWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	try {
		switch (uMsg) {
		case WM_CREATE: hwndTracker = hWnd; break;
		case WM_DESTROY: hwndTracker = null; break;
		case WM_KEYDOWN: tracker_keydown(wParam); break;
		case WM_MOUSEWHEEL:
			scroll_to(state.patpos - (zoom * cast(short)HIWORD(wParam)) / WHEEL_DELTA);
			break;
		case WM_VSCROLL:
			switch (LOWORD(wParam)) {
				case SB_LINEUP: scroll_to(state.patpos - zoom); break;
				case SB_LINEDOWN: scroll_to(state.patpos + zoom); break;
				case SB_PAGEUP: scroll_to(state.patpos - 96); break;
				case SB_PAGEDOWN: scroll_to(state.patpos + 96); break;
				case SB_THUMBTRACK: scroll_to(HIWORD(wParam)); break;
				default: break;
			}
			break;
		case WM_SIZE:
			tracker_width = LOWORD(lParam) - pos_width;
			tracker_height = HIWORD(lParam);
			break;
		case WM_LBUTTONDOWN:
			SetFocus(hWnd);
			cursor_to_xy(LOWORD(lParam), HIWORD(lParam),
				!!(GetKeyState(VK_SHIFT) & 0x8000));
			break;
		case WM_MOUSEMOVE:
			if (wParam & MK_LBUTTON)
				cursor_to_xy(LOWORD(lParam), HIWORD(lParam), true);
			break;
		case WM_CONTEXTMENU:
			TrackPopupMenu(GetSubMenu(hcontextmenu, 0), 0,
				LOWORD(lParam), HIWORD(lParam), 0, hwndMain, null);
			break;
		case WM_SETFOCUS:
			if (editbox_had_focus) {
				editbox_had_focus = false;
				cursor_track = null; // force update of editbox text
				cursor_moved(false);
			} else
				// fallthrough
		case WM_KILLFOCUS:
			InvalidateRect(hWnd, null, false);
			break;
		case WM_PAINT: tracker_paint(hWnd); break;
		default: return DefWindowProc(hWnd, uMsg, wParam, lParam);
		}
	} catch (Exception e) {
		handleError(e);
	}
	return 0;
}

private HDC hdcState;

private void show_state(int pos, const char *buf) {
	static const WORD[6] xt = [ 20, 80, 180, 240, 300, 360 ];
	RECT rc;
	int left = xt[pos >> 4];
	rc.left = scale_x(left);
	rc.top = (pos & 15) * font_height + 1;
	rc.right = scale_x(left + 60);
	rc.bottom = rc.top + font_height;
	ExtTextOutA(hdcState, rc.left, rc.top, ETO_OPAQUE, &rc, &buf[0], cast(uint)strlen(buf), null);
}

private void show_simple_state(int pos, ubyte value) {
	char[3] buf;
	sprintf(&buf[0], "%02X", value);
	show_state(pos, &buf[0]);
}

private void show_slider_state(int pos, slider *s) {
	char[9] buf;
	if (s.cycles)
		sprintf(&buf[0], "%02X . %02X", s.cur >> 8, s.target);
	else
		sprintf(&buf[0], "%02X", s.cur >> 8);
	show_state(pos, &buf[0]);
}

private void show_oscillator_state(int pos, ubyte start, ubyte speed, ubyte range) {
	char[9] buf;
	if (range)
		sprintf(&buf[0], "%02X %02X %02X", start, speed, range);
	else
		strcpy(&buf[0], "Off");
	show_state(pos, &buf[0]);
}

extern(Windows) private void MidiInProc2(HMIDIIN handle, UINT wMsg, DWORD_PTR dwInstance, DWORD_PTR dwParam1, DWORD_PTR dwParam2) nothrow {
	try {
		if (wMsg == MIM_DATA)
		{
			ubyte
				eventType = (dwParam1 & 0xFF),
				param1 = (dwParam1 >> 8) & 0xFF,
				param2 = (dwParam1 >> 16) & 0xFF;

			int note = param1 + (octave - 4)*12;

			if ((eventType & 0x80) && eventType < 0xF0) {	// if not a system exclusive message
				switch (eventType & 0xF0) {
				case 0x90:	// Note On event
					if (param2 > 0	// Make sure volume is not zero. Some devices use this instead of the Note Off event.
						&& note > 0 && note < 0x48)	// Make sure it's within range.
						addOrInsertNote(note);
					break;
				default: break;
				}
			}
		}
	} catch (Exception e) {
		handleError(e);
	}
}

extern(Windows) LRESULT StateWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	static immutable char*[4] gs = [
		"Volume:", "Tempo:", "Transpose:", "CA inst.:"
	];
	static immutable char*[6] cs1 = [
		"Volume:", "Panning:", "Transpose:",
		"Instrument:", "Vibrato:", "Tremolo:"
	];
	static immutable char*[6] cs2 = [
		"Note length:", "Note style:", "Fine tune:",
		"Subroutine:", "Vib. fadein:", "Portamento:"
	];
	try {
		switch (uMsg) {
		case WM_CREATE:
			hwndState = hWnd;
			create_controls(hWnd, &state_template, lParam);
			closeMidiInDevice();
			openMidiInDevice(cast(int)midiDevice, &MidiInProc2);
			break;
		case WM_ERASEBKGND: {
			DefWindowProc(hWnd, uMsg, wParam, lParam);
			hdcState = cast(HDC)wParam;
			set_up_hdc(hdcState);
			int i;
			for (i = 0x01; i <= 0x04; i++) show_state(i, gs[i-0x01]);
			for (i = 0x21; i <= 0x26; i++) show_state(i, cs1[i-0x21]);
			for (i = 0x41; i <= 0x46; i++) show_state(i, cs2[i-0x41]);
			reset_hdc(hdcState);
			return 1;
		}
		case WM_PAINT: {
			char[11] buf;
			hdcState = BeginPaint(hWnd, &ps);
			set_up_hdc(hdcState);

			show_slider_state(0x11, &state.volume);
			show_slider_state(0x12, &state.tempo);
			show_simple_state(0x13, state.transpose);
			show_simple_state(0x14, state.first_CA_inst);

			channel_state *c = &state.chan[cursor_chan];
			show_slider_state(0x31, &c.volume);
			show_slider_state(0x32, &c.panning);
			show_simple_state(0x33, c.transpose);
			show_simple_state(0x34, c.inst);
			show_oscillator_state(0x35, c.vibrato_start, c.vibrato_speed, c.vibrato_max_range);
			show_oscillator_state(0x36, c.tremolo_start, c.tremolo_speed, c.tremolo_range);
			show_simple_state(0x51, c.note_len);
			show_simple_state(0x52, c.note_style);
			show_simple_state(0x53, c.finetune);
			if (c.sub_count) {
				sprintf(&buf[0], "%d x%d", c.sub_start, c.sub_count);
				show_state(0x54, &buf[0]);
			} else {
				show_state(0x54, "No");
			}
			show_simple_state(0x55, c.vibrato_fadein);
			if (c.port_length)
				sprintf(&buf[0], "%02X %02X %02X", c.port_start, c.port_length, c.port_range);
			else
				strcpy(&buf[0], "Off");
			show_state(0x56, &buf[0]);
			reset_hdc(hdcState);
			EndPaint(hWnd, &ps);
			break;
		}
		case WM_DESTROY:
			closeMidiInDevice();
		break;
		default: return DefWindowProc(hWnd, uMsg, wParam, lParam);
		}
	} catch (Exception e) {
		handleError(e);
	}
	return 0;
}
