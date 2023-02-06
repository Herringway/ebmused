module win32.inst;

import std.algorithm.comparison : max, min;
import std.experimental.logger;
import core.stdc.stdio;
import core.stdc.string;
import core.sys.windows.commctrl;
import core.sys.windows.windows;
import core.sys.windows.mmsystem;
import std.exception;
import std.experimental.logger;
import std.string;
import std.utf;
import ebmusv2;
import win32.ctrltbl;
import main;
import structs;
import play;
import misc;
import win32.fonts;
import win32.misc;
import win32.sound;
import midi;
import brr;

enum IDC_SAMPLIST_CAPTION = 1;
enum IDC_SAMPLIST = 2;
enum IDC_INSTLIST_CAPTION = 3;
enum IDC_INSTLIST = 4;
enum IDC_MIDIINCOMBO = 5;

__gshared private HWND samplist, instlist, insttest;
__gshared private int prev_chmask;
__gshared private ptrdiff_t selectedInstrument = 0;

private immutable control_desc[] inst_list_controls = [
	{ "Static",  10, 10,100, 20, "Sample Directory:", 0, 0 },
	{ WC_LISTVIEW,10, 30,180,-60, null, IDC_SAMPLIST, WS_BORDER | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS  }, //Sample Directory ListBox

	{ "Static", 200, 10,100, 20, "Instrument Config:", 0, 0 },
	{ WC_LISTVIEW,200, 30,180,-60, null, IDC_INSTLIST, WS_BORDER | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS  }, //Instrument Config ListBox

	{ "Static", 400, 10,100, 20, "Instrument test:", 0, 0},
	{ "ebmused_insttest",400, 30,140,260, null, 3, 0 },
	{ "Static", 400, 300,100, 20, "MIDI In Device:", 0, 0},
	{ "ComboBox", 400, 320, 140, 200, null, IDC_MIDIINCOMBO, CBS_DROPDOWNLIST | WS_VSCROLL },
];
__gshared private window_template inst_list_template = {
	inst_list_controls.length, inst_list_controls.length, 0, 0, inst_list_controls
};

__gshared private ubyte[64] valid_insts;
__gshared private int[8] cnote;

int note_from_key(int key, bool shift) nothrow {
	if (key == VK_OEM_PERIOD) return 0x48; // continue
	if (key == VK_SPACE) return 0x49; // rest
	if (shift) {
		static char[22] drums = "1234567890\xBD\xBBQWERTYUIOP";
		char *p = strchr(&drums[0], key);
		if (p) return cast(int)(0x4A + (p-&drums[0]));
	} else {
		static char[17] low  = "ZSXDCVGBHNJM\xBCL";
		static char[17] high = "Q2W3ER5T6Y7UI9O0P";
		char *p = strchr(&low[0], key);
		if (p) return cast(int)(octave*12 + (p-&low[0]));
		p = strchr(&high[0], key);
		if (p) return cast(int)((octave+1)*12 + (p-&high[0]));
	}
	return -1;
}

static void draw_square(int note, HBRUSH brush) nothrow {
	HDC hdc = GetDC(insttest);
	int x = (note / 12 + 1) * 20;
	int y = (note % 12 + 1) * 20;
	RECT rc = { scale_x(x), scale_y(y), scale_x(x + 20), scale_y(y + 20) };
	FillRect(hdc, &rc, brush);
	ReleaseDC(insttest, hdc);
}

static void note_off(int note) nothrow {
	for (int ch = 0; ch < 8; ch++)
		if (state.chan[ch].samp_pos >= 0 && cnote[ch] == note)
			state.chan[ch].note_release = 0;
	draw_square(note, GetStockObject(WHITE_BRUSH));
}

static void note_on(int note, int velocity) nothrow {
	ptrdiff_t sel = assumeWontThrow(ListView_GetSelectionMark(instlist));
	if (sel < 0) return;
	int inst = valid_insts[sel];

	int ch;
	for (ch = 0; ch < 8; ch++)
		if (state.chan[ch].samp_pos < 0) break;
	if (ch == 8) return;
	cnote[ch] = note;
	channel_state *c = &state.chan[ch];
	set_inst(&state, c, inst);
	c.samp_pos = 0;
	c.samp = &samp[instruments[c.inst].sampleID];

	c.note_release = 1;
	c.env_height = 1;
	calc_freq(c, note << 8);
	c.left_vol = c.right_vol = cast(byte)min(max(velocity, 0), 127);
	draw_square(note, cast(HBRUSH)(COLOR_HIGHLIGHT + 1));
}

extern(Windows) private void MidiInProc(HMIDIIN handle, UINT wMsg, DWORD_PTR dwInstance, DWORD_PTR dwParam1, DWORD_PTR dwParam2) {
	if (wMsg == MIM_DATA)
	{
		ubyte
			eventType = (dwParam1 & 0xFF),
			param1 = (dwParam1 >> 8) & 0xFF,
			param2 = (dwParam1 >> 16) & 0xFF;

		if ((eventType & 0x80) && eventType < 0xF0) {	// If not a system exclusive MIDI message
			switch (eventType & 0xF0) {
			case 0xC0:	// Instrument change event
				SendMessageA(instlist, LB_SETCURSEL, param1, 0);
				break;
			case 0x90:	// Note On event
				if (param2 > 0)
					note_on(param1 + (octave - 4)*12, param2/2);
				else
					note_off(param1 + (octave - 4)*12);
				break;
			case 0x80:	// Note Off event
					note_off(param1 + (octave - 4)*12);
				break;
			default: break;
			}
		}
	}
}

__gshared private WNDPROC ListBoxWndProc;
// Custom window procedure for the instrument ListBox
extern(Windows) private LRESULT InstListWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	if (uMsg == WM_KEYDOWN && !(lParam & (1 << 30))) {
		int note = note_from_key(cast(int)wParam, false);
		if (note >= 0 && note < 0x48)
			note_on(note, 24);
	}
	if (uMsg == WM_KEYUP) {
		int note = note_from_key(cast(int)wParam, false);
		if (note >= 0 && note < 0x48)
			note_off(note);
	}
	// so pressing 0 or 2 doesn't move the selection around
	if (uMsg == WM_CHAR) return 0;
	return CallWindowProc(ListBoxWndProc, hWnd, uMsg, wParam, lParam);
}

extern(Windows) LRESULT InstTestWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	switch (uMsg) {
	case WM_CREATE: insttest = hWnd; break;
	case WM_ERASEBKGND: {
		DefWindowProcA(hWnd, uMsg, wParam, lParam);
		HDC hdc = cast(HDC)wParam;
		set_up_hdc(hdc);
		for (char o = '1'; o <= '6'; o++)
			TextOutA(hdc, scale_x(20 * (o - '0')), 0, &o, 1);
		for (int i = 0; i < 12; i++)
			TextOutA(hdc, 0, 20 * (i + 1), &"C C#D D#E F F#G G#A A#B "[2*i], 2);
		Rectangle(hdc, scale_x(19), scale_y(19), scale_x(140), scale_y(260));
		reset_hdc(hdc);
		return 1;
	}
	case WM_LBUTTONDOWN:
	case WM_LBUTTONUP: {
		int octave = LOWORD(lParam) / scale_x(20) - 1;
		if (octave < 0 || octave > 5) break;
		int note = HIWORD(lParam) / scale_y(20) - 1;
		if (note < 0 || note > 11) break;
		note += 12 * octave;
		if (uMsg == WM_LBUTTONDOWN) note_on(note, 24);
		else note_off(note);
		break;
	}
	default:
		return DefWindowProcA(hWnd, uMsg, wParam, lParam);
	}
	return 0;
}

immutable sampleDirectoryHeaders = [
	ListHeader("#", 30),
	ListHeader("Start", 40),
	ListHeader("Loop", 40),
	ListHeader("Size", 40),
];

immutable instrumentConfigHeaders = [
	ListHeader("S#", 30),
	ListHeader("ADSR/Gain", 80),
	ListHeader("Tuning", 50),
];

extern(Windows) LRESULT InstrumentsWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	switch (uMsg) {
	case WM_CREATE: {
		prev_chmask = chmask;
		WPARAM fixed = cast(WPARAM)fixed_font();
		static char[40] buf;

		create_controls(hWnd, &inst_list_template, lParam);

		SendDlgItemMessageA(hWnd, IDC_SAMPLIST_CAPTION, WM_SETFONT, fixed, 0);
		samplist = GetDlgItem(hWnd, IDC_SAMPLIST);
		SendMessageA(samplist, WM_SETFONT, fixed, 0);
		SendDlgItemMessageA(hWnd, IDC_INSTLIST_CAPTION, WM_SETFONT, fixed, 0);
		instlist = GetDlgItem(hWnd, IDC_INSTLIST);
		SendMessageA(instlist, WM_SETFONT, fixed, 0);
		assumeWontThrow(ListView_SetExtendedListViewStyle(instlist, LVS_EX_FULLROWSELECT));
		LVCOLUMNA lvc;
		lvc.mask = LVCF_TEXT | LVCF_WIDTH;
		foreach (idx, header; sampleDirectoryHeaders) {
			lvc.pszText = cast(char*)header.label.toStringz;
			lvc.cx = scale_x(header.width);
			ListView_InsertColumnA(samplist, cast(uint)idx, &lvc);
		}
		foreach (idx, header; instrumentConfigHeaders) {
			lvc.pszText = cast(char*)header.label.toStringz;
			lvc.cx = scale_x(header.width);
			ListView_InsertColumnA(instlist, cast(uint)idx, &lvc);
		}

		// Insert a custom window procedure on the instrument list, so we
		// can see WM_KEYDOWN and WM_KEYUP messages for instrument testing.
		// (LBS_WANTKEYBOARDINPUT doesn't notify on WM_KEYUP)
		ListBoxWndProc = cast(WNDPROC)SetWindowLongPtrA(instlist, GWLP_WNDPROC,
			cast(LONG_PTR)&InstListWndProc);

		LV_ITEMA lvi;
		lvi.iItem = assumeWontThrow(ListView_GetItemCount(samplist));
		for (int i = 0; i < 128; i++) { //filling out the Sample Directory ListBox
			if (samp[i].data == null) continue;
			lvi.mask = LVIF_TEXT | LVIF_PARAM;
			lvi.lParam = i;
			sprintf(&buf[0], "%02X", i);
			lvi.pszText = &buf[0];
			lvi.iSubItem = 0;
			ListView_InsertItemA(samplist, &lvi);

			lvi.mask = LVIF_TEXT;
			lvi.iSubItem = 1;
			sprintf(&buf[0], "%04X", sampleDirectory[i][0]);
			ListView_SetItemA(samplist, &lvi);

			lvi.iSubItem = 2;
			sprintf(&buf[0], "%04X", sampleDirectory[i][1]);
			ListView_SetItemA(samplist, &lvi);

			lvi.iSubItem = 3;
			sprintf(&buf[0], "%4d", samp[i].length >> 4);
			ListView_SetItemA(samplist, &lvi);

			lvi.iItem++;
		}

		ubyte *p = &valid_insts[0];
		lvi.iItem = assumeWontThrow(ListView_GetItemCount(instlist));
		for (int i = 0; i < 64; i++) { //filling out the Instrument Config ListBox
			const instrument = instruments[i];
			if (instrument.tuning == 0) continue;
			//            Index ADSR            Tuning

			lvi.mask = LVIF_TEXT | LVIF_PARAM;
			lvi.lParam = i;
			assumeWontThrow(sformat!"%02X\0"(buf[], instrument.sampleID));
			lvi.pszText = &buf[0];
			lvi.iSubItem = 0;
			ListView_InsertItemA(instlist, &lvi);

			lvi.mask = LVIF_TEXT;
			lvi.iSubItem = 1;
			assumeWontThrow(sformat!"%04X %02X\0"(buf[], instrument.adsrGain.adsr, instrument.adsrGain.gain));
			ListView_SetItemA(instlist, &lvi);

			lvi.iSubItem = 2;
			assumeWontThrow(sformat!"%04X\0"(buf[], instrument.tuning));
			ListView_SetItemA(instlist, &lvi);

			lvi.iItem++;
			*p++ = cast(ubyte)i;
		}
		if (sound_init())
			song_playing = true;
		timer_speed = 0;
		memset(&state.chan, 0, state.chan.sizeof);
		for (int ch = 0; ch < 8; ch++) {
			state.chan[ch].samp_pos = -1;
		}

		// Restore the previous instrument selection
		if (SendMessageA(instlist, LB_GETCOUNT, 0, 0) < selectedInstrument)
			selectedInstrument = 0;
		SendMessageA(instlist, LB_SETCURSEL, selectedInstrument, 0);
		SetFocus(instlist);

		// Populate the MIDI In Devices combo box
		HWND cb = GetDlgItem(hWnd, IDC_MIDIINCOMBO);
		SendMessageA(cb, CB_RESETCONTENT, 0, 0);
		SendMessageA(cb, CB_ADDSTRING, 0, cast(LPARAM)"None".ptr);

		MIDIINCAPSA inCaps;
		uint numDevices = midiInGetNumDevs();
		for (uint i=0; i<numDevices; i++) {
			if (midiInGetDevCapsA(i, &inCaps, MIDIINCAPSA.sizeof) == MMSYSERR_NOERROR)
				SendMessageA(cb, CB_ADDSTRING, 0, cast(LPARAM)&inCaps.szPname[0]);
		}

		SendMessageA(cb, CB_SETCURSEL, midiDevice + 1, 0);
		closeMidiInDevice();
		openMidiInDevice(cast(int)midiDevice, &MidiInProc);

		break;
	}
	case WM_COMMAND: {
		ushort id = LOWORD(wParam), action = HIWORD(wParam);
		switch (id) {
		case IDC_MIDIINCOMBO:
			if (action == CBN_SELCHANGE) {
				midiDevice = SendMessageA(cast(HWND)lParam, CB_GETCURSEL, 0, 0) - 1;
				closeMidiInDevice();
				openMidiInDevice(cast(int)midiDevice, &MidiInProc);
			} else if (action == CBN_CLOSEUP) {
				SetFocus(instlist);
			}
			break;
		default: break;
		}
		break;
	}
	case WM_ROM_CLOSED:
		assumeWontThrow(ListView_DeleteAllItems(samplist));
		SendMessageA(instlist, LB_RESETCONTENT, 0, 0);
		break;
	case WM_SIZE:
		move_controls(hWnd, &inst_list_template, lParam);
		break;
	case WM_DESTROY:
		song_playing = false;
		state = pattop_state;
		timer_speed = 500;
		chmask = prev_chmask;
		closeMidiInDevice();

		// Store the current selected instrument.
		selectedInstrument = SendMessageA(instlist, LB_GETCURSEL, 0, 0);
		break;
	default:
		return DefWindowProcA(hWnd, uMsg, wParam, lParam);
	}
	return 0;
}
