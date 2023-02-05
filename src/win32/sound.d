module win32.sound;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.sys.windows.windows;
import core.sys.windows.mmsystem;
import std.string;
import win32.id;
import ebmusv2;
import structs;
import win32.misc;
import main;
import win32.handles;
import play;
import win32.tracker;

__gshared HWAVEOUT hwo;

__gshared WAVEHDR[2] wh;
__gshared WAVEHDR* curbuf = &wh[0];
__gshared int bufs_used;

int sound_init() nothrow {
	WAVEFORMATEX wfx;

	if (hwo) {
		printf("Already playing!\n");
		return 0;
	}

	wfx.wFormatTag = WAVE_FORMAT_PCM;
	wfx.nChannels = 2;
	wfx.nSamplesPerSec = mixrate;
	wfx.nAvgBytesPerSec = mixrate*4;
	wfx.nBlockAlign = 4;
	wfx.wBitsPerSample = 16;
	wfx.cbSize = wfx.sizeof;

	int error = waveOutOpen(&hwo, WAVE_MAPPER, &wfx, cast(DWORD_PTR)hwndMain, 0, CALLBACK_WINDOW);
	if (error) {
	    char[60] buf = 0;
		sprintf(&buf[0], "waveOut device could not be opened (%d)", error);
		MessageBox2(buf.fromStringz, [], MB_ICONERROR);
		return 0;
	}

	wh[0].lpData = cast(char*)malloc(bufsize*4 * 2);
	wh[0].dwBufferLength = bufsize*4;
	wh[1].lpData = wh[0].lpData + bufsize*4;
	wh[1].dwBufferLength = bufsize*4;
	waveOutPrepareHeader(hwo, &wh[0], wh[0].sizeof);
	waveOutPrepareHeader(hwo, &wh[1], wh[1].sizeof);
	return 1;
}

private void sound_uninit() nothrow {
	waveOutUnprepareHeader(hwo, &wh[0], wh[0].sizeof);
	waveOutUnprepareHeader(hwo, &wh[1], wh[1].sizeof);
	waveOutClose(hwo);
	free(wh[0].lpData);
	hwo = NULL;
}

void winmm_message(uint uMsg) nothrow {
	if (uMsg == MM_WOM_CLOSE)
		return;

	if (uMsg == MM_WOM_DONE) {
		bufs_used--;
//		cnt -= bufsize*4;
	}/* else
		cnt = 0;*/

	if (song_playing) {
		while (bufs_used < 2) {
			if (hwndTracker != null)
				tracker_scrolled();
			auto buffer = (cast(short[2]*)curbuf.lpData)[0 .. curbuf.dwBufferLength];
			fill_buffer(buffer);
			waveOutWrite(hwo, curbuf, wh[0].sizeof);
			bufs_used++;
			curbuf = &wh[(curbuf - &wh[0]) ^ 1];
		}
	} else {
		if (bufs_used == 0)
			sound_uninit();
	}
}

extern(Windows) ptrdiff_t OptionsDlgProc(HWND hWnd, uint uMsg, WPARAM wParam, LPARAM lParam) nothrow {
	switch (uMsg) {
	case WM_INITDIALOG:
		SetDlgItemInt(hWnd, IDC_RATE, mixrate, FALSE);
		SetDlgItemInt(hWnd, IDC_BUFSIZE, bufsize, FALSE);
		song_playing = FALSE;
		break;
	case WM_COMMAND:
		int new_rate, new_bufsize;
		switch (LOWORD(wParam)) {
		case IDOK:
			new_rate = GetDlgItemInt(hWnd, IDC_RATE, NULL, FALSE);
			new_bufsize = GetDlgItemInt(hWnd, IDC_BUFSIZE, NULL, FALSE);
			if (new_rate < 8000) new_rate = 8000;
			if (new_rate >= 128000) new_rate = 128000;
			if (new_bufsize < new_rate/100) new_bufsize = new_rate/100;
			if (new_bufsize > new_rate) new_bufsize = new_rate;

			mixrate = new_rate;
			bufsize = new_bufsize;
			goto case;
		case IDCANCEL:
			EndDialog(hWnd, LOWORD(wParam));
			break;
		default: break;
		}
		goto default;
	default: return FALSE;
	}
	return TRUE;
}
