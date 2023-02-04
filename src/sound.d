import core.stdc.stdio;
import core.stdc.stdlib;
import core.sys.windows.windows;
import core.sys.windows.mmsystem;
import std.string;
import id;
import ebmusv2;
import structs;
import misc;
import main;
import play;
import tracker;

extern(C):

__gshared int mixrate = 44100;
__gshared int bufsize = 2205;
__gshared int chmask = 255;
__gshared int timer_speed = 500;
__gshared HWAVEOUT hwo;
__gshared BOOL song_playing;

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

//DWORD cnt;

private void fill_buffer() nothrow {
	short[2]* bufp = cast(short[2]*)curbuf.lpData;

	if (hwndTracker != NULL)
		tracker_scrolled();

	int bytes_left = curbuf.dwBufferLength;
	while (bytes_left > 0) {
		if ((state.next_timer_tick -= timer_speed) < 0) {
			state.next_timer_tick += mixrate;
			if (!do_timer()) {
				curbuf.dwBufferLength -= bytes_left;
				break;
			}
		}

//		for (int blah = 0; blah < 50; blah++) {
		int left = 0, right = 0;
		channel_state *c = &state.chan[0];
		for (int cm = chmask; cm; c++, cm >>= 1) {
			if (!(cm & 1)) continue;

			if (c.samp_pos < 0) continue;

			int ipos = c.samp_pos >> 15;

			sample *s = c.samp;
			if (ipos > s.length) {
				printf("This can't happen. %d > %d\n", ipos, s.length);
				c.samp_pos = -1;
				continue;
			}

			if (c.note_release != 0) {
				if (c.inst_adsr1 & 0x1F)
					c.env_height *= c.decay_rate;
			} else {
				// release takes about 15ms (not dependent on tempo)
				c.env_height -= (32000 / 512.0) / mixrate;
				if (c.env_height < 0) {
					c.samp_pos = -1;
					continue;
				}
			}
			double volume = c.env_height / 128.0;
			assert(s.data);
			int s1 = s.data[ipos];
			s1 += (s.data[ipos+1] - s1) * (c.samp_pos & 0x7FFF) >> 15;

			left  += cast(int)(s1 * c.left_vol  * volume);
			right += cast(int)(s1 * c.right_vol * volume);

//			int sp = c.samp_pos;

			c.samp_pos += c.note_freq;
			if ((c.samp_pos >> 15) >= s.length) {
				if (s.loop_len)
					c.samp_pos -= s.loop_len << 15;
				else
					c.samp_pos = -1;
			}
//			if (blah != 1) c.samp_pos = sp;
		}
		if (left < -32768) left = -32768;
		else if (left > 32767) left = 32767;
		if (right < -32768) right = -32768;
		else if (right > 32767) right = 32767;
		(*bufp)[0] = cast(short)left;
		(*bufp)[1] = cast(short)right;
//		}
		bufp++;
		bytes_left -= 4;
	}
/*	{	MMTIME mmt;
		mmt.wType = TIME_BYTES;
		waveOutGetPosition(hwo, &mmt, sizeof(mmt));
		printf("%lu / %lu", mmt.u.cb + cnt, curbuf.dwBufferLength);
		for (int i = mmt.u.cb + cnt; i >= 0; i -= 500)
			putchar(219);
		putchar('\n');
	}*/
	waveOutWrite(hwo, curbuf, wh[0].sizeof);
	bufs_used++;
	curbuf = &wh[(curbuf - &wh[0]) ^ 1];
}

void winmm_message(UINT uMsg) nothrow {
	if (uMsg == MM_WOM_CLOSE)
		return;

	if (uMsg == MM_WOM_DONE) {
		bufs_used--;
//		cnt -= bufsize*4;
	}/* else
		cnt = 0;*/

	if (song_playing) {
		while (bufs_used < 2)
			fill_buffer();
	} else {
		if (bufs_used == 0)
			sound_uninit();
	}
}

extern(Windows) ptrdiff_t OptionsDlgProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam) nothrow {
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
