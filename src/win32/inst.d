module win32.inst;

import std.algorithm.comparison : max, min;
import std.experimental.logger;
import core.stdc.stdio;
import core.stdc.string;
import core.sys.windows.windows;
import core.sys.windows.mmsystem;
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

enum inst_list_template_num = 10;
enum inst_list_template_lower = 10;

__gshared private HWND samplist, instlist, insttest;
__gshared private int prev_chmask;
__gshared private ptrdiff_t selectedInstrument = 0;

private immutable control_desc[10] inst_list_controls = [
	{ "Static",  10, 10,100, 20, "Sample Directory:", 0, 0 },
	{ "Static",  13, 30,180, 20, "    Strt Loop Size", 1, 0 },
	{ "ListBox", 10, 50,180,-60, null, 2, WS_BORDER | WS_VSCROLL }, //Sample Directory ListBox

	{ "Static", 200, 10,100, 20, "Instrument Config:", 0, 0 },
	{ "Static", 203, 30,160, 20, "S#  ADSR/Gain Tuning", 3, 0 },
	{ "ListBox",200, 50,180,-60, null, 4, WS_BORDER | WS_VSCROLL }, //Instrument Config ListBox

	{ "Static", 400, 10,100, 20, "Instrument test:", 0, 0},
	{ "ebmused_insttest",400, 30,140,260, null, 3, 0 },
	{ "Static", 400, 300,100, 20, "MIDI In Device:", 0, 0},
	{ "ComboBox", 400, 320, 140, 200, null, IDC_MIDIINCOMBO, CBS_DROPDOWNLIST | WS_VSCROLL },
];
__gshared private window_template inst_list_template = {
	inst_list_template_num, inst_list_template_lower, 0, 0, &inst_list_controls[0]
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
	ptrdiff_t sel = SendMessageA(instlist, LB_GETCURSEL, 0, 0);
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
	c.samp = &samp[spc[inst_base + 6*c.inst]];

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

extern(Windows) LRESULT InstrumentsWndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	switch (uMsg) {
	case WM_CREATE: {
		prev_chmask = chmask;
		WPARAM fixed = cast(WPARAM)fixed_font();
		static char[40] buf;

		// HACK: For some reason when the compiler has optimization turned on, it doesn't initialize the values of inst_list_template correctly. So we'll reset them here. . .
		// NOTE: This may be due to a sprintf overflowing, as was the case with bgm_list_template when compiling in Visual Studio 2015
		inst_list_template.num = inst_list_template_num;
		inst_list_template.lower = inst_list_template_lower;

		create_controls(hWnd, &inst_list_template, lParam);

		SendDlgItemMessageA(hWnd, IDC_SAMPLIST_CAPTION, WM_SETFONT, fixed, 0);
		samplist = GetDlgItem(hWnd, IDC_SAMPLIST);
		SendMessageA(samplist, WM_SETFONT, fixed, 0);
		SendDlgItemMessageA(hWnd, IDC_INSTLIST_CAPTION, WM_SETFONT, fixed, 0);
		instlist = GetDlgItem(hWnd, IDC_INSTLIST);
		SendMessageA(instlist, WM_SETFONT, fixed, 0);

		// Insert a custom window procedure on the instrument list, so we
		// can see WM_KEYDOWN and WM_KEYUP messages for instrument testing.
		// (LBS_WANTKEYBOARDINPUT doesn't notify on WM_KEYUP)
		ListBoxWndProc = cast(WNDPROC)SetWindowLongPtrA(instlist, GWLP_WNDPROC,
			cast(LONG_PTR)&InstListWndProc);

		for (int i = 0; i < 128; i++) { //filling out the Sample Directory ListBox
			if (samp[i].data == null) continue;
			ushort *ptr = cast(ushort *)&spc[0x6C00 + 4*i];
			sprintf(&buf[0], "%02X: %04X %04X %4d", i,
				ptr[0], ptr[1], samp[i].length >> 4);
			SendMessageA(samplist, LB_ADDSTRING, 0, cast(LPARAM)&buf[0]);
		}

		ubyte *p = &valid_insts[0];
		for (int i = 0; i < 64; i++) { //filling out the Instrument Config ListBox
			ubyte *inst = &spc[inst_base + i*6];
			if (inst[4] == 0 && inst[5] == 0) continue;
			//            Index ADSR            Tuning
			sprintf(&buf[0], "%02X: %02X %02X %02X  %02X%02X",
				inst[0], inst[1], inst[2], inst[3], inst[4], inst[5]);
			SendMessageA(instlist, LB_ADDSTRING, 0, cast(LPARAM)&buf[0]);
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
		SendMessageA(samplist, LB_RESETCONTENT, 0, 0);
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
